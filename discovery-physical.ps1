
<#
  v123 Discovery (parameterless)
  - REST-first: enumerate *all* machines per unique project (Sub+RG+Project) once
  - Write full inventory to JSON and CSV (per-project and combined)
  - Then post-process: join CSV input rows to inventory -> discovery-output.json (unchanged schema)
  - Safe property access under StrictMode; name normalization
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
function Write-Info($msg) { Write-Host ("[INFO] " + $msg) }
function Write-Warn($msg) { Write-Warning ("[WARN] " + $msg) }
function Write-Err($msg)  { Write-Error ("[ERROR] " + $msg) }

# ---- Helpers ----
function Get-Prop { param($Object,[string]$Name) if ($null -eq $Object) { return $null } $p=$Object.PSObject.Properties[$Name]; if($p){$p.Value}else{$null} }
function Normalize-Name([string]$name){ if(-not $name){return $null} $n=$name.Trim().ToLower(); if($n.Contains('.')){$n=$n.Split('.')[0]} return $n }
function Save-Text($path,$text){ try{ $d=Split-Path $path; if(-not(Test-Path $d)){ New-Item -ItemType Directory -Path $d -Force|Out-Null }; $text|Out-File -FilePath $path -Encoding UTF8 }catch{ Write-Warn "Failed writing $path : $($_.Exception.Message)" }}
function Save-Json($path,$obj,$depth=8){ try{ $json=$obj|ConvertTo-Json -Depth $depth; Save-Text -path $path -text $json }catch{ Write-Warn "Failed JSON save $path : $($_.Exception.Message)" }}
function Invoke-AzJson([string[]]$CliArgs,[string]$RawOutPath){ try{ if(-not($CliArgs -contains '--output') -and -not($CliArgs -contains '-o')){ $CliArgs+=@('--output','json') } $cmdLine="az "+($CliArgs -join ' '); Write-Info ("Running: "+$cmdLine); $res=& az @CliArgs 2>&1; $text=($res|Out-String); if($RawOutPath){ Save-Text -path $RawOutPath -text $text }; try{ return ($text|ConvertFrom-Json) }catch{ Write-Warn "JSON parse failed for: $cmdLine"; return $null } }catch{ Write-Warn "az failed: $($_.Exception.Message)"; return $null } }
function Rest-EnumerateMachines([string]$sub,[string]$rg,[string]$proj,[string]$diagDir){ $uri="/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Migrate/migrateProjects/$proj/machines?api-version=2018-09-01-preview"; $raw=Join-Path $diagDir "rest-migrateProjects-machines.txt"; return (Invoke-AzJson -CliArgs @('rest','--method','get','--url',"https://management.azure.com$uri") -RawOutPath $raw) }

# ---- Environment ----
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
if($rows.Count -eq 0){ throw "Input CSV is empty: $InputCsv" }

# Required columns
$req=@('MigrationType','SrcSubscriptionId','SrcResourceGroup','MigrationProjectName','TgtSubscriptionId','TgtResourceGroup','TgtVNet','TgtSubnet','TgtLocation','BootDiagStorageAccountName','BootDiagStorageAccountRG','AdminUsername','VMName','BusinessApplicationName')
$present=$rows[0].PSObject.Properties.Name
$missing=$req | Where-Object { $_ -notin $present }
if($missing.Count -gt 0){ throw ("Input CSV missing required columns: "+($missing -join ', ')) }

# Diagnostic root
$diagRoot = Join-Path $OutputFolder 'raw'
if(-not(Test-Path $diagRoot)){ New-Item -ItemType Directory -Path $diagRoot -Force|Out-Null }
if($DebugRaw){ Save-Json -path (Join-Path $diagRoot 'csv-rows.json') -obj $rows -depth 6 }

# ---- Phase 1: Enumerate ALL machines per unique (sub,rg,project) ----
$sets = $rows | Select-Object -Property SrcSubscriptionId,SrcResourceGroup,MigrationProjectName -Unique
$inventoryCombined = New-Object System.Collections.Generic.List[object]
$inventoryBySet = @{}

