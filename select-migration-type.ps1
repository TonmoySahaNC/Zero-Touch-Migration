param(
    [string]$TokenFile = ".\token.enc",
    [string]$InputCsv  = ".\migration_input.csv",
    [string]$Script3   = ".\discovery-physical.ps1",
    [string]$Mode      = ""
)

try {
    if (-not (Test-Path $InputCsv)) {
        throw "Input CSV not found: $InputCsv"
    }

    # read only first row to determine migration type / validate
    $rows = Import-Csv -Path $InputCsv
    if ($rows.Count -eq 0) {
        throw "Input CSV is empty: $InputCsv"
    }

    $first = $rows[0]
    $csvMigrationType = $first.MigrationType

    if ($Mode -and $Mode -ne "") {
        # Mode override: accepts "DryRun" or "Replicate"
        $modeParam = $Mode
    }
    else {
        $modeParam = ""  # will be used downstream via environment or prompt
    }

    if (-not $csvMigrationType -or $csvMigrationType.Trim().ToLower() -ne "physical") {
        throw "Unsupported migration type in CSV. This flow currently supports only 'Physical'. CSV value: '$csvMigrationType'"
    }

    if (-not (Test-Path $Script3)) {
        throw "Discovery script not found: $Script3"
    }

    & $Script3 -TokenFile $TokenFile -InputCsv $InputCsv -Mode $modeParam
}
catch {
    Write-Error ("Fatal error in select-migration-type: " + $_.ToString())
    exit 1
}
