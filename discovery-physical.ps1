
<# 
  v120 Discovery (parameterless)
  - REST-first enumerate machines; safe property access (no 'displayName' assumption)
  - Name normalization for matching (trim, lowercase, strip domain)
  - CLI used only for diagnostics; not required for success
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host ("[INFO] " + $msg) }
function Write-Warn($msg) { Write-Warning ("[WARN] " + $msg) }
function Write-Err($msg)  { Write-Error ("[ERROR] " + $msg) }

$InputCsv    = $env:MIG_INPUT_CSV
$OutputFolder= $env:MIG_OUTPUT_DIR
$Detailed    = ($env:MIG_DETAILED -eq "true")
$DebugRaw    = ($env:MIG_DEBUG_RAW -eq "true")

$requiredColumns = @(
  "MigrationType","SrcSubscriptionId","SrcResourceGroup","MigrationProjectName",
  "TgtSubscriptionId","TgtResourceGroup","TgtVNet","TgtSubnet","TgtLocation",
  "BootDiagStorageAccountName","BootDiagStorageAccountRG","AdminUsername",
  "VMName","BusinessApplicationName"
)

function Test-Columns($rows) {
  $arr = @($rows)
  if ($arr.Count -eq 0) { throw "Input CSV has no rows." }
  $sample  = $arr[0]
  $present = $sample.PSObject.Properties.Name
  $missing = $requiredColumns | Where-Object { $_ -notin $present }
  if (@($missing).Count -gt 0) { throw ("Input CSV missing required columns: " + ((@($missing)) -join ", ")) }
}

function Save-Text($path, $text) {
  try { $d = Split-Path $path; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } ; $text | Out-File -FilePath $path -Encoding UTF8 } catch { Write-Warn "Failed writing $path : $($_.Exception.Message)" }
}

function Save-Json($path, $obj, $depth=6) {
  try { $json = $obj | ConvertTo-Json -Depth $depth; Save-Text -path $path -text $json } catch { Write-Warn "Failed JSON save $path : $($_.Exception.Message)" }
}

function Invoke-AzJson([string[]]$CliArgs, [string]$RawOutPath) {
  try {
    if (-not ($CliArgs -contains '--output') -and -not ($CliArgs -contains '-o')) { $CliArgs += @('--output','json') }
    $cmdLine = "az " + ($CliArgs -join " ")
    Write-Info ("Running: " + $cmdLine)
    $res = & az @CliArgs 2>&1
    $text = ($res | Out-String)
    if ($RawOutPath) { Save-Text -path $RawOutPath -text $text }
    try { return ($text | ConvertFrom-Json) } catch { Write-Warn "JSON parse failed for: $cmdLine"; return $null }
  } catch {
    Write-Warn "az failed: $($_.Exception.Message)"
    return $null
  }
}

function Get-ProjectMachinesRest([string]$projectName,[string]$resourceGroup,[string]$subscriptionId,[string]$diagDir) {
  $uri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/migrateProjects/$projectName/machines?api-version=2018-09-01-preview"
  $cliArgs = @("rest","--method","get","--url","https://management.azure.com$uri")
  $rawPath = Join-Path $diagDir "rest-migrateProjects-machines.txt"
  return (Invoke-AzJson -CliArgs $cliArgs -RawOutPath $rawPath)
}

function Normalize-Name([string]$name) {
  if (-not $name) { return $null }
  $n = $name.Trim().ToLower()
  if ($n.Contains('.')) { $n = $n.Split('.')[0] } # strip domain suffix
  return $n
}

function Get-CandidateNames($machine) {
  $names = New-Object System.Collections.Generic.HashSet[string]
  try {
    if ($machine.name) { $null = $names.Add((Normalize-Name $machine.name)) }
    $props = $machine.properties
    if ($props) {
      $discList = @($props.discoveryData)
      foreach ($d in $discList) {
        if ($d.machineName) { $null = $names.Add((Normalize-Name $d.machineName)) }
        if ($d.fqdn)        { $null = $names.Add((Normalize-Name $d.fqdn)) }
      }
    }
  } catch {}
  return $names
}

