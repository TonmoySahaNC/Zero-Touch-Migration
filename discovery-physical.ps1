
<#
.SYNOPSIS
  Discovery phase: read intake CSV, fetch Azure Migrate discovered VM data per project, and emit discovery-output.json.

.DESCRIPTION
  - Uses Azure CLI 'migrate' extension to get discovered servers by display name. # ref: turn3search12
  - Falls back to REST enumeration for project machines if CLI path returns nothing. # ref: turn3search24
  - Writes discovery-output.json consumable by next phases.

.PARAMETER InputCsv
  Path to migration_input.csv (with BusinessApplicationName, no AdminPassword).

.PARAMETER OutputFolder
  Directory for outputs (discovery-output.json).

.NOTES
  Requires 'az login' already performed and subscription context set (or inferred per row).
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$InputCsv,
  [string]$OutputFolder = ".\out",
  [switch]$Verbose
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host ("[INFO] " + $msg) }
function Write-Warn($msg) { Write-Warning ("[WARN] " + $msg) }
function Write-Err($msg)  { Write-Error ("[ERROR] " + $msg) }

# Lightweight schema validation
$requiredColumns = @(
  "MigrationType","SrcSubscriptionId","SrcResourceGroup","MigrationProjectName",
  "TgtSubscriptionId","TgtResourceGroup","TgtVNet","TgtSubnet","TgtLocation",
  "BootDiagStorageAccountName","BootDiagStorageAccountRG","AdminUsername",
  "VMName","BusinessApplicationName"
)

function Test-Columns($rows) {
  $present = $rows[0].PSObject.Properties.Name
  $missing = $requiredColumns | Where-Object { $_ -notin $present }
  if ($missing.Count -gt 0) {
    throw ("Input CSV missing required columns: " + ($missing -join ", "))
  }
}

function Get-DiscoveredServerCli(
  [string]$projectName,
  [string]$resourceGroup,
  [string]$subscriptionId,
  [string]$vmDisplayName
) {
  # Set subscription context in case rows span multiple subscriptions
  if ($subscriptionId -and $subscriptionId.Trim() -ne "") {
    az account set --subscription $subscriptionId | Out-Null
  }
  # Using Azure CLI migrate extension to fetch discovered server(s). # ref: turn3search12
  $cmd = @(
    "migrate","local","get-discovered-server",
    "--project-name", $projectName,
    "--resource-group", $resourceGroup,
    "--display-name", $vmDisplayName,
    "--subscription", $subscriptionId
  )
  $json = az @cmd --only-show-errors 2>$null
  if ($json) { return ($json | ConvertFrom-Json) }
  return $null
}

function Get-ProjectMachinesRest(
  [string]$projectName,
  [string]$resourceGroup,
  [string]$subscriptionId
) {
  # Enumerate machines via Azure Migrate REST (migrateProjects). # ref: turn3search24
  $uri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/migrateProjects/$projectName/machines?api-version=2018-09-01-preview"
  $json = az rest --method get --url "https://management.azure.com$uri" --output json --only-show-errors 2>$null
  if ($json) { return ($json | ConvertFrom-Json) }
  return $null
}

