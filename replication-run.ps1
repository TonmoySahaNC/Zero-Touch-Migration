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
                if ($s -ne "") { return $s }
            }
        }
    }
    return ""
}

function Resolve-Mode {
    param([string]$ModeParam)

    if ($ModeParam -and $ModeParam.Trim() -ne "") {
        return $ModeParam.Trim()
    }

    if ($env:MIG_MODE -and $env:MIG_MODE.Trim() -ne "") {
        return $env:MIG_MODE.Trim()
    }

    # default
    return "DryRun"
}

# Placeholder so you can hook in DB / file data sync right before cutover if you want
function Invoke-PreCutoverDataSync {
    param(
        [string]$MachineName,
        [object]$CsvRow
    )

    # TODO: Implement DB / file sync here (DMS, AzCopy, etc.) as per your app.
    # This is only called if you wire it in for a Cutover-style run.
    Write-Host "[INFO] (placeholder) Pre-cutover data sync for $MachineName (implement as needed)"
}

try {
    Write-Host "========== replication-run.ps1 (Azure Migrate) =========="

    if (-not (Test-Path $DiscoveryFile)) {
        throw "Discovery file not found: $DiscoveryFile"
    }
    if (-not (Test-Path $InputCsv)) {
        throw "Input CSV not found: $InputCsv"
    }

    $effectiveMode = Resolve-Mode -ModeParam $Mode
    $effectiveModeUpper = $effectiveMode.ToUpperInvariant()
    Write-Host ("Mode          : " + $effectiveModeUpper)
    Write-Host ("DiscoveryFile : " + $DiscoveryFile)
    Write-Host ("InputCsv      : " + $InputCsv)

    # Import modules (Az should already be installed in the GitHub workflow)
    Import-Module Az.Accounts,Az.Resources,Az.Network,Az.Migrate -ErrorAction Stop

    # Read CSV
    $csvRows = Import-Csv -Path $InputCsv
    if (-not $csvRows -or $csvRows.Count -eq 0) {
        throw "Input CSV is empty."
    }

    # Read discovery JSON (array of machines)
    $discoveryJson = Get-Content -Path $DiscoveryFile -Raw
    $discoveredMachines = $discoveryJson | ConvertFrom-Json
    if (-not $discoveredMachines) {
        throw "Discovery file appears empty / invalid JSON: $DiscoveryFile"
    }

    # For fast lookup by machine name
    $discoveredByName = @{}
    foreach ($m in $discoveredMachines) {
        if ($null -ne $m.MachineName -and $m.MachineName.ToString().Trim() -ne "") {
            $discoveredByName[$m.MachineName.ToString().Trim()] = $m
        }
        elseif ($null -ne $m.VMName -and $m.VMName.ToString().Trim() -ne "") {
            $discoveredByName[$m.VMName.ToString().Trim()] = $m
        }
    }

    # Track initialization of replication infra so we only call it once per project+region
    $initializedInfra = @{}

    foreach ($row in $csvRows) {

        $migrationType       = Get-Field $row @("MigrationType","Type")
        $subscriptionId      = Get-Field $row @("TargetSubscriptionId","SubscriptionId")
        $projectRG           = Get-Field $row @("MigrationProjectRG","MigrationProjectResourceGroup","ProjectResourceGroup")
        $projectName         = Get-Field $row @("MigrationProjectName","ProjectName","AzMigrateProjectName")
        $targetRegion        = Get-Field $row @("TargetRegion","Region")
        $targetRGName        = Get-Field $row @("TargetResourceGroup","TargetRG","TargetResourceGroupName")
        $targetNetworkId     = Get-Field $row @("TargetNetworkId","TargetVNetId")
        $targetSubnetName    = Get-Field $row @("TargetSubnetName","TargetSubnet")
        $csvVmName           = Get-Field $row @("VMName","MachineName","SourceVMName")
        $targetVMName        = Get-Field $row @("TargetVMName","VMName","MachineName")
        if (-not $targetVMName) { $targetVMName = $csvVmName }

        if (-not $csvVmName) {
            Write-Warning "Row missing VMName/MachineName. Skipping row: $($row | Out-String)"
            continue
        }

        Write-Host ""
        Write-Host "----- Processing row for VM: $csvVmName -----"
        Write-Host "  MigrationType : $migrationType"
        Write-Host "  Project       : $projectName (RG: $projectRG, Region: $targetRegion)"
        Write-Host "  Target RG     : $targetRGName"
        Write-Host "  Target VNet   : $targetNetworkId"
        Write-Host "  Target Subnet : $targetSubnetName"
        Write-Host "  Target VMName : $targetVMName"

        if ($subscriptionId) {
            Write-Host ("  Setting context to Subscription: " + $subscriptionId)
            Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null
        }

        if (-not $projectRG -or -not $projectName) {
            Write-Warning "  Project RG / Project Name not set for $csvVmName. Skipping."
            continue
        }

        if (-not $targetRGName -or -not $targetNetworkId -or -not $targetSubnetName -or -not $targetRegion) {
            Write-Warning "  Target settings incomplete for $csvVmName. Skipping."
            continue
        }

        # Get Azure Migrate project
        $migrateProject = Get-AzMigrateProject -Name $projectName -ResourceGroupName $projectRG -ErrorAction SilentlyContinue
        if (-not $migrateProject) {
            if ($effectiveModeUpper -eq "DRYRUN") {
                Write-Warning "  [DryRun] Azure Migrate project $projectName in RG $projectRG not found. Would create it."
            } else {
                Write-Host "  Creating Azure Migrate project $projectName in RG $projectRG..."
                $migrateProject = New-AzMigrateProject -Name $projectName -ResourceGroupName $projectRG -Location $targetRegion -ErrorAction Stop
            }
        } else {
            Write-Host "  Found Azure Migrate project: $($migrateProject.Name)"
        }

        # Initialize replication infra once per project+region
        $infraKey = "$($projectRG)|$($projectName)|$($targetRegion)"
        if (-not $initializedInfra.ContainsKey($infraKey)) {
            if ($effectiveModeUpper -eq "DRYRUN") {
                Write-Host "  [DryRun] Would initialize replication infra for project $projectName ($targetRegion)."
            } else {
                Write-Host "  Initializing replication infra for project $projectName ($targetRegion)..."
                Initialize-AzMigrateReplicationInfrastructure `
                    -ResourceGroupName $projectRG `
                    -ProjectName       $projectName `
                    -Scenario          "AgentlessVMware" `
                    -TargetRegion      $targetRegion `
                    -ErrorAction       Stop
            }
            $initializedInfra[$infraKey] = $true
        }

        # Map VMName from csv to discovered machine
        $disc = $null
        if ($discoveredByName.ContainsKey($csvVmName)) {
            $disc = $discoveredByName[$csvVmName]
        } else {
            Write-Warning "  Could not find discovered machine for $csvVmName in $DiscoveryFile. Skipping."
            continue
        }

        # We expect properties like Id and OsDiskId on the discovered object.
        $machineId = $disc.Id
        $osDiskId  = $disc.OsDiskId

        if (-not $machineId) {
            Write-Warning "  Discovered server for $csvVmName doesn't have Machine Id. Skipping."
            continue
        }

        if (-not $osDiskId) {
            # You can refine this to pick OS disk from $disc.Disks collection if present.
            Write-Warning "  Discovered server for $csvVmName doesn't have OSDiskId. You may need to customize this mapping."
        }

        # Build target RG ARM ID
        $ctx = Get-AzContext
        $subForRG = $subscriptionId
        if (-not $subForRG) { $subForRG = $ctx.Subscription.Id }
        $targetRGId = "/subscriptions/$subForRG/resourceGroups/$targetRGName"

        switch ($effectiveModeUpper) {
            "DRYRUN" {
                Write-Host "  [DryRun] Would call New-AzMigrateServerReplication with:"
                Write-Host "     MachineId            = $machineId"
                Write-Host "     TargetResourceGroupId= $targetRGId"
                Write-Host "     TargetNetworkId      = $targetNetworkId"
                Write-Host "     TargetSubnetName     = $targetSubnetName"
                Write-Host "     TargetVMName         = $targetVMName"
                Write-Host "     TargetRegion         = $targetRegion"
                Write-Host "     DiskType             = StandardSSD_LRS"
                Write-Host "     OSDiskID             = $osDiskId"
            }
            "REPLICATE" {
                Write-Host "  Enabling replication for $csvVmName via Azure Migrate..."

                $job = New-AzMigrateServerReplication `
                    -ResourceGroupName     $projectRG `
                    -ProjectName           $projectName `
                    -MachineId             $machineId `
                    -TargetResourceGroupId $targetRGId `
                    -TargetNetworkId       $targetNetworkId `
                    -TargetSubnetName      $targetSubnetName `
                    -TargetVMName          $targetVMName `
                    -DiskType              "StandardSSD_LRS" `
                    -OSDiskID              $osDiskId `
                    -TargetRegion          $targetRegion `
                    -ErrorAction           Stop

                Write-Host "  Replication job triggered. Job name: $($job.Name)"
                Write-Host "  Monitor with: Get-AzMigrateServerReplication -ProjectName $projectName -ResourceGroupName $projectRG"
            }
            default {
                Write-Warning "  Unsupported Mode '$effectiveModeUpper' for now. Only DryRun / Replicate implemented."
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
