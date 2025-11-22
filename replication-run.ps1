<#
  CSV-driven replication for PHYSICAL servers using `az migrate local`.
  - Called from login-and-trigger.ps1
  - Only MigrationType = Physical is handled
#>

param(
    [string]$TokenFile = ".\token.enc",

    [Parameter(Mandatory = $true)]
    [string]$InputCsv,

    [string]$Mode = "DryRun"   # DryRun or Replicate
)

function Get-Field {
    param(
        [object]$Row,
        [string]$Name
    )
    if ($Row -and $Row.PSObject -and $Row.PSObject.Properties.Name -contains $Name) {
        $v = $Row.$Name
        if ($null -ne $v) {
            $s = $v.ToString().Trim()
            if ($s -ne "") { return $s }
        }
    }
    return ""
}

try {
    Write-Host "========== replication-run.ps1 (az migrate local) =========="
    Write-Host ("InputCsv : " + $InputCsv)
    Write-Host ("Mode     : " + $Mode)

    # Normalize mode
    $modeUpper = [string]$Mode
    if (-not $modeUpper) { $modeUpper = "REPLICATE" }
    else { $modeUpper = $modeUpper.ToUpper() }

    if (-not (Test-Path $InputCsv)) {
        throw "Input CSV not found: $InputCsv"
    }

    # Ensure az CLI exists
    $azCmd = Get-Command az -ErrorAction SilentlyContinue
    if (-not $azCmd) {
        throw "Azure CLI 'az' not found in PATH."
    }

    $rows = Import-Csv -Path $InputCsv
    if (-not $rows -or $rows.Count -eq 0) {
        throw "Input CSV is empty."
    }

    # track projects we've run replication init for
    $initializedProjects = @{}

    foreach ($row in $rows) {

        $migrationType = Get-Field $row "MigrationType"
        $vmName        = Get-Field $row "VMName"

        if (-not $vmName) {
            Write-Warning ("Skipping row with no VMName. Raw row: " + ($row | Out-String))
            continue
        }

        Write-Host ""
        Write-Host ("----- Processing VM: " + $vmName + " -----")
        Write-Host ("  MigrationType : " + $migrationType)

        if (-not $migrationType) { $migrationType = "" }
        $mtNorm = $migrationType.ToLower()

        if ($mtNorm -ne "physical") {
            Write-Host "  Not Physical. Skipping (this script only handles Physical)."
            continue
        }

        # Azure Migrate project info
        $projRG   = Get-Field $row "SrcResourceGroup"
        $projName = Get-Field $row "MigrationProjectName"

        if (-not $projRG -or -not $projName) {
            Write-Warning ("  Project RG/Name missing for " + $vmName + ". Skipping.")
            continue
        }

        # Target info
        $tgtSub    = Get-Field $row "TgtSubscriptionId"
        $tgtRG     = Get-Field $row "TgtResourceGroup"
        $tgtVNet   = Get-Field $row "TgtVNet"
        $tgtSubnet = Get-Field $row "TgtSubnet"
        $tgtRegion = Get-Field $row "TgtLocation"

        # Target VM name: if CSV has TargetVMName, use it; otherwise fall back to VMName
        $targetVMName = Get-Field $row "TargetVMName"
        if (-not $targetVMName) { $targetVMName = $vmName }

        # Storage / cache
        $bootDiagSA   = Get-Field $row "BootDiagStorageAccountName"
        $bootDiagSARG = Get-Field $row "BootDiagStorageAccountRG"

        if (-not $tgtSub -or -not $tgtRG -or -not $tgtVNet -or -not $tgtSubnet -or -not $tgtRegion) {
            Write-Warning ("  Target subscription/RG/VNet/Subnet/Region incomplete for " + $vmName + ". Skipping.")
            continue
        }

        $cacheStorageId = ""
        if ($bootDiagSA -and $bootDiagSARG) {
            $cacheStorageId = "/subscriptions/$tgtSub/resourceGroups/$bootDiagSARG/providers/Microsoft.Storage/storageAccounts/$bootDiagSA"
        }

        # -------- 1) Get ALL discovered servers, then filter in PowerShell --------
        Write-Host ("  Checking discovery in Azure Migrate project '" + $projName + "' (RG: " + $projRG + ") ...")

        $getDiscArgs = @(
            "migrate","local","get-discovered-server",
            "--resource-group",$projRG,
            "--project-name",$projName,
            "--output","json"
        )

        # Capture ONLY stdout, ignore stderr (warnings/errors printed separately)
        $discRawStr = ""
        $discRawStr = az @getDiscArgs 2>$null

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($discRawStr)) {
            Write-Warning "  az migrate local get-discovered-server failed or returned empty for project:"
            Write-Warning ("    RG=" + $projRG + " Project=" + $projName)
            # For logging, run once more capturing stderr:
            $errOut = az @getDiscArgs 2>&1
            Write-Warning "  Raw az output:"
            Write-Warning ($errOut | Out-String)
            continue
        }

        $discList = $null
        try {
            $discList = $discRawStr | ConvertFrom-Json
        } catch {
            Write-Warning "  Failed to parse discovery JSON. Raw:"
            Write-Warning $discRawStr
            continue
        }

        if (-not $discList) {
            Write-Warning ("  No discoverable servers found in project " + $projName + ". Skipping " + $vmName + ".")
            continue
        }

        if (-not ($discList -is [System.Array])) {
            $discList = ,$discList
        }

        # Find matching machine by name
        $disc = $discList | Where-Object {
            $_.machineName -and ($_.machineName.ToString().ToLower() -eq $vmName.ToLower())
        } | Select-Object -First 1

        if (-not $disc) {
            Write-Warning ("  Discovered servers found, but none matching VMName='" + $vmName + "'. Skipping.")
            continue
        }

        $discName = [string]$disc.machineName
        Write-Host ("  Discovered: " + $discName)

        # -------- 2) Optional: replication init per project --------
        $projKey = "$projRG|$projName"
        if (-not $initializedProjects.ContainsKey($projKey)) {

            # IMPORTANT: set this to the actual appliance name you see in portal (Servers -> Azure Migrate appliances)
            $sourceApplianceName = "migrateapplia"
            $targetApplianceName = $sourceApplianceName

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

            if ($modeUpper -eq "DRYRUN") {
                Write-Host "  [DryRun] Would run (init):"
                Write-Host ("    az " + ($initArgs -join " "))
            }
            else {
                Write-Host "  Initializing replication infra for project..."
                try {
                    az @initArgs 2>&1 | Out-String | Write-Host
                    Write-Host "  Replication infra init completed (or already set up)."
                } catch {
                    Write-Warning ("  replication init failed for project " + $projName + ". Exception: " + $_.Exception.Message)
                }
            }

            $initializedProjects[$projKey] = $true
        }

        # -------- 3) Start replication for this VM --------
        # IMPORTANT: confirm these flags with:
        #   az migrate local replication new --help
        $repArgs = @(
            "migrate","local","replication","new",
            "--resource-group",$projRG,
            "--project-name",$projName,
            "--machine-name",$vmName,                  # verify flag
            "--target-subscription-id",$tgtSub,        # verify flag
            "--target-resource-group",$tgtRG,          # verify flag
            "--target-location",$tgtRegion,            # verify flag
            "--target-vnet",$tgtVNet,                  # verify flag
            "--target-subnet",$tgtSubnet,              # verify flag
            "--target-vm-name",$targetVMName           # verify flag
        )

        if ($cacheStorageId) {
            $repArgs += @("--cache-storage-account-id",$cacheStorageId)  # verify flag
        }

        if ($modeUpper -eq "DRYRUN") {
            Write-Host "  [DryRun] Would run (replicate):"
            Write-Host ("    az " + ($repArgs -join " "))
            continue
        }

        Write-Host "  Starting replication with:"
        Write-Host ("    az " + ($repArgs -join " "))

        try {
            $repOutObj = az @repArgs 2>&1
            $repOutStr = ""
            if ($repOutObj -ne $null) { $repOutStr = ($repOutObj | Out-String) }
            Write-Host "  az migrate local replication new output:"
            Write-Host $repOutStr
        } catch {
            $msg = "  az migrate local replication new failed for " + $vmName + ". Exception: " + $_.Exception.Message
            Write-Warning $msg
        }
    }

    Write-Host ""
    Write-Host "===== replication-run.ps1 complete ====="
    exit 0
}
catch {
    $err = "Fatal error in replication-run: " + $_.Exception.Message
    Write-Error $err
    exit 1
}
