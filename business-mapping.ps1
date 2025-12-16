
<#
.SYNOPSIS
  Business Application Mapping: group discovered VMs by BusinessApplicationName.

.DESCRIPTION
  - Reads discovery-output.json.
  - Groups by BusinessApplicationName.
  - Emits mapping-output.json with per-app VM list and basic stats.

.PARAMETER DiscoveryFile
  Path to discovery-output.json produced by discovery-physical.ps1.

.PARAMETER OutputFolder
  Directory for outputs (mapping-output.json).
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$DiscoveryFile,
  [string]$OutputFolder = ".\out",
  [switch]$Verbose
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host ("[INFO] " + $msg) }
function Write-Err($msg)  { Write-Error ("[ERROR] " + $msg) }

try {
  Write-Info "========== business-mapping.ps1 =========="
  Write-Info "DiscoveryFile: $DiscoveryFile"
  Write-Info "OutputFolder : $OutputFolder"

  if (-not (Test-Path $DiscoveryFile)) { throw "Discovery file not found: $DiscoveryFile" }
  if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
  }

  $records = Get-Content -Path $DiscoveryFile -Raw | ConvertFrom-Json
  if (-not $records -or $records.Count -eq 0) { throw "Discovery output is empty: $DiscoveryFile" }

  # Group by BusinessApplicationName
  $apps = @{}
  foreach ($rec in $records) {
    $app = $rec.Intake.BusinessApplicationName
    if (-not $app -or $app.Trim() -eq "") { $app = "__UNASSIGNED__" }
    if (-not $apps.ContainsKey($app)) { $apps[$app] = New-Object System.Collections.Generic.List[object] }
    $apps[$app].Add($rec) | Out-Null
  }

  # Build mapping output
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($k in $apps.Keys) {
    $list = $apps[$k]
    $vmNames = ($list | ForEach-Object { $_.Intake.VMName })
    $found   = ($list | Where-Object { $_.Discovery.FoundInAzureMigrate }).Count
    $total   = $list.Count
    $obj = [PSCustomObject]@{
      BusinessApplicationName = $k
      VMCount                 = $total
      DiscoveredCount         = $found
      VMNames                 = $vmNames
      Items                   = $list
    }
    $out.Add($obj) | Out-Null
  }

  $outFile = Join-Path $OutputFolder "mapping-output.json"
  $out | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding UTF8
  Write-Info ("Business mapping complete. Applications: " + $apps.Keys.Count)
  Write-Info ("Saved file: $outFile")
}
catch {
  Write-Err ("Fatal error in business-mapping: " + $_.ToString())
  exit 1
}
