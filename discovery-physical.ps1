
<#
  v128 Discovery (parameterless)
  - Compatible with Windows PowerShell 5.1 (no ternary operator)
  - REST-first inventory per unique project with pagination (nextLink/continuationToken; pageSize=100)
  - StrictMode-safe counting & manifest
  - Post-processing join: matches CSV VMName and optionally DNSName to inventory candidates (name/machineName/fqdn)
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
function Write-Info($msg) { Write-Host ("[INFO] " + $msg) }
function Write-Warn($msg) { Write-Warning ("[WARN] " + $msg) }
function Write-Err($msg)  { Write-Error ("[ERROR] " + $msg) }

function Get-Prop { param($Object,[string]$Name) if ($null -eq $Object) { return $null } $p=$Object.PSObject.Properties[$Name]; if($p){$p.Value}else{$null} }
function Normalize-Name([string]$name){ if(-not $name){return $null } $n=$name.Trim().ToLower(); if($n.Contains('.')){ $n=$n.Split('.')[0] } return $n }
function Save-Text($path,$text){ try{ $d=Split-Path $path; if(-not(Test-Path $d)){ New-Item -ItemType Directory -Path $d -Force|Out-Null }; $text|Out-File -FilePath $path -Encoding UTF8 }catch{ Write-Warn "Failed writing $path : $($_.Exception.Message)" }}
function Save-Json($path,$obj,$depth=8){ try{ $json=$obj|ConvertTo-Json -Depth $depth; Save-Text -path $path -text $json }catch{ Write-Warn "Failed JSON save $path : $($_.Exception.Message)" }}
function Invoke-AzRaw([string]$Url,[string]$RawOutPath){ try{ $cmdArgs=@('rest','--method','get','--url',$Url); Write-Info ("Running: az " + ($cmdArgs -join ' ')); $res = & az @cmdArgs 2>&1; $text = ($res | Out-String); if($RawOutPath){ Save-Text -path $RawOutPath -text $text }; try{ return ($text | ConvertFrom-Json) } catch { Write-Warn "JSON parse failed for: $Url"; return $null } } catch { Write-Warn "az failed: $($_.Exception.Message)"; return $null } }

function Rest-EnumerateMachinesAll([string]$sub,[string]$rg,[string]$proj,[string]$diagDir){
  $base = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Migrate/migrateProjects/$proj/machines?api-version=2018-09-01-preview&pageSize=100"
  $pageIndex = 1
  $all = New-Object System.Collections.Generic.List[object]
  $url = $base
  do {
    $rawPath = Join-Path $diagDir ("rest-migrateProjects-machines-page" + $pageIndex + ".txt")
    $json = Invoke-AzRaw -Url $url -RawOutPath $rawPath
    $vals = @((Get-Prop -Object $json -Name 'value'))
    foreach($v in $vals){ $all.Add($v) | Out-Null }
    $next = Get-Prop -Object $json -Name 'nextLink'
    $pageIndex++
    $url = $next
  } while ($url)
  return $all
}

$InputCsv     = $env:MIG_INPUT_CSV
$OutputFolder = $env:MIG_OUTPUT_DIR
$Detailed     = ($env:MIG_DETAILED -eq 'true')
$DebugRaw     = ($env:MIG_DEBUG_RAW -eq 'true')

if(-not(Test-Path $InputCsv)){ throw "Input CSV not found: $InputCsv" }
if(-not(Test-Path $OutputFolder)){ New-Item -ItemType Directory -Path $OutputFolder -Force|Out-Null }
Write-Info "========== discovery-physical.ps1 =========="
Write-Info "InputCsv     : $InputCsv"
Write-Info "OutputFolder : $OutputFolder"

$rows = @((Import-Csv -Path $InputCsv))
if(($rows|Measure-Object).Count -eq 0){ throw "Input CSV is empty: $InputCsv" }

$req=@('MigrationType','SrcSubscriptionId','SrcResourceGroup','MigrationProjectName','TgtSubscriptionId','TgtResourceGroup','TgtVNet','TgtSubnet','TgtLocation','BootDiagStorageAccountName','BootDiagStorageAccountRG','AdminUsername','VMName','BusinessApplicationName')
$present=@($rows[0].PSObject.Properties.Name)
$missing=@($req | Where-Object { $_ -notin $present })
if( ( $missing | Measure-Object ).Count -gt 0 ){
  Write-Err ("CSV header columns present: "+($present -join ', '))
  Write-Err ("CSV header columns required: "+($req -join ', '))
  throw ("Input CSV missing required columns: "+($missing -join ', '))
}

$diagRoot = Join-Path $OutputFolder 'raw'
if(-not(Test-Path $diagRoot)){ New-Item -ItemType Directory -Path $diagRoot -Force|Out-Null }
if($DebugRaw){ Save-Json -path (Join-Path $diagRoot 'csv-rows.json') -obj $rows -depth 6 }

