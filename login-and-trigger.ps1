if ($UseServicePrincipal -or $env:USE_SERVICE_PRINCIPAL -eq "true") {
    $tenantId     = $env:AZURE_TENANT_ID
    $clientId     = $env:AZURE_CLIENT_ID
    $clientSecret = $env:AZURE_CLIENT_SECRET

    if (-not $tenantId -or -not $clientId -or -not $clientSecret) {
        throw "Missing AZURE_TENANT_ID / AZURE_CLIENT_ID / AZURE_CLIENT_SECRET."
    }

    $secureSecret = ConvertTo-SecureString $clientSecret -AsPlainText -Force
    $spCred       = New-Object PSCredential($clientId, $secureSecret)

    Connect-AzAccount -ServicePrincipal -Tenant $tenantId -Credential $spCred -ErrorAction Stop

    Write-Host "Authenticated using service principal. Subscriptions loaded automatically."
}
else {
    # normal user login path
}
