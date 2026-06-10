<#
.SYNOPSIS
Exports or imports UiPath Data Fabric native entities through a portable migration package.

.DESCRIPTION
Run-DataFabricMigration.ps1 is the main runner for the Data Fabric migration tool. It collects
missing inputs from the console unless -NoPrompt is supplied, resolves artifact paths under the
project directory, imports src\DataFabricMigration.psm1, authenticates with uip, runs export or
import, streams progress, and writes a short report plus detailed logs.

Export flow:
1. Collect source tenant and package options.
2. Resolve the package, working, log, and report paths.
3. Import the migration module and authenticate to the source tenant.
4. Export selected native entity schemas, create bodies, records, relationship metadata, optional
   file attachments, and checksums.
5. Compress the migration package ZIP and write the export report.

Import flow:
1. Collect destination tenant and package options.
2. Resolve the package, working, log, and report paths.
3. Import the migration module and authenticate to the destination tenant.
4. Expand and validate the package checksums.
5. Create or reuse base entities without relationship fields in the first entity create body.
6. Insert scalar record values. Relationship fields and values are reported as skipped because
   current uip df schema output does not expose related entity/display-field metadata.
7. Optionally upload file attachments and write import-report.json plus the runner report.

.PARAMETER Mode
Execution mode: Export or Import. If omitted, the runner prompts in interactive mode.

.PARAMETER URL
Optional UiPath authority passed to uip login --authority, such as https://cloud.uipath.com.

.PARAMETER Organization
Optional UiPath organization logical name passed to uip login.

.PARAMETER Tenant
Optional UiPath tenant name passed to uip login and uip df commands.

.PARAMETER PackagePath
Path to the migration package ZIP. If omitted, the runner uses artifacts\packages\migration-package.zip.

.PARAMETER EntityNames
Comma-separated entity names for export. Leave blank to export all migratable native entities.

.PARAMETER IncludeFiles
Downloads file-field attachments during export or uploads exported attachments during import.

.PARAMETER PageSize
Record page size used during export.

.PARAMETER BatchSize
Record batch size used during import when single-record inserts are not required for ID mapping.

.PARAMETER ProjectDir
Project root used to resolve src, artifacts, logs, reports, and default package paths.

.PARAMETER ReportPath
Optional path for the short user-facing report.

.PARAMETER LogPath
Optional path for detailed progress logs.

.PARAMETER NoPrompt
Requires all necessary values through parameters and fails instead of prompting.

.EXAMPLE
.\Run-DataFabricMigration.ps1

Runs interactively and prompts for missing export/import values.

.EXAMPLE
.\Run-DataFabricMigration.ps1 -NoPrompt -Mode Export -Tenant SourceTenant -EntityNames "Demo,DemoMain" -PackagePath .\artifacts\packages\migration-package.zip -IncludeFiles

Exports selected entities and file attachments without prompts.

.EXAMPLE
.\Run-DataFabricMigration.ps1 -NoPrompt -Mode Import -Tenant DestinationTenant -PackagePath .\artifacts\packages\migration-package.zip -IncludeFiles

Imports the package, skips unsupported relationship fields/values, and uploads attachments.