$sets = @($rows | Select-Object -Property SrcSubscriptionId,SrcResourceGroup,MigrationProjectName -Unique)
$inventoryCombined = New-Object System.Collections.Generic.List[object]
$inventoryBySet = @{}

foreach($s in $sets){
  $sub=$s.SrcSubscriptionId; $rg=$s.SrcResourceGroup; $proj=$s.MigrationProjectName
  $setKey = "$($sub)|$($rg)|$($proj)"
  $projDiag = Join-Path $diagRoot ("proj-"+$proj)
  if(-not(Test-Path $projDiag)){ New-Item -ItemType Directory -Path $projDiag -Force|Out-Null }
  Write-Info "Enumerating project '$proj' (RG:$rg, Sub:$sub) via REST with pagination..."
  $allVals = Rest-EnumerateMachinesAll -sub $sub -rg $rg -proj $proj -diagDir $projDiag
  $inventoryBySet[$setKey] = $allVals
  foreach($m in $allVals){ $inventoryCombined.Add($m) | Out-Null }
  Save-Json -path (Join-Path $projDiag "discovery-full-$proj.json") -obj $allVals -depth 8
  Write-Info ("Project '$proj' total machines: " + (($allVals|Measure-Object).Count))
}

$invDir = Join-Path $OutputFolder 'inventory'
if(-not(Test-Path $invDir)){ New-Item -ItemType Directory -Path $invDir -Force|Out-Null }
Save-Json -path (Join-Path $invDir 'discovery-full.json') -obj $inventoryCombined -depth 8

$flat = foreach($m in $inventoryCombined){
  $props = Get-Prop -Object $m -Name 'properties'
  $disc  = @($(Get-Prop -Object $props -Name 'discoveryData'))
  $first = $null; if(($disc|Measure-Object).Count -gt 0){ $first = $disc[0] }
  [PSCustomObject]@{
    id            = Get-Prop -Object $m     -Name 'id'
    name          = Get-Prop -Object $m     -Name 'name'
    osName        = Get-Prop -Object $props -Name 'osName'
    bootType      = Get-Prop -Object $props -Name 'bootType'
    disc_osType   = Get-Prop -Object $first -Name 'osType'
    disc_machine  = Get-Prop -Object $first -Name 'machineName'
    disc_fqdn     = Get-Prop -Object $first -Name 'fqdn'
    disc_cpuCount = Get-Prop -Object (Get-Prop -Object $first -Name 'extendedInfo') -Name 'cpuCount'
    disc_memoryGB = Get-Prop -Object (Get-Prop -Object $first -Name 'extendedInfo') -Name 'memoryInGB'
  }
}
$flat | Export-Csv -Path (Join-Path $invDir 'discovery-full.csv') -NoTypeInformation -Encoding UTF8
Write-Info ("Inventory collected. Machines (combined): " + (($inventoryCombined|Measure-Object).Count))

