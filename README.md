
# Zero-Touch Migration – v129.1 package (surgical)

This bundle contains:

- **login-and-trigger.ps1 (v129)** – prefers **pwsh**; quotes `-File` paths; sets WorkingDirectory; no ternaries.
- **discovery-physical.ps1 (v129.1)** – quoted `az rest --url`; REST pagination; DNSName matching; StrictMode-safe manifest; **enriched join fields** (OSName fallback; BootType/CPU/Memory from `extendedInfo`).
- **business-mapping.ps1 (v122)** – reads `MIG_DISCOVERY_FILE`, writes diagnostic copy, aggregates by BusinessApplicationName.

## Usage
```powershell
Expand-Archive .\ztm-full-v129.1.zip -DestinationPath .

# Service Principal login expected if -UseServicePrincipal is provided
.
login-and-trigger.ps1 `
  -UseServicePrincipal `
  -InputCsv .\migration_input.csv `
  -Mode DryRun `
  -DiscoveryScriptPath .\discovery-physical.ps1 `
  -MappingScriptPath .usiness-mapping.ps1 `
  -OutputFolder .\out
```

## Outputs
- `out\inventory\discovery-full.json|.csv` – full paginated inventory
- `out\discovery-output.json` – join results (now includes OSName/BootType/CPUCount/MemoryGB)
- `out\csv-to-discovery-join.csv` – human-friendly join summary
- `out\manifest.json` – exact paths and counts; console prints `Manifest summary -> ...`
- `out\mapping-output.json` – Business Application summary

## Notes
- Quoting the URL is necessary to prevent Windows shells from splitting `&pageSize=100` (command separator).
- Azure Migrate `Machines—Enumerate` is paginated via `nextLink/continuationToken`; v129.1 follows all pages by default.
