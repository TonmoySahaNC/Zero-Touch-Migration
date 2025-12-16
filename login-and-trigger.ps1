param(
  [switch]$UseServicePrincipal,
  [string]$InputCsv            = ".\migration_input.csv",
  [string]$SubscriptionId      = "",
  [string]$DiscoveryScriptPath = ".\discovery-physical.ps1",
  [string]$MappingScriptPath   = ".\business-mapping.ps1",
  [string]$OutputFolder        = ".\out",
  [switch]$VerboseLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host ("[INFO] " + $msg) }
function Write-Warn($msg) { Write-Warning ("[WARN] " + $msg) }
function Write-Err($msg)  { Write-Error ("[ERROR] " + $msg) }

try {
  Write-Info "========== login-and-trigger.ps1 =========="
  Write-Info "InputCsv: $InputCsv"

  if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI 'az' is not available on PATH." }

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

  if ($SubscriptionId -and $SubscriptionId.Trim() -ne "") {
    Write-Info "Setting subscription context: $SubscriptionId"
    az account set --subscription $SubscriptionId
  }

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

  $env:MIG_INPUT_CSV   = (Resolve-Path $InputCsv).Path
  $env:MIG_OUTPUT_DIR  = (Resolve-Path $OutputFolder).Path
  $env:MIG_VERBOSE_LOG = ($VerboseLog.IsPresent ? "true" : "false")

  Write-Info "Starting Discovery phase..."
  # Spawn new PowerShell process to avoid inherited common parameter collisions (e.g., -Verbose twice)
  $discArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', (Resolve-Path $DiscoveryScriptPath).Path,
                '-InputCsv', (Resolve-Path $InputCsv).Path,
                '-OutputFolder', (Resolve-Path $OutputFolder).Path)
  if ($VerboseLog) { $discArgs += @('-Detailed') }
  $disc = Start-Process -FilePath 'powershell' -ArgumentList $discArgs -NoNewWindow -Wait -PassThru
  if ($disc.ExitCode -ne 0) { throw "Discovery phase failed (exit code $($disc.ExitCode))." }

  $discFile = Join-Path $OutputFolder "discovery-output.json"
  if (-not (Test-Path $discFile)) { throw "Discovery output missing: $discFile" }

  Write-Info "Starting Business Application Mapping phase..."
  $mapArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', (Resolve-Path $MappingScriptPath).Path,
               '-DiscoveryFile', (Resolve-Path $discFile).Path,
               '-OutputFolder', (Resolve-Path $OutputFolder).Path)
  if ($VerboseLog) { $mapArgs += @('-Detailed') }
  $map = Start-Process -FilePath 'powershell' -ArgumentList $mapArgs -NoNewWindow -Wait -PassThru
  if ($map.ExitCode -ne 0) { throw "Business mapping phase failed (exit code $($map.ExitCode))." }

  Write-Info "login-and-trigger finished successfully."
}
catch {
  Write-Err "Fatal error in login-and-trigger: $($_.Exception.Message)"
  exit 1
}