.NOTES
The tool migrates native user-created Data Fabric entities only. It does not delete destination
entities, remove fields, or change existing field data types because those operations are unsafe or
unsupported through the Data Fabric CLI.
#>
[CmdletBinding()]
param(
    [ValidateSet('Export', 'Import')]
    [string]$Mode = $null,

    [string]$URL = '',

    [string]$Organization = '',

    [string]$Tenant = '',

    [string]$PackagePath = '',

    [string]$EntityNames = '',

    [switch]$IncludeFiles = $false,

    [int]$PageSize = 100,

    [int]$BatchSize = 50,

    [string]$ProjectDir = $PSScriptRoot,

    [string]$ReportPath = '',

    [string]$LogPath = '',

    [switch]$NoPrompt = $false
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Parses user yes/no style input into a Boolean switch value.
function ConvertTo-BoolOption {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return $Value.Trim() -match '^(1|y|yes|true)$'
}

# Converts the comma-separated entity-name prompt/parameter into a clean string array.
function ConvertTo-EntityNameArray {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

# Formats a single name/value pair for the short success or failure report.
function Format-ResultLine {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Value
    )

    "{0}: {1}" -f $Name, $Value
}

# Writes the short user-facing report, creating the report directory when needed.
function Write-MigrationReport {
    param(
        [AllowNull()]
        [string]$Path,

        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Set-Content -LiteralPath $Path -Value $Text -Encoding UTF8
}

# Returns the root directory used for generated packages, logs, reports, and working files.
function Get-MigrationArtifactRoot {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectDir
    )

    return Join-Path $ProjectDir 'artifacts'
}

# Resolves the default migration package ZIP path under artifacts/packages.
function Resolve-MigrationDefaultPackagePath {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectDir
    )

    return Join-Path (Join-Path (Get-MigrationArtifactRoot -ProjectDir $ProjectDir) 'packages') 'migration-package.zip'
}

# Resolves the detailed log path, using artifacts/logs when the caller does not provide one.
function Resolve-MigrationLogPath {
    param(
        [AllowNull()]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ProjectDir
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    return Join-Path (Join-Path (Get-MigrationArtifactRoot -ProjectDir $ProjectDir) 'logs') "DataFabricMigration-$timestamp.log"
}

# Resolves the short report path, using artifacts/reports when the caller does not provide one.
function Resolve-MigrationReportPath {
    param(
        [AllowNull()]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ProjectDir,

        [AllowNull()]
        [string]$Mode
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    }

    $safeMode = if ([string]::IsNullOrWhiteSpace($Mode)) { 'Migration' } else { $Mode }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    return Join-Path (Join-Path (Get-MigrationArtifactRoot -ProjectDir $ProjectDir) 'reports') "DataFabric$safeMode-$timestamp-report.txt"
}

# Creates an isolated timestamped working directory for export or import internals.
function Resolve-MigrationWorkingDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectDir,

        [Parameter(Mandatory)]
        [ValidateSet('Export', 'Import')]
        [string]$Mode
    )

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    return Join-Path (Join-Path (Join-Path (Get-MigrationArtifactRoot -ProjectDir $ProjectDir) 'work') $Mode.ToLowerInvariant()) $timestamp
}

# Finds the migration module from the organized src layout, with legacy root fallback for compatibility.
function Resolve-MigrationModulePath {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectDir
    )

    $candidates = @(
        (Join-Path $ProjectDir 'src\DataFabricMigration.psm1'),
        (Join-Path $ProjectDir 'DataFabricMigration.psm1')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "DataFabricMigration module not found under '$ProjectDir'. Ensure the script is run from the project directory or pass -ProjectDir explicitly."
}

# Initializes the detailed log file with a simple header before progress events are appended.
function Initialize-MigrationLog {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Set-Content -LiteralPath $Path -Encoding UTF8 -Value @(
        "Data Fabric migration log"
        "Started: $((Get-Date).ToString('o'))"
        ''
    )
}

# Safely reads a property from a structured progress event with a fallback value.
function Get-ProgressEventValue {
    param(
        [AllowNull()]
        [object]$Event,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$DefaultValue
    )

    if ($null -eq $Event) {
        return $DefaultValue
    }

    $property = $Event.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }

    return $property.Value
}

# Converts detailed event data to compact JSON for log-file diagnostics.
function ConvertTo-CompactJson {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    try {
        return ($Value | ConvertTo-Json -Depth 30 -Compress)
    }
    catch {
        return [string]$Value
    }
}

