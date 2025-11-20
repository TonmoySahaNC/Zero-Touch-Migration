Write-Host "Select migration type (enter the number)"
Write-Host "1) Physical"
Write-Host "2) VMware"
Write-Host "3) HyperV"

$choice = $env:MIGRATION_TYPE
if (-not $choice) {
    $choice = Read-Host "Enter number (use 1 for Physical)"
}

switch ($choice) {
    "1" { # Physical path... }
    "Physical" { # just in case you pass string in env
        # Physical path...
    }
    default {
        throw "Only Physical is supported for CI right now."
    }
}
