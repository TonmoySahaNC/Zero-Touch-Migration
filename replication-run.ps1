param(
    [string]$TokenFile = ".\token.enc",
    [Parameter(Mandatory = $true)][string]$DiscoveryFile
)

# -------------------------
# Helpers
# -------------------------

function Read-DiscoveryFile {
    param([string]$path)
    $text = Get-Content -Raw -Path $path
    return ConvertFrom-Json $text
}

function Sanitize-ResourceName {
    param([string]$name)
    if (-not $name -or $name -eq "") {
        $name = "vm" + (Get-Random -Minimum 1000 -Maximum 9999)
    }
    $chars = $name.ToCharArray()
    $out = ""
    foreach ($c in $chars) {
        if ($c -match "[A-Za-z0-9-]") {
            $out += $c
        }
    }
    $out = $out.Trim("-")
    if ($out.Length -gt 64) {
        $out = $out.Substring(0,64)
    }
    if ($out -eq "") {
        $out = "vm" + (Get-Random -Minimum 1000 -Maximum 9999)
    }
    return $out
}

function Make-WindowsComputerName {
    param([string]$baseName)
    if (-not $baseName -or $baseName -eq "") {
        $baseName = "win" + (Get-Random -Minimum 10 -Maximum 99)
    }
    $chars = $baseName.ToCharArray()
    $out = ""
    foreach ($c in $chars) {
        if ($c -match "[A-Za-z0-9]") {
            $out += $c
        }
    }
    if ($out.Length -gt 12) {
        $out = $out.Substring(0,12)
    }
    $rnd = (Get-Random -Minimum 100 -Maximum 999).ToString()
    $candidate = $out + $rnd
    if ($candidate.Length -gt 15) {
        $candidate = $candidate.Substring(0,15)
    }
    if ($candidate -match "^[0-9]+$") {
        $candidate = "win" + $candidate.Substring(0, 12)
    }
    return $candidate
}

function Get-LatestDiscoveryData {
    param($rawObj)
    if ($null -eq $rawObj) {
        return $null
    }

    if ($rawObj.PSObject.Properties.Match("properties") -and $rawObj.properties -and
        $rawObj.properties.PSObject.Properties.Match("discoveryData") -and $rawObj.properties.discoveryData) {

        $arr = $rawObj.properties.discoveryData

        if (-not ($arr -is [System.Collections.IEnumerable]) -or ($arr -is [string])) {
            $single = $arr
            $out = [PSCustomObject]@{
                machineName     = $single.machineName
                osName          = $single.osName
                lastUpdatedTime = $single.lastUpdatedTime
                _raw            = $single
            }
            return $out
        }

        $best   = $null
        $bestDt = [DateTime]::MinValue

        foreach ($entry in $arr) {
            $dtStr = $null
            if ($entry.PSObject.Properties.Match("lastUpdatedTime") -and $entry.lastUpdatedTime) {
                $dtStr = $entry.lastUpdatedTime
            }
            elseif ($entry.PSObject.Properties.Match("enqueueTime") -and $entry.enqueueTime) {
                $dtStr = $entry.enqueueTime
            }

            $dt = [DateTime]::MinValue
            try {
                if ($dtStr) {
                    $dt = [DateTime]::Parse($dtStr)
                }
            }
            catch {}

            if ($dt -gt $bestDt) {
                $bestDt = $dt
                $best   = $entry
            }
        }

        if ($best -ne $null) {
            return [PSCustomObject]@{
                machineName     = $best.machineName
                osName          = $best.osName
                lastUpdatedTime = $best.lastUpdatedTime
                _raw            = $best
            }
        }
    }

    return $null
}

