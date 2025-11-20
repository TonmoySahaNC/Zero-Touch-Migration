param(
    [string]$TokenFile    = ".\token.enc",
    [string]$InputCsv     = ".\migration_input.csv",
    [string]$OutputFolder = ".\",
    [string]$Script4      = ".\replication-run.ps1",
    [string]$Mode         = ""
)

try {
    if (-not (Test-Path $InputCsv)) {
        throw "Input CSV not found: $InputCsv"
    }

    $rows = Import-Csv -Path $InputCsv
    if ($rows.Count -eq 0) {
        throw "Input CSV is empty: $InputCsv"
    }

    # take global settings from the first row
    $first = $rows[0]

    $srcSubscriptionId = $first.SrcSubscriptionId
    $srcRG             = $first.SrcResourceGroup
    $projectName       = $first.MigrationProjectName

    if (-not $srcSubscriptionId -or -not $srcRG -or -not $projectName) {
        throw "Missing source subscription / resource-group / project name in CSV first row."
    }

    # gather VM names to include (case-insensitive)
    $vmNames = @()
    foreach ($r in $rows) {
        if ($r.VMName -and $r.VMName.Trim() -ne "") {
            $vmNames += $r.VMName.Trim()
        }
    }
    $vmNames = $vmNames | ForEach-Object { $_.ToLower() } | Sort-Object -Unique

    Write-Host ("Setting subscription context to " + $srcSubscriptionId)
    Set-AzContext -Subscription $srcSubscriptionId -ErrorAction Stop

    # find migrate project resource
    $projResources = Get-AzResource -ResourceGroupName $srcRG -ResourceName $projectName -ErrorAction SilentlyContinue
    if (-not $projResources) {
        $projResources = Get-AzResource -ResourceGroupName $srcRG -ErrorAction Stop |
            Where-Object { $_.ResourceType -like "Microsoft.Migrate/*" -and $_.Name -eq $projectName }
    }
    if (-not $projResources) {
        throw ("Could not find migration project named " + $projectName + " in RG " + $srcRG)
    }

    $proj = $projResources[0]
    Write-Host ("Found project: " + $proj.Name + " [" + $proj.ResourceType + "]")

    if ($proj.ResourceType -ieq "Microsoft.Migrate/migrateprojects") {
        $apiPath = "/subscriptions/$srcSubscriptionId/resourceGroups/$srcRG/providers/Microsoft.Migrate/migrateProjects/$projectName/machines?api-version=2018-09-01-preview"
    }
    elseif ($proj.ResourceType -ieq "Microsoft.Migrate/assessmentProjects") {
        $apiPath = "/subscriptions/$srcSubscriptionId/resourceGroups/$srcRG/providers/Microsoft.Migrate/assessmentProjects/$projectName/machines?api-version=2019-10-01"
    }
    else {
        $apiPath = "/subscriptions/$srcSubscriptionId/resourceGroups/$srcRG/providers/Microsoft.Migrate/migrateProjects/$projectName/machines?api-version=2018-09-01-preview"
    }

    Write-Host "Calling Azure Migrate API:"
    Write-Host "  $apiPath"

    $allMachines = @()
    $next = $apiPath

    while ($next) {
        $resp = Invoke-AzRest -Path $next -Method GET -ErrorAction Stop
        $body = $resp.Content | ConvertFrom-Json

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
        if ($body.nextLink) { $nextLink = $body.nextLink }
        elseif ($body.'@odata.nextLink') { $nextLink = $body.'@odata.nextLink' }

        if ($nextLink) { $next = $nextLink } else { $next = $null }
    }

    if ($allMachines.Count -eq 0) {
        throw "Discovery produced zero machines from Azure Migrate."
    }

    # helper to pick latest discovery entry and normalise names/os
    function Get-LatestDiscoveryData {
        param($rawObj)
        if ($null -eq $rawObj) { return $null }

        $out = [PSCustomObject]@{ machineName = $null; displayName = $null; osName = $null; osType = $null; discovery = $null }

        # properties may be in .properties or top-level
        $props = $null
        if ($rawObj.PSObject.Properties.Match('properties')) { $props = $rawObj.properties } else { $props = $rawObj }

        if ($props -ne $null) {
            if ($props.PSObject.Properties.Match('name') -and $props.name) { $out.machineName = $props.name }
            if ($props.PSObject.Properties.Match('displayName') -and $props.displayName) { $out.displayName = $props.displayName }
            if ($props.PSObject.Properties.Match('osName') -and $props.osName) { $out.osName = $props.osName }
            if ($props.PSObject.Properties.Match('operatingSystem') -and $props.operatingSystem) { $out.osName = $props.operatingSystem }
            if ($props.PSObject.Properties.Match('osType') -and $props.osType) { $out.osType = $props.osType }
            if ($props.PSObject.Properties.Match('discoveryData') -and $props.discoveryData) {
                $arr = $props.discoveryData
                # pick most recent by lastUpdatedTime or enqueueTime if present
                if ($arr -is [System.Array]) {
                    $best = $null
                    $bestDt = [DateTime]::MinValue
                    foreach ($e in $arr) {
                        $dt = [DateTime]::MinValue
                        try {
                            if ($e.PSObject.Properties.Match('lastUpdatedTime') -and $e.lastUpdatedTime) { $dt = [DateTime]::Parse($e.lastUpdatedTime) }
                            elseif ($e.PSObject.Properties.Match('enqueueTime') -and $e.enqueueTime) { $dt = [DateTime]::Parse($e.enqueueTime) }
                        } catch {}
                        if ($dt -gt $bestDt) { $bestDt = $dt; $best = $e }
                    }
                    if ($best -ne $null) {
                        if ($best.PSObject.Properties.Match('machineName') -and $best.machineName) { $out.machineName = $best.machineName }
                        if ($best.PSObject.Properties.Match('osName') -and $best.osName) { $out.osName = $best.osName }
                        $out.discovery = $best
                    }
                }
                else {
                    $single = $arr
                    if ($single.PSObject.Properties.Match('machineName') -and $single.machineName) { $out.machineName = $single.machineName }
                    if ($single.PSObject.Properties.Match('osName') -and $single.osName) { $out.osName = $single.osName }
                    $out.discovery = $single
                }
            }
        }

        return $out
    }

    # normalize, then filter by vmNames
    $normalized = @()
    foreach ($m in $allMachines) {
        $ld = Get-LatestDiscoveryData -rawObj $m

        $nameCandidates = @()
        if ($ld.machineName) { $nameCandidates += $ld.machineName }
        if ($ld.displayName) { $nameCandidates += $ld.displayName }
        # also attempt top-level fields
        if ($m.PSObject.Properties.Match('name') -and $m.name) { $nameCandidates += $m.name }
        if ($m.PSObject.Properties.Match('properties') -and $m.properties) {
            $p = $m.properties
            if ($p.PSObject.Properties.Match('machineName') -and $p.machineName) { $nameCandidates += $p.machineName }
            if ($p.PSObject.Properties.Match('displayName') -and $p.displayName) { $nameCandidates += $p.displayName }
        }

        $nameCandidates = $nameCandidates |
            Where-Object { $_ -and $_.ToString().Trim() -ne "" } |
            ForEach-Object { $_.ToString().Trim() } |
            Sort-Object -Unique

        $matched = $false
        foreach ($cand in $nameCandidates) {
            if ($vmNames -contains $cand.ToLower()) { $matched = $true; break }
        }

        if ($matched) {
            $obj = [PSCustomObject]@{
                MachineName = ($nameCandidates | Select-Object -First 1)
                OS          = ($ld.osName -or $ld.osType -or "UNKNOWN")
                Raw         = $m
            }
            $normalized += $obj
        }
    }

    if ($normalized.Count -eq 0) {
        throw "After filtering with CSV VM list, zero machines matched. Check VMName values in CSV versus discovery data."
    }

    $timestamp = (Get-Date).ToString("yyyyMMddHHmmss")
    $outFile = Join-Path -Path $OutputFolder -ChildPath ("migration_discovery_filtered_" + $projectName + "_" + $timestamp + ".json")
    $normalized | ConvertTo-Json -Depth 64 | Out-File -FilePath $outFile -Encoding utf8

    Write-Host ("Discovery complete. Found " + $normalized.Count + " machines (filtered).")
    Write-Host "Saved file: $outFile"

    if (-not (Test-Path $Script4)) {
        throw ("replication script not found: " + $Script4)
    }

    & $Script4 -TokenFile $TokenFile -DiscoveryFile $outFile -InputCsv $InputCsv -Mode $Mode
}
catch {
    Write-Error ("Fatal error in discovery-physical: " + $_.ToString())
    exit 1
}
