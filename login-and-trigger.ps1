
<#
  v114
  - Accepts -Mode (DryRun|Replicate) to stay compatible with existing YAML.
  - Sets MIG_MODE environment variable for downstream phases.
  - Runs child scripts parameterless via Start-Process to avoid any -Verbose collisions.
#>

param(
  [switch]$UseServicePrincipal,
  [string]$InputCsv            = ".\migration_input.csv",
  [string]$Mode                = "DryRun",  # accepted for YAML backward compatibility
  [string]$SubscriptionId      = "",
  [string]$DiscoveryScriptPath = ".\discovery-physical.ps1",
  [string]$MappingScriptPath   = ".\business-mapping.ps1",
  [string]$OutputFolder        = ".\out",
  [switch]$VerboseLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host ("[INFO] " + $msg) }
function Write-Err($msg)  { Write-Error ("[ERROR] " + $msg) }

try {
  Write-Info "========== login-and-trigger.ps1 =========="
  Write-Info "InputCsv: $InputCsv"

  if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI 'az' is not available on PATH." }

  # Login
  if ($UseServicePrincipal) {
    Write-Info "Logging in with Service Principal..."
    if (-not $env:AZURE_CLIENT_ID -or -not $env:AZURE_CLIENT_SECRET -or -not $env:AZURE_TENANT_ID) {
      throw "AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID must be set for SP login."
    }
    az login --service-principal -u $env:AZURE_CLIENT_ID -p $env:AZURE_CLIENT_SECRET --tenant $env:AZURE_TENANT_ID | Out-Null
  } else {
    Write-Info "Interactive login..."
    az login | Out-Null
  }

  # Subscription context
  if ($SubscriptionId -and $SubscriptionId.Trim() -ne "") {
    Write-Info "Setting subscription context: $SubscriptionId"
    az account set --subscription $SubscriptionId
  }

  # Ensure migrate CLI extension
  $ext = az extension show --name migrate --only-show-errors 2>$null
  if (-not $ext) {
    Write-Info "Azure CLI 'migrate' extension missing. Installing..."
    az extension add --name migrate --only-show-errors | Out-Null
  } else {
    Write-Info "Azure CLI 'migrate' extension present."
  }

  # Validate paths
  if (-not (Test-Path $InputCsv)) { throw "Input CSV not found: $InputCsv" }
  if (-not (Test-Path $DiscoveryScriptPath)) { throw "Discovery script not found: $DiscoveryScriptPath" }
  if (-not (Test-Path $MappingScriptPath))   { throw "Business mapping script not found: $MappingScriptPath" }

  if (-not (Test-Path $OutputFolder)) {
    Write-Info "Creating output folder: $OutputFolder"
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
  }

  # --- Set environment variables for child phases ---
  $env:MIG_INPUT_CSV    = (Resolve-Path $InputCsv).Path
  $env:MIG_OUTPUT_DIR   = (Resolve-Path $OutputFolder).Path
  $env:MIG_DETAILED     = ($VerboseLog.IsPresent ? "true" : "false")
  $env:MIG_MODE         = $Mode

  Write-Info "Starting Discovery phase..."
  $disc = Start-Process -FilePath 'powershell' `
           -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Resolve-Path $DiscoveryScriptPath).Path) `
           -NoNewWindow -Wait -PassThru
  if ($disc.ExitCode -ne 0) { throw "Discovery phase failed (exit code $($disc.ExitCode))." }

  $discFile = Join-Path $OutputFolder "discovery-output.json"
  if (-not (Test-Path $discFile)) { throw "Discovery output missing: $discFile" }

  # Set for mapping
  $env:MIG_DISCOVERY_FILE = (Resolve-Path $discFile).Path

  Write-Info "Starting Business Application Mapping phase..."
  $map = Start-Process -FilePath 'powershell' `
          -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Resolve-Path $MappingScriptPath).Path) `
          -NoNewWindow -Wait -PassThru
  if ($map.ExitCode -ne 0) { throw "Business mapping phase failed (exit code $($map.ExitCode))." }

  Write-Info "login-and-trigger finished successfully."
}
catch {
  Write-Err "Fatal error in login-and-trigger: $($_.Exception.Message)"
  exit 1
}