try {
  Write-Info "========== discovery-physical.ps1 =========="
  Write-Info "InputCsv     : $InputCsv"
  Write-Info "OutputFolder : $OutputFolder"

  if (-not (Test-Path $InputCsv)) { throw "Input CSV not found: $InputCsv" }
  if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

  $rows = @((Import-Csv -Path $InputCsv))
  if ($rows.Count -eq 0) { throw "Input CSV is empty: $InputCsv" }
  Test-Columns -rows $rows

  $diagDir = Join-Path $OutputFolder "raw"
  if (-not (Test-Path $diagDir)) { New-Item -ItemType Directory -Path $diagDir -Force | Out-Null }
  if ($DebugRaw) { Save-Json -path (Join-Path $diagDir "csv-rows.json") -obj $rows -depth 6 }

  $srcSubs  = ($rows | Select-Object -ExpandProperty SrcSubscriptionId | Sort-Object -Unique)
  $projects = ($rows | Select-Object -ExpandProperty MigrationProjectName | Sort-Object -Unique)
  Write-Info ("Unique source subscriptions: " + ($srcSubs -join ", "))
  Write-Info ("Unique migrate projects    : " + ($projects -join ", "))

  $outObjects = New-Object System.Collections.Generic.List[object]

  foreach ($r in $rows) {
    $vm  = $r.VMName
    $proj= $r.MigrationProjectName
    $rg  = $r.SrcResourceGroup
    $sub = $r.SrcSubscriptionId

    $rowDiagDir = Join-Path $diagDir ("proj-" + $proj + "-vm-" + $vm)
    if (-not (Test-Path $rowDiagDir)) { New-Item -ItemType Directory -Path $rowDiagDir -Force | Out-Null }

    Write-Info "Row => VM:'$vm' Project:'$proj' RG:'$rg' Sub:'$sub'"

    # REST-first enumerate machines
    $enum = Get-ProjectMachinesRest -projectName $proj -resourceGroup $rg -subscriptionId $sub -diagDir $rowDiagDir
    if ($DebugRaw -and $enum) { Save-Json -path (Join-Path $rowDiagDir "rest-migrateProjects-machines.json") -obj $enum -depth 8 }

    $disc = $null
    $source = "None"
    if ($enum -and $enum.value) {
      $csvNorm = Normalize-Name $vm
      foreach ($m in $enum.value) {
        $cands = Get-CandidateNames -machine $m
        if ($cands.Contains($csvNorm)) { $disc = $m; $source = "REST:migrateProjects"; break }
      }
    }

    # CLI diag (try filtered; ignore failures)
    if (-not $disc) {
      $cliArgs = @("migrate","local","get-discovered-server","--project-name",$proj,"--resource-group",$rg,"--display-name",$vm,"--subscription",$sub)
      $rawPath = Join-Path $rowDiagDir ("cli-" + $vm + "-with-filter.txt")
      $cliObj  = Invoke-AzJson -CliArgs $cliArgs -RawOutPath $rawPath
      if ($DebugRaw -and $cliObj) { Save-Json -path (Join-Path $rowDiagDir "cli-json.json") -obj $cliObj -depth 8 }
      if ($cliObj) { $disc = $cliObj; $source = "CLI:migrate/local" }
    }

    # Extract useful properties safely
    $osType=$null; $osName=$null; $bootType=$null; $cpuCount=$null; $memoryGB=$null; $diskSummary=$null
    if ($disc) {
      $props = $disc.properties
      if ($props) {
        $bootType = $props.bootType
        $osName   = $props.osName
        $discList = @($props.discoveryData)
        if ($discList -and $discList.Count -gt 0) {
          $dd = $discList[0]
          $osType = $dd.osType
          if ($dd.extendedInfo) {
            $cpuCount    = $dd.extendedInfo.cpuCount
            $memoryGB    = $dd.extendedInfo.memoryInGB
            $diskSummary = $dd.extendedInfo.diskSummary
          }
        }
      }
    }

    $found  = [bool]$disc
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
        FoundInAzureMigrate = $found
        Source              = $source
        BootType            = $bootType
        OSType              = $osType
        OSName              = $osName
        CPUCount            = $cpuCount
        MemoryGB            = $memoryGB
        DiskSummary         = $diskSummary
        Raw                 = $disc
      }
    }

    $outObjects.Add($out) | Out-Null

    if (-not $disc) {
      Write-Warn "No discovered data found for VM '$vm' in project '$proj'. See diagnostics: $rowDiagDir"
    } else {
      Write-Info "Discovered VM '$vm' via $source"
    }
  }

  $outFile = Join-Path $OutputFolder "discovery-output.json"
  $outObjects | ConvertTo-Json -Depth 8 | Out-File -FilePath $outFile -Encoding UTF8
  Write-Info ("Discovery complete. Records: " + $outObjects.Count)
  Write-Info ("Saved file: $outFile")
  if ($DebugRaw) { Write-Info ("Diagnostics saved under: " + $diagDir) }
}
catch {
  Write-Err ("Fatal error in discovery-physical: " + $_.ToString())
  exit 1
}