# Appends one line to the detailed log when logging is enabled.
function Write-MigrationLogLine {
    param(
        [AllowNull()]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    Add-Content -LiteralPath $Path -Encoding UTF8 -Value $Message
}

# Writes one structured progress event to the detailed log with timestamp, stage, detail, and data.
function Write-MigrationLogEvent {
    param(
        [AllowNull()]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$Event
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $timestamp = Get-ProgressEventValue -Event $Event -Name 'Timestamp' -DefaultValue (Get-Date).ToString('o')
    $level = Get-ProgressEventValue -Event $Event -Name 'Level' -DefaultValue 'Info'
    $operation = Get-ProgressEventValue -Event $Event -Name 'Operation' -DefaultValue 'Migration'
    $stage = Get-ProgressEventValue -Event $Event -Name 'Stage' -DefaultValue 'Progress'
    $message = Get-ProgressEventValue -Event $Event -Name 'Message' -DefaultValue ''
    $detail = Get-ProgressEventValue -Event $Event -Name 'Detail' -DefaultValue $null
    $data = Get-ProgressEventValue -Event $Event -Name 'Data' -DefaultValue $null

    Write-MigrationLogLine -Path $Path -Message ("{0} [{1}] [{2}/{3}] {4}" -f $timestamp, $level, $operation, $stage, $message)
    if (-not [string]::IsNullOrWhiteSpace($detail)) {
        Write-MigrationLogLine -Path $Path -Message ("  Detail: {0}" -f $detail)
    }

    $json = ConvertTo-CompactJson -Value $data
    if (-not [string]::IsNullOrWhiteSpace($json)) {
        Write-MigrationLogLine -Path $Path -Message ("  Data: {0}" -f $json)
    }
}

# Prints concise, user-friendly progress status to the terminal.
function Write-TerminalProgressEvent {
    param(
        [Parameter(Mandatory)]
        [object]$Event
    )

    $message = Get-ProgressEventValue -Event $Event -Name 'Message' -DefaultValue ''
    if ([string]::IsNullOrWhiteSpace($message)) {
        return
    }

    $level = [string](Get-ProgressEventValue -Event $Event -Name 'Level' -DefaultValue 'Info')
    $prefix = if ($level -in @('Warn', 'Warning')) {
        'WARN '
    }
    elseif ($level -eq 'Error') {
        'ERROR '
    }
    else {
        ''
    }

    Write-Host ("[{0}] {1}{2}" -f (Get-Date -Format 'HH:mm:ss'), $prefix, $message)
}

# Invokes the supplied text prompt hook so tests can mock interactive input.
function Read-TextInput {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ReadText,

        [Parameter(Mandatory)]
        [string]$Prompt
    )

    $value = & $ReadText $Prompt
    if ($null -eq $value) {
        return $null
    }

    return [string]$value
}

# Resolves a text value from parameters or prompts, honoring -NoPrompt.
function Resolve-TextValue {
    param(
        [AllowNull()]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [scriptblock]$ReadText,

        [switch]$NoPrompt
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value.Trim()
    }

    if ($NoPrompt) {
        return $null
    }

    $answer = Read-TextInput -ReadText $ReadText -Prompt $Prompt
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $null
    }

    return $answer.Trim()
}

# Resolves numeric input with defaults and validation for page/batch sizes.
function Resolve-IntegerValue {
    param(
        [int]$Value,

        [Parameter(Mandatory)]
        [int]$DefaultValue,

        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$ReadText,

        [switch]$NoPrompt
    )

    if ($Value -gt 0) {
        return $Value
    }

    if ($NoPrompt) {
        return $DefaultValue
    }

    $answer = Read-TextInput -ReadText $ReadText -Prompt "$Prompt [$DefaultValue]"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $DefaultValue
    }

    $parsed = 0
    if (-not [int]::TryParse($answer.Trim(), [ref]$parsed) -or $parsed -lt 1) {
        throw "$Name must be a positive integer."
    }

    return $parsed
}

# Resolves switch values from parameters or yes/no prompts.
function Resolve-SwitchValue {
    param(
        [bool]$Value,

        [bool]$WasProvided,

        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [scriptblock]$ReadText,

        [switch]$NoPrompt
    )

    if ($WasProvided) {
        return $Value
    }

    if ($NoPrompt) {
        return $false
    }

    return ConvertTo-BoolOption -Value (Read-TextInput -ReadText $ReadText -Prompt "$Prompt [y/N]")
}