foreach($s in $sets){
  $sub=$s.SrcSubscriptionId; $rg=$s.SrcResourceGroup; $proj=$s.MigrationProjectName
  $setKey = "$($sub)|$($rg)|$($proj)"
  $projDiag = Join-Path $diagRoot ("proj-"+$proj)
  if(-not(Test-Path $projDiag)){ New-Item -ItemType Directory -Path $projDiag -Force|Out-Null }
  Write-Info "Enumerating project '$proj' (RG:$rg, Sub:$sub) via REST..."
  $enum = Rest-EnumerateMachines -sub $sub -rg $rg -proj $proj -diagDir $projDiag
  if($enum -and $enum.value){
    $inventoryBySet[$setKey] = $enum.value
    foreach($m in $enum.value){ $inventoryCombined.Add($m) | Out-Null }
    # Persist per-project
    Save-Json -path (Join-Path $projDiag "discovery-full-$proj.json") -obj $enum.value -depth 8
  } else {
    $inventoryBySet[$setKey] = @()
    Write-Warn "No machines returned by REST for project '$proj'."
  }
}

# Combined full inventory persist (JSON + CSV)
$invDir = Join-Path $OutputFolder 'inventory'
if(-not(Test-Path $invDir)){ New-Item -ItemType Directory -Path $invDir -Force|Out-Null }
Save-Json -path (Join-Path $invDir 'discovery-full.json') -obj $inventoryCombined -depth 8

# Flatten to CSV
$flat = foreach($m in $inventoryCombined){
  $props = Get-Prop -Object $m -Name 'properties'
  $disc  = @($(Get-Prop -Object $props -Name 'discoveryData'))
  $first = $null; if($disc -and $disc.Count -gt 0){ $first = $disc[0] }
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

Write-Info ("Inventory collected. Machines (combined): " + ($inventoryCombined | Measure-Object).Count)

# ---- Phase 2: Post-process join -> discovery-output.json (for mapping) ----
$outObjects = New-Object System.Collections.Generic.List[object]
foreach($r in $rows){
  $vm   = $r.VMName
  $proj = $r.MigrationProjectName
  $rg   = $r.SrcResourceGroup
  $sub  = $r.SrcSubscriptionId
  $csvNorm = Normalize-Name $vm
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
    if($names.Contains($csvNorm)){ $match=$m; $matchReason='name|machineName|fqdn'; break }
  }

  # Build enriched record
  $osType=$null; $osName=$null; $bootType=$null; $cpuCount=$null; $memoryGB=$null; $diskSummary=$null
  if($match){
    $props = Get-Prop -Object $match -Name 'properties'
    $bootType = Get-Prop -Object $props -Name 'bootType'
    $osName   = Get-Prop -Object $props -Name 'osName'
    $discList = @($(Get-Prop -Object $props -Name 'discoveryData'))
    if($discList -and $discList.Count -gt 0){
      $dd = $discList[0]
      $osType = Get-Prop -Object $dd -Name 'osType'
      $ext    = Get-Prop -Object $dd -Name 'extendedInfo'
      if($ext){ $cpuCount=Get-Prop -Object $ext -Name 'cpuCount'; $memoryGB=Get-Prop -Object $ext -Name 'memoryInGB'; $diskSummary=Get-Prop -Object $ext -Name 'diskSummary' }
    }
  }

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

# Save join results for mapping and an auxiliary join CSV for quick review
$outFile = Join-Path $OutputFolder 'discovery-output.json'
$outObjects | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding UTF8
Write-Info ("Discovery complete. Records: "+ ($outObjects|Measure-Object).Count)
Write-Info ("Saved file: $outFile")

$joinCsv = foreach($o in $outObjects){
  [PSCustomObject]@{
    VMName          = $o.Intake.VMName
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
$joinCsv | Export-Csv -Path (Join-Path $OutputFolder 'csv-to-discovery-join.csv') -NoTypeInformation -Encoding UTF8
Write-Info ("Saved join CSV: " + (Join-Path $OutputFolder 'csv-to-discovery-join.csv'))

