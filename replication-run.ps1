param(
    [string]$TokenFile = ".\token.enc",
    [Parameter(Mandatory = $true)][string]$DiscoveryFile,
    [string]$InputCsv = ".\migration_input.csv",
    [string]$Mode     = ""
)

function Read-DiscoveryFile {
    param([string]$path)
    $text = Get-Content -Raw -Path $path
    return ConvertFrom-Json $text
}

function Sanitize-ResourceName {
    param([string]$name)
    if (-not $name -or $name -eq "") { $name = "vm" + (Get-Random -Minimum 1000 -Maximum 9999) }
    $chars = $name.ToCharArray()
    $out = ""
    foreach ($c in $chars) {
        if ($c -match "[A-Za-z0-9-]") { $out += $c }
    }
    $out = $out.Trim("-")
    if ($out.Length -gt 64) { $out = $out.Substring(0,64) }
    if ($out -eq "") { $out = "vm" + (Get-Random -Minimum 1000 -Maximum 9999) }
    return $out
}

function Make-WindowsComputerName {
    param([string]$baseName)
    if (-not $baseName -or $baseName -eq "") { $baseName = "win" + (Get-Random -Minimum 10 -Maximum 99) }
    $chars = $baseName.ToCharArray()
    $out = ""
    foreach ($c in $chars) { if ($c -match "[A-Za-z0-9]") { $out += $c } }
    if ($out.Length -gt 12) { $out = $out.Substring(0,12) }
    $rnd = (Get-Random -Minimum 100 -Maximum 999).ToString()
    $candidate = $out + $rnd
    if ($candidate.Length -gt 15) { $candidate = $candidate.Substring(0,15) }
    if ($candidate -match "^[0-9]+$") { $candidate = "win" + $candidate.Substring(0,12) }
    return $candidate
}

function Map-Image-From-OS {
    param([string]$osString)
    if (-not $osString -or $osString -eq "") { return $null }
    $lower = $osString.ToLower()
    if ($lower -match "windows server 2022" -or $lower -match " 2022") {
        return [PSCustomObject]@{ Publisher = "MicrosoftWindowsServer"; Offer = "WindowsServer"; Sku = "2022-datacenter" }
    }
    if ($lower -match "windows server 2019" -or $lower -match " 2019") {
        return [PSCustomObject]@{ Publisher = "MicrosoftWindowsServer"; Offer = "WindowsServer"; Sku = "2019-datacenter" }
    }
    if ($lower -match "windows") {
        return [PSCustomObject]@{ Publisher = "MicrosoftWindowsServer"; Offer = "WindowsServer"; Sku = "2019-datacenter" }
    }
    if ($lower -match "ubuntu 22.04" -or $lower -match "22.04") {
        return [PSCustomObject]@{ Publisher = "Canonical"; Offer = "UbuntuServer"; Sku = "22_04-lts" }
    }
    if ($lower -match "ubuntu 20.04" -or $lower -match "20.04") {
        return [PSCustomObject]@{ Publisher = "Canonical"; Offer = "UbuntuServer"; Sku = "20_04-lts" }
    }
    return $null
}