# Validates that the collected inputs are sufficient to run the selected migration mode.
function Assert-MigrationInputComplete {
    param(
        [Parameter(Mandatory)]
        [object]$MigrationInput
    )

    if ([string]::IsNullOrWhiteSpace($MigrationInput.Mode)) {
        throw 'Mode is required when -NoPrompt is used.'
    }

    if ([string]::IsNullOrWhiteSpace($MigrationInput.PackagePath)) {
        throw 'Package path is required when -NoPrompt is used.'
    }
}

# Collects and normalizes all user inputs before the migration engine is called.
function Resolve-MigrationInput {
    param(
        [string]$Mode = $null,

        [string]$Tenant = '',

        [string]$Organization = '',

        [string]$URL = '',

        [string]$PackagePath = '',

        [string]$EntityNames = '',

        [bool]$IncludeFiles = $false,

        [bool]$IncludeFilesSpecified = $false,

        [int]$PageSize = 100,

        [int]$BatchSize = 50,

        [string]$ProjectDir = $PSScriptRoot,

        [switch]$NoPrompt = $false,

        [scriptblock]$ReadText = { param($Prompt) Read-Host -Prompt $Prompt }
    )

    $resolvedMode = Resolve-TextValue -Value $Mode -Prompt 'Migration mode (Export/Import)' -ReadText $ReadText -NoPrompt:$NoPrompt
    if (-not [string]::IsNullOrWhiteSpace($resolvedMode)) {
        $normalizedMode = $resolvedMode.Trim()
        if ($normalizedMode -notin @('Export', 'Import')) {
            $titleMode = (Get-Culture).TextInfo.ToTitleCase($normalizedMode.ToLowerInvariant())
            if ($titleMode -in @('Export', 'Import')) {
                $normalizedMode = $titleMode
            }
            else {
                throw 'Mode must be Export or Import.'
            }
        }
        $resolvedMode = $normalizedMode
    }

    $resolvedTenant = Resolve-TextValue -Value $Tenant -Prompt 'Tenant name (blank lets uip login prompt or use its default)' -ReadText $ReadText -NoPrompt:$NoPrompt
    $resolvedOrganization = Resolve-TextValue -Value $Organization -Prompt 'Organization logical name (blank lets uip login prompt or use its default)' -ReadText $ReadText -NoPrompt:$NoPrompt
    $resolvedURL = Resolve-TextValue -Value $URL -Prompt 'URL/authority (blank uses the uip CLI default authority)' -ReadText $ReadText -NoPrompt:$NoPrompt

    $resolvedPackagePath = Resolve-TextValue -Value $PackagePath -Prompt 'Migration package ZIP path' -ReadText $ReadText -NoPrompt:$NoPrompt
    if ([string]::IsNullOrWhiteSpace($resolvedPackagePath) -and -not $NoPrompt) {
        $resolvedPackagePath = Resolve-MigrationDefaultPackagePath -ProjectDir $ProjectDir
    }

    $resolvedEntityNames = $EntityNames
    $resolvedIncludeFiles = $IncludeFiles
    $resolvedPageSize = if ($PageSize -gt 0) { $PageSize } else { 100 }
    $resolvedBatchSize = if ($BatchSize -gt 0) { $BatchSize } else { 50 }

    if ($resolvedMode -eq 'Export') {
        $resolvedEntityNames = Resolve-TextValue -Value $EntityNames -Prompt 'Entity names for export (comma-separated, blank exports all native entities)' -ReadText $ReadText -NoPrompt:$NoPrompt
        $resolvedIncludeFiles = Resolve-SwitchValue -Value $IncludeFiles -WasProvided $IncludeFilesSpecified -Prompt 'Include file field attachments?' -ReadText $ReadText -NoPrompt:$NoPrompt
        $resolvedPageSize = Resolve-IntegerValue -Value $PageSize -DefaultValue 100 -Prompt 'Export page size' -Name 'Page size' -ReadText $ReadText -NoPrompt:$NoPrompt
    }
    elseif ($resolvedMode -eq 'Import') {
        $resolvedIncludeFiles = Resolve-SwitchValue -Value $IncludeFiles -WasProvided $IncludeFilesSpecified -Prompt 'Upload exported file field attachments?' -ReadText $ReadText -NoPrompt:$NoPrompt
        $resolvedBatchSize = Resolve-IntegerValue -Value $BatchSize -DefaultValue 50 -Prompt 'Import batch size' -Name 'Batch size' -ReadText $ReadText -NoPrompt:$NoPrompt
    }

    $resolved = [pscustomobject]@{
        Mode = $resolvedMode
        Tenant = $resolvedTenant
        Organization = $resolvedOrganization
        URL = $resolvedURL
        PackagePath = $resolvedPackagePath
        EntityNames = $resolvedEntityNames
        IncludeFiles = [bool]$resolvedIncludeFiles
        PageSize = $resolvedPageSize
        BatchSize = $resolvedBatchSize
    }

    Assert-MigrationInputComplete -MigrationInput $resolved
    return $resolved
}

