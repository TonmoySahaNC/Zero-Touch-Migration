
<# 
  Business Application Mapping (parameterless):
  Reads MIG_DISCOVERY_FILE, MIG_OUTPUT_DIR, MIG_DETAILED from environment.
  Groups discovered VMs by BusinessApplicationName and writes mapping-output.json.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host ("[INFO] " + $msg) }
function Write-Err($msg)  { Write-Error ("[ERROR] " + $msg) }

$DiscoveryFile = $env:MIG_DISCOVERY_FILE
$OutputFolder  = $env:MIG_OUTPUT_DIR
$Detailed      = ($env:MIG_DETAILED -eq "true")

try {
  Write-Info "========== business-mapping.ps1 =========="
  Write-Info "DiscoveryFile: $DiscoveryFile"
  Write-Info "OutputFolder : $OutputFolder"

  if (-not (Test-Path $DiscoveryFile)) { throw "Discovery file not found: $DiscoveryFile" }
  if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

  $records = Get-Content -Path $DiscoveryFile -Raw | ConvertFrom-Json
  if (-not $records) { throw "Discovery output is empty: $DiscoveryFile" }
  if ($records -isnot [System.Collections.IEnumerable]) { $records = @($records) }

  $apps = @{}
  foreach ($rec in $records) {
    $app = $rec.Intake.BusinessApplicationName
    if (-not $app -or $app.Trim() -eq "") { $app = "__UNASSIGNED__" }
    if (-not $apps.ContainsKey($app)) { $apps[$app] = New-Object System.Collections.Generic.List[object] }
    $apps[$app].Add($rec) | Out-Null
  }

  $out = New-Object System.Collections.Generic.List[object]
  foreach ($k in $apps.Keys) {
    $list   = $apps[$k]
    $vmNames= ($list | ForEach-Object { $_.Intake.VMName })
    $found  = ($list | Where-Object { $_.Discovery.FoundInAzureMigrate }).Count
    $total  = $list.Count
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

