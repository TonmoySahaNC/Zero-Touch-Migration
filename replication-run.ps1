param(
    [string]$TokenFile    = ".\token.enc",
    [Parameter(Mandatory = $true)][string]$DiscoveryFile,
    [string]$InputCsv     = ".\migration_input.csv",
    [string]$Mode         = ""
)

function Get-Field {
    param(
        [object]$Row,
        [string[]]$Names
    )

    foreach ($n in $Names) {
        if ($Row.PSObject.Properties.Name -contains $n) {
            $val = $Row.$n
            if ($null -ne $val) {
                $s = $val.ToString().Trim()
                if ($s -ne "") {
                    return $s
                }
            }
        }
    }
    return ""
}

function Resolve-Mode {
    param(
        [string]$ModeParam
    )

    if ($ModeParam -and $ModeParam.Trim() -ne "") {
        return $ModeParam.Trim()
    }

    if ($env:MIG_MODE -and $env:MIG_MODE.Trim() -ne "") {
        return $env:MIG_MODE.Trim()
    }

    # default
    return "DryRun"
}

# Placeholder for data sync hook if you later want DB/file sync before cutover
function Invoke-PreCutoverDataSync {
    param(
        [string]$MachineName,
        [object]$CsvRow
    )

    # Implement DMS / AzCopy / File Sync etc. here if needed later.
    Write-Host "[INFO] (placeholder) Pre-cutover data sync for $MachineName"
}

