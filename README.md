# Data Fabric Migration Tool

Standalone PowerShell utility for exporting and importing UiPath Data Fabric entities, records, and optional file-field attachments.

The primary entrypoint is `Run-DataFabricMigration.ps1`. It prompts for missing values in the console, or runs fully non-interactively when all required parameters are supplied with `-NoPrompt`. The migration engine still uses the installed `uip df` CLI and creates a portable ZIP package. It migrates native user-created entities only. System/federated entities, system fields, unsupported choice-set fields, and unresolved relationships are skipped and reported.

## Files

- `Run-DataFabricMigration.ps1` is the user-facing PowerShell utility.
- `src/DataFabricMigration.psm1` contains the reusable migration logic and testable helper functions.
- `scripts/Export-DataFabric.ps1` is an advanced non-interactive export wrapper.
- `scripts/Import-DataFabric.ps1` is an advanced non-interactive import wrapper.
- `tests/Run-DataFabricMigrationTests.ps1` runs local tests without live Data Fabric writes.
- `artifacts/packages` stores generated migration ZIP packages.
- `artifacts/work/export` and `artifacts/work/import` store runtime working directories.
- `artifacts/logs` stores detailed progress logs.
- `artifacts/reports` stores short success or failure reports.

## Prerequisites

```powershell
uip login status --output json
uip df entities list --native-only --output json
```

If `uip df` is unavailable, install the Data Fabric CLI tool first:

```powershell
uip tools install @uipath/data-fabric-tool
```

If client credentials are not supplied, the utility uses the current `uip login` session. For cross-organization migrations, provide the organization logical name, tenant, client ID, and client secret for each phase. Export should use source organization credentials. Import should use destination organization credentials.

## Run From PowerShell

Interactive mode prompts for missing values:

```powershell
.\Run-DataFabricMigration.ps1
```

Export from a source organization without prompts:

```powershell
.\Run-DataFabricMigration.ps1 `
  -NoPrompt `
  -Mode Export `
  -Organization "SourceOrg" `
  -Tenant "SourceTenant" `
  -ClientId "SourceExternalAppId" `
  -ClientSecret "SourceExternalAppSecret" `
  -EntityNames "Customer,Invoice" `
  -PackagePath .\artifacts\packages\migration-package.zip `
  -IncludeFiles `
  -PageSize 100
```

Import into a destination organization without prompts:

```powershell
.\Run-DataFabricMigration.ps1 `
  -NoPrompt `
  -Mode Import `
  -Organization "DestinationOrg" `
  -Tenant "DestinationTenant" `
  -ClientId "DestinationExternalAppId" `
  -ClientSecret "DestinationExternalAppSecret" `
  -PackagePath .\artifacts\packages\migration-package.zip `
  -IncludeFiles `
  -ImportRelationships `
  -BatchSize 50
```

Write the console report to a file:

```powershell
.\Run-DataFabricMigration.ps1 -Mode Export -PackagePath .\artifacts\packages\migration-package.zip -ReportPath .\artifacts\reports\migration-report.txt
```

Write detailed progress logs to a specific file:

```powershell
.\Run-DataFabricMigration.ps1 -Mode Export -PackagePath .\artifacts\packages\migration-package.zip -LogPath .\artifacts\logs\export.log
```

## Input Behavior

