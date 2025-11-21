param(
    # Passed by login-and-trigger.ps1, even if we don't use it inside this script
    [string]$TokenFile = ".\token.enc",

    [Parameter(Mandatory = $true)]
    [string]$InputCsv,              # e.g. .\migration_input.csv

    [string]$OutputFolder = ".\",   # where discovery-output.json will be written

    [string]$NextScript  = ".\replication-run.ps1",

    [string]$Mode = ""              # Replicate / DryRun (if you use it)
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

function Normalize-Machine {
    param(
        [object]$Row
    )

    # Adjust mappings if you add more fields later
    $vmName          = Get-Field $Row @("VMName","MachineName","Name")
    $osType          = Get-Field $Row @("OSType","OS","OSName")
    $cpuCount        = Get-Field $Row @("CPU","vCPU","CPUs")
    $memoryGB        = Get-Field $Row @("MemoryGB","RAMGB","Memory")
    $diskCount       = Get-Field $Row @("DiskCount","Disks")
    $totalDiskGB     = Get-Field $Row @("TotalDiskGB","DiskSizeGB")
    $environment     = Get-Field $Row @("Environment","Env")
    $location        = Get-Field $Row @("Location","Site")
    $notes           = Get-Field $Row @("Notes","Comments")

    [PSCustomObject]@{
        MachineName  = $vmName
        OSType       = $osType
        CPUCount     = $cpuCount
        MemoryGB     = $memoryGB
        DiskCount    = $diskCount
        TotalDiskGB  = $totalDiskGB
        Environment  = $environment
        Location     = $location
        Notes        = $notes
    }
}

try {
    Write-Host "========== discovery-physical.ps1 =========="
    Write-Host ("InputCsv     : " + $InputCsv)
    Write-Host ("OutputFolder : " + $OutputFolder)
    Write-Host ("Next script  : " + $NextScript)
    Write-Host ("Mode         : " + ($Mode ?? ""))

    if (-not (Test-Path $InputCsv)) {
        throw "Input CSV not found: $InputCsv"
    }

    if (-not (Test-Path $OutputFolder)) {
        Write-Host ("OutputFolder does not exist. Creating: " + $OutputFolder)
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }

    $rows = Import-Csv -Path $InputCsv
    if (-not $rows -or $rows.Count -eq 0) {
        throw "Input CSV is empty: $InputCsv"
    }

    $normalized = @()
    foreach ($r in $rows) {
        $n = Normalize-Machine -Row $r
        if ($n.MachineName -and $n.MachineName.Trim() -ne "") {
            $normalized += $n
        }
    }

    $outFile = Join-Path $OutputFolder "discovery-output.json"
    $normalized | ConvertTo-Json -Depth 5 | Out-File -FilePath $outFile -Encoding UTF8

    Write-Host ("Discovery complete. Found " + $normalized.Count + " machines.")
    Write-Host ("Saved file: " + $outFile)

    if (-not (Test-Path $NextScript)) {
        throw ("replication script not found at " + $NextScript)
    }

    Write-Host ("Reading discovery file via replication-run: " + $outFile)

    if ($Mode -and $Mode.Trim() -ne "") {
        & $NextScript -TokenFile $TokenFile -DiscoveryFile $outFile -InputCsv $InputCsv -Mode $Mode
    }
    else {
        & $NextScript -TokenFile $TokenFile -DiscoveryFile $outFile -InputCsv $InputCsv
    }
}
catch {
    Write-Error ("Fatal error in discovery-physical: " + $_.ToString())
    exit 1
}
