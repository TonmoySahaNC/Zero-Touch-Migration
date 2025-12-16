
<# 
  Discovery phase (parameterless): 
  Reads MIG_INPUT_CSV, MIG_OUTPUT_DIR, MIG_DETAILED from environment.
  Collects discovered VM data from Azure Migrate and writes discovery-output.json.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host ("[INFO] " + $msg) }
function Write-Warn($msg) { Write-Warning ("[WARN] " + $msg) }
function Write-Err($msg)  { Write-Error ("[ERROR] " + $msg) }

# --- Read environment ---
$InputCsv    = $env:MIG_INPUT_CSV
$OutputFolder= $env:MIG_OUTPUT_DIR
$Detailed    = ($env:MIG_DETAILED -eq "true")

# Required CSV columns (updated schema)
$requiredColumns = @(
  "MigrationType","SrcSubscriptionId","SrcResourceGroup","MigrationProjectName",
  "TgtSubscriptionId","TgtResourceGroup","TgtVNet","TgtSubnet","TgtLocation",
  "BootDiagStorageAccountName","BootDiagStorageAccountRG","AdminUsername",
  "VMName","BusinessApplicationName"
)

function Test-Columns($rows) {
  # Normalize rows to array; pick a safe sample
  $arr = @($rows)
  if ($arr.Count -eq 0) { throw "Input CSV has no rows." }
  $sample  = $arr[0]
  $present = $sample.PSObject.Properties.Name
  $missing = $requiredColumns | Where-Object { $_ -notin $present }
  if ($missing.Count -gt 0) { throw ("Input CSV missing required columns: " + ($missing -join ", ")) }
}

function Get-DiscoveredServerCli([string]$projectName,[string]$resourceGroup,[string]$subscriptionId,[string]$vmDisplayName) {
  if ($subscriptionId -and $subscriptionId.Trim() -ne "") { az account set --subscription $subscriptionId | Out-Null }
  # Azure CLI 'migrate' extension (auto-installs on first use); get by display name
  $cmd = @("migrate","local","get-discovered-server",
           "--project-name",$projectName,"--resource-group",$resourceGroup,
           "--display-name",$vmDisplayName,"--subscription",$subscriptionId)
  $json = az @cmd --only-show-errors 2>$null
  if ($json) { return ($json | ConvertFrom-Json) }
  return $null
}

function Get-ProjectMachinesRest([string]$projectName,[string]$resourceGroup,[string]$subscriptionId) {
  # Fallback enumeration via REST (Microsoft.Migrate/migrateProjects/.../machines)
  $uri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/migrateProjects/$projectName/machines?api-version=2018-09-01-preview"
  $json = az rest --method get --url "https://management.azure.com$uri" --output json --only-show-errors 2>$null
  if ($json) { return ($json | ConvertFrom-Json) }
  return $null
}

function Select-MachineMatch($enumerateResult,[string]$vmDisplayName) {
  if (-not $enumerateResult -or -not $enumerateResult.value) { return $null }
  foreach ($m in $enumerateResult.value) {
    $disp     = $m.properties.displayName
    $discList = $m.properties.discoveryData
    $discName = $null
    if ($discList -and $discList.Count -gt 0) { $discName = $discList[0].machineName }
    if ($disp -and $disp -eq $vmDisplayName) { return $m }
    if ($discName -and $discName -eq $vmDisplayName) { return $m }
    if ($m.name -eq $vmDisplayName) { return $m }
  }
  return $null
}

try {
  Write-Info "========== discovery-physical.ps1 =========="
  Write-Info "InputCsv     : $InputCsv"
  Write-Info "OutputFolder : $OutputFolder"

  if (-not (Test-Path $InputCsv)) { throw "Input CSV not found: $InputCsv" }
  if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

  $rows = Import-Csv -Path $InputCsv
  # Normalize single PSCustomObject to array
  $rows = @($rows)
  if ($rows.Count -eq 0) { throw "Input CSV is empty: $InputCsv" }
  Test-Columns -rows $rows

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

    if ($Detailed) { Write-Info "Discovering VM '$vm' in project '$proj' (RG: $rg, Sub: $sub)..." }

    # Primary: CLI discovered server
    $cliObj = Get-DiscoveredServerCli -projectName $proj -resourceGroup $rg -subscriptionId $sub -vmDisplayName $vm

    # Fallback: enumerate via REST
    $restMatch = $null
    if (-not $cliObj) {
      $enum = Get-ProjectMachinesRest -projectName $proj -resourceGroup $rg -subscriptionId $sub
      $restMatch = Select-MachineMatch -enumerateResult $enum -vmDisplayName $vm
    }

    # Build enriched record
    $disc = $cliObj
    if (-not $disc -and $restMatch) { $disc = $restMatch }

    $osType=$null; $osName=$null; $bootType=$null; $cpuCount=$null; $memoryGB=$null; $diskSummary=$null

    if ($disc) {
      $props = $disc.properties
      if ($props) {
        $bootType = $props.bootType
        $osName   = $props.osName
        if ($props.discoveryData -and $props.discoveryData.Count -gt 0) {
          $dd = $props.discoveryData[0]
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
    $source = "None"
    if ($cliObj)      { $source = "CLI:migrate/local" }
    elseif ($restMatch){ $source = "REST:migrateProjects" }

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
      Write-Warn "No discovered data found for VM '$vm' in project '$proj'. Check appliance sync or VM naming."
    }
  }

  $outFile = Join-Path $OutputFolder "discovery-output.json"
  $outObjects | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding UTF8
  Write-Info ("Discovery complete. Records: " + $outObjects.Count)
  Write-Info ("Saved file: $outFile")
}
catch {
  Write-Err ("Fatal error in discovery-physical: " + $_.ToString())
  exit 1
}


