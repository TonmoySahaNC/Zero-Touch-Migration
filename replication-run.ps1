param(
    [Parameter(Mandatory = $true)]
    [string]$InputCsv,                        # e.g. .\migration_input.csv

    [string]$Mode = "Replicate"               # or "DryRun"
)

function Resolve-Mode {
    param([string]$ModeParam)

    if ($ModeParam -and $ModeParam.Trim() -ne "") { return $ModeParam.Trim() }
    if ($env:MIG_MODE -and $env:MIG_MODE.Trim() -ne "") { return $env:MIG_MODE.Trim() }
    return "Replicate"
}

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

try {
    $modeFinal = Resolve-Mode $Mode
    $modeUpper = $modeFinal.ToUpperInvariant()

    Write-Host "========== replication-run.ps1 (using az migrate local) =========="
    Write-Host "Mode     : $modeUpper"
    Write-Host "InputCsv : $InputCsv"

    if (-not (Test-Path $InputCsv)) {
        throw "Input CSV not found: $InputCsv"
    }

    # Make sure az CLI is available
    $az = Get-Command az -ErrorAction SilentlyContinue
    if (-not $az) {
        throw "Azure CLI 'az' not found in PATH. Install Azure CLI and try again."
    }

    # Read CSV
    $rows = Import-Csv -Path $InputCsv
    if (-not $rows -or $rows.Count -eq 0) {
        throw "Input CSV is empty: $InputCsv"
    }

    # This flag ensures we only call 'az migrate local replication init' once per project
    $initializedProjects = @{}

    foreach ($row in $rows) {
        $migrationType = Get-Field $row @("MigrationType","Type")
        $mtNorm        = ($migrationType ?? "").ToLowerInvariant()

        $vmName        = Get-Field $row @("VMName","MachineName","ServerName")
        if (-not $vmName) {
            Write-Warning "Row missing VMName/MachineName. Skipping row:`n$($row | Out-String)"
            continue
        }

        Write-Host ""
        Write-Host "----- Processing: $vmName -----"
        Write-Host "  MigrationType : $migrationType"

        # Common project info
        $projRG    = Get-Field $row @("SrcResourceGroup","ProjectRg","MigrationProjectRG")
        $projName  = Get-Field $row @("MigrationProjectName","ProjectName","AzMigrateProjectName")
        if (-not $projRG -or -not $projName) {
            Write-Warning "  Project RG / Name not set in CSV. Skipping $vmName."
            continue
        }

        # Target info
        $tgtSub    = Get-Field $row @("TgtSubscriptionId","TargetSubscriptionId")
        $tgtRG     = Get-Field $row @("TgtResourceGroup","TargetResourceGroup","TargetRG")
        $tgtVNet   = Get-Field $row @("TgtVNet","TargetVNet","TargetVNetName")
        $tgtSubnet = Get-Field $row @("TgtSubnet","TargetSubnet","TargetSubnetName")
        $tgtRegion = Get-Field $row @("TgtLocation","TargetRegion","Region")

        $targetVM  = Get-Field $row @("TargetVMName","VMName")
        if (-not $targetVM) { $targetVM = $vmName }

        # Storage account for cache/log/boot diag
        $bootDiagSAName = Get-Field $row @("BootDiagStorageAccountName","LogStorageAccountName")
        $bootDiagSARG   = Get-Field $row @("BootDiagStorageAccountRG","LogStorageAccountRG")

        if (-not $tgtSub -or -not $tgtRG -or -not $tgtVNet -or -not $tgtSubnet -or -not $tgtRegion) {
            Write-Warning "  Target Subscription/RG/VNet/Subnet/Region not fully set in CSV. Skipping $vmName."
            continue
        }

        if (-not $bootDiagSAName -or -not $bootDiagSARG) {
            Write-Warning "  BootDiag/Log Storage Account name/RG not set for $vmName. Skipping."
            continue
        }

        $logStorageId = "/subscriptions/$tgtSub/resourceGroups/$bootDiagSARG/providers/Microsoft.Storage/storageAccounts/$bootDiagSAName"

        # =============================== PHYSICAL ===============================
        if ($mtNorm -eq "physical") {

            Write-Host "  [PHYSICAL] Using az migrate local for Azure Migrate project '$projName' in RG '$projRG'."

            # 1) Confirm the server is discovered
            $azArgs = @(
                "migrate","local","get-discovered-server",
                "--resource-group",$projRG,
                "--project-name",$projName,
                "--display-name",$vmName,
                "--output","json"
            )

            $discJson = az @azArgs 2>$null
            if (-not $discJson) {
                Write-Warning "  [PHYSICAL] No discovered server found in Azure Migrate for '$vmName'. Skipping."
                continue
            }

            $discObjs = $null
            try {
                $discObjs = $discJson | ConvertFrom-Json
            } catch {
                Write-Warning "  [PHYSICAL] Failed to parse discovery JSON for '$vmName'. Raw output:`n$discJson"
                continue
            }

            if ($discObjs -is [System.Array]) {
                $disc = $discObjs | Select-Object -First 1
            } else {
                $disc = $discObjs
            }

            if (-not $disc) {
                Write-Warning "  [PHYSICAL] No discovered object for '$vmName' after parsing. Skipping."
                continue
            }

            Write-Host "  [PHYSICAL] Found discovered server in Azure Migrate: $($disc.machineName)"

            # 2) Initialize replication infra once per Project (optional, AzLocal scenario)
            $projectKey = "$projRG|$projName"
            if (-not $initializedProjects.ContainsKey($projectKey)) {

                # TODO: Set your appliance name from Azure Migrate portal (Servers -> Migration tools -> Appliances)
                $sourceApplianceName = "<YOUR_APPLIANCE_NAME>"    # e.g. "migrateapplia"
                $targetApplianceName = "<YOUR_TARGET_APPLIANCE>"  # often same as source for on-prem->Azure

                if ($modeUpper -eq "DRYRUN") {
                    Write-Host "  [PHYSICAL][DryRun] Would initialize replication infra with:"
                    Write-Host "     az migrate local replication init --resource-group $projRG --project-name $projName `"
                    Write-Host "        --source-appliance-name $sourceApplianceName --target-appliance-name $targetApplianceName `"
                    Write-Host "        --cache-storage-account-id $logStorageId"
                }
                else {
                    Write-Host "  [PHYSICAL] Initializing az migrate local replication infra for project '$projName' (one-time)..."

                    $initArgs = @(
                        "migrate","local","replication","init",
                        "--resource-group",$projRG,
                        "--project-name",$projName,
                        "--source-appliance-name",$sourceApplianceName,
                        "--target-appliance-name",$targetApplianceName,
                        "--cache-storage-account-id",$logStorageId
                    )

                    try {
                        az @initArgs | Out-Null
                        Write-Host "  [PHYSICAL] Replication infra initialized (or already configured)."
                    } catch {
                        Write-Warning "  [PHYSICAL] az migrate local replication init failed: $($_.Exception.Message)"
                    }
                }

                $initializedProjects[$projectKey] = $true
            }

            # 3) Enable replication for this server
            if ($modeUpper -eq "DRYRUN") {
                Write-Host "  [PHYSICAL][DryRun] Would now call:"
                Write-Host "     az migrate local replication new --resource-group $projRG --project-name $projName ..."
                Write-Host "     (Populate args from 'az migrate local replication new --help' for:"
                Write-Host "        - source machine (from discovery)"
                Write-Host "        - target subscription: $tgtSub"
                Write-Host "        - target RG: $tgtRG"
                Write-Host "        - target region: $tgtRegion"
                Write-Host "        - target VNet: $tgtVNet, Subnet: $tgtSubnet"
                Write-Host "        - log/cache storage account: $logStorageId"
                Write-Host "     )"
                continue
            }

            Write-Host "  [PHYSICAL] Starting replication for '$vmName' via az migrate local replication new..."

            # TODO: You MUST fill the exact CLI arguments based on:
            #          az migrate local replication new --help
            #
            # Example pattern (pseudo-code, adjust to real flags):
            #
            # az migrate local replication new \
            #   --resource-group ZTM-Source-SDC \
            #   --project-name ZTM-POC \
            #   --source-machine-name <from $disc> \
            #   --target-subscription-id $tgtSub \
            #   --target-resource-group $tgtRG \
            #   --target-region $tgtRegion \
            #   --target-vnet VNET-HCEZTM-Target-01 \
            #   --target-subnet Subnet-HCEZTM-Target-01 \
            #   --log-storage-account-id $logStorageId

            # Build az args here once you know the flags
            $replicationArgs = @(
                "migrate","local","replication","new",
                "--resource-group",$projRG,
                "--project-name",$projName
                # ADD: other flags from `az migrate local replication new --help`
            )

            try {
                az @replicationArgs
                Write-Host "  [PHYSICAL] Replication command submitted for '$vmName'."
            } catch {
                Write-Warning "  [PHYSICAL] az migrate local replication new failed for '$vmName': $($_.Exception.Message)"
            }

            continue
        }

        # ========================== OTHER TYPES (VMware, etc.) ==========================
        Write-Warning "  [$vmName] MigrationType '$migrationType' not implemented in this script (only Physical handled here)."
    }

    Write-Host ""
    Write-Host "===== replication-run.ps1 complete (az migrate local) ====="
}
catch {
    Write-Error "Fatal error in replication-run: $($_.Exception.Message)"
    exit 1
}