function Get-CoresAndRamFromDiscovery {
    param($entry)
    $ret = @{ Cores = $null; RAM_GB = $null }
    if ($null -eq $entry) { return $ret }
    try {
        if ($entry.PSObject.Properties.Match("extendedInfo") -and $entry.extendedInfo) {
            $ei = $entry.extendedInfo
            if ($ei.PSObject.Properties.Match("memoryDetails") -and $ei.memoryDetails) {
                $md = $ei.memoryDetails
                try {
                    $mdObj = $md | ConvertFrom-Json
                    if ($mdObj.NumberOfProcessorCore) { $ret.Cores = [int]$mdObj.NumberOfProcessorCore }
                    if ($mdObj.NumberOfCores) { $ret.Cores = [int]$mdObj.NumberOfCores }
                    if ($mdObj.AllocatedMemoryInMB) { $ret.RAM_GB = [math]::Round(([double]$mdObj.AllocatedMemoryInMB / 1024), 2) }
                    if ($mdObj.TotalMemoryMB) { $ret.RAM_GB = [math]::Round(([double]$mdObj.TotalMemoryMB / 1024), 2) }
                } catch {
                    if ($md.NumberOfProcessorCore) { $ret.Cores = [int]$md.NumberOfProcessorCore }
                    if ($md.AllocatedMemoryInMB) { $ret.RAM_GB = [math]::Round(([double]$md.AllocatedMemoryInMB / 1024), 2) }
                }
            }
        }
    } catch {}
    if (-not $ret.Cores) {
        if ($entry.PSObject.Properties.Match("cpuCount") -and $entry.cpuCount) { $ret.Cores = [int]$entry.cpuCount }
        if ($entry.PSObject.Properties.Match("numCpus") -and $entry.numCpus) { $ret.Cores = [int]$entry.numCpus }
    }
    if (-not $ret.RAM_GB) {
        if ($entry.PSObject.Properties.Match("memoryInMB") -and $entry.memoryInMB) { $ret.RAM_GB = [math]::Round(([double]$entry.memoryInMB / 1024), 2) }
        if ($entry.PSObject.Properties.Match("totalMemoryMB") -and $entry.totalMemoryMB) { $ret.RAM_GB = [math]::Round(([double]$entry.totalMemoryMB / 1024), 2) }
    }
    return $ret
}