function Map-Image-From-OS {
    param([string]$osString)

    if (-not $osString -or $osString -eq "") {
        return $null
    }

    $lower = $osString.ToLower()

    if ($lower -match "windows server 2022" -or $lower -match " 2022") {
        return [PSCustomObject]@{
            Publisher = "MicrosoftWindowsServer"
            Offer     = "WindowsServer"
            Sku       = "2022-datacenter"
        }
    }

    if ($lower -match "windows server 2019" -or $lower -match " 2019") {
        return [PSCustomObject]@{
            Publisher = "MicrosoftWindowsServer"
            Offer     = "WindowsServer"
            Sku       = "2019-datacenter"
        }
    }

    if ($lower -match "windows") {
        return [PSCustomObject]@{
            Publisher = "MicrosoftWindowsServer"
            Offer     = "WindowsServer"
            Sku       = "2019-datacenter"
        }
    }

    if ($lower -match "ubuntu 22.04" -or $lower -match "22.04") {
        return [PSCustomObject]@{
            Publisher = "Canonical"
            Offer     = "UbuntuServer"
            Sku       = "22_04-lts"
        }
    }

    if ($lower -match "ubuntu 20.04" -or $lower -match "20.04") {
        return [PSCustomObject]@{
            Publisher = "Canonical"
            Offer     = "UbuntuServer"
            Sku       = "20_04-lts"
        }
    }

    return $null
}

function Remove-SecurityProfileDeep {
    param($obj)

    if ($null -eq $obj) {
        return
    }

    try {
        if ($obj.PSObject.Properties.Match("SecurityProfile")) {
            $obj.PSObject.Properties.Remove("SecurityProfile")
        }
    }
    catch {}

    foreach ($p in $obj.PSObject.Properties) {
        $val = $p.Value
        if ($null -eq $val) {
            continue
        }

        if ($val -is [System.Collections.IEnumerable] -and -not ($val -is [string])) {
            foreach ($item in $val) {
                if ($item -ne $null -and $item.PSObject -ne $null) {
                    Remove-SecurityProfileDeep -obj $item
                }
            }
        }
        else {
            if ($val -ne $null -and $val.PSObject -ne $null) {
                Remove-SecurityProfileDeep -obj $val
            }
        }
    }
}

function Get-CoresAndRamFromDiscovery {
    param($entry)
    $ret = @{ Cores = $null; RAM_GB = $null }

    if ($null -eq $entry) {
        return $ret
    }

    if ($entry.PSObject.Properties.Match("extendedInfo") -and $entry.extendedInfo) {
        $ei = $entry.extendedInfo

        if ($ei.PSObject.Properties.Match("memoryDetails") -and $ei.memoryDetails) {
            $md = $ei.memoryDetails
            try {
                $mdObj = $md | ConvertFrom-Json

                if ($mdObj.NumberOfProcessorCore) {
                    $ret.Cores = [int]$mdObj.NumberOfProcessorCore
                }
                elseif ($mdObj.NumberOfCores) {
                    $ret.Cores = [int]$mdObj.NumberOfCores
                }

                if ($mdObj.AllocatedMemoryInMB) {
                    $ret.RAM_GB = [math]::Round(([double]$mdObj.AllocatedMemoryInMB / 1024), 2)
                }
                elseif ($mdObj.TotalMemoryMB) {
                    $ret.RAM_GB = [math]::Round(([double]$mdObj.TotalMemoryMB / 1024), 2)
                }
            }
            catch {
                try {
                    if ($md.NumberOfProcessorCore) {
                        $ret.Cores = [int]$md.NumberOfProcessorCore
                    }
                    if ($md.AllocatedMemoryInMB) {
                        $ret.RAM_GB = [math]::Round(([double]$md.AllocatedMemoryInMB / 1024), 2)
                    }
                }
                catch {}
            }
        }
    }

    if (-not $ret.Cores) {
        if ($entry.PSObject.Properties.Match("cpuCount") -and $entry.cpuCount) {
            $ret.Cores = [int]$entry.cpuCount
        }
        if ($entry.PSObject.Properties.Match("numCpus") -and $entry.numCpus) {
            $ret.Cores = [int]$entry.numCpus
        }
    }

    if (-not $ret.RAM_GB) {
        if ($entry.PSObject.Properties.Match("memoryInMB") -and $entry.memoryInMB) {
            $ret.RAM_GB = [math]::Round(([double]$entry.memoryInMB / 1024), 2)
        }
        if ($entry.PSObject.Properties.Match("totalMemoryMB") -and $entry.totalMemoryMB) {
            $ret.RAM_GB = [math]::Round(([double]$entry.totalMemoryMB / 1024), 2)
        }
    }

    return $ret
}

