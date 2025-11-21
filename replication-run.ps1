param(
    [string]$TokenFile    = ".\token.enc",
    [Parameter(Mandatory = $true)][string]$DiscoveryFile,
    [string]$InputCsv     = ".\migration_input.csv",
    [string]$Mode         = ""          # DryRun / Replicate
)

# ================== ASR CONFIG - EDIT THESE FOR PHYSICAL ==================
# These are specific to your environment. Get them from the Recovery Services vault (ZTM-POC-MigrateVault-xxxxx).

# Recovery Services vault where VMware/Physical replication appliance is registered
$AsrVaultName                       = "ZTM-POC-MigrateVault-1163665249"   # << EDIT if different
$AsrVaultResourceGroup              = "ZTM-Source-SDC"                    # << EDIT if different

# Fabric friendly name – usually the configuration server or appliance name you see under
# Vault -> Site Recovery Infrastructure -> Configuration servers / Replication appliances
$AsrFabricFriendlyName              = "ZTM-ConfigServer-01"               # << EDIT: your config server / appliance friendly name

# Protection container (under that fabric). Often something like "vmware-container" or similar.
$AsrProtectionContainerFriendlyName = "vmware-container"                  # << EDIT: see Protection Containers blade

# Replication policy name used for VMware/Physical to Azure
$AsrPolicyName                      = "ZTM-VM-Policy"                     # << EDIT: name of ASR replication policy

# Protection container mapping usually already exists (policy <-> protection container).
# We’ll auto-pick the mapping that uses $AsrPolicyName. If there’s only one mapping, it will be used.

# Appliance name (under Vault -> Site Recovery Infrastructure -> Replication appliances)
$AsrApplianceName                   = "ZTM-ReplicationAppliance-01"       # << EDIT: name shown in portal

# Storage account used for ASR log / cache (Resource ID, not just name)
# e.g. "/subscriptions/xxx/resourceGroups/rgname/providers/Microsoft.Storage/storageAccounts/logstorage"
$AsrLogStorageAccountId             = "/subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.Storage/storageAccounts/<LOGSA>"   # << EDIT

# ==========================================================================

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
                if ($s -ne "") {
                    return $s
                }
            }
        }
    }
    return ""
}

function Resolve-Mode {
    param(
        [string]$ModeParam
    )

    if ($ModeParam -and $ModeParam.Trim() -ne "") {
        return $ModeParam.Trim()
    }

    if ($env:MIG_MODE -and $env:MIG_MODE.Trim() -ne "") {
        return $env:MIG_MODE.Trim()
    }

    return "DryRun"
}