$outObjects = New-Object System.Collections.Generic.List[object]
foreach($r in $rows){
  $vm      = $r.VMName
  $csvNorm = Normalize-Name $vm
  $csvDns  = $null
  if ($r.PSObject.Properties['DNSName']) { $csvDns = Normalize-Name $r.DNSName }

  $proj = $r.MigrationProjectName
  $rg   = $r.SrcResourceGroup
  $sub  = $r.SrcSubscriptionId
  $setKey = "$sub|$rg|$proj"
  $projList = @()
  if($inventoryBySet.ContainsKey($setKey)){ $projList = @($inventoryBySet[$setKey]) }

  $match = $null; $matchSource='REST:migrateProjects'; $matchReason=''
  foreach($m in $projList){
    $names = New-Object System.Collections.Generic.HashSet[string]
    $null = $names.Add((Normalize-Name (Get-Prop -Object $m -Name 'name')))
    $props = Get-Prop -Object $m -Name 'properties'
    $discL = @($(Get-Prop -Object $props -Name 'discoveryData'))
    foreach($d in $discL){
      $mn = Normalize-Name (Get-Prop -Object $d -Name 'machineName')
      $fq = Normalize-Name (Get-Prop -Object $d -Name 'fqdn')
      if($mn){ $null = $names.Add($mn) }
      if($fq){ $null = $names.Add($fq) }
    }
    if($names.Contains($csvNorm)){
      $match=$m
      $matchReason='name|machineName|fqdn'
      break
    } elseif($csvDns -and $names.Contains($csvDns)){
      $match=$m
      $matchReason='DNSName=>fqdn|machineName'
      break
    }
  }

  $osType=$null; $osName=$null; $bootType=$null; $cpuCount=$null; $memoryGB=$null; $diskSummary=$null
  if($match){
    $props = Get-Prop -Object $match -Name 'properties'
    $bootType = Get-Prop -Object $props -Name 'bootType'
    $osName   = Get-Prop -Object $props -Name 'osName'
    $discList = @($(Get-Prop -Object $props -Name 'discoveryData'))
    if(($discList|Measure-Object).Count -gt 0){
      $dd = $discList[0]
      $osType = Get-Prop -Object $dd -Name 'osType'
      $ext    = Get-Prop -Object $dd -Name 'extendedInfo'
      if($ext){ $cpuCount=Get-Prop -Object $ext -Name 'cpuCount'; $memoryGB=Get-Prop -Object $ext -Name 'memoryInGB'; $diskSummary=Get-Prop -Object $ext -Name 'diskSummary' }
    }
  }

  # Precompute DNSName value (no ternary in hashtables)
  $dnsValue = $null
  if ($r.PSObject.Properties['DNSName']) { $dnsValue = $r.DNSName }

  $out = [PSCustomObject]@{
    Intake = [PSCustomObject]@{
      MigrationType              = $r.MigrationType
      SrcSubscriptionId          = $r.SrcSubscriptionId
      SrcResourceGroup           = $r.SrcResourceGroup
      MigrationProjectName       = $r.MigrationProjectName
      TgtSubscriptionId          = $r.TgtSubscriptionId
      TgtResourceGroup           = $r.TgtResourceGroup
      TgtVNet                    = $r.TgtVNet
      TgtSubnet                  = $r.TgtSubnet
      TgtLocation                = $r.TgtLocation
      BootDiagStorageAccountName = $r.BootDiagStorageAccountName
      BootDiagStorageAccountRG   = $r.BootDiagStorageAccountRG
      AdminUsername              = $r.AdminUsername
      VMName                     = $r.VMName
      BusinessApplicationName    = $r.BusinessApplicationName
      DNSName                    = $dnsValue
    }
    Discovery = [PSCustomObject]@{
      FoundInAzureMigrate = [bool]$match
      Source              = $matchSource
      MatchReason         = $matchReason
      BootType            = $bootType
      OSType              = $osType
      OSName              = $osName
      CPUCount            = $cpuCount
      MemoryGB            = $memoryGB
      DiskSummary         = $diskSummary
      Raw                 = $match
    }
  }
  $outObjects.Add($out) | Out-Null
}

$outFile   = Join-Path $OutputFolder 'discovery-output.json'
$joinCsv   = Join-Path $OutputFolder 'csv-to-discovery-join.csv'
$fullJson  = Join-Path (Join-Path $OutputFolder 'inventory') 'discovery-full.json'
$fullCsv   = Join-Path (Join-Path $OutputFolder 'inventory') 'discovery-full.csv'

$outObjects | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding UTF8
Write-Info ("Discovery complete. Records: "+ (($outObjects|Measure-Object).Count))
Write-Info ("Saved file: $outFile")

$joinData = foreach($o in $outObjects){
  [PSCustomObject]@{
    VMName          = $o.Intake.VMName
    DNSName         = $o.Intake.DNSName
    Found           = $o.Discovery.FoundInAzureMigrate
    MatchReason     = $o.Discovery.MatchReason
    MatchedId       = (Get-Prop -Object $o.Discovery.Raw -Name 'id')
    MatchedName     = (Get-Prop -Object $o.Discovery.Raw -Name 'name')
    OSName          = $o.Discovery.OSName
    OSType          = $o.Discovery.OSType
    CPUCount        = $o.Discovery.CPUCount
    MemoryGB        = $o.Discovery.MemoryGB
  }
}
$joinData | Export-Csv -Path $joinCsv -NoTypeInformation -Encoding UTF8
Write-Info ("Saved join CSV: " + $joinCsv)

$manifest = [ordered]@{
  OutputDir    = $OutputFolder
  Inventory    = [ordered]@{
    FullJson = $fullJson
    FullCsv  = $fullCsv
    Machines = (($inventoryCombined|Measure-Object).Count)
  }
  JoinResults  = [ordered]@{
    DiscoveryJson = $outFile
    JoinCsv       = $joinCsv
    Rows          = (($outObjects|Measure-Object).Count)
    FoundCount    = (($outObjects | Where-Object { $_.Discovery.FoundInAzureMigrate } | Measure-Object).Count)
  }
}
Save-Json -path (Join-Path $OutputFolder 'manifest.json') -obj $manifest -depth 6
Write-Info ("Saved manifest: " + (Join-Path $OutputFolder 'manifest.json'))
Write-Info ("Manifest summary ⇒ Machines:" + $manifest.Inventory.Machines + ", Rows:" + $manifest.JoinResults.Rows + ", Found:" + $manifest.JoinResults.FoundCount)