function Select-MachineMatch($enumerateResult, [string]$vmDisplayName) {
  if (-not $enumerateResult -or -not $enumerateResult.value) { return $null }
  # try matching by discoveryData.machineName or properties.displayName when available
  foreach ($m in $enumerateResult.value) {
    $disp = $m.properties.displayName
    $discList = $m.properties.discoveryData
    $discName = $null
    if ($discList -and $discList.Count -gt 0) {
      $discName = $discList[0].machineName
    }
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
  if (-not (Test-Path $OutputFolder)) {
    Write-Info "Creating output folder: $OutputFolder"
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
  }

  $rows = Import-Csv -Path $InputCsv
  if (-not $rows -or $rows.Count -eq 0) { throw "Input CSV is empty: $InputCsv" }
  Test-Columns -rows $rows

  # Consolidate unique subscriptions and projects (for summary/logging)
  $srcSubs = ($rows | Select-Object -ExpandProperty SrcSubscriptionId | Sort-Object -Unique)
  $projects = ($rows | Select-Object -ExpandProperty MigrationProjectName | Sort-Object -Unique)
  Write-Info ("Unique source subscriptions: " + ($srcSubs -join ", "))
  Write-Info ("Unique migrate projects    : " + ($projects -join ", "))

  $outObjects = New-Object System.Collections.Generic.List[object]

  foreach ($r in $rows) {
    $vm = $r.VMName
    $proj = $r.MigrationProjectName
    $rg   = $r.SrcResourceGroup
    $sub  = $r.SrcSubscriptionId

    if ($Verbose) { Write-Info "Discovering VM '$vm' in project '$proj' (RG: $rg, Sub: $sub)..." }

    # 1) Primary: CLI discovered server (filtered by display-name) # ref: turn3search12
    $cliObj = Get-DiscoveredServerCli -projectName $proj -resourceGroup $rg -subscriptionId $sub -vmDisplayName $vm

    # 2) Fallback: enumerate project machines via REST and match # ref: turn3search24
    $restMatch = $null
    if (-not $cliObj) {
      $enum = Get-ProjectMachinesRest -projectName $proj -resourceGroup $rg -subscriptionId $sub
      $restMatch = Select-MachineMatch -enumerateResult $enum -vmDisplayName $vm
    }

    # Build enriched record
    $disc = $cliObj
    if (-not $disc -and $restMatch) { $disc = $restMatch }

    $osType      = $null
    $osName      = $null
    $bootType    = $null
    $cpuCount    = $null
    $memoryGB    = $null
    $diskSummary = $null

    # Extract common properties from discovered payload when available
    if ($disc) {
      # CLI returns a dict; REST returns an ARM resource with properties.*
      $props = $disc.properties
      if ($props) {
        $bootType = $props.bootType
        $osName   = $props.osName
        # From discoveryData if available (REST enumerate example shows OS and disks inside discoveryData). # ref: turn3search24
        if ($props.discoveryData -and $props.discoveryData.Count -gt 0) {
          $dd = $props.discoveryData[0]
          $osType   = $dd.osType
          # Extended info may have cpu/memory/disk details depending on appliance configuration
          if ($dd.extendedInfo) {
            $cpuCount = $dd.extendedInfo.cpuCount
            $memoryGB = $dd.extendedInfo.memoryInGB
            $diskSummary = $dd.extendedInfo.diskSummary
          }
        }
      }
    }

    $out = [PSCustomObject]@{
      Intake = [PSCustomObject]@{
        MigrationType                = $r.MigrationType
        SrcSubscriptionId            = $r.SrcSubscriptionId
        SrcResourceGroup             = $r.SrcResourceGroup
        MigrationProjectName         = $r.MigrationProjectName
        TgtSubscriptionId            = $r.TgtSubscriptionId
        TgtResourceGroup             = $r.TgtResourceGroup
        TgtVNet                      = $r.TgtVNet
        TgtSubnet                    = $r.TgtSubnet
        TgtLocation                  = $r.TgtLocation
        BootDiagStorageAccountName   = $r.BootDiagStorageAccountName
        BootDiagStorageAccountRG     = $r.BootDiagStorageAccountRG
        AdminUsername                = $r.AdminUsername
        VMName                       = $r.VMName
        BusinessApplicationName      = $r.BusinessApplicationName
      }
      Discovery = [PSCustomObject]@{
        FoundInAzureMigrate          = [bool        Source                       = if ($cliObj) { "CLI:migrate/local" } elseif ($restMatch) { "REST:migrateProjects" } else { "None" }
        BootType                     = $bootType
        OSType                       = $osType
        OSName                       = $osName
        CPUCount                     = $cpuCount
        MemoryGB                     = $memoryGB
        DiskSummary                  = $diskSummary
        Raw                          = $disc  # include raw fragment for downstream analysis
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
