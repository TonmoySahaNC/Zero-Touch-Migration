param(
    # Passed from discovery-physical.ps1 (and ultimately from login-and-trigger.ps1)
    [string]$TokenFile = ".\token.enc",

    [Parameter(Mandatory = $true)]
    [string]$DiscoveryFile,                    # .\discovery-output.json

    [string]$InputCsv = ".\migration_input.csv",

    [string]$Mode = ""                         # Replicate / DryRun
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
    Write-Host "========== replication-run.ps1 (az migrate local) =========="

    $modeFinal = Resolve-Mode $Mode
    $modeUpper = $modeFinal.ToUpperInvariant()

    Write-Host ("Mode          : " + $modeUpper)
    Write-Host ("DiscoveryFile : " + $DiscoveryFile)
    Write-Host ("InputCsv      : " + $InputCsv)

    if (-not (Test-Path $DiscoveryFile)) {
        throw "Discovery file not found: $DiscoveryFile"
    }
    if (-not (Test-Path $InputCsv)) {
        throw "Input CSV not found: $InputCsv"
    }

    # Just read discovery file so we can log count, but we're not tightly coupled to it
    $discContent = Get-Content $DiscoveryFile -Raw | ConvertFrom-Json
    $discCount   = 0
    if ($discContent -is [System.Array]) { $discCount = $discContent.Count }
    elseif ($discContent) { $discCount = 1 }

    Write-Host ("Discovery objects : " + $discCount)

    # Make sure az CLI is available
    $az = Get-Command az -ErrorAction SilentlyContinue
    if (-not $az) {
        throw "Azure CLI 'az' not found in PATH. Install Azure CLI and try again."
    }

    $rows = Import-Csv -Path $InputCsv
    if (-not $rows -or $rows.Count -eq 0) {
        throw "Input CSV is empty: $InputCsv"
    }

    # Cache per-project initialization for az migrate local replication init (if you decide to use it)
    $initializedProjects = @{}

    foreach ($row in $rows) {

        $migrationType = Get-Field $row @("MigrationType","Type")
        $mtNorm        = ($migrationType ?? "").ToLowerInvariant()

        $vmName        = Get-Field $row @("VMName","MachineName","ServerName")
        if (-not $vmName) {
            Write-Warning "Row missing VMName / MachineName. Skipping row:`n$($row | Out-String)"
            continue
        }

        Write-Host ""
        Write-Host "----- Processing: $vmName -----"
        Write-Host "  MigrationType : $migrationType"

        # Azure Migrate project info
        $projRG    = Get-Field $row @("SrcResourceGroup","ProjectRg","MigrationProjectRG")
        $projName  = Get-Field $row @("MigrationProjectName","ProjectName","AzMigrateProjectName")

        if (-not $projRG -or -not $projName) {
            Write-Warning "  Project RG/Name not set for $vmName. Skipping."
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

        # Log/cache / boot diag storage
        $bootDiagSAName = Get-Field $row @("BootDiagStorageAccountName","LogStorageAccountName")
        $bootDiagSARG   = Get-Field $row @("BootDiagStorageAccountRG","LogStorageAccountRG")

        if (-not $tgtSub -or -not $tgtRG -or -not $tgtVNet -or -not $tgtSubnet -or -not $tgtRegion) {
            Write-Warning "  Target Subscription/RG/VNet/Subnet/Region not fully set. Skipping $vmName."
            continue
        }

        if (-not $bootDiagSAName -or -not $bootDiagSARG) {
            Write-Warning "  BootDiag/Log Storage AccountName/RG not set. Skipping $vmName."
            continue
        }

        $logStorageId = "/subscriptions/$tgtSub/resourceGroups/$bootDiagSARG/providers/Microsoft.Storage/storageAccounts/$bootDiagSAName"

        # =============================== PHYSICAL PATH ===============================
        if ($mtNorm -eq "physical") {
            Write-Host "  [PHYSICAL] Using 'az migrate local' for Azure Migrate project '$projName' (RG: $projRG)."

            # 1) Confirm discovery
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

            Write-Host "  [PHYSICAL] Found discovered server: $($disc.machineName)"

            # 2) (Optional) Initialize replication infra once per project
            $projectKey = "$projRG|$projName"
            if (-not $initializedProjects.ContainsKey($projectKey)) {

                # TODO: Replace with your actual appliance name from Azure Migrate UI (e.g. 'migrateapplia')
                $sourceApplianceName = "migrateapplia"
                $targetApplianceName = "migrateapplia"

                if ($modeUpper -eq "DRYRUN") {
                    Write-Host "  [PHYSICAL][DryRun] Would initialize replication infra:"
                    Write-Host "    az migrate local replication init `"
                    Write-Host "       --resource-group $projRG `"
                    Write-Host "       --project-name $projName `"
                    Write-Host "       --source-appliance-name $sourceApplianceName `"
                    Write-Host "       --target-appliance-name $targetApplianceName `"
                    Write-Host "       --cache-storage-account-id $logStorageId"
                }
                else {
                    Write-Host "  [PHYSICAL] Initializing replication infra for project '$projName'..."
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
                        Write-Warning "  [PHYSICAL] 'az migrate local replication init' failed: $($_.Exception.Message)"
                    }
                }

                $initializedProjects[$projectKey] = $true
            }

            # 3) Start replication for this server
            if ($modeUpper -eq "DRYRUN") {
                Write-Host "  [PHYSICAL][DryRun] Would now call:"
                Write-Host "    az migrate local replication new ..."
                Write-Host "    (Fill exact flags from 'az migrate local replication new --help' for:"
                Write-Host "       * source machine"
                Write-Host "       * target subscription/resource group"
                Write-Host "       * target region / vnet / subnet"
                Write-Host "       * cache/log storage account"
                Write-Host "    )"
                continue
            }

            Write-Host "  [PHYSICAL] Starting replication for '$vmName' via 'az migrate local replication new'..."

            # NOTE:
            # You MUST verify and adjust these flags by running:
            #   az migrate local replication new --help
            # in your environment. Param names can differ by version.
            #
            # The below is a BEST-GUESS template and may need tweaking.

            $replicationArgs = @(
                "migrate","local","replication","new",
                "--resource-group",$projRG,
                "--project-name",$projName,
                # guessed parameter names below; adjust them based on 'az migrate local replication new --help':
                "--machine-name",$vmName,
                "--target-subscription-id",$tgtSub,
                "--target-resource-group",$tgtRG,
                "--target-location",$tgtRegion,
                "--target-vnet",$tgtVNet,
                "--target-subnet",$tgtSubnet,
                "--cache-storage-account-id",$logStorageId,
                "--target-vm-name",$targetVM
            )

            try {
                az @replicationArgs
                Write-Host "  [PHYSICAL] Replication command submitted for '$vmName'."
            } catch {
                Write-Warning "  [PHYSICAL] 'az migrate local replication new' failed for '$vmName': $($_.Exception.Message)"
            }

            continue
        }

        # ======================= OTHER TYPES (VMware, etc.) =======================
        Write-Warning "  [$vmName] MigrationType '$migrationType' not implemented in this script (only Physical handled)."
    }

    Write-Host ""
    Write-Host "===== replication-run.ps1 complete ====="
}
catch {
    Write-Error ("Fatal error in replication-run: " + $_.Exception.Message)
    exit 1
}