try {
    Write-Host "Reading discovery file: $DiscoveryFile"
    $discovered = Read-DiscoveryFile -path $DiscoveryFile

    if (-not $discovered -or $discovered.Count -eq 0) {
        throw "Discovery file empty or unreadable."
    }

    if (-not (Test-Path $InputCsv)) {
        throw "Input CSV not found: $InputCsv"
    }

    $rows = Import-Csv -Path $InputCsv
    if ($rows.Count -eq 0) { throw "Input CSV empty." }

    # global settings from first row
    $first = $rows[0]

    $targetSub  = $first.TgtSubscriptionId
    $targetRG   = $first.TgtResourceGroup
    $targetVNet = $first.TgtVNet
    $targetSubnet = $first.TgtSubnet
    $targetLocation = $first.TgtLocation
    $storageAccountName = $first.BootDiagStorageAccountName
    $storageAccountRG   = $first.BootDiagStorageAccountRG
    $adminUsernameCSV   = $first.AdminUsername
    $adminPasswordCSV   = $first.AdminPassword

    # VM names we expect (from csv)
    $vmNames = @()
    foreach ($r in $rows) {
        if ($r.VMName -and $r.VMName.Trim() -ne "") {
            $vmNames += $r.VMName.Trim()
        }
    }
    $vmNames = $vmNames | ForEach-Object { $_.ToLower() } | Sort-Object -Unique

    # Build internal machine list from discovery file
    $machines = @()
    foreach ($m in $discovered) {
        # raw discovery record is under .Raw
        $raw = $m.Raw

        # attempt to extract machine names & latest discovery entry
        $ld = $null
        if ($raw.PSObject.Properties.Match('properties')) {
            $props = $raw.properties
            if ($props.PSObject.Properties.Match('discoveryData') -and $props.discoveryData) {
                $arr = $props.discoveryData
                if ($arr -is [System.Array]) {
                    $best = $null; $bestDt = [DateTime]::MinValue
                    foreach ($e in $arr) {
                        $dt = [DateTime]::MinValue
                        try {
                            if ($e.lastUpdatedTime) { $dt = [DateTime]::Parse($e.lastUpdatedTime) }
                        } catch {}
                        if ($dt -gt $bestDt) { $bestDt = $dt; $best = $e }
                    }
                    $ld = $best
                }
                else {
                    $ld = $arr
                }
            }
        }

        # candidates for name
        $cands = @()
        if ($ld -and $ld.machineName) { $cands += $ld.machineName }
        if ($raw.PSObject.Properties.Match('name') -and $raw.name) { $cands += $raw.name }
        if ($raw.PSObject.Properties.Match('properties') -and $raw.properties) {
            $pr = $raw.properties
            if ($pr.PSObject.Properties.Match('machineName') -and $pr.machineName) { $cands += $pr.machineName }
            if ($pr.PSObject.Properties.Match('displayName') -and $pr.displayName) { $cands += $pr.displayName }
        }

        $cands = $cands |
            Where-Object { $_ -and $_.ToString().Trim() -ne "" } |
            ForEach-Object { $_.ToString().Trim() } |
            Sort-Object -Unique

        $matchesCsv = $false
        foreach ($cand in $cands) {
            if ($vmNames -contains $cand.ToLower()) { $matchesCsv = $true; break }
        }

        if ($matchesCsv) {
            $os = $null
            if ($ld -and $ld.osName) { $os = $ld.osName }
            elseif ($raw.PSObject.Properties.Match('properties') -and $raw.properties) {
                $p = $raw.properties
                if ($p.PSObject.Properties.Match('osName') -and $p.osName) { $os = $p.osName }
                if (-not $os -and $p.PSObject.Properties.Match('operatingSystem') -and $p.operatingSystem) { $os = $p.operatingSystem }
                if (-not $os -and $p.PSObject.Properties.Match('osType') -and $p.osType) { $os = $p.osType }
            }
            if (-not $os) { $os = "UNKNOWN" }

            # cores/ram
            $coresRam = Get-CoresAndRamFromDiscovery -entry $ld

            $machines += [PSCustomObject]@{
                PreferredName = ($cands | Select-Object -First 1)
                OS = $os
                RawDiscovery = $raw
                Cores = $coresRam.Cores
                RAM_GB = $coresRam.RAM_GB
            }
        }
    }

    if ($machines.Count -eq 0) {
        throw "No machines from discovery matched the CSV VM list."
    }

    # dedupe by PreferredName (case-insensitive)
    $seen = @{}
    $finalMachines = @()
    foreach ($x in $machines) {
        $k = $x.PreferredName.ToLower()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $finalMachines += $x }
    }

    Write-Host ("Loaded " + $discovered.Count + " discovered entries, after CSV filtering " + $finalMachines.Count + " machines will be considered.")

    # get target context & validate
    Write-Host ("Setting target subscription context to " + $targetSub)
    Set-AzContext -Subscription $targetSub -ErrorAction Stop

    $rgObj = Get-AzResourceGroup -Name $targetRG -ErrorAction SilentlyContinue
    if (-not $rgObj) { throw ("Target RG not found: " + $targetRG) }

    $vnet = Get-AzVirtualNetwork -Name $targetVNet -ResourceGroupName $targetRG -ErrorAction SilentlyContinue
    if (-not $vnet) { throw ("Target VNet not found: " + $targetVNet) }

    $subnetObj = $null
    foreach ($s in $vnet.Subnets) {
        if ($s.Name -eq $targetSubnet) { $subnetObj = $s; break }
    }
    if (-not $subnetObj) { throw ("Target Subnet not found: " + $targetSubnet) }

    if (-not $targetLocation -or $targetLocation -eq "") { $targetLocation = $vnet.Location; Write-Host "No location provided. Using VNet location: $targetLocation" } else { Write-Host "Using provided location: $targetLocation" }

    # Storage account handling
    $useStorageAccount = $false
    $sa = $null
    if ($storageAccountName -and $storageAccountName -ne "") {
        try {
            $sa = Get-AzStorageAccount -ResourceGroupName $storageAccountRG -Name $storageAccountName -ErrorAction Stop
            $useStorageAccount = $true
            Write-Host ("Using provided storage account: " + $storageAccountName + " in RG " + $storageAccountRG)
        }
        catch {
            Write-Host ("Warning: storage account " + $storageAccountName + " in RG " + $storageAccountRG + " not found or not accessible. Script may attempt to create one.")
        }
    }

    # build report for DryRun summary
    $report = @()
    foreach ($m in $finalMachines) {
        $row = [PSCustomObject]@{
            MachineName = $m.PreferredName
            OS = $m.OS
            CPU_Cores = $m.Cores
            RAM_GB = $m.RAM_GB
            TargetVMExists = $false
        }
        try {
            $nm = Sanitize-ResourceName -name $m.PreferredName
            $vmCheck = Get-AzVM -Name $nm -ResourceGroupName $targetRG -ErrorAction SilentlyContinue
            if ($vmCheck) { $row.TargetVMExists = $true }
        } catch {}
        $report += $row
    }

    Write-Host ""
    Write-Host "===== DryRun Validation ====="
    Write-Host ""
    $report | Format-Table -AutoSize

    $effectiveMode = $Mode
    if (-not $effectiveMode -or $effectiveMode -eq "") {
        if ($env:MIG_MODE -and $env:MIG_MODE -ne "") { $effectiveMode = $env:MIG_MODE }
        else {
            $choice = Read-Host "Enter mode (DryRun or Replicate). Default DryRun"
            if (-not $choice -or $choice.Trim() -eq "") { $effectiveMode = "DryRun" } else { $effectiveMode = $choice }
        }
    }

    if ($effectiveMode.ToLower() -eq "dryrun") {
        Write-Host "DryRun selected. No replication will be performed unless you override."
        $go = Read-Host "Enter Y to start replication now or any other key to stop"
        if ($go -ne "Y") { Write-Host "Exiting after DryRun."; exit 0 }
    }

    # now perform replication for each machine
    foreach ($m in $finalMachines) {
        $pref = $m.PreferredName
        $os   = $m.OS
        $vmName = Sanitize-ResourceName -name $pref

        Write-Host ("Processing machine: " + $pref + " (OS: " + $os + ")")

        $imageObj = Map-Image-From-OS -osString $os
        if (-not $imageObj) {
            Write-Host ("Could not map OS automatically for: " + $os)
            $pub = Read-Host "Publisher"
            $offer = Read-Host "Offer"
            $sku = Read-Host "Sku"
            $imageObj = [PSCustomObject]@{ Publisher = $pub; Offer = $offer; Sku = $sku }
        }

        # NIC
        $nicName = $vmName + "-nic"
        $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $targetRG -ErrorAction SilentlyContinue
        if ($nic) { Write-Host ("Using existing NIC: " + $nicName) }
        else {
            Write-Host ("Creating NIC: " + $nicName)
            $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $targetRG -Location $targetLocation -SubnetId $subnetObj.Id -ErrorAction Stop
        }

        # determine Windows vs Linux from OS string
        $isWindows = $false
        if ($os.ToLower().IndexOf("win") -ge 0) { $isWindows = $true }

        if ($isWindows) {
            $computerName = Make-WindowsComputerName -baseName $pref
            Write-Host ("Using Windows computer name: " + $computerName)
        }
        else {
            $chars = $pref.ToCharArray()
            $outHost = ""
            foreach ($c in $chars) { if ($c -match "[A-Za-z0-9-]") { $outHost += $c } }
            if ($outHost.Length -gt 63) { $outHost = $outHost.Substring(0,63) }
            if (-not $outHost) { $outHost = "linuxvm" + (Get-Random -Minimum 1000 -Maximum 9999) }
            $computerName = $outHost
        }

        # admin credentials: prefer CSV values (global)
        $adminUser = $adminUsernameCSV
        $adminPassPlain = $adminPasswordCSV

        if (-not $adminUser -or $adminUser.Trim() -eq "") {
            $adminUser = Read-Host ("Enter admin username for VM " + $pref)
        }
        if (-not $adminPassPlain -or $adminPassPlain.Trim() -eq "") {
            $adminPassPlain = Read-Host ("Enter admin password for VM " + $pref)
        }
        if ($adminPassPlain -and $adminPassPlain -ne "") {
            $adminPass = ConvertTo-SecureString $adminPassPlain -AsPlainText -Force
        }
        else {
            $adminPass = $null
        }

        $vmSize = "Standard_D2s_v3"
        $vmConfig = New-AzVMConfig -VMName $vmName -VMSize $vmSize
        if ($imageObj -and $imageObj.Publisher -and $imageObj.Offer -and $imageObj.Sku) {
            $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName $imageObj.Publisher -Offer $imageObj.Offer -Skus $imageObj.Sku -Version "latest"
        }

        if ($isWindows) {
            if (-not $adminUser -or $adminUser -eq "") { throw ("Windows admin username required for " + $vmName) }
            $cred = New-Object System.Management.Automation.PSCredential ($adminUser, $adminPass)
            $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $computerName -Credential $cred -ProvisionVMAgent -EnableAutoUpdate
        }
        else {
            if ($adminPass) {
                $cred = New-Object System.Management.Automation.PSCredential ($adminUser, $adminPass)
                $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $computerName -Credential $cred -DisablePasswordAuthentication:$false
            }
            else {
                $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $computerName -DisablePasswordAuthentication:$false
            }
        }

        $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id

        # Attach boot diag if storage account available or create if needed
        if ($useStorageAccount -and $sa -ne $null) {
            $cmd = Get-Command -Name Set-AzVMBootDiagnostics -ErrorAction SilentlyContinue
            if ($cmd) {
                try {
                    $vmConfig = Set-AzVMBootDiagnostics -VM $vmConfig -ResourceGroupName $storageAccountRG -StorageAccountName $storageAccountName -Enable -ErrorAction Stop
                    Write-Host ("Using provided storage account " + $storageAccountName + " for boot diagnostics")
                }
                catch {
                    Write-Host ("Warning: Failed to attach provided storage account via Set-AzVMBootDiagnostics: " + $_.ToString())
                }
            }
            else {
                if ($sa.PrimaryEndpoints -and $sa.PrimaryEndpoints.Blob) {
                    $blobUri = $sa.PrimaryEndpoints.Blob
                    $bootDiag = New-Object -TypeName PSCustomObject
                    $bootDiag | Add-Member -MemberType NoteProperty -Name "Enabled" -Value $true
                    $bootDiag | Add-Member -MemberType NoteProperty -Name "StorageUri" -Value $blobUri
                    $diagProf = New-Object -TypeName PSCustomObject
                    $diagProf | Add-Member -MemberType NoteProperty -Name "BootDiagnostics" -Value $bootDiag
                    $vmConfig.DiagnosticsProfile = $diagProf
                }
            }
        }
        else {
            if ($storageAccountName -and $storageAccountName -ne "") {
                Write-Host ("Creating storage account " + $storageAccountName + " in RG " + $storageAccountRG + " (location " + $targetLocation + ") for boot diagnostics")
                try {
                    $sa = New-AzStorageAccount -ResourceGroupName $storageAccountRG -Name $storageAccountName -Location $targetLocation -SkuName Standard_LRS -Kind StorageV2 -ErrorAction Stop
                    $useStorageAccount = $true
                    if ($sa.PrimaryEndpoints -and $sa.PrimaryEndpoints.Blob) {
                        $blobUri = $sa.PrimaryEndpoints.Blob
                        $bootDiag = New-Object -TypeName PSCustomObject
                        $bootDiag | Add-Member -MemberType NoteProperty -Name "Enabled" -Value $true
                        $bootDiag | Add-Member -MemberType NoteProperty -Name "StorageUri" -Value $blobUri
                        $diagProf = New-Object -TypeName PSCustomObject
                        $diagProf | Add-Member -MemberType NoteProperty -Name "BootDiagnostics" -Value $bootDiag
                        $vmConfig.DiagnosticsProfile = $diagProf
                    }
                }
                catch {
                    Write-Host ("Warning: failed to create storage account: " + $_.ToString())
                }
            }
        }

        Write-Host ("Creating VM " + $vmName + " in RG " + $targetRG + " (Location: " + $targetLocation + ") ...")
        try {
            New-AzVM -ResourceGroupName $targetRG -Location $targetLocation -VM $vmConfig -ErrorAction Stop
            Write-Host ("VM " + $vmName + " created.")
        }
        catch {
            Write-Error ("Failed to create VM " + $vmName + ": " + $_.ToString())
        }
    }

    Write-Host "Replication completed for processed machines."
}
catch {
    Write-Error ("Fatal error in replication-run: " + $_.ToString())
    exit 1
}
