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

    return "DryRun"
}

try {
    Write-Host "========== replication-run.ps1 (Azure Migrate / physical-aware) =========="

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

    Import-Module Az.Accounts,Az.Resources,Az.Network,Az.Migrate -ErrorAction Stop

    $csvRows = Import-Csv -Path $InputCsv
    if (-not $csvRows -or $csvRows.Count -eq 0) {
        throw "Input CSV is empty: $InputCsv"
    }

    $discoveryJson = Get-Content -Path $DiscoveryFile -Raw
    $discoveredMachines = $null
    try {
        $discoveredMachines = $discoveryJson | ConvertFrom-Json
    } catch {
        Write-Warning "Discovery file is not valid JSON or not used. Continuing without it."
    }

    $initializedInfra = @{}

    foreach ($row in $csvRows) {

        $migrationType          = Get-Field $row @("MigrationType","Type")
        $migrationTypeNorm      = $migrationType.ToLowerInvariant()

        # Project (Azure Migrate) details (using your Src* columns)
        $projectSubscriptionId  = Get-Field $row @("SrcSubscriptionId","ProjectSubscriptionId","SubscriptionId")
        $projectRG              = Get-Field $row @("SrcResourceGroup","MigrationProjectRG","MigrationProjectResourceGroup","ProjectResourceGroup")
        $projectName            = Get-Field $row @("MigrationProjectName","ProjectName","AzMigrateProjectName")

        # Target details (Tgt* columns)
        $targetSubscriptionId   = Get-Field $row @("TgtSubscriptionId","TargetSubscriptionId")
        if (-not $targetSubscriptionId) { $targetSubscriptionId = $projectSubscriptionId }

        $targetRGName           = Get-Field $row @("TgtResourceGroup","TargetResourceGroup","TargetRG","TargetResourceGroupName")
        $targetVNetName         = Get-Field $row @("TgtVNet","TargetVNetName","TargetVNet")
        $targetSubnetName       = Get-Field $row @("TgtSubnet","TargetSubnetName","TargetSubnet")
        $targetRegion           = Get-Field $row @("TgtLocation","TargetRegion","Region")

        $bootDiagStorageName    = Get-Field $row @("BootDiagStorageAccountName")
        $bootDiagStorageRG      = Get-Field $row @("BootDiagStorageAccountRG")

        $csvVmName              = Get-Field $row @("VMName","MachineName","SourceVMName")
        $targetVMName           = Get-Field $row @("TargetVMName","VMName","MachineName")
        if (-not $targetVMName) { $targetVMName = $csvVmName }

        if (-not $csvVmName) {
            Write-Warning "Row missing VMName/MachineName. Skipping row: $($row | Out-String)"
            continue
        }

        Write-Host ""
        Write-Host "----- Processing row for VM: $csvVmName -----"
        Write-Host "  MigrationType : $migrationType"

        # PHYSICAL: for now, we log and skip automatic replication
        if ($migrationTypeNorm -eq "physical") {
            Write-Warning "  [$csvVmName] MigrationType=Physical. Azure Migrate PowerShell does not support starting physical replication."
            Write-Warning "  [$csvVmName] Replication must be configured via Azure Migrate/ASR portal (vault: ZTM-POC-MigrateVault-1163665249)."
            continue
        }

        # For future: support VMware via Az.Migrate
        if ($migrationTypeNorm -ne "vmware") {
            Write-Warning "  [$csvVmName] Unsupported MigrationType '$migrationType'. Currently only Physical (skipped) and VMware (Az.Migrate) are modeled."
            continue
        }

        # ---------- VMware path via Azure Migrate ----------

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

        $targetRGId     = "/subscriptions/$targetSubscriptionId/resourceGroups/$targetRGName"
        $targetNetworkId = "/subscriptions/$targetSubscriptionId/resourceGroups/$targetRGName/providers/Microsoft.Network/virtualNetworks/$targetVNetName"

        Write-Host "  Project       : $projectName (RG: $projectRG, Region: $targetRegion)"
        Write-Host "  Target RG     : $targetRGName"
        Write-Host "  Target VNet   : $targetNetworkId"
        Write-Host "  Target Subnet : $targetSubnetName"
        Write-Host "  Target VMName : $targetVMName"

        # VMware discovered server lookup
        $discServer = Get-AzMigrateDiscoveredServer `
            -ProjectName       $projectName `
            -ResourceGroupName $projectRG `
            -DisplayName       $csvVmName `
            -MachineType       "VMware" `
            -ErrorAction       SilentlyContinue

        if (-not $discServer) {
            Write-Warning "  Could not find VMware discovered server for $csvVmName in Azure Migrate project $projectName. Skipping."
            continue
        }

        $machineId = $discServer.Id
        $osDiskId  = $discServer.OsDiskId

        if (-not $machineId) {
            Write-Warning "  Discovered server for $csvVmName has no MachineId. Skipping."
            continue
        }
        if (-not $osDiskId) {
            Write-Warning "  Discovered server for $csvVmName has no OsDiskId. Skipping."
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
                Write-Host "  Enabling replication for $csvVmName via Azure Migrate (VMware)..."

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
