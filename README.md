
# Zero-Touch Migration – v129.2 package (surgical)

**Changes from v129.1**
- Smart `discoveryData` selection in join (prefer entries with non-empty `bootType`/`osName`; prioritize `microsoftDiscovery=true`).
- JSON serialization depth increased to **12** (avoid truncation warnings in logs/files).

**Includes**
- `login-and-trigger.ps1` (v129)
- `discovery-physical.ps1` (v129.2)
- `business-mapping.ps1` (v122.1)

**Usage**
```powershell
Expand-Archive .\ztm-full-v129.2.zip -DestinationPath .

.\login-and-trigger.ps1 `
  -UseServicePrincipal `
  -InputCsv .\migration_input.csv `
  -Mode DryRun `
  -DiscoveryScriptPath .\discovery-physical.ps1 `
  -MappingScriptPath .usiness-mapping.ps1 `
  -OutputFolder .\out
```

Outputs are identical to v129.1, with richer join fields and no depth warnings.