try {
    Write-Host "========== replication-run.ps1 (Physical via ASR, VMware via Az.Migrate) =========="

    if (-not (Test-Path $DiscoveryFile)) {
        throw "Discovery file not found: $DiscoveryFile"
    }
    if (-not (Test-Path $InputCsv)) {
        throw "Input CSV not found: $InputCsv"
    }

    $effectiveMode      = Resolve-Mode -ModeParam $Mode
    $effectiveModeUpper = $effectiveMode.ToUpperInvariant()

    Write-Host ("Mode          : " + $effectiveModeUpper)
    Write-Host ("DiscoveryFile : " + $DiscoveryFile)
    Write-Host ("InputCsv      : " + $InputCsv)

    Import-Module Az.Accounts,Az.Resources,Az.Network,Az.Migrate,Az.RecoveryServices -ErrorAction Stop

    $csvRows = Import-Csv -Path $InputCsv
    if (-not $csvRows -or $csvRows.Count -eq 0) {
        throw "Input CSV is empty: $InputCsv"
    }

    # We don’t strictly need discovery-output.json for ASR, but we keep it for consistency / future.
    $discoveryJson = Get-Content -Path $DiscoveryFile -Raw
    $discoveredMachines = $null
    try {
        $discoveredMachines = $discoveryJson | ConvertFrom-Json
    } catch {
        Write-Warning "Discovery file is not valid JSON or not used. Continuing without it."
    }

    # ---------- ASR init (for PHYSICAL) ----------
    $hasPhysical = $false
    foreach ($row in $csvRows) {
        $mt = Get-Field $row @("MigrationType","Type")
        if ($mt -and $mt.Trim().ToLowerInvariant() -eq "physical") {
            $hasPhysical = $true
            break
        }
    }

    $asrInitialized           = $false
    $asrFabric                = $null
    $asrProtectionContainer   = $null
    $asrPolicy                = $null
    $asrContainerMapping      = $null

    if ($hasPhysical) {
        Write-Host "Initializing ASR (Site Recovery) context for PHYSICAL migrations..."

        # Set vault context
        $vault = Get-AzRecoveryServicesVault -Name $AsrVaultName -ResourceGroupName $AsrVaultResourceGroup -ErrorAction Stop
        Set-AzRecoveryServicesVaultContext -Vault $vault -ErrorAction Stop
        # NOTE: On some environments Set-AzRecoveryServicesAsrVaultContext is flaky; on a clean Az install (GitHub runner) it should work.
        Set-AzRecoveryServicesAsrVaultContext -Vault $vault -ErrorAction Stop

        # Get fabric (config server / appliance)
        $asrFabric = Get-AzRecoveryServicesAsrFabric -ErrorAction Stop |
                     Where-Object { $_.FriendlyName -eq $AsrFabricFriendlyName }

        if (-not $asrFabric) {
            throw "ASR Fabric with FriendlyName '$AsrFabricFriendlyName' not found in vault $AsrVaultName."
        }

        # Get protection container
        $asrProtectionContainer = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $asrFabric -ErrorAction Stop |
                                  Where-Object { $_.FriendlyName -eq $AsrProtectionContainerFriendlyName }

        if (-not $asrProtectionContainer) {
            throw "ASR Protection Container with FriendlyName '$AsrProtectionContainerFriendlyName' not found in fabric '$AsrFabricFriendlyName'."
        }

        # Get policy
        $asrPolicy = Get-AzRecoveryServicesAsrPolicy -ErrorAction Stop |
                     Where-Object { $_.FriendlyName -eq $AsrPolicyName -or $_.Name -eq $AsrPolicyName }

        if (-not $asrPolicy) {
            throw "ASR Policy '$AsrPolicyName' not found in vault $AsrVaultName."
        }

        # Get container mapping (container <-> policy)
        $asrContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $asrProtectionContainer -ErrorAction Stop |
                               Where-Object { $_.PolicyFriendlyName -eq $AsrPolicyName -or $_.PolicyId -like "*$($asrPolicy.Name)*" }

        if (-not $asrContainerMapping) {
            Write-Warning "No ProtectionContainerMapping found for policy '$AsrPolicyName'. Using first mapping on container."
            $asrContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $asrProtectionContainer -ErrorAction Stop |
                                   Select-Object -First 1
            if (-not $asrContainerMapping) {
                throw "No ProtectionContainerMapping found for container '$AsrProtectionContainerFriendlyName'."
            }
        }

        $asrInitialized = $true
        Write-Host "ASR context initialized: Vault=$AsrVaultName, Fabric=$AsrFabricFriendlyName, Container=$AsrProtectionContainerFriendlyName, Policy=$AsrPolicyName"
    }

    # ---------- Azure Migrate infra cache (for VMware) ----------
    $initializedMigrateInfra = @{}

    foreach ($row in $csvRows) {

        $migrationType          = Get-Field $row @("MigrationType","Type")
        $migrationTypeNorm      = ($migrationType ?? "").ToLowerInvariant()

        # Common source & target fields from your CSV
        $projectSubscriptionId  = Get-Field $row @("SrcSubscriptionId","ProjectSubscriptionId","SubscriptionId")
        $projectRG              = Get-Field $row @("SrcResourceGroup","MigrationProjectRG","MigrationProjectResourceGroup","ProjectResourceGroup")
        $projectName            = Get-Field $row @("MigrationProjectName","ProjectName","AzMigrateProjectName")

        $targetSubscriptionId   = Get-Field $row @("TgtSubscriptionId","TargetSubscriptionId")
        if (-not $targetSubscriptionId) { $targetSubscriptionId = $projectSubscriptionId }

        $targetRGName           = Get-Field $row @("TgtResourceGroup","TargetResourceGroup","TargetRG","TargetResourceGroupName")
        $targetVNetName         = Get-Field $row @("TgtVNet","TargetVNetName","TargetVNet")
        $targetSubnetName       = Get-Field $row @("TgtSubnet","TargetSubnetName","TargetSubnet")
        $targetRegion           = Get-Field $row @("TgtLocation","TargetRegion","Region")

        $bootDiagStorageName    = Get-Field $row @("BootDiagStorageAccountName")
        $bootDiagStorageRG      = Get-Field $row @("BootDiagStorageAccountRG")

        $csvVmName              = Get-Field $row @("VMName","MachineName","SourceVMName")
        $targetVMName           = Get-Field $row @("TargetVMName","VMName","MachineName")
        if (-not $targetVMName) { $targetVMName = $csvVmName }

        # For physical ASR we’ll also try to read IP and OS type if you add them in CSV
        $srcIpAddress           = Get-Field $row @("SrcIPAddress","SourceIPAddress","IPAddress")
        $osType                 = Get-Field $row @("OSType","OS","OSName")
        if (-not $osType) { $osType = "Windows" }    # default – edit if you know it's Linux

        if (-not $csvVmName) {
            Write-Warning "Row missing VMName/MachineName. Skipping row: $($row | Out-String)"
            continue
        }

        Write-Host ""
        Write-Host "----- Processing row for VM: $csvVmName -----"
        Write-Host "  MigrationType : $migrationType"

        # ========== PHYSICAL: use ASR (Site Recovery) ==========
        if ($migrationTypeNorm -eq "physical") {

            if (-not $asrInitialized) {
                Write-Error "ASR not initialized but physical rows found. Aborting."
                throw "ASR not initialized."
            }

            if (-not $targetSubscriptionId -or -not $targetRGName -or -not $targetVNetName -or -not $targetSubnetName -or -not $targetRegion) {
                Write-Warning "  [$csvVmName] Target subscription / RG / VNet / Subnet / Region not fully set. Skipping."
                continue
            }

            $targetRGId      = "/subscriptions/$targetSubscriptionId/resourceGroups/$targetRGName"
            $targetNetworkId = "/subscriptions/$targetSubscriptionId/resourceGroups/$targetRGName/providers/Microsoft.Network/virtualNetworks/$targetVNetName"

            Write-Host "  [ASR] Target RG     : $targetRGName"
            Write-Host "  [ASR] Target VNet   : $targetNetworkId"
            Write-Host "  [ASR] Target Subnet : $targetSubnetName"
            Write-Host "  [ASR] Target Region : $targetRegion"
            Write-Host "  [ASR] Target VMName : $targetVMName"

            # 1) Get existing protectable item (discovered via appliance)
            $protectable = Get-AzRecoveryServicesAsrProtectableItem `
                -ProtectionContainer $asrProtectionContainer `
                -SiteId $asrFabric.ID `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.FriendlyName -eq $csvVmName -or $_.Name -eq $csvVmName }

            # 2) If not found and we have IP, try to "discover" using New-AzRecoveryServicesAsrProtectableItem (physical add)
            if (-not $protectable -and $srcIpAddress) {
                Write-Host "  [ASR] No existing protectable item for '$csvVmName'. Will add one for physical server using IP $srcIpAddress."

                if ($effectiveModeUpper -eq "DRYRUN") {
                    Write-Host "  [DryRun][ASR] Would run New-AzRecoveryServicesAsrProtectableItem -FriendlyName $csvVmName -IPAddress $srcIpAddress -OSType $osType -ProtectionContainer <container>"
                }
                else {
                    $protectable = New-AzRecoveryServicesAsrProtectableItem `
                        -ProtectionContainer $asrProtectionContainer `
                        -FriendlyName $csvVmName `
                        -IPAddress $srcIpAddress `
                        -OSType $osType `
                        -ErrorAction Stop

                    Write-Host "  [ASR] Added protectable item: $($protectable.FriendlyName)"
                }
            }

            if (-not $protectable) {
                Write-Warning "  [ASR] Could not find or create protectable item for '$csvVmName'. Check that the appliance has discovered this machine and/or add SrcIPAddress in CSV."
                continue
            }

            switch ($effectiveModeUpper) {
                "DRYRUN" {
                    Write-Host "  [DryRun][ASR] Would enable replication for physical server '$csvVmName' using:"
                    Write-Host "     Vault                  = $AsrVaultName"
                    Write-Host "     Fabric                 = $($asrFabric.FriendlyName)"
                    Write-Host "     ProtectionContainer    = $($asrProtectionContainer.FriendlyName)"
                    Write-Host "     Policy                 = $AsrPolicyName"
                    Write-Host "     ApplianceName          = $AsrApplianceName"
                    Write-Host "     ProtectableItem        = $($protectable.FriendlyName)"
                    Write-Host "     RecoveryResourceGroup  = $targetRGId"
                    Write-Host "     RecoveryNetworkId      = $targetNetworkId"
                    Write-Host "     RecoverySubnetName     = $targetSubnetName"
                    Write-Host "     RecoveryVmName         = $targetVMName"
                    Write-Host "     DiskType               = StandardSSD_LRS"
                    Write-Host "     LogStorageAccountId    = $AsrLogStorageAccountId"
                    if ($bootDiagStorageName -and $bootDiagStorageRG) {
                        Write-Host "     BootDiagStorageAccount = $bootDiagStorageName (RG: $bootDiagStorageRG)"
                    }
                }
                "REPLICATE" {
                    Write-Host "  [ASR] Enabling replication for PHYSICAL server '$csvVmName'..."

                    # For VMware/Physical modernized scenario we use the ReplicateVMwareToAzure parameter set.
                    # This is documented for VMware, but used for physical as well behind the config server. 

                    $job = New-AzRecoveryServicesAsrReplicationProtectedItem `
                        -ReplicateVMwareToAzure `
                        -ProtectableItem            $protectable `
                        -Name                       $csvVmName `
                        -ProtectionContainerMapping $asrContainerMapping `
                        -ApplianceName              $AsrApplianceName `
                        -Fabric                     $asrFabric `
                        -RecoveryResourceGroupId    $targetRGId `
                        -DiskType                   "StandardSSD_LRS" `
                        -RecoveryVmName             $targetVMName `
                        -RecoveryAzureNetworkId     $targetNetworkId `
                        -RecoveryAzureSubnetName    $targetSubnetName `
                        -LogStorageAccountId        $AsrLogStorageAccountId `
                        -ErrorAction                Stop

                    Write-Host "  [ASR] Replication job triggered for '$csvVmName'. Job name: $($job.Name)"
                    Write-Host "  [ASR] Monitor via: Get-AzRecoveryServicesAsrReplicationProtectedItem | Where-Object { \$_.Name -eq '$csvVmName' }"
                }
                default {
                    Write-Warning "  [ASR] Unsupported Mode '$effectiveModeUpper'. Only DryRun / Replicate implemented."
                }
            }

            continue
        }

        # ========== VMWARE: use Azure Migrate cmdlets (agentless) ==========
        if ($migrationTypeNorm -eq "vmware") {

            if ($projectSubscriptionId) {
                Write-Host ("  [Migrate] Setting context to Project Subscription: " + $projectSubscriptionId)
                Set-AzContext -SubscriptionId $projectSubscriptionId -ErrorAction Stop | Out-Null
            }

            if (-not $projectRG -or -not $projectName) {
                Write-Warning "  [Migrate][$csvVmName] Project RG / Project Name not set. Skipping."
                continue
            }

            if (-not $targetSubscriptionId -or -not $targetRGName -or -not $targetVNetName -or -not $targetSubnetName -or -not $targetRegion) {
                Write-Warning "  [Migrate][$csvVmName] Target subscription / RG / VNet / Subnet / Region not fully set. Skipping."
                continue
            }

            $migrateProject = Get-AzMigrateProject -Name $projectName -ResourceGroupName $projectRG -ErrorAction SilentlyContinue
            if (-not $migrateProject) {
                if ($effectiveModeUpper -eq "DRYRUN") {
                    Write-Warning "  [Migrate][DryRun] Azure Migrate project $projectName in RG $projectRG not found. Would create it."
                }
                else {
                    Write-Host "  [Migrate] Creating Azure Migrate project $projectName in RG $projectRG..."
                    $migrateProject = New-AzMigrateProject -Name $projectName -ResourceGroupName $projectRG -Location $targetRegion -ErrorAction Stop
                }
            }
            else {
                Write-Host "  [Migrate] Found Azure Migrate project: $($migrateProject.Name)"
            }

            $infraKey = "$($projectRG)|$($projectName)|$($targetRegion)"
            if (-not $initializedMigrateInfra.ContainsKey($infraKey)) {
                if ($effectiveModeUpper -eq "DRYRUN") {
                    Write-Host "  [Migrate][DryRun] Would initialize replication infra for project $projectName ($targetRegion)."
                }
                else {
                    Write-Host "  [Migrate] Initializing replication infra for project $projectName ($targetRegion)..."
                    Initialize-AzMigrateReplicationInfrastructure `
                        -ResourceGroupName $projectRG `
                        -ProjectName       $projectName `
                        -Scenario          "agentlessVMware" `
                        -TargetRegion      $targetRegion `
                        -ErrorAction       Stop
                }
                $initializedMigrateInfra[$infraKey] = $true
            }

            $targetRGId      = "/subscriptions/$targetSubscriptionId/resourceGroups/$targetRGName"
            $targetNetworkId = "/subscriptions/$targetSubscriptionId/resourceGroups/$targetRGName/providers/Microsoft.Network/virtualNetworks/$targetVNetName"

            Write-Host "  [Migrate] Project       : $projectName (RG: $projectRG, Region: $targetRegion)"
            Write-Host "  [Migrate] Target RG     : $targetRGName"
            Write-Host "  [Migrate] Target VNet   : $targetNetworkId"
            Write-Host "  [Migrate] Target Subnet : $targetSubnetName"
            Write-Host "  [Migrate] Target VMName : $targetVMName"

            $discServer = Get-AzMigrateDiscoveredServer `
                -ProjectName       $projectName `
                -ResourceGroupName $projectRG `
                -DisplayName       $csvVmName `
                -MachineType       "VMware" `
                -ErrorAction       SilentlyContinue

            if (-not $discServer) {
                Write-Warning "  [Migrate] Could not find VMware discovered server for $csvVmName in Azure Migrate project $projectName. Skipping."
                continue
            }

            $machineId = $discServer.Id
            $osDiskId  = $discServer.OsDiskId

            if (-not $machineId) {
                Write-Warning "  [Migrate] Discovered server for $csvVmName has no MachineId. Skipping."
                continue
            }
            if (-not $osDiskId) {
                Write-Warning "  [Migrate] Discovered server for $csvVmName has no OsDiskId. Skipping."
                continue
            }

            switch ($effectiveModeUpper) {
                "DRYRUN" {
                    Write-Host "  [Migrate][DryRun] Would call New-AzMigrateServerReplication with:"
                    Write-Host "     MachineId             = $machineId"
                    Write-Host "     TargetResourceGroupId = $targetRGId"
                    Write-Host "     TargetNetworkId       = $targetNetworkId"
                    Write-Host "     TargetSubnetName      = $targetSubnetName"
                    Write-Host "     TargetVMName          = $targetVMName"
                    Write-Host "     DiskType              = StandardSSD_LRS"
                    Write-Host "     OSDiskId              = $osDiskId"
                    Write-Host "     TargetRegion          = $targetRegion"
                    Write-Host "     LicenseType           = NoLicenseType"
                }
                "REPLICATE" {
                    Write-Host "  [Migrate] Enabling replication for $csvVmName via Azure Migrate (VMware)..."

                    $job = New-AzMigrateServerReplication `
                        -MachineId             $machineId `
                        -TargetResourceGroupId $targetRGId `
                        -TargetNetworkId       $targetNetworkId `
                        -TargetSubnetName      $targetSubnetName `
                        -TargetVMName          $targetVMName `
                        -DiskType              "StandardSSD_LRS" `
                        -OSDiskID              $osDiskId `
                        -TargetRegion          $targetRegion `
                        -LicenseType           "NoLicenseType" `
                        -ErrorAction           Stop

                    Write-Host "  [Migrate] Replication job triggered. Job name: $($job.Name)"
                    Write-Host "  [Migrate] Monitor with: Get-AzMigrateServerReplication -ProjectName $projectName -ResourceGroupName $projectRG"
                }
                default {
                    Write-Warning "  [Migrate] Unsupported Mode '$effectiveModeUpper'. Only DryRun / Replicate implemented."
                }
            }

            continue
        }

        # Any other MigrationType → skip for now
        Write-Warning "  [$csvVmName] Unsupported MigrationType '$migrationType'. Currently supported: Physical (ASR), VMware (Azure Migrate)."
    }

    Write-Host ""
    Write-Host "===== replication-run.ps1 complete ====="
}
catch {
    Write-Error ("Fatal error in replication-run: " + $_.ToString())
    exit 1
}
