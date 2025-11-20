param(
    [switch]$UseServicePrincipal,
    [string]$TokenFile = ".\token.enc",
    [string]$Script2   = ".\select-migration-type.ps1"
)

try {
    Write-Host "Connecting to Azure"

    if ($UseServicePrincipal -or $env:USE_SERVICE_PRINCIPAL -eq "true") {
        $tenantId     = $env:AZURE_TENANT_ID
        $clientId     = $env:AZURE_CLIENT_ID
        $clientSecret = $env:AZURE_CLIENT_SECRET

        if (-not $tenantId -or -not $clientId -or -not $clientSecret) {
            throw "Missing AZURE_TENANT_ID, AZURE_CLIENT_ID or AZURE_CLIENT_SECRET."
        }

        $secureSecret = ConvertTo-SecureString $clientSecret -AsPlainText -Force
        $spCred       = New-Object System.Management.Automation.PSCredential($clientId, $secureSecret)

        Connect-AzAccount -ServicePrincipal -Tenant $tenantId -Credential $spCred -ErrorAction Stop

        Write-Host "Connected using service principal."
    }
    else {
        Write-Host "Connecting interactively using user login."
        Connect-AzAccount -ErrorAction Stop
    }

    Write-Host ""
    Write-Host "Retrieving subscriptions in this context"
    Get-AzSubscription | Format-Table -Property Name, Id, TenantId

    Write-Host ""
    Write-Host "Acquiring access token"
    $tokenResult = Get-AzAccessToken -ResourceUrl "https://management.azure.com/" -ErrorAction Stop
    $token = $tokenResult.Token

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($token)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    [System.IO.File]::WriteAllBytes($TokenFile, $protected)

    Write-Host "Encrypted token saved to" $TokenFile

    if (-not (Test-Path $Script2)) {
        throw "Next script not found: $Script2"
    }

    Write-Host "Calling next script"
    & $Script2 -TokenFile $TokenFile
}
catch {
    Write-Error ("Fatal error in login-and-trigger: " + $_)
    exit 1
}
