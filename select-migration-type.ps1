param(
    [string]$TokenFile = ".\token.enc",
    [string]$Script3   = ".\discovery-physical.ps1"
)

try {
    Write-Host "Select migration type (enter the number)"
    Write-Host "1) Physical"
    Write-Host "2) VMware"
    Write-Host "3) HyperV"

    $choice = Read-Host "Enter number (use 1 for Physical)"

    switch ($choice) {
        "1" {
            Write-Host "Physical chosen. Launching discovery..."
            if (-not (Test-Path $Script3)) {
                throw "Discovery script not found: $Script3"
            }
            & $Script3 -TokenFile $TokenFile
        }
        "2" {
            Write-Host "VMware migration not implemented yet."
        }
        "3" {
            Write-Host "HyperV migration not implemented yet."
        }
        default {
            throw "Invalid selection. Use 1 for Physical."
        }
    }
}
catch {
    Write-Error ("Fatal error in select-migration-type: " + $_)
    exit 1
}
