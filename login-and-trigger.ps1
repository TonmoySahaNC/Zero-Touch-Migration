
<#
.SYNOPSIS
  Logs in to Azure (SPN or interactive), validates prerequisites, and triggers Discovery + Business Application Mapping.

.DESCRIPTION
  - Supports Service Principal login via environment variables:
      AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID
  - Optionally sets Azure subscription context (either parameter or inferred later).
  - Ensures Azure CLI "migrate" extension is installed (auto-installs if missing).
  - Calls discovery-physical.ps1, then business-mapping.ps1.

.NOTES
  Assumes Azure CLI is available on the GitHub runner (standard Microsoft-hosted images have az installed).
  Discovery uses 'az migrate local get-discovered-server' for project machines (migrate extension). See Microsoft Learn.  # ref: turn3search12, turn3search4
#>

param(
  [switch]$UseServicePrincipal,
  [string]$InputCsv            = ".\migration_input.csv",
  [string]$SubscriptionId      = "",  # optional override
  [string]$DiscoveryScriptPath = ".\discovery-physical.ps1",
  [string]$MappingScriptPath   = ".\business-mapping.ps1",
  [string]$OutputFolder        = ".\out",
  [switch]$VerboseLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info($msg) {
  Write-Host ("[INFO] " + $msg)
}
function Write-Warn($msg) {
  Write-Warning ("[WARN] " + $msg)
}
function Write-Err($msg) {
  Write-Error ("[ERROR] " + $msg)
}

try {
  Write-Info "========== login-and-trigger.ps1 =========="
  Write-Info "InputCsv: $InputCsv"

  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI 'az' is not available on PATH."
  }

  if ($UseServicePrincipal) {
    Write-Info "Logging in with Service Principal..."
    if (-not $env:AZURE_CLIENT_ID -or -not $env:AZURE_CLIENT_SECRET -or -not $env:AZURE_TENANT_ID) {
      throw "AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID must be set for SP login."
    }
    az login --service-principal -u $env:AZURE_CLIENT_ID -p $env:AZURE_CLIENT_SECRET --tenant $env:AZURE_TENANT_ID | Out-Null
  }
  else {
    Write-Info "Interactive login..."
    az login | Out-Null
  }

  if ($SubscriptionId -and $SubscriptionId.Trim() -ne "") {
    Write-Info "Setting subscription context: $SubscriptionId"
    az account set --subscription $SubscriptionId
  }

  # Ensure migrate extension exists (auto-installs first time). See Microsoft Learn. # ref: turn3search4
  $ext = az extension show --name migrate --only-show-errors 2>$null
  if (-not $ext) {
    Write-Info "Azure CLI 'migrate' extension missing. Installing..."
    az extension add --name migrate --only-show-errors | Out-Null
  } else {
    Write-Info "Azure CLI 'migrate' extension present."
  }

  if (-not (Test-Path $InputCsv)) { throw "Input CSV not found: $InputCsv" }
  if (-not (Test-Path $DiscoveryScriptPath)) { throw "Discovery script not found: $DiscoveryScriptPath" }
  if (-not (Test-Path $MappingScriptPath))   { throw "Business mapping script not found: $MappingScriptPath" }

  if (-not (Test-Path $OutputFolder)) {
    Write-Info "Creating output folder: $OutputFolder"
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
  }

  # Environment hints for downstream scripts
  $env:MIG_INPUT_CSV   = (Resolve-Path $InputCsv).Path
  $env:MIG_OUTPUT_DIR  = (Resolve-Path $OutputFolder).Path
  $env:MIG_VERBOSE_LOG = ($VerboseLog.IsPresent ? "true" : "false")

  Write-Info "Starting Discovery phase..."
  & $DiscoveryScriptPath -InputCsv $InputCsv -OutputFolder $OutputFolder -Verbose:$VerboseLog

  $discFile = Join-Path $OutputFolder "discovery-output.json"
  if (-not (Test-Path $discFile)) { throw "Discovery output missing: $discFile" }

  Write-Info "Starting Business Application Mapping phase..."
  & $MappingScriptPath -DiscoveryFile $discFile -OutputFolder $OutputFolder -Verbose:$VerboseLog

  Write-Info "login-and-trigger finished successfully."
}
catch {
  Write-Err "Fatal error in login-and-trigger: $($_.Exception.Message)"
  exit 1

