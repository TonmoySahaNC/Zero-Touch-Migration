param(
    [string]$TenantId = $env:AZURE_TENANT_ID,
    [string]$ClientId = $env:AZURE_CLIENT_ID,
    [string]$ClientSecret = $env:AZURE_CLIENT_SECRET,
    [ValidateSet('DryRun','Replicate')][string]$Mode = 'DryRun',
    [string]$CsvPath = (Join-Path $PSScriptRoot 'migration_input.csv'),
    [switch]$InstallAz,
    [switch]$UseAzCli
)

function Prompt-IfMissing([string]$name, [ref]$value, [bool]$secure=$false) {
    if ([string]::IsNullOrWhiteSpace($value.Value)) {
        if ($secure) {
            $s = Read-Host -Prompt "Enter $name" -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            $value.Value = $plain
        } else {
            $value.Value = Read-Host -Prompt "Enter $name"
        }
    }
}

# Prompt for missing values
[ref]$t = [ref]$TenantId
[ref]$c = [ref]$ClientId
[ref]$s = [ref]$ClientSecret
Prompt-IfMissing 'AZURE_TENANT_ID' ([ref]$t)
Prompt-IfMissing 'AZURE_CLIENT_ID' ([ref]$c)
Prompt-IfMissing 'AZURE_CLIENT_SECRET' ([ref]$s) -secure:$true

$TenantId = $t.Value
$ClientId = $c.Value
$ClientSecret = $s.Value

# Export environment variables for scripts that consume them
$env:AZURE_TENANT_ID = $TenantId
$env:AZURE_CLIENT_ID = $ClientId
$env:AZURE_CLIENT_SECRET = $ClientSecret

Write-Host "Using Tenant: $TenantId`nClientId: $ClientId`nCsv: $CsvPath`nMode: $Mode"

if ($InstallAz) {
    Write-Host 'Installing Az PowerShell modules (CurrentUser)...'
    try {
        Install-Module Az -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    } catch {
        Write-Warning "Install-Module failed: $_"
    }
}

if (-not $UseAzCli) {
    Write-Host 'Authenticating with Connect-AzAccount (service principal)...'
    try {
        $secureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
        $creds = New-Object System.Management.Automation.PSCredential($ClientId, $secureSecret)
        Connect-AzAccount -ServicePrincipal -Credential $creds -Tenant $TenantId -ErrorAction Stop
    } catch {
        Write-Error "Connect-AzAccount failed: $_"
        exit 2
    }
} else {
    Write-Host 'Authenticating with Azure CLI (az) as service principal...'
    try {
        az login --service-principal -u $ClientId -p $ClientSecret --tenant $TenantId | Out-Null
    } catch {
        Write-Error "az login failed: $_"
        exit 3
    }
}

if ($Mode -eq 'Replicate') {
    $confirm = Read-Host -Prompt 'Mode is Replicate and will perform real replication. Type YES to continue'
    if ($confirm -ne 'YES') {
        Write-Host 'Aborting — replicate not confirmed.'
        exit 0
    }
}

try {
    Push-Location $PSScriptRoot
    if (-not (Test-Path -Path '.\login-and-trigger.ps1')) {
        Write-Error 'login-and-trigger.ps1 not found in repository root.'
        exit 4
    }

    Write-Host 'Running login-and-trigger.ps1...'
    & .\login-and-trigger.ps1 -UseServicePrincipal -InputCsv $CsvPath -Mode $Mode
    $exit = $LASTEXITCODE
    Pop-Location
    exit $exit
} catch {
    Write-Error "Execution failed: $_"
    exit 5
}