# Main runner: imports the module, resolves inputs, wires progress logging, and calls export/import.
function Invoke-DataFabricMigrationRunner {
    [CmdletBinding()]
    param(
        [ValidateSet('Export', 'Import')]
        [string]$Mode = $null,

        [string]$Tenant = '',

        [string]$Organization = '',

        [string]$URL = '',

        [string]$PackagePath = '',

        [string]$EntityNames = '',

        [switch]$IncludeFiles = $false,

        [int]$PageSize = 100,

        [int]$BatchSize = 50,

        [string]$ProjectDir = $PSScriptRoot,

        [string]$ReportPath = '',

        [string]$LogPath = '',

        [switch]$NoPrompt = $false
    )

    $logPathForRun = $null
    $reportPathForRun = $null
    try {
        $projectRoot = $ProjectDir
        if ([string]::IsNullOrWhiteSpace($projectRoot)) {
            $projectRoot = $PSScriptRoot
        }

        $logPathForRun = Resolve-MigrationLogPath -Path $LogPath -ProjectDir $projectRoot
        $reportPathForRun = Resolve-MigrationReportPath -Path $ReportPath -ProjectDir $projectRoot -Mode $Mode
        Initialize-MigrationLog -Path $logPathForRun
        Write-Host ("Detailed log: {0}" -f $logPathForRun)
        Write-Host ("Report file: {0}" -f $reportPathForRun)
        Write-MigrationLogLine -Path $logPathForRun -Message ("Runner started with PowerShell PID {0}." -f $PID)

        $modulePath = Resolve-MigrationModulePath -ProjectDir $projectRoot
        Import-Module $modulePath -Force

        $migrationInput = Resolve-MigrationInput `
            -Mode $Mode `
            -Tenant $Tenant `
            -Organization $Organization `
            -URL $URL `
            -PackagePath $PackagePath `
            -EntityNames $EntityNames `
            -IncludeFiles:$IncludeFiles `
            -IncludeFilesSpecified:$PSBoundParameters.ContainsKey('IncludeFiles') `
            -PageSize $PageSize `
            -BatchSize $BatchSize `
            -ProjectDir $projectRoot `
            -NoPrompt:$NoPrompt

        Write-MigrationLogLine -Path $logPathForRun -Message ("Resolved mode: {0}; package: {1}; tenant: {2}; organization: {3}; URL: {4}." -f $migrationInput.Mode, $migrationInput.PackagePath, $migrationInput.Tenant, $migrationInput.Organization, $migrationInput.URL)

        $progressCallback = {
            param($Event)

            Write-TerminalProgressEvent -Event $Event
            Write-MigrationLogEvent -Path $logPathForRun -Event $Event
        }

        if ($migrationInput.Mode -eq 'Export') {
            $arguments = @{
                PackagePath = $migrationInput.PackagePath
                PageSize = $migrationInput.PageSize
                ProgressCallback = $progressCallback
                WorkingDirectory = Resolve-MigrationWorkingDirectory -ProjectDir $projectRoot -Mode Export
            }
            if (-not [string]::IsNullOrWhiteSpace($migrationInput.Tenant)) {
                $arguments.Tenant = $migrationInput.Tenant
            }
            if (-not [string]::IsNullOrWhiteSpace($migrationInput.Organization)) {
                $arguments.Organization = $migrationInput.Organization
            }
            if (-not [string]::IsNullOrWhiteSpace($migrationInput.URL)) {
                $arguments.URL = $migrationInput.URL
            }

            [string[]]$entityNames = @(ConvertTo-EntityNameArray -Value $migrationInput.EntityNames)
            if ($entityNames.Count -gt 0) {
                $arguments.EntityName = $entityNames
            }
            if ($migrationInput.IncludeFiles) {
                $arguments.IncludeFiles = $true
            }

            $result = Export-DataFabricPackage @arguments

            $lines = @(
                'Data Fabric export completed.',
                (Format-ResultLine -Name 'Package' -Value $result.packagePath),
                (Format-ResultLine -Name 'Working directory' -Value $result.workingDirectory),
                (Format-ResultLine -Name 'Exported entities' -Value $result.entityCount),
                (Format-ResultLine -Name 'Skipped entities' -Value $result.skippedEntityCount),
                (Format-ResultLine -Name 'Errors' -Value $result.errorCount)
            )

            $reportText = $lines -join [Environment]::NewLine
            Write-MigrationReport -Path $reportPathForRun -Text $reportText
            Write-MigrationLogLine -Path $logPathForRun -Message $reportText
            $reportText
            return 0
        }

        $arguments = @{
            PackagePath = $migrationInput.PackagePath
            BatchSize = $migrationInput.BatchSize
            ProgressCallback = $progressCallback
            WorkingDirectory = Resolve-MigrationWorkingDirectory -ProjectDir $projectRoot -Mode Import
        }
        if (-not [string]::IsNullOrWhiteSpace($migrationInput.Tenant)) {
            $arguments.Tenant = $migrationInput.Tenant
        }
        if (-not [string]::IsNullOrWhiteSpace($migrationInput.Organization)) {
            $arguments.Organization = $migrationInput.Organization
        }
        if (-not [string]::IsNullOrWhiteSpace($migrationInput.URL)) {
            $arguments.URL = $migrationInput.URL
        }
        if ($migrationInput.IncludeFiles) {
            $arguments.IncludeFiles = $true
        }

        $result = Import-DataFabricPackage @arguments

        $lines = @(
            'Data Fabric import completed.',
            (Format-ResultLine -Name 'Package directory' -Value $result.packageDirectory),
            (Format-ResultLine -Name 'Report' -Value $result.reportPath),
            (Format-ResultLine -Name 'Created entities' -Value $result.createdEntityCount),
            (Format-ResultLine -Name 'Reused entities' -Value $result.reusedEntityCount),
            (Format-ResultLine -Name 'Inserted records' -Value $result.insertedRecordCount),
            (Format-ResultLine -Name 'Uploaded files' -Value $result.uploadedFileCount),
            (Format-ResultLine -Name 'Skipped items' -Value $result.skippedItemCount),
            (Format-ResultLine -Name 'Failures' -Value $result.failureCount)
        )

        $reportText = $lines -join [Environment]::NewLine
        Write-MigrationReport -Path $reportPathForRun -Text $reportText
        Write-MigrationLogLine -Path $logPathForRun -Message $reportText
        $reportText
        return 0
    }
    catch {
        $failureReport = @(
            'Data Fabric migration failed.',
            (Format-ResultLine -Name 'Error' -Value $_.Exception.Message)
        ) -join [Environment]::NewLine

        try {
            Write-MigrationReport -Path $reportPathForRun -Text $failureReport
        }
        catch {
            [Console]::Error.WriteLine("Failed to write migration report: $($_.Exception.Message)")
        }

        Write-MigrationLogLine -Path $logPathForRun -Message $failureReport
        [Console]::Error.WriteLine($failureReport)
        return 1
    }
}

$exitCode = Invoke-DataFabricMigrationRunner @PSBoundParameters
exit $exitCode
