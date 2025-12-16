<#
  v122.1 business-mapping.ps1
  - Depth increased to 12 for JSON serialization to avoid truncation warnings
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
function Write-Info($msg) { Write-Host ("[INFO] " + $msg) }
function Write-Err($msg)  { Write-Error ("[ERROR] " + $msg) }

try {
  Write-Info "========== business-mapping.ps1 =========="
  $discFile = $env:MIG_DISCOVERY_FILE
  $outDir   = $env:MIG_OUTPUT_DIR
  if (-not $discFile -or -not (Test-Path $discFile)) { throw "Discovery file not found: $discFile" }
  if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

  Write-Info "DiscoveryFile: $discFile"
  Write-Info "OutputFolder : $outDir"

  $rawDir = Join-Path $outDir 'raw'
  if (-not (Test-Path $rawDir)) { New-Item -ItemType Directory -Path $rawDir -Force | Out-Null }

  $rows = Get-Content -Path $discFile -Raw | ConvertFrom-Json
  ($rows | ConvertTo-Json -Depth 12) | Out-File -FilePath (Join-Path $rawDir 'discovery-output-copy.json') -Encoding UTF8
  Write-Info ("Saved diagnostic copy: " + (Join-Path $outDir 'raw' 'discovery-output-copy.json'))

  $apps = @{}
  foreach ($r in $rows) {
    $app = $r.Intake.BusinessApplicationName
    if (-not $apps.ContainsKey($app)) {
      $apps[$app] = [PSCustomObject]@{
        BusinessApplicationName = $app
        VMCount         = 0
        DiscoveredCount = 0
        VMNames         = New-Object System.Collections.Generic.List[string]
        Items           = New-Object System.Collections.Generic.List[object]
      }
    }
    $apps[$app].VMCount++
    if ($r.Discovery.FoundInAzureMigrate) { $apps[$app].DiscoveredCount++ }
    [void]$apps[$app].VMNames.Add($r.Intake.VMName)
    [void]$apps[$app].Items.Add($r)
  }

  $result = New-Object System.Collections.Generic.List[object]
  foreach ($k in $apps.Keys) { $result.Add($apps[$k]) | Out-Null }

  $outFile = Join-Path $outDir 'mapping-output.json'
  ($result | ConvertTo-Json -Depth 12) | Out-File -FilePath $outFile -Encoding UTF8

  Write-Info "Application summary:"
  foreach ($a in $result) { Write-Info (" - " + $a.BusinessApplicationName + ": " + $a.DiscoveredCount + "/" + $a.VMCount + " discovered") }
  Write-Info ("Business mapping complete. Applications: " + (($result | Measure-Object).Count))
  Write-Info ("Saved file: " + $outFile)
}
catch { Write-Err "Fatal error in business-mapping: $($_.Exception.Message)"; exit 1 }