- `-Mode` accepts `Export` or `Import`.
- `-Tenant`, `-Organization`, `-ClientId`, and `-ClientSecret` are optional only when using the current `uip login` session.
- If any client credential value is supplied, all four values are required: tenant, organization, client ID, and client secret.
- Prompted client secrets are read with `Read-Host -AsSecureString` and converted only for the `uip login` call.
- `-NoPrompt` throws on missing required values instead of asking.
- `-ReportPath` writes the final short success or failure report.
- If `-PackagePath` is omitted during interactive use, the package defaults to `.\artifacts\packages\migration-package.zip`.
- `-LogPath` writes detailed timestamped progress logs. If omitted, logs are created under `.\artifacts\logs\DataFabricMigration-<timestamp>.log`.
- If `-ReportPath` is omitted, reports are created under `.\artifacts\reports\`.
- Export supports `-EntityNames`, `-IncludeFiles`, `-PageSize`, and `-PackagePath`.
- Import supports `-IncludeFiles`, `-ImportRelationships`, `-BatchSize`, and `-PackagePath`.

## Progress And Logs

The runner prints concise terminal updates during long runs:

- Export: startup, authentication, entity discovery, skipped entities, each entity being exported, record pages read, file downloads, package creation, and final counts.
- Import: startup, package validation, destination entity discovery, each entity being imported, entity create/reuse, record batches, relationship updates, file uploads, and final counts.

The detailed log file includes the same progress with ISO timestamps, operation/stage names, warning/error levels, and structured event details such as package paths, batch sizes, entity IDs, record counts, batch numbers, and skipped-item reasons. Use this file for troubleshooting if a migration fails or stalls.

## Logical Flow

1. `Run-DataFabricMigration.ps1` collects parameters or prompts for missing input.
2. The runner resolves runtime paths under `artifacts`, initializes the log/report files, and imports `src/DataFabricMigration.psm1`.
3. Export mode logs into the source tenant, lists native entities, exports schema and records, optionally downloads file attachments, writes checksums, and creates the package ZIP.
4. Import mode validates and expands the package, logs into the destination tenant, creates or reuses entities, optionally adds compatible relationship fields, inserts records in batches, optionally updates relationships and uploads files, then writes `import-report.json`.
5. `scripts/Export-DataFabric.ps1` and `scripts/Import-DataFabric.ps1` bypass prompts for automation but call the same module functions.

## Advanced Script Entry Points

Use these single-phase wrappers when automation needs direct export or import control.

### Export

Export all migratable native entities in the active tenant:

```powershell
.\scripts\Export-DataFabric.ps1 -PackagePath .\artifacts\packages\migration-package.zip
```

Export selected entities from a source organization:

```powershell
.\scripts\Export-DataFabric.ps1 `
  -Organization "SourceOrg" `
  -Tenant "SourceTenant" `
  -ClientId "SourceExternalAppId" `
  -ClientSecret "SourceExternalAppSecret" `
  -EntityName "Customer","Invoice" `
  -PackagePath .\artifacts\packages\migration-package.zip
```

Include file-field attachments:

```powershell
.\scripts\Export-DataFabric.ps1 -PackagePath .\artifacts\packages\migration-package.zip -IncludeFiles
```

### Import

Import into the active destination tenant:

```powershell
.\scripts\Import-DataFabric.ps1 -PackagePath .\artifacts\packages\migration-package.zip
```

Import into a destination organization and upload exported file attachments:

```powershell
.\scripts\Import-DataFabric.ps1 `
  -Organization "DestinationOrg" `
  -Tenant "DestinationTenant" `
  -ClientId "DestinationExternalAppId" `
  -ClientSecret "DestinationExternalAppSecret" `
  -PackagePath .\artifacts\packages\migration-package.zip `
  -IncludeFiles
```

Preview import actions without making changes:

```powershell
.\scripts\Import-DataFabric.ps1 -PackagePath .\artifacts\packages\migration-package.zip -WhatIf
```

Relationship schema and value updates are skipped by default. After confirming the destination can accept relationship fields, opt in:

```powershell
.\scripts\Import-DataFabric.ps1 -PackagePath .\artifacts\packages\migration-package.zip -ImportRelationships
```

## Package Format

The ZIP contains:

- `manifest.json`: source tenant metadata, entity mappings, record counts, relationship field definitions, skipped items, and export errors.
- `checksums.json`: SHA-256 checksums for package validation before import.
- `entities/<EntityName>/schema.json`: exported schema from `uip df entities get`, with unsupported choice-set fields removed.
- `entities/<EntityName>/create-body.json`: sanitized entity-create body used by import for missing entities.
- `entities/<EntityName>/records.json`: sanitized export records with first-pass insert data, separated file-field metadata, relationship values, and source record IDs.
- `files/<EntityName>/<RecordId>/...`: downloaded file attachments when `-IncludeFiles` is used.

## Migration Behavior

- Only entities with `Type = Entity` and `Source = Native` are imported.
- System fields are removed from record insert payloads: `Id`, `CreatedBy`, `CreateTime`, `UpdatedBy`, `UpdateTime`.
- Choice set fields are not supported. Fields of type `CHOICE_SET_SINGLE` and `CHOICE_SET_MULTIPLE`, including their record values, are skipped during export and import because the current `uip df` CLI does not expose the choice set definitions/options required to recreate them.
- Destination entities are matched by entity name. Existing entities are reused; missing entities are created.
- Records are inserted in batches. Source-to-destination record ID mappings are written to `import-report.json`.
- File attachments upload after records exist and can be mapped.
- Relationship fields and values are preserved only when `-ImportRelationships` is specified. The importer creates missing compatible relationship fields after all destination entities exist, inserts records with destination ID mapping enabled, then updates relationship values using destination record IDs.
- Failures are collected in reports; one failed entity, batch, file, or relationship does not stop the whole import.

## Test

Run the local test harness:

```powershell
.\tests\Run-DataFabricMigrationTests.ps1
```
