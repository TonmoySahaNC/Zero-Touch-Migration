param(
    [string]$TokenFile    = ".\token.enc",
    [string]$InputCsv     = ".\migration_input.csv",
    [string]$OutputFolder = ".\",
    [string]$Script4      = ".\replication-run.ps1"
)

function Get-Field {
    param(
        [object]$Row,
        [string[]]$Names
    )
    foreach ($n in $Names) {
        if ($Row.PSObject.Properties.Name -contains $n) {
            $val = $Row.$n
            if ($null -ne $val) {
                $s = $val.ToString().Trim()
                if ($s -ne "") { return $s }
            }
        }
    }
    return ""
}

try {
    if (-not (Test-Path $InputCsv)) {
        throw ("Input CSV file not found: " + $InputCsv)
    }

    $csvRows = Import-Csv -Path $InputCsv
    if (-not $csvRows -or $csvRows.Count -eq 0) {
        throw "Input CSV has no data."
    }

    # Only care about rows where MigrationType = Physical
    $physicalRows = @()
    foreach ($row in $csvRows) {
        $mt = ""
        if ($row.PSObject.Properties.Name -contains "MigrationType" -and $row.MigrationType) {
            $mt = $row.MigrationType.ToString().Trim().ToLower()
        }
        if ($mt -eq "physical") { $physicalRows += $row }
    }

    if ($physicalRows.Count -eq 0) {
        throw "No rows with MigrationType 'Physical' found in CSV."
    }

    # Source info from first Physical row (supports old/new headers)
    $first = $physicalRows[0]

    $sourceSubId = Get-Field -Row $first -Names @("SourceSubscriptionId","SrcSubscriptionId","SourceSubId")
    $sourceRG    = Get-Field -Row $first -Names @("SourceResourceGroup","SrcResourceGroup","SourceRG")
    $projectName = Get-Field -Row $first -Names @("MigrateProjectName","MigrationProjectName","AzureMigrateProjectName")

    if ($sourceSubId -eq "" -or $sourceRG -eq "" -or $projectName -eq "") {
        throw "SourceSubscriptionId/SrcSubscriptionId, SourceResourceGroup/SrcResourceGroup, or MigrateProjectName/MigrationProjectName missing in CSV."
    }

    Write-Host ("Setting subscription context to " + $sourceSubId)
    Set-AzContext -Subscription $sourceSubId -ErrorAction Stop

    # Find Azure Migrate project
    $projResources = Get-AzResource -ResourceGroupName $sourceRG -ResourceName $projectName -ErrorAction SilentlyContinue

    if (-not $projResources) {
        $projResources = Get-AzResource -ResourceGroupName $sourceRG -ErrorAction Stop |
            Where-Object { $_.ResourceType -like "Microsoft.Migrate/*" -and $_.Name -eq $projectName }
    }

    if (-not $projResources) {
        throw ("Could not find a Microsoft.Migrate project named " + $projectName + " in RG " + $sourceRG + ".")
    }

    $proj = $projResources[0]
    Write-Host ("Found project: " + $proj.Name + " [" + $proj.ResourceType + "]")

    # Build API path for machines
    $apiPath = ""
    if ($proj.ResourceType -ieq "Microsoft.Migrate/migrateprojects") {
        $apiPath = "/subscriptions/" + $sourceSubId + "/resourceGroups/" + $sourceRG + "/providers/Microsoft.Migrate/migrateProjects/" + $projectName + "/machines?api-version=2018-09-01-preview"
    } elseif ($proj.ResourceType -ieq "Microsoft.Migrate/assessmentProjects") {
        $apiPath = "/subscriptions/" + $sourceSubId + "/resourceGroups/" + $sourceRG + "/providers/Microsoft.Migrate/assessmentProjects/" + $projectName + "/machines?api-version=2019-10-01"
    } else {
        $apiPath = "/subscriptions/" + $sourceSubId + "/resourceGroups/" + $sourceRG + "/providers/Microsoft.Migrate/migrateProjects/" + $projectName + "/machines?api-version=2018-09-01-preview"
    }

    Write-Host "Calling Azure Migrate API:"
    Write-Host ("  " + $apiPath)

    $allMachines = @()
    $next = $apiPath

    while ($next) {
        $resp     = Invoke-AzRest -Path $next -Method GET -ErrorAction Stop
        $bodyText = $resp.Content
        $body     = $bodyText | ConvertFrom-Json

        if ($null -ne $body.value) {
            $allMachines += $body.value
        } elseif ($body -is [System.Array]) {
            $allMachines += $body
        } else {
            $allMachines += ,$body
        }

        $nextLink = $null
        if ($body.PSObject.Properties.Name -contains "nextLink" -and $body.nextLink) {
            $nextLink = $body.nextLink
        } elseif ($body.PSObject.Properties.Name -contains "@odata.nextLink" -and $body.'@odata.nextLink') {
            $nextLink = $body.'@odata.nextLink'
        }

        if ($nextLink) { $next = $nextLink } else { $next = $null }
    }

    if ($allMachines.Count -eq 0) {
        throw "Discovery produced zero machines from Azure Migrate project. Check appliance and access."
    }

    # Helper to choose best discoveryData entry
    function Get-BestDiscoveryEntry {
        param([object]$props)

        if (-not $props) { return $null }

        $discArray = $null
        if ($props.PSObject.Properties.Name -contains "discoveryData" -and $props.discoveryData) {
            $discArray = $props.discoveryData
        }

        if (-not $discArray) { return $null }

        $chosen = $null
        foreach ($d in $discArray) {
            if ($d.PSObject.Properties.Name -contains "solutionName" -and $d.solutionName) {
                $sn = $d.solutionName.ToString()
                if ($sn -like "*Servers-Discovery*") {
                    $chosen = $d
                }
            }
        }

        if ($null -eq $chosen) {
            $chosen = $discArray[0]
        }

        return $chosen
    }

    # Normalize ALL machines, dedupe by VM name (machineName)
    $normalized = @()
    $seenVM = @{}

    foreach ($m in $allMachines) {
        $props = $null
        if ($m.PSObject.Properties.Name -contains "properties" -and $m.properties) {
            $props = $m.properties
        }

        $disc = Get-BestDiscoveryEntry -props $props
        if (-not $disc) { continue }

        $vmName = ""
        if ($disc.PSObject.Properties.Name -contains "machineName" -and $disc.machineName) {
            $vmName = $disc.machineName.ToString()
        }

        if ([string]::IsNullOrWhiteSpace($vmName)) {
            if ($m.PSObject.Properties.Name -contains "name" -and $m.name) {
                $vmName = $m.name.ToString()
            }
        }

        if ([string]::IsNullOrWhiteSpace($vmName)) {
            continue
        }

        if ($seenVM.ContainsKey($vmName)) {
            continue
        }
        $seenVM[$vmName] = $true

        $osName = "UNKNOWN"
        if ($disc.PSObject.Properties.Name -contains "osName" -and $disc.osName) {
            $osName = $disc.osName.ToString()
        }

        $cpuCores = $null
        $ramGb    = $null

        if ($disc.PSObject.Properties.Name -contains "extendedInfo" -and $disc.extendedInfo) {
            $ext = $disc.extendedInfo
            if ($ext.PSObject.Properties.Name -contains "memoryDetails" -and $ext.memoryDetails) {
                try {
                    $memObj = $ext.memoryDetails | ConvertFrom-Json
                    if ($memObj -and $memObj.PSObject.Properties.Name -contains "NumberOfProcessorCore" -and $memObj.NumberOfProcessorCore) {
                        $cpuCores = [int]$memObj.NumberOfProcessorCore
                    }
                    if ($memObj -and $memObj.PSObject.Properties.Name -contains "AllocatedMemoryInMB" -and $memObj.AllocatedMemoryInMB) {
                        $ramGb = [Math]::Round([double]$memObj.AllocatedMemoryInMB / 1024, 2)
                    }
                } catch {
                    # ignore parse errors
                }
            }
        }

        $normalized += [PSCustomObject]@{
            MachineName = $vmName
            OS          = $osName
            CpuCores    = $cpuCores
            RamGB       = $ramGb
            Raw         = $m
        }
    }

    if ($normalized.Count -eq 0) {
        throw "Normalization produced zero entries from Azure Migrate discovery data."
    }

    $timestamp = (Get-Date).ToString("yyyyMMddHHmmss")
    $outFile   = Join-Path -Path $OutputFolder -ChildPath ("migration_discovery_filtered_" + $projectName + "_" + $timestamp + ".json")

    $normalized | ConvertTo-Json -Depth 50 | Out-File -FilePath $outFile -Encoding utf8

    Write-Host ("Discovery complete. Found " + $normalized.Count + " machines.")
    Write-Host ("Saved file: " + $outFile)

    if (-not (Test-Path $Script4)) {
        throw ("replication script not found at " + $Script4)
    }

    Write-Host ("Reading discovery file via replication-run: " + $outFile)
    & $Script4 -TokenFile $TokenFile -DiscoveryFile $outFile -InputCsv $InputCsv
}
catch {
    Write-Error ("Fatal error in discovery-physical: " + $_.ToString())
    exit 1
}
