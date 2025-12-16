
<#
  v122 Business Application Mapping (parameterless)
  - Robust counts with Measure-Object; prints summary; saves diagnostic copy
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
function Write-Info($msg) { Write-Host ("[INFO] " + $msg) }
function Write-Err($msg)  { Write-Error ("[ERROR] " + $msg) }
$DiscoveryFile = $env:MIG_DISCOVERY_FILE
$OutputFolder  = $env:MIG_OUTPUT_DIR
$Detailed      = ($env:MIG_DETAILED -eq 'true')
$DebugRaw      = ($env:MIG_DEBUG_RAW -eq 'true')
try{
  Write-Info '========== business-mapping.ps1 =========='
  Write-Info "DiscoveryFile: $DiscoveryFile"
  Write-Info "OutputFolder : $OutputFolder"
  if(-not(Test-Path $DiscoveryFile)){ throw "Discovery file not found: $DiscoveryFile" }
  if(-not(Test-Path $OutputFolder)){ New-Item -ItemType Directory -Path $OutputFolder -Force|Out-Null }
  $records = Get-Content -Path $DiscoveryFile -Raw | ConvertFrom-Json
  if(-not $records){ throw "Discovery output is empty: $DiscoveryFile" }
  if($records -isnot [System.Collections.IEnumerable]){ $records=@($records) }
  $records=@($records)
  $diagPath = Join-Path $OutputFolder 'raw'
  if(-not(Test-Path $diagPath)){ New-Item -ItemType Directory -Path $diagPath -Force|Out-Null }
  ($records|ConvertTo-Json -Depth 8)|Out-File -FilePath (Join-Path $diagPath 'discovery-output-copy.json') -Encoding UTF8
  Write-Info "Saved diagnostic copy: $diagPath\discovery-output-copy.json"
  $apps=@{}
  foreach($rec in $records){ $app=$rec.Intake.BusinessApplicationName; if(-not $app -or $app.Trim() -eq ''){ $app='__UNASSIGNED__' }; if(-not $apps.ContainsKey($app)){ $apps[$app]=New-Object System.Collections.Generic.List[object] }; $apps[$app].Add($rec)|Out-Null }
  $out=New-Object System.Collections.Generic.List[object]
  foreach($k in $apps.Keys){ $list=$apps[$k]; $vmNames=($list|ForEach-Object {$_.Intake.VMName}); $found=($list|Where-Object { $_.Discovery -and $_.Discovery.FoundInAzureMigrate }|Measure-Object).Count; $total=($list|Measure-Object).Count; $obj=[PSCustomObject]@{ BusinessApplicationName=$k; VMCount=$total; DiscoveredCount=$found; VMNames=$vmNames; Items=$list }; $out.Add($obj)|Out-Null }
  Write-Info 'Application summary:'
  foreach($o in $out){ Write-Info (" - " + $o.BusinessApplicationName + ": " + $o.DiscoveredCount + "/" + $o.VMCount + " discovered") }
  $outFile = Join-Path $OutputFolder 'mapping-output.json'
  $out|ConvertTo-Json -Depth 6|Out-File -FilePath $outFile -Encoding UTF8
  Write-Info ("Business mapping complete. Applications: " + (($apps.Keys|Measure-Object).Count))
  Write-Info ("Saved file: $outFile")
}
catch{ Write-Err ("Fatal error in business-mapping: " + $_.ToString()); exit 1 }

