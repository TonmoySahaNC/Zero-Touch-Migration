<#
.SYNOPSIS
  CSV-driven replication starter using az migrate local for physical servers.
.PARAMETER TokenFile
  Optional (kept for compatibility)
.PARAMETER InputCsv
  Path to the CSV with target/source info.
.PARAMETER Mode
  DryRun | Replicate
#>

param(
    [string]$TokenFile = ".\token.enc",
    [Parameter(Mandatory = $true)]
    [string]$InputCsv,
    [string]$Mode = "DryRun"
)

Set-StrictMode -Version Latest
try {
    Write-Host "========== replication-run.ps1 (az migrate local) =========="
    Write-Host ("InputCsv : " + $InputCsv)
    Write-Host ("Mode     : " + $Mode)

    if (-not (Test-Path $InputCsv)) {
        throw "Input CSV not found: $InputCsv"
    }

    # Ensure az CLI exists
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI 'az' not found in PATH. Install Azure CLI before running this script."
    }

    # Read CSV
    $rows = Import-Csv -Path $InputCsv
    if (-not $rows -or $rows.Count -eq 0) {
        throw "Input CSV is empty or unreadable."
    }

    # Track which projects have been initialized with replication init (optional)
    $initializedProjects = @{}

    foreach ($r in $rows) {
        # normalize fields (add or modify names as per your CSV)
        $migrationType = ($r.MigrationType -as [string])?.Trim()
        $vmName        = ($r.VMName -as [string])?.Trim()
        $projRG        = ($r.SrcResourceGroup -as [string])?.Trim()
        $projName      = ($r.MigrationProjectName -as [string])?.Trim()

        $tgtSub        = ($r.TgtSubscriptionId -as [string])?.Trim()
        $tgtRG         = ($r.TgtResourceGroup -as [string])?.Trim()
        $tgtVNet       = ($r.TgtVNet -as [string])?.Trim()
        $tgtSubnet     = ($r.TgtSubnet -as [string])?.Trim()
        $tgtRegion     = ($r.TgtLocation -as [string])?.Trim()

        $bootDiagSA    = ($r.BootDiagStorageAccountName -as [string])?.Trim()
        $bootDiagSARG  = ($r.BootDiagStorageAccountRG -as [string])?.Trim()
        $targetVMName  = ($r.TargetVMName -as [string])?.Trim()
        if (-not $targetVMName) { $targetVMName = $vmName }

        # Quick validation
        if (-not $vmName -or -not $projRG -or -not $projName) {
            Write-Warning "Skipping row because VMName / SrcResourceGroup / MigrationProjectName missing: $($r | Out-String)"
            continue
        }

        Write-Host "----- Processing: $vmName ($migrationType) -----"

        if (($migrationType -as [string]).ToLowerInvariant() -eq "physical") {

            # 1) confirm discovered server via az
            Write-Host "  Checking discovery in Azure Migrate project '$projName' (RG: $projRG)..."
            $getDiscArgs = @(
                "migrate","local","get-discovered-server",
                "--resource-group",$projRG,
                "--project-name",$projName,
                "--display-name",$vmName,
                "--output","json"
            )
            $discRaw = $null
            try {
                $discRaw = az @getDiscArgs 2>&1
            } catch {
                Write-Warning "  az migrate local get-discovered-server failed: $($_.Exception.Message)"
                Write-Warning "  Raw output: $discRaw"
            }
            if (-not $discRaw -or $discRaw.Trim() -eq "") {
                Write-Warning "  No discovered server found for '$vmName'. Skipping."
                continue
            }

            # parse JSON (can be array)
            try {
                $discObj = $discRaw | ConvertFrom-Json
            } catch {
                Write-Warning "  Failed to parse discovery JSON. Raw output:`n$discRaw"
                continue
            }

            if ($discObj -is [System.Array]) {
                $disc = $discObj | Select-Object -First 1
            } else {
                $disc = $discObj
            }

            if (-not $disc) {
                Write-Warning "  Discovery returned no object for $vmName. Skipping."
                continue
            }

            Write-Host "  Discovered: $($disc.machineName) / IPs: $($disc.ipAddresses -join ', ')"

            # 2) optional: initialize replication infra per project (run once)
            $projKey = "$projRG|$projName"
            if (-not $initializedProjects.ContainsKey($projKey)) {
                # IMPORTANT: set these to the appliance friendly name(s) you see in the portal
                $sourceApplianceName = "migrateapplia"    # <-- update if your appliance name differs
                $targetApplianceName = $sourceApplianceName

                $cacheStorageId = ""
                if ($bootDiagSA -and $bootDiagSARG) {
                    $cacheStorageId = "/subscriptions/$tgtSub/resourceGroups/$bootDiagSARG/providers/Microsoft.Storage/storageAccounts/$bootDiagSA"
                }

                $initArgs = @(
                    "migrate","local","replication","init",
                    "--resource-group",$projRG,
                    "--project-name",$projName,
                    "--source-appliance-name",$sourceApplianceName,
                    "--target-appliance-name",$targetApplianceName
                )
                if ($cacheStorageId) {
                    $initArgs += @("--cache-storage-account-id",$cacheStorageId)
                }

                if ($Mode -eq "DryRun") {
                    Write-Host "  [DryRun] Would run:"
                    Write-Host "    az " + ($initArgs -join " ")
                } else {
                    Write-Host "  Initializing replication infra for project..."
                    try {
                        az @initArgs | Out-Null
                        Write-Host "  Replication infra init completed (or already configured)."
                    } catch {
                        Write-Warning "  replication init failed: $($_.Exception.Message)"
                    }
                }

                $initializedProjects[$projKey] = $true
            }

            # 3) start replication (this is the core action)
            # Build the az command for replication new - **confirm flags with `az migrate local replication new --help`**
            $repArgs = @(
                "migrate","local","replication","new",
                "--resource-group",$projRG,
                "--project-name",$projName,
                # The following are common flags; verify with your CLI version's --help:
                "--machine-name",$vmName,
                "--target-subscription-id",$tgtSub,
                "--target-resource-group",$tgtRG,
                "--target-location",$tgtRegion,
                "--target-vnet",$tgtVNet,
                "--target-subnet",$tgtSubnet,
                "--cache-storage-account-id",$cacheStorageId,
                "--target-vm-name",$targetVMName,
                "--output","json"
            )

            # Remove any empty args
            $repArgs = $repArgs | Where-Object { $_ -and $_.ToString().Trim() -ne "" }

            if ($Mode -eq "DryRun") {
                Write-Host "  [DryRun] Would run:"
                Write-Host "    az " + ($repArgs -join " ")
                continue
            }

            # Execute the replication command
            try {
                Write-Host "  Running: az " + ($repArgs -join " ")
                $repOut = az @repArgs 2>&1
                Write-Host "  Replication started for $vmName. Output:"
                Write-Host $repOut
            } catch {
                Write-Warning "  az migrate local replication new failed for $vmName: $($_.Exception.Message)"
            }

            continue
        }

        # if other types appear, just log them
        Write-Warning "  MigrationType '$migrationType' not handled by this script. (Only 'Physical' implemented.)"
    }

    Write-Host "===== replication-run.ps1 complete ====="
}
catch {
    Write-Error "Fatal error in replication-run: $($_.Exception.Message)"
    exit 1
}