# -------------------------
# Main
# -------------------------

try {
    Write-Host "Reading discovery file:" $DiscoveryFile
    $machinesOrig = Read-DiscoveryFile -path $DiscoveryFile

    if (-not $machinesOrig) {
        throw "Discovery file empty or unreadable."
    }

    $tempList = @()

    foreach ($m in $machinesOrig) {
        $disc = Get-LatestDiscoveryData -rawObj $m.Raw
        $preferredName = ""
        $os = ""
        $rawDiscoveryEntry = $null

        if ($disc -ne $null) {
            if ($disc.PSObject.Properties.Match("machineName") -and $disc.machineName) {
                $preferredName = $disc.machineName
            }
            if ($disc.PSObject.Properties.Match("osName") -and $disc.osName) {
                $os = $disc.osName
            }
            if ($disc.PSObject.Properties.Match("_raw") -and $disc._raw) {
                $rawDiscoveryEntry = $disc._raw
            }
        }

        if ($preferredName -eq "" -or $preferredName -eq $null) {
            if ($m.PSObject.Properties.Match("MachineName") -and $m.MachineName) {
                $preferredName = $m.MachineName
            }
        }

        if ($preferredName -eq "" -or $preferredName -eq $null) {
            $preferredName = "vm" + (Get-Random -Minimum 1000 -Maximum 9999)
        }

        if ($os -eq "" -or $os -eq $null) {
            if ($m.PSObject.Properties.Match("OS") -and $m.OS) {
                $os = $m.OS
            }
        }

        if ($os -eq "" -or $os -eq $null) {
            $os = "UNKNOWN"
        }

        $coresRam = @{ Cores = $null; RAM_GB = $null }
        if ($rawDiscoveryEntry -ne $null) {
            $coresRam = Get-CoresAndRamFromDiscovery -entry $rawDiscoveryEntry
        }

        $wrapper = [PSCustomObject]@{
            PreferredName = $preferredName
            OS            = $os
            Raw           = $m.Raw
            Cores         = $coresRam.Cores
            RAM_GB        = $coresRam.RAM_GB
        }

        $tempList += $wrapper
    }

    # dedupe by PreferredName (case-insensitive)
    $seen = @{}
    $machines = @()

    foreach ($w in $tempList) {
        $key = $w.PreferredName.ToLower()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $machines += $w
        }
    }

    Write-Host "Loaded" $machinesOrig.Count "machines in file, after dedupe" $machines.Count

    Write-Host "Choose mode:"
    Write-Host "1) DryRun"
    Write-Host "2) Replicate"
    $choice = Read-Host "Enter 1 or 2"

    $targetSub      = Read-Host "Enter target subscription id"
    $targetRG       = Read-Host "Enter target resource group name"
    $targetVNet     = Read-Host "Enter target VNet name"
    $targetSubnet   = Read-Host "Enter target Subnet name"
    $targetLocation = Read-Host "Enter target location/region (example: swedencentral). Leave blank to use VNet location."
    $storageAccountName = Read-Host "Enter storage account name for boot diagnostics (leave blank to allow script to create one)"
    $storageAccountRG   = ""

    if ($storageAccountName -ne "" -and $storageAccountName -ne $null) {
        $storageAccountRG = Read-Host "Enter resource group of storage account (required if you supplied a storage account name)"
        if (-not $storageAccountRG) {
            throw "Storage account resource group required when storage account name is provided."
        }
    }

    Write-Host "Setting target subscription context to" $targetSub
    Set-AzContext -Subscription $targetSub -ErrorAction Stop

    $rgObj = Get-AzResourceGroup -Name $targetRG -ErrorAction SilentlyContinue
    if (-not $rgObj) {
        throw ("Target RG not found: " + $targetRG)
    }

    $vnet = Get-AzVirtualNetwork -Name $targetVNet -ResourceGroupName $targetRG -ErrorAction SilentlyContinue
    if (-not $vnet) {
        throw ("Target VNet not found: " + $targetVNet)
    }

    $subnetObj = $null
    foreach ($s in $vnet.Subnets) {
        if ($s.Name -eq $targetSubnet) {
            $subnetObj = $s
            break
        }
    }
    if (-not $subnetObj) {
        throw ("Target Subnet not found: " + $targetSubnet)
    }

    if (-not $targetLocation -or $targetLocation -eq "") {
        $targetLocation = $vnet.Location
        Write-Host "No location provided. Using VNet location:" $targetLocation
    }
    else {
        Write-Host "Using provided location:" $targetLocation
    }

    # Storage account handling
    $useStorageAccount = $false
    $sa = $null

    if ($storageAccountName -and $storageAccountName -ne "") {
        try {
            $sa = Get-AzStorageAccount -ResourceGroupName $storageAccountRG -Name $storageAccountName -ErrorAction Stop

            if ($sa.Sku.Name -notmatch "Standard" -or
                ($sa.Kind -ne "StorageV2" -and $sa.Kind -ne "Storage")) {

                Write-Host "Warning: Storage account" $storageAccountName "found but SKU or Kind may be incompatible."
                Write-Host "Kind:" $sa.Kind "Sku:" $sa.Sku.Name
                $resp = Read-Host "Proceed to use it anyway? Enter Y to use, N to abort"
                if ($resp -ne "Y") {
                    throw "User aborted due to incompatible storage account."
                }
            }

            $useStorageAccount = $true
            Write-Host "Using provided storage account:" $storageAccountName "in RG" $storageAccountRG
        }
        catch {
            Write-Host "Storage account" $storageAccountName "in RG" $storageAccountRG "not found or not accessible."
            $create = Read-Host "Do you want to create it now in RG $storageAccountRG and location $targetLocation? (Y/N)"
            if ($create -eq "Y") {
                Write-Host "Creating storage account" $storageAccountName "in RG" $storageAccountRG "Location:" $targetLocation
                try {
                    $sa = New-AzStorageAccount -ResourceGroupName $storageAccountRG -Name $storageAccountName -Location $targetLocation -SkuName Standard_LRS -Kind StorageV2 -ErrorAction Stop
                    Write-Host "Storage account created:" $storageAccountName
                    $useStorageAccount = $true
                }
                catch {
                    throw ("Failed to create storage account " + $storageAccountName + ": " + $_)
                }
            }
            else {
                throw ("Storage account " + $storageAccountName + " not found and user chose not to create one. Aborting to avoid auto-creation.")
            }
        }
    }

    # DryRun
    $report = @()

    foreach ($w in $machines) {
        $preferredName = $w.PreferredName
        $os = $w.OS
        $san = Sanitize-ResourceName -name $preferredName
        $exists = $false

        try {
            $vmCheck = Get-AzVM -Name $san -ResourceGroupName $targetRG -ErrorAction SilentlyContinue
            if ($vmCheck) {
                $exists = $true
            }
        }
        catch {}

        $row = [PSCustomObject]@{
            MachineName   = $preferredName
            OS            = $os
            CPU_Cores     = $w.Cores
            RAM_GB        = $w.RAM_GB
            TargetVMExists = $exists
        }
        $report += $row
    }

    Write-Host ""
    Write-Host "===== DryRun Validation ====="
    $report | Format-Table -AutoSize

    if ($choice -eq "1") {
        Write-Host ""
        Write-Host "DryRun complete. No replication executed."
        $go = Read-Host "Enter Y to start replication or any other key to exit"
        if ($go -ne "Y") {
            exit 0
        }
    }

    # Replication loop
    foreach ($w in $machines) {
        $preferredName = $w.PreferredName
        $os = $w.OS
        $raw = $w.Raw

        if ($os -eq "" -or $os -eq $null) {
            throw ("OS UNKNOWN for " + $preferredName + ". Fix discovery JSON.")
        }

        Write-Host "Processing machine:" $preferredName "(OS:" $os ")"

        $vmName = Sanitize-ResourceName -name $preferredName

        $imageObj = Map-Image-From-OS -osString $os
        if (-not $imageObj) {
            Write-Host "Could not map OS automatically for:" $os
            $pub   = Read-Host "Publisher (example: MicrosoftWindowsServer or Canonical)"
            $offer = Read-Host "Offer (example: WindowsServer or UbuntuServer)"
            $sku   = Read-Host "Sku (example: 2019-datacenter or 20_04-lts)"

            $imageObj = [PSCustomObject]@{
                Publisher = $pub
                Offer     = $offer
                Sku       = $sku
            }
        }
        else {
            Write-Host "Selected image:" $imageObj.Publisher "/" $imageObj.Offer "/" $imageObj.Sku
        }

        $nicName = $vmName + "-nic"
        $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $targetRG -ErrorAction SilentlyContinue
        if ($nic) {
            Write-Host "Using existing NIC:" $nicName
        }
        else {
            Write-Host "Creating NIC:" $nicName
            $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $targetRG -Location $targetLocation -SubnetId $subnetObj.Id -ErrorAction Stop
        }

        $isWindows = $false
        if ($os.ToLower().IndexOf("win") -ge 0) {
            $isWindows = $true
        }

        if ($isWindows) {
            $computerName = Make-WindowsComputerName -baseName $preferredName
            Write-Host "Using Windows computer name:" $computerName
        }
        else {
            $chars = $preferredName.ToCharArray()
            $outHost = ""
            foreach ($c in $chars) {
                if ($c -match "[A-Za-z0-9-]") {
                    $outHost += $c
                }
            }
            if ($outHost.Length -gt 63) {
                $outHost = $outHost.Substring(0,63)
            }
            $computerName = $outHost
            Write-Host "Using Linux hostname:" $computerName
        }

        # Admin user
        $adminUser = ""
        while ($true) {
            if ($isWindows) {
                $adminUser = Read-Host ("Enter local admin username for Windows VM " + $vmName)
            }
            else {
                $adminUser = Read-Host ("Enter admin username for Linux VM " + $vmName)
            }

            if ($isWindows) {
                $forbidden = @(
                    [char]92,  # \
                    [char]47,  # /
                    [char]59,  # ;
                    [char]58,  # :
                    [char]42,  # *
                    [char]96,  # `
                    [char]34,  # "
                    [char]124, # |
                    [char]32   # space
                )
                $bad = $false

                if (-not $adminUser -or $adminUser -eq "") {
                    $bad = $true
                }

                foreach ($ch in $forbidden) {
                    if ($adminUser.Contains($ch)) {
                        $bad = $true
                        break
                    }
                }

                if (-not $bad) {
                    break
                }

                Write-Host "Invalid username. No spaces or these characters: \ / ; : * ` \" | and cannot be empty."
            }
            else {
                break
            }
        }

        $adminPass = $null
        if ($isWindows) {
            $adminPass = Read-Host "Enter password (will be used to create local admin account)" -AsSecureString
        }
        else {
            $pw = Read-Host "Enter password or leave blank to configure SSH later"
            if ($pw -ne "") {
                $adminPass = ConvertTo-SecureString $pw -AsPlainText -Force
            }
        }

        $vmSize = "Standard_D2s_v3"
        $vmConfig = New-AzVMConfig -VMName $vmName -VMSize $vmSize

        if ($imageObj -and $imageObj.Publisher -and $imageObj.Offer -and $imageObj.Sku) {
            $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName $imageObj.Publisher -Offer $imageObj.Offer -Skus $imageObj.Sku -Version "latest"
        }

        Remove-SecurityProfileDeep -obj $vmConfig
        try { $vmConfig.SecurityProfile = $null } catch {}
        try {
            if ($vmConfig.PSObject.Properties.Match("SecurityProfile")) {
                $vmConfig.PSObject.Properties.Remove("SecurityProfile")
            }
        }
        catch {}

        if ($isWindows) {
            if (-not $adminUser -or $adminUser -eq "") {
                throw ("Windows admin username required for " + $vmName)
            }
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

        # Boot diagnostics storage account
        if ($useStorageAccount -and $sa -ne $null) {
            $cmd = Get-Command -Name Set-AzVMBootDiagnostics -ErrorAction SilentlyContinue
            if ($cmd) {
                try {
                    $vmConfig = Set-AzVMBootDiagnostics -VM $vmConfig -ResourceGroupName $storageAccountRG -StorageAccountName $storageAccountName -Enable -ErrorAction Stop
                    Write-Host "Using provided storage account for boot diagnostics via Set-AzVMBootDiagnostics:" $storageAccountName
                }
                catch {
                    Write-Host "Warning: Failed to attach provided storage account via Set-AzVMBootDiagnostics. Error:" $_
                    throw "Cannot attach provided storage account to VM config. Aborting to avoid auto-creation."
                }
            }
            else {
                try {
                    $blobUri = $null

                    if ($sa.PrimaryEndpoints -and $sa.PrimaryEndpoints.Blob) {
                        $blobUri = $sa.PrimaryEndpoints.Blob
                    }
                    elseif ($sa.Properties -and $sa.PrimaryEndpoints -and $sa.PrimaryEndpoints.Blob) {
                        $blobUri = $sa.PrimaryEndpoints.Blob
                    }

                    if (-not $blobUri) {
                        Write-Host "Warning: Could not find storage account blob endpoint. Aborting to avoid auto-creation."
                        throw "Storage account blob endpoint missing."
                    }

                    if (-not $vmConfig.DiagnosticsProfile) {
                        $vmConfig.DiagnosticsProfile = @{}
                    }

                    $bootDiag = New-Object -TypeName PSCustomObject
                    $bootDiag | Add-Member -MemberType NoteProperty -Name "Enabled"    -Value $true
                    $bootDiag | Add-Member -MemberType NoteProperty -Name "StorageUri" -Value $blobUri

                    $diagProf = New-Object -TypeName PSCustomObject
                    $diagProf | Add-Member -MemberType NoteProperty -Name "BootDiagnostics" -Value $bootDiag

                    $vmConfig.DiagnosticsProfile = $diagProf

                    Write-Host "Using provided storage account for boot diagnostics via DiagnosticsProfile StorageUri:" $blobUri
                }
                catch {
                    Write-Host "Warning: Fallback attaching storage account for boot diagnostics failed. Error:" $_
                    throw "Cannot attach provided storage account to VM config. Aborting to avoid auto-creation."
                }
            }
        }

        Remove-SecurityProfileDeep -obj $vmConfig
        try { $vmConfig.SecurityProfile = $null } catch {}
        try {
            if ($vmConfig.PSObject.Properties.Match("SecurityProfile")) {
                $vmConfig.PSObject.Properties.Remove("SecurityProfile")
            }
        }
        catch {}

        Write-Host "Creating VM" $vmName "in RG" $targetRG "Location:" $targetLocation
        try {
            New-AzVM -ResourceGroupName $targetRG -Location $targetLocation -VM $vmConfig -ErrorAction Stop
            Write-Host "VM" $vmName "created."
        }
        catch {
            if ($_.Exception -and ($_.Exception.Message -match "SkuNotAvailable" -or $_.Exception.Message -match "Capacity Restrictions")) {
                throw ("VM size not available in location " + $targetLocation + ". Try another size or region.")
            }
            else {
                throw $_
            }
        }
    }

    Write-Host "Replication completed for all machines."
}
catch {
    Write-Error ("Fatal error in replication-run: " + $_)
    exit 1
}