try {
    Write-Host "========== replication-run.ps1 (Azure Migrate) =========="

    if (-not (Test-Path $DiscoveryFile)) {
        throw "Discovery file not found: $DiscoveryFile"
    }
    if (-not (Test-Path $InputCsv)) {
        throw "Input CSV not found: $InputCsv"
    }

    $effectiveMode      = Resolve-Mode -ModeParam $Mode
    $effectiveModeUpper = $effectiveMode.ToUpperInvariant()

    Write-Host ("Mode          : " + $effectiveModeUpper)
    Write-Host ("DiscoveryFile : " + $DiscoveryFile)
    Write-Host ("InputCsv      : " + $InputCsv)

    # Import Azure modules
    Import-Module Az.Accounts,Az.Resources,Az.Network,Az.Migrate -ErrorAction Stop

    # Read CSV
    $csvRows = Import-Csv -Path $InputCsv
    if (-not $csvRows -or $csvRows.Count -eq 0) {
        throw "Input CSV is empty: $InputCsv"
    }

    # Read discovery JSON if you want to log/use later (currently not strictly needed)
    $discoveryJson       = Get-Content -Path $DiscoveryFile -Raw
    $discoveredMachines  = $null
    try {
        $discoveredMachines = $discoveryJson | ConvertFrom-Json
    } catch {
        Write-Warning "Discovery file is not valid JSON or not used. Continuing without it."
    }

    # Track infra initialization per project+region so we call Initialize only once
    $initializedInfra = @{}

    foreach ($row in $csvRows) {

        # ----- MAP CSV COLUMNS (using your confirmed headers) -----

        # Migration type – you use "Physical"
        $migrationType          = Get-Field $row @("MigrationType","Type")

        # Azure Migrate project lives under "source" subscription/RG
        $projectSubscriptionId  = Get-Field $row @("SrcSubscriptionId","ProjectSubscriptionId","SubscriptionId")
        $projectRG              = Get-Field $row @(
            "SrcResourceGroup",
            "MigrationProjectRG",
            "MigrationProjectResourceGroup",
            "ProjectResourceGroup"
        )
        $projectName            = Get-Field $row @(
            "MigrationProjectName",
            "ProjectName",
            "AzMigrateProjectName"
        )

        # Target subscription / RG / networking (where replicated VM will land)
        $targetSubscriptionId   = Get-Field $row @("TgtSubscriptionId","TargetSubscriptionId")
        if (-not $targetSubscriptionId) {
            # fall back to project subscription if target sub not explicitly given
            $targetSubscriptionId = $projectSubscriptionId
        }

        $targetRGName           = Get-Field $row @(
            "TgtResourceGroup",
            "TargetResourceGroup",
            "TargetRG",
            "TargetResourceGroupName"
        )

        $targetVNetName         = Get-Field $row @(
            "TgtVNet",
            "TargetVNetName",
            "TargetVNet"
        )

        $targetSubnetName       = Get-Field $row @(
            "TgtSubnet",
            "TargetSubnetName",
            "TargetSubnet"
        )

        # Region for target VM
        $targetRegion           = Get-Field $row @(
            "TgtLocation",
            "TargetRegion",
            "Region"
        )

        # Boot diag storage (not used by Azure Migrate, kept for future manual VM creation if needed)
        $bootDiagStorageName    = Get-Field $row @("BootDiagStorageAccountName")
        $bootDiagStorageRG      = Get-Field $row @("BootDiagStorageAccountRG")

        # VM names
        $csvVmName              = Get-Field $row @("VMName","MachineName","SourceVMName")
        $targetVMName           = Get-Field $row @("TargetVMName","VMName","MachineName")
        if (-not $targetVMName) { $targetVMName = $csvVmName }

        if (-not $csvVmName) {
            Write-Warning "Row missing VMName/MachineName. Skipping row: $($row | Out-String)"
            continue
        }

        Write-Host ""
        Write-Host "----- Processing row for VM: $csvVmName -----"

        # ----- Validate project info -----
        if ($projectSubscriptionId) {
            Write-Host ("  Setting context to Project Subscription: " + $projectSubscriptionId)
            Set-AzContext -SubscriptionId $projectSubscriptionId -ErrorAction Stop | Out-Null
        }

        if (-not $projectRG -or -not $projectName) {
            Write-Warning "  Project RG / Project Name not set for $csvVmName. Skipping."
            continue
        }

        if (-not $targetSubscriptionId -or -not $targetRGName -or -not $targetVNetName -or -not $targetSubnetName -or -not $targetRegion) {
            Write-Warning "  Target subscription / RG / VNet / Subnet / Region not fully set for $csvVmName. Skipping."
            continue
        }

        # ----- Get or create Azure Migrate project -----
        $migrateProject = Get-AzMigrateProject -Name $projectName -ResourceGroupName $projectRG -ErrorAction SilentlyContinue
        if (-not $migrateProject) {
            if ($effectiveModeUpper -eq "DRYRUN") {
                Write-Warning "  [DryRun] Azure Migrate project $projectName in RG $projectRG not found. Would create it."
            }
            else {
                Write-Host "  Creating Azure Migrate project $projectName in RG $projectRG..."
                $migrateProject = New-AzMigrateProject -Name $projectName -ResourceGroupName $projectRG -Location $targetRegion -ErrorAction Stop
            }
        }
        else {
            Write-Host "  Found Azure Migrate project: $($migrateProject.Name)"
        }

        # ----- Initialize replication infrastructure once per project+region -----
        $infraKey = "$($projectRG)|$($projectName)|$($targetRegion)"
        if (-not $initializedInfra.ContainsKey($infraKey)) {
            if ($effectiveModeUpper -eq "DRYRUN") {
                Write-Host "  [DryRun] Would initialize replication infra for project $projectName ($targetRegion)."
            }
            else {
                Write-Host "  Initializing replication infra for project $projectName ($targetRegion)..."
                Initialize-AzMigrateReplicationInfrastructure `
                    -ResourceGroupName $projectRG `
                    -ProjectName       $projectName `
                    -Scenario          "agentlessVMware" `
                    -TargetRegion      $targetRegion `
                    -ErrorAction       Stop
            }
            $initializedInfra[$infraKey] = $true
        }

        # ----- Build target RG + VNet IDs -----
        $targetRGId = "/subscriptions/$targetSubscriptionId/resourceGroups/$targetRGName"

        # Build full VNet ARM ID from VNet name
        $targetNetworkId = "/subscriptions/$targetSubscriptionId/resourceGroups/$targetRGName/providers/Microsoft.Network/virtualNetworks/$targetVNetName"

        Write-Host "  MigrationType : $migrationType"
        Write-Host "  Project       : $projectName (RG: $projectRG, Region: $targetRegion)"
        Write-Host "  Target RG     : $targetRGName"
        Write-Host "  Target VNet   : $targetNetworkId"
        Write-Host "  Target Subnet : $targetSubnetName"
        Write-Host "  Target VMName : $targetVMName"

        # ----- Get discovered server from Azure Migrate -----
        $discServer = Get-AzMigrateDiscoveredServer `
            -ProjectName       $projectName `
            -ResourceGroupName $projectRG `
            -DisplayName       $csvVmName `
            -ErrorAction       SilentlyContinue

        if (-not $discServer) {
            Write-Warning "  Could not find discovered server for $csvVmName in Azure Migrate project $projectName. Skipping."
            continue
        }

        $machineId = $discServer.Id
        $osDiskId  = $discServer.OsDiskId

        if (-not $machineId) {
            Write-Warning "  Discovered server for $csvVmName has no MachineId. Skipping."
            continue
        }
        if (-not $osDiskId) {
            Write-Warning "  Discovered server for $csvVmName has no OsDiskId. You may need to customize disk mapping. Skipping."
            continue
        }

        switch ($effectiveModeUpper) {
            "DRYRUN" {
                Write-Host "  [DryRun] Would call New-AzMigrateServerReplication with:"
                Write-Host "     MachineId             = $machineId"
                Write-Host "     TargetResourceGroupId = $targetRGId"
                Write-Host "     TargetNetworkId       = $targetNetworkId"
                Write-Host "     TargetSubnetName      = $targetSubnetName"
                Write-Host "     TargetVMName          = $targetVMName"
                Write-Host "     DiskType              = StandardSSD_LRS"
                Write-Host "     OSDiskId              = $osDiskId"
                Write-Host "     TargetRegion          = $targetRegion"
                Write-Host "     LicenseType           = NoLicenseType"
            }
            "REPLICATE" {
                Write-Host "  Enabling replication for $csvVmName via Azure Migrate..."

                $job = New-AzMigrateServerReplication `
                    -MachineId             $machineId `
                    -TargetResourceGroupId $targetRGId `
                    -TargetNetworkId       $targetNetworkId `
                    -TargetSubnetName      $targetSubnetName `
                    -TargetVMName          $targetVMName `
                    -DiskType              "StandardSSD_LRS" `
                    -OSDiskID              $osDiskId `
                    -TargetRegion          $targetRegion `
                    -LicenseType           "NoLicenseType" `
                    -ErrorAction           Stop

                Write-Host "  Replication job triggered. Job name: $($job.Name)"
                Write-Host "  Monitor with: Get-AzMigrateServerReplication -ProjectName $projectName -ResourceGroupName $projectRG"
            }
            default {
                Write-Warning "  Unsupported Mode '$effectiveModeUpper'. Only DryRun / Replicate implemented."
            }
        }
    }

    Write-Host ""
    Write-Host "===== replication-run.ps1 complete ====="
}
catch {
    Write-Error ("Fatal error in replication-run: " + $_.ToString())
    exit 1
}
