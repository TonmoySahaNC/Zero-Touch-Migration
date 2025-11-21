param(
    [string]$TokenFile    = ".\token.enc",
    [Parameter(Mandatory = $true)][string]$DiscoveryFile,
    [string]$InputCsv     = ".\migration_input.csv"
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

function Get-WindowsComputerName {
    param(
        [string]$BaseName
    )

    if ([string]::IsNullOrWhiteSpace($BaseName)) {
        return ("WIN" + (Get-Random -Maximum 9999))
    }

    $name = $BaseName -replace "[^A-Za-z0-9\-]", ""
    if ($name.Length -gt 15) {
        $name = $name.Substring(0, 15)
    }

    if ($name -match "^[0-9]+$") {
        $prefix = "WIN"
        $suffixLength = 12
        if ($name.Length -lt $suffixLength) {
            $suffixLength = $name.Length
        }
        $name = $prefix + $name.Substring(0, $suffixLength)
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = "WIN" + (Get-Random -Maximum 9999)
    }

    return $name
}

try {
    Import-Module Az.Compute -ErrorAction Stop
    Import-Module Az.Network -ErrorAction Stop
    Import-Module Az.Storage -ErrorAction Stop

    # Detect once whether Set-AzVMBootDiagnostics is available
    $BootDiagCmd = $null
    try {
        $BootDiagCmd = Get-Command -Name Set-AzVMBootDiagnostics -ErrorAction SilentlyContinue
    } catch {
        $BootDiagCmd = $null
    }

    Write-Host ("Reading discovery file: " + $DiscoveryFile)
    if (-not (Test-Path $DiscoveryFile)) {
        throw ("Discovery file not found: " + $DiscoveryFile)
    }

    $jsonText = Get-Content -Path $DiscoveryFile -Raw
    $discovered = $jsonText | ConvertFrom-Json

    if ($null -eq $discovered) {
        throw "Discovery JSON is null or empty."
    }

    # Ensure we have an array
    if ($discovered -isnot [System.Collections.IEnumerable] -or $discovered -is [string]) {
        $discovered = @($discovered)
    }

    Write-Host ("Loaded " + $discovered.Count + " discovered entries from JSON.")

    if (-not (Test-Path $InputCsv)) {
        throw ("Input CSV file not found: " + $InputCsv)
    }

    $csvRows = Import-Csv -Path $InputCsv
    if (-not $csvRows -or $csvRows.Count -eq 0) {
        throw "Input CSV has no data."
    }

    # Filter to Physical rows
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

    # Build map: VMName -> row (case-insensitive)
    $vmMap = @{}
    $allowedNames = @()
    foreach ($row in $physicalRows) {
        $vmName = Get-Field -Row $row -Names @("VMName")
        if ($vmName -ne "") {
            $key = $vmName.ToUpper()
            if (-not $vmMap.ContainsKey($key)) {
                $vmMap[$key] = $row
                $allowedNames += $vmName
            }
        }
    }

    if ($allowedNames.Count -eq 0) {
        throw "No VMName values found in Physical rows in CSV."
    }

    Write-Host ("CSV specifies these VM names for Physical migration: " + ($allowedNames -join ", "))

    # Filter discovered machines to only those in CSV VMName
    $machinesToUse = @()
    $seenNames = @{}

    foreach ($m in $discovered) {
        $mn = ""
        if ($m.PSObject.Properties.Name -contains "MachineName" -and $m.MachineName) {
            $mn = $m.MachineName.ToString().Trim()
        } elseif ($m.PSObject.Properties.Name -contains "machineName" -and $m.machineName) {
            $mn = $m.machineName.ToString().Trim()
        }

        if ($mn -eq "") { continue }

        $key = $mn.ToUpper()
        if ($vmMap.ContainsKey($key)) {
            if (-not $seenNames.ContainsKey($key)) {
                $seenNames[$key] = $true
                $machinesToUse += $m
            }
        }
    }

    if ($machinesToUse.Count -eq 0) {
        throw "After applying CSV VMName filter, there are no machines to process. Check VMName values in CSV vs discovery MachineName."
    }

    Write-Host ("Loaded " + $discovered.Count + " discovered entries, after CSV filter and dedupe " + $machinesToUse.Count + " machines will be considered.")

    # From first Physical row, get target sub, RG, etc (used as defaults)
    $first = $physicalRows[0]

    $defaultTgtSubId  = Get-Field -Row $first -Names @("TgtSubscriptionId","TargetSubscriptionId","TargetSubId")
    $defaultTgtRG     = Get-Field -Row $first -Names @("TgtResourceGroup","TargetResourceGroup","TgtRG","TargetRG")
    $defaultTgtVNet   = Get-Field -Row $first -Names @("TgtVNet","TargetVNet","TargetVNetName")
    $defaultTgtSubnet = Get-Field -Row $first -Names @("TgtSubnet","TargetSubnet","TargetSubnetName")
    $defaultLocation  = Get-Field -Row $first -Names @("TgtLocation","TargetLocation","Location")
    $defaultBootSA    = Get-Field -Row $first -Names @("BootDiagStorageAccountName","BootDiagStorage","BootDiagSAName")
    $defaultBootSARG  = Get-Field -Row $first -Names @("BootDiagStorageAccountRG","BootDiagStorageRG","BootDiagSARG")
    $defaultAdminUser = Get-Field -Row $first -Names @("AdminUsername")
    $defaultAdminPass = Get-Field -Row $first -Names @("AdminPassword")

    if ($defaultTgtSubId -eq "" -or $defaultTgtRG -eq "") {
        throw "TgtSubscriptionId and TgtResourceGroup are required in CSV."
    }

    Write-Host ("Setting target subscription context to " + $defaultTgtSubId)
    Set-AzContext -Subscription $defaultTgtSubId -ErrorAction Stop

    # Check if we can connect to storage account (for info; final use is per-VM)
    if ($defaultBootSA -ne "" -and $defaultBootSARG -ne "") {
        try {
            $sa = Get-AzStorageAccount -Name $defaultBootSA -ResourceGroupName $defaultBootSARG -ErrorAction Stop
            Write-Host ("Using provided storage account: " + $defaultBootSA + " in RG " + $defaultBootSARG)
        } catch {
            Write-Warning ("Provided storage account " + $defaultBootSA + " in RG " + $defaultBootSARG + " not found or not accessible. Boot diagnostics may use another storage.")
        }
    }

    # DryRun: show MachineName, OS, CPU, RAM, TargetVMExists
    Write-Host ""
    Write-Host "===== DryRun Validation ====="
    Write-Host ""

    $report = @()
    foreach ($m in $machinesToUse) {
        $mn = $m.MachineName
        $os = $m.OS
        $cpu = $null
        $ram = $null

        if ($m.PSObject.Properties.Name -contains "CpuCores") { $cpu = $m.CpuCores }
        if ($m.PSObject.Properties.Name -contains "RamGB")    { $ram = $m.RamGB }

        $exists = $false
        try {
            $vmCheck = Get-AzVM -Name $mn -ResourceGroupName $defaultTgtRG -ErrorAction Stop
            if ($vmCheck) { $exists = $true }
        } catch {
            $exists = $false
        }

        $report += [PSCustomObject]@{
            MachineName    = $mn
            OS             = $os
            CPU_Cores      = $cpu
            RAM_GB         = $ram
            TargetVMExists = $exists
        }
    }

    $report | Format-Table -AutoSize

    Write-Host ""
    Write-Host "DryRun complete. No replication executed yet."

    # Interactive vs non-interactive (GitHub Actions) handling
    $mode = $env:MIG_MODE
    if ([string]::IsNullOrWhiteSpace($mode)) {
        $mode = Read-Host "Enter mode (DryRun or Replicate). Default DryRun"
    }

    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = "DryRun" }
    $mode = $mode.Trim()

    if ($mode.ToLower() -ne "replicate") {
        Write-Host "DryRun selected. No replication will be performed unless you confirm."
        if (-not $env:CI) {
            $confirm = Read-Host "Enter Y to start replication now or any other key to stop"
            if ($confirm.ToUpper() -ne "Y") {
                Write-Host "Replication cancelled by user."
                exit 0
            }
        } else {
            Write-Host "Non-interactive environment detected and MIG_MODE not set to Replicate. Stopping after DryRun."
            exit 0
        }
    } else {
        if ($env:CI) {
            Write-Host "Non-interactive mode detected (MIG_MODE=Replicate). Proceeding with replication."
        }
    }

    Write-Host ""
    Write-Host "===== Starting Replication ====="
    Write-Host ""

    foreach ($m in $machinesToUse) {
        $mn = $m.MachineName.ToString().Trim()
        $key = $mn.ToUpper()

        if (-not $vmMap.ContainsKey($key)) {
            Write-Warning ("No CSV row found for VM " + $mn + ". Skipping.")
            continue
        }

        $row = $vmMap[$key]

        $targetSubId  = Get-Field -Row $row -Names @("TgtSubscriptionId","TargetSubscriptionId","TargetSubId")
        $targetRG     = Get-Field -Row $row -Names @("TgtResourceGroup","TargetResourceGroup","TgtRG","TargetRG")
        $targetVNet   = Get-Field -Row $row -Names @("TgtVNet","TargetVNet","TargetVNetName")
        $targetSubnet = Get-Field -Row $row -Names @("TgtSubnet","TargetSubnet","TargetSubnetName")
        $location     = Get-Field -Row $row -Names @("TgtLocation","TargetLocation","Location")
        $bootSA       = Get-Field -Row $row -Names @("BootDiagStorageAccountName","BootDiagStorage","BootDiagSAName")
        $bootSARG     = Get-Field -Row $row -Names @("BootDiagStorageAccountRG","BootDiagStorageRG","BootDiagSARG")
        $adminUser    = Get-Field -Row $row -Names @("AdminUsername")
        $adminPass    = Get-Field -Row $row -Names @("AdminPassword")

        if ($targetSubId -eq "")  { $targetSubId  = $defaultTgtSubId }
        if ($targetRG -eq "")     { $targetRG     = $defaultTgtRG }
        if ($targetVNet -eq "")   { $targetVNet   = $defaultTgtVNet }
        if ($targetSubnet -eq "") { $targetSubnet = $defaultTgtSubnet }
        if ($location -eq "")     { $location     = $defaultLocation }
        if ($bootSA -eq "")       { $bootSA       = $defaultBootSA }
        if ($bootSARG -eq "")     { $bootSARG     = $defaultBootSARG }
        if ($adminUser -eq "")    { $adminUser    = $defaultAdminUser }
        if ($adminPass -eq "")    { $adminPass    = $defaultAdminPass }

        if ($targetSubId -eq "" -or $targetRG -eq "") {
            Write-Warning ("Target subscription or RG missing for VM " + $mn + ". Skipping.")
            continue
        }

        if ($targetVNet -eq "" -or $targetSubnet -eq "") {
            Write-Warning ("No VNet or subnet specified for VM " + $mn + ". Skipping VM creation.")
            continue
        }

        if ($location -eq "") {
            Write-Warning ("Location not specified for VM " + $mn + ". Skipping.")
            continue
        }

        if ($adminUser -eq "" -or $adminPass -eq "") {
            Write-Warning ("AdminUsername or AdminPassword missing in CSV for VM " + $mn + ". Skipping.")
            continue
        }

        Set-AzContext -Subscription $targetSubId -ErrorAction Stop

        $osName    = ""
        $isWindows = $true

        if ($m.PSObject.Properties.Name -contains "OS" -and $m.OS) {
            $osName = $m.OS.ToString()
        }

        $osLower = $osName.ToLower()
        if ($osLower -like "*linux*" -or
            $osLower -like "*ubuntu*" -or
            $osLower -like "*centos*" -or
            $osLower -like "*red hat*") {
            $isWindows = $true -eq $false  # force boolean, avoids IsWindows var conflict
        } else {
            $isWindows = $true
        }

        Write-Host ("Processing machine: " + $mn + " (OS: " + $osName + ")")

        # Resolve VNet and Subnet
        try {
            Write-Host ("Using target VNet " + $targetVNet + " and subnet " + $targetSubnet + " for VM " + $mn)
            $vnet = Get-AzVirtualNetwork -Name $targetVNet -ResourceGroupName $targetRG -ErrorAction Stop
        } catch {
            Write-Warning ("VNet " + $targetVNet + " in RG " + $targetRG + " not found for VM " + $mn + ". Skipping VM creation.")
            continue
        }

        $subnet = $null
        foreach ($sn in $vnet.Subnets) {
            if ($sn.Name -eq $targetSubnet) {
                $subnet = $sn
                break
            }
        }

        if (-not $subnet) {
            Write-Warning ("Subnet " + $targetSubnet + " not found in VNet " + $targetVNet + " for VM " + $mn + ". Skipping VM creation.")
            continue
        }

        # NIC
        $nicName = $mn + "-nic"
        $nic = $null
        try {
            $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $targetRG -ErrorAction Stop
            Write-Host ("Using existing NIC: " + $nicName)
        } catch {
            Write-Host ("Creating NIC: " + $nicName)
            $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $targetRG -Location $location -SubnetId $subnet.Id
        }

        # Admin credential
        $securePass = ConvertTo-SecureString $adminPass -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential ($adminUser, $securePass)

        # Decide OS image based on osName
        $publisher = ""
        $offer     = ""
        $sku       = ""

        if ($isWindows) {
            $publisher = "MicrosoftWindowsServer"
            $offer     = "WindowsServer"
            $sku       = "2019-datacenter"
            if ($osLower -like "*2016*") { $sku = "2016-datacenter" }
            if ($osLower -like "*2022*") { $sku = "2022-datacenter" }
        } else {
            $publisher = "Canonical"
            $offer     = "UbuntuServer"
            $sku       = "18_04-lts"
        }

        Write-Host ("Selected image: " + $publisher + " / " + $offer + " / " + $sku)

        $vmSize = "Standard_D2s_v3"

        $vmConfig = New-AzVMConfig -VMName $mn -VMSize $vmSize

        if ($isWindows) {
            $compName = Get-WindowsComputerName -BaseName $mn
            Write-Host ("Using Windows computer name: " + $compName)
            $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $compName -Credential $cred -ProvisionVMAgent -EnableAutoUpdate
        } else {
            $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $mn -Credential $cred -DisablePasswordAuthentication:$false
        }

        $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id
        $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName $publisher -Offer $offer -Skus $sku -Version "latest"

        # --- BOOT DIAGNOSTICS HANDLING ---

        if ($BootDiagCmd) {
            # Cmdlet exists (local runs). If a storage account is provided, use it.
            if ($bootSA -ne "" -and $bootSARG -ne "") {
                try {
                    $sa = Get-AzStorageAccount -Name $bootSA -ResourceGroupName $bootSARG -ErrorAction Stop
                    $bootUri = $sa.PrimaryEndpoints.Blob.ToString()
                    Write-Host ("Using boot diagnostics storage: " + $bootSA + " in RG " + $bootSARG)
                    $vmConfig = Set-AzVMBootDiagnostics -VM $vmConfig -Enable -StorageUri $bootUri
                } catch {
                    Write-Warning ("Failed to configure boot diagnostics with storage account " + $bootSA + " in RG " + $bootSARG + ". Disabling boot diagnostics.")
                    try {
                        if ($vmConfig.DiagnosticsProfile -and $vmConfig.DiagnosticsProfile.BootDiagnostics) {
                            $vmConfig.DiagnosticsProfile.BootDiagnostics.Enabled    = $false
                            $vmConfig.DiagnosticsProfile.BootDiagnostics.StorageUri = $null
                        }
                    } catch {}
                }
            } else {
                # Cmdlet exists but no SA specified -> disable to prevent auto-creation
                Write-Host "No boot diagnostics storage account specified. Disabling boot diagnostics."
                try {
                    if ($vmConfig.DiagnosticsProfile -and $vmConfig.DiagnosticsProfile.BootDiagnostics) {
                        $vmConfig.DiagnosticsProfile.BootDiagnostics.Enabled    = $false
                        $vmConfig.DiagnosticsProfile.BootDiagnostics.StorageUri = $null
                    }
                } catch {}
            }
        } else {
            # Cmdlet NOT available (GitHub runner) -> explicitly disable boot diagnostics
            Write-Host "Set-AzVMBootDiagnostics not available. Disabling boot diagnostics on VM config to avoid auto-created storage accounts."
            try {
                if ($vmConfig.DiagnosticsProfile -and $vmConfig.DiagnosticsProfile.BootDiagnostics) {
                    $vmConfig.DiagnosticsProfile.BootDiagnostics.Enabled    = $false
                    $vmConfig.DiagnosticsProfile.BootDiagnostics.StorageUri = $null
                } else {
                    $vmConfig.PSObject.Properties.Remove('DiagnosticsProfile') | Out-Null
                }
            } catch {}
        }

        # --- END BOOT DIAGNOSTICS HANDLING ---

        Write-Host ("Creating VM " + $mn + " in RG " + $targetRG + " (Location: " + $location + ") ...")

        try {
            New-AzVM -ResourceGroupName $targetRG -Location $location -VM $vmConfig -ErrorAction Stop | Out-Null
            Write-Host ("VM " + $mn + " created.")
        } catch {
            Write-Error ("Failed to create VM " + $mn + ": " + $_.Exception.Message)
        }
    }

    Write-Host "Replication completed for processed machines."
}
catch {
    Write-Error ("Fatal error in replication-run: " + $_.ToString())
    exit 1
}
