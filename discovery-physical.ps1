function Get-MigInput {
    param(
        [string]$EnvName,
        [string]$Prompt
    )

    $val = $env:$EnvName
    if ($val -and $val -ne "") {
        return $val
    }

    return Read-Host $Prompt
}

param(
    [string]$TokenFile    = ".\token.enc",
    [string]$OutputFolder = ".\",
    [string]$Script4      = ".\replication-run.ps1"
)

try {
    $subscriptionId = Get-MigInput -EnvName "MIG_SRC_SUBSCRIPTION_ID" -Prompt "Enter subscription id for migration project"
    $rg             = Get-MigInput -EnvName "MIG_SRC_RG"              -Prompt "Enter resource group name that contains the migration project"
    $projectName    = Get-MigInput -EnvName "MIG_PROJECT_NAME"        -Prompt "Enter migration project name"

    Write-Host "Setting subscription context to $subscriptionId"
    Set-AzContext -Subscription $subscriptionId -ErrorAction Stop

    $projResources = Get-AzResource -ResourceGroupName $rg -ResourceName $projectName -ErrorAction SilentlyContinue

    if (-not $projResources) {
        $projResources = Get-AzResource -ResourceGroupName $rg -ErrorAction Stop |
            Where-Object { $_.ResourceType -like "Microsoft.Migrate/*" -and $_.Name -eq $projectName }
    }

    if (-not $projResources) {
        throw ("Could not find a Microsoft.Migrate project named " + $projectName + " in RG " + $rg + ".")
    }

    $proj = $projResources[0]
    Write-Host ("Found project: " + $proj.Name + " [" + $proj.ResourceType + "]")

    if ($proj.ResourceType -ieq "Microsoft.Migrate/migrateprojects") {
        $apiPath = "/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.Migrate/migrateProjects/$projectName/machines?api-version=2018-09-01-preview"
    }
    elseif ($proj.ResourceType -ieq "Microsoft.Migrate/assessmentProjects") {
        $apiPath = "/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.Migrate/assessmentProjects/$projectName/machines?api-version=2019-10-01"
    }
    else {
        $apiPath = "/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.Migrate/migrateProjects/$projectName/machines?api-version=2018-09-01-preview"
    }

    Write-Host "Calling Azure Migrate API:"
    Write-Host "  $apiPath"

    $allMachines = @()
    $next = $apiPath

    while ($next) {
        $resp = Invoke-AzRest -Path $next -Method GET -ErrorAction Stop
        $bodyText = $resp.Content
        $body = $bodyText | ConvertFrom-Json

        if ($null -ne $body.value) {
            $allMachines += $body.value
        }
        elseif ($body -is [System.Array]) {
            $allMachines += $body
        }
        else {
            $allMachines += ,$body
        }

        $nextLink = $null
        if ($body.nextLink) {
            $nextLink = $body.nextLink
        }
        elseif ($body.'@odata.nextLink') {
            $nextLink = $body.'@odata.nextLink'
        }

        if ($nextLink) {
            $next = $nextLink
        }
        else {
            $next = $null
        }
    }

    if ($allMachines.Count -eq 0) {
        throw "Discovery produced zero machines. Ensure the appliance has sent discovery data and your account can read project machines."
    }

    $normalized = @()

    foreach ($m in $allMachines) {
        $props = $null
        if ($m.PSObject.Properties.Match('properties')) {
            $props = $m.properties
        }
        else {
            $props = $m
        }

        $machineName = $null
        if ($props -ne $null) {
            if ($props.PSObject.Properties.Match('name') -and $props.name) {
                $machineName = $props.name
            }
            elseif ($props.PSObject.Properties.Match('displayName') -and $props.displayName) {
                $machineName = $props.displayName
            }
            elseif ($props.PSObject.Properties.Match('machineName') -and $props.machineName) {
                $machineName = $props.machineName
            }
        }

        if (-not $machineName -and $m.PSObject.Properties.Match('name') -and $m.name) {
            $machineName = $m.name
        }

        if (-not $machineName) {
            $machineName = "vm-" + ([guid]::NewGuid().ToString("N").Substring(0,8))
        }

        $os = ""
        if ($props -ne $null) {
            if ($props.PSObject.Properties.Match('osName') -and $props.osName) {
                $os = $props.osName
            }
            elseif ($props.PSObject.Properties.Match('operatingSystem') -and $props.operatingSystem) {
                $os = $props.operatingSystem
            }
            elseif ($props.PSObject.Properties.Match('osType') -and $props.osType) {
                $os = $props.osType
            }
        }

        if (-not $os) {
            $os = "UNKNOWN"
        }

        $obj = [PSCustomObject]@{
            MachineName = $machineName
            OS          = $os
            Raw         = $m
        }

        $normalized += $obj
    }

    $timestamp = (Get-Date).ToString("yyyyMMddHHmmss")
    $fileName  = "migration_discovery_" + $projectName + "_" + $timestamp + ".json"
    $outFile   = Join-Path -Path $OutputFolder -ChildPath $fileName

    $normalized | ConvertTo-Json -Depth 64 | Out-File -FilePath $outFile -Encoding utf8

    Write-Host ("Discovery complete. Found " + $normalized.Count + " machines.")
    Write-Host "Saved file: $outFile"

    if (-not (Test-Path $Script4)) {
        throw ("replication script not found: " + $Script4)
    }

    & $Script4 -TokenFile $TokenFile -DiscoveryFile $outFile
}
catch {
    Write-Error ("Fatal error in discovery-physical: " + $_)
    exit 1
}
