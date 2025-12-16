
param(
    [switch]$UseServicePrincipal,      # use SPN (clientId/secret + tenant provided through env or Azure CLI)
    [string]$InputCsv = ".\migration_input.csv",
    [string]$Mode     = "Replicate",   # DryRun | Replicate
    [string]$SubscriptionId = ""       # optional - specify subscription to set context
)

Set-StrictMode -Version Latest
try {
    Write-Host "========== login-and-trigger.ps1 =========="

    if ($UseServicePrincipal) {
        Write-Host "Logging in with Service Principal..."
        # Expect AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID in env or use az login with service-principal args here
        if (-not $env:AZURE_CLIENT_ID -or -not $env:AZURE_CLIENT_SECRET -or -not $env:AZURE_TENANT_ID) {
            Write-Error "AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID must be set in environment for SPN login."
            exit 1
        }
        az login --service-principal -u $env:AZURE_CLIENT_ID -p $env:AZURE_CLIENT_SECRET --tenant $env:AZURE_TENANT_ID | Out-Null
    }
    else {
        Write-Host "Interactive login..."
        az login | Out-Null
    }

    if ($SubscriptionId -and $SubscriptionId.Trim() -ne "") {
        Write-Host "Setting subscription: $SubscriptionId"
        az account set --subscription $SubscriptionId
    }

    # Create token file for compatibility with older scripts (not used by replication-run but kept for parity)
    try {
        $accessToken = az account get-access-token --query accessToken -o tsv
        if ($accessToken) {
            $tokenFile = ".\token.enc"
            $accessToken | Out-File -FilePath $tokenFile -Encoding ascii
            Write-Host "Acquired access token and saved to $tokenFile"
        }
    } catch {
        Write-Warning "Unable to save token file: $($_.Exception.Message)"
    }

    # Call discovery directly (no discovery script)
    $replicationScript = ".\discovery-run.ps1"
    if (-not (Test-Path $replicationScript)) {
        Write-Error "Replication script not found at $replicationScript"
        exit 1
    }
    
    # Call replication-run directly (no discovery script)
    $replicationScript = ".\replication-run.ps1"
    if (-not (Test-Path $replicationScript)) {
        Write-Error "Replication script not found at $replicationScript"
        exit 1
    }

    # Export MIG_MODE and MIG_INPUT_CSV to environment to be consumed by downstream scripts if needed
    $env:MIG_MODE = $Mode
    $env:MIG_INPUT_CSV = $InputCsv

    Write-Host "Calling replication-run..."
    & $replicationScript -TokenFile ".\token.enc" -InputCsv $InputCsv -Mode $Mode

    Write-Host "login-and-trigger finished."
}
catch {
    Write-Error "Fatal error in login-and-trigger: $($_.Exception.Message)"
    exit 1
}
