[CmdletBinding()]
param(
    [ValidateSet('Export', 'Import')]
    [string]$Mode = $null,

    [string]$Tenant = '',

    [string]$Organization = '',

    [string]$ClientId = '',

    [string]$ClientSecret = '',

    [string]$PackagePath = '',

    [string]$EntityNames = '',

    [switch]$IncludeFiles = $false,

    [switch]$ImportRelationships = $false,

    [int]$PageSize = 100,

    [int]$BatchSize = 50,

    [string]$ProjectDir = $PSScriptRoot,

    [string]$ReportPath = '',

    [string]$LogPath = '',

    [switch]$NoPrompt = $false
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Converts SecureString prompt output to plain text only at the execution boundary where the CLI needs it.
function ConvertFrom-InputSecureString {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Security.SecureString]) {
        $bstr = [System.IntPtr]::Zero
        try {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
            return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        }
        finally {
            if ($bstr -ne [System.IntPtr]::Zero) {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
    }

    return [string]$Value
}

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

# Invokes the supplied secure prompt hook and converts the value for CLI login use.
function Read-SecretInput {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ReadSecret,

        [Parameter(Mandatory)]
        [string]$Prompt
    )

    return ConvertFrom-InputSecureString -Value (& $ReadSecret $Prompt)
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

    $hasCredentialValue = -not [string]::IsNullOrWhiteSpace($MigrationInput.Organization) -or
        -not [string]::IsNullOrWhiteSpace($MigrationInput.ClientId) -or
        -not [string]::IsNullOrWhiteSpace($MigrationInput.ClientSecret)

    if ($hasCredentialValue -and (
            [string]::IsNullOrWhiteSpace($MigrationInput.Tenant) -or
            [string]::IsNullOrWhiteSpace($MigrationInput.Organization) -or
            [string]::IsNullOrWhiteSpace($MigrationInput.ClientId) -or
            [string]::IsNullOrWhiteSpace($MigrationInput.ClientSecret))) {
        throw 'Client credential login requires Tenant, Organization, ClientId, and ClientSecret.'
    }
}

# Collects and normalizes all user inputs before the migration engine is called.
function Resolve-MigrationInput {
    param(
        [string]$Mode = $null,

        [string]$Tenant = '',

        [string]$Organization = '',

        [string]$ClientId = '',

        [string]$ClientSecret = '',

        [string]$PackagePath = '',

        [string]$EntityNames = '',

        [bool]$IncludeFiles = $false,

        [bool]$IncludeFilesSpecified = $false,

        [bool]$ImportRelationships = $false,

        [bool]$ImportRelationshipsSpecified = $false,

        [int]$PageSize = 100,

        [int]$BatchSize = 50,

        [string]$ProjectDir = $PSScriptRoot,

        [switch]$NoPrompt = $false,

        [scriptblock]$ReadText = { param($Prompt) Read-Host -Prompt $Prompt },

        [scriptblock]$ReadSecret = { param($Prompt) Read-Host -Prompt $Prompt -AsSecureString }
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

    $resolvedTenant = Resolve-TextValue -Value $Tenant -Prompt 'Tenant name (blank uses current uip login tenant unless client credentials are supplied)' -ReadText $ReadText -NoPrompt:$NoPrompt
    $resolvedOrganization = Resolve-TextValue -Value $Organization -Prompt 'Organization logical name (blank uses current uip login session)' -ReadText $ReadText -NoPrompt:$NoPrompt
    $resolvedClientId = Resolve-TextValue -Value $ClientId -Prompt 'Client ID (blank uses current uip login session)' -ReadText $ReadText -NoPrompt:$NoPrompt
    $resolvedClientSecret = $ClientSecret

    if ([string]::IsNullOrWhiteSpace($resolvedClientSecret) -and -not $NoPrompt -and -not [string]::IsNullOrWhiteSpace($resolvedClientId)) {
        $resolvedClientSecret = Read-SecretInput -ReadSecret $ReadSecret -Prompt 'Client secret'
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedClientSecret)) {
        $resolvedClientSecret = [string]$resolvedClientSecret
    }

    $resolvedPackagePath = Resolve-TextValue -Value $PackagePath -Prompt 'Migration package ZIP path' -ReadText $ReadText -NoPrompt:$NoPrompt
    if ([string]::IsNullOrWhiteSpace($resolvedPackagePath) -and -not $NoPrompt) {
        $resolvedPackagePath = Resolve-MigrationDefaultPackagePath -ProjectDir $ProjectDir
    }

    $resolvedEntityNames = $EntityNames
    $resolvedIncludeFiles = $IncludeFiles
    $resolvedImportRelationships = $ImportRelationships
    $resolvedPageSize = if ($PageSize -gt 0) { $PageSize } else { 100 }
    $resolvedBatchSize = if ($BatchSize -gt 0) { $BatchSize } else { 50 }

    if ($resolvedMode -eq 'Export') {
        $resolvedEntityNames = Resolve-TextValue -Value $EntityNames -Prompt 'Entity names for export (comma-separated, blank exports all native entities)' -ReadText $ReadText -NoPrompt:$NoPrompt
        $resolvedIncludeFiles = Resolve-SwitchValue -Value $IncludeFiles -WasProvided $IncludeFilesSpecified -Prompt 'Include file field attachments?' -ReadText $ReadText -NoPrompt:$NoPrompt
        $resolvedPageSize = Resolve-IntegerValue -Value $PageSize -DefaultValue 100 -Prompt 'Export page size' -Name 'Page size' -ReadText $ReadText -NoPrompt:$NoPrompt
    }
    elseif ($resolvedMode -eq 'Import') {
        $resolvedIncludeFiles = Resolve-SwitchValue -Value $IncludeFiles -WasProvided $IncludeFilesSpecified -Prompt 'Upload exported file field attachments?' -ReadText $ReadText -NoPrompt:$NoPrompt
        $resolvedImportRelationships = Resolve-SwitchValue -Value $ImportRelationships -WasProvided $ImportRelationshipsSpecified -Prompt 'Update relationship fields after import?' -ReadText $ReadText -NoPrompt:$NoPrompt
        $resolvedBatchSize = Resolve-IntegerValue -Value $BatchSize -DefaultValue 50 -Prompt 'Import batch size' -Name 'Batch size' -ReadText $ReadText -NoPrompt:$NoPrompt
    }

    $resolved = [pscustomobject]@{
        Mode = $resolvedMode
        Tenant = $resolvedTenant
        Organization = $resolvedOrganization
        ClientId = $resolvedClientId
        ClientSecret = $resolvedClientSecret
        PackagePath = $resolvedPackagePath
        EntityNames = $resolvedEntityNames
        IncludeFiles = [bool]$resolvedIncludeFiles
        ImportRelationships = [bool]$resolvedImportRelationships
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

        [string]$ClientId = '',

        [string]$ClientSecret = '',

        [string]$PackagePath = '',

        [string]$EntityNames = '',

        [switch]$IncludeFiles = $false,

        [switch]$ImportRelationships = $false,

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
            -ClientId $ClientId `
            -ClientSecret $ClientSecret `
            -PackagePath $PackagePath `
            -EntityNames $EntityNames `
            -IncludeFiles:$IncludeFiles `
            -IncludeFilesSpecified:$PSBoundParameters.ContainsKey('IncludeFiles') `
            -ImportRelationships:$ImportRelationships `
            -ImportRelationshipsSpecified:$PSBoundParameters.ContainsKey('ImportRelationships') `
            -PageSize $PageSize `
            -BatchSize $BatchSize `
            -ProjectDir $projectRoot `
            -NoPrompt:$NoPrompt

        Write-MigrationLogLine -Path $logPathForRun -Message ("Resolved mode: {0}; package: {1}; tenant: {2}; organization: {3}." -f $migrationInput.Mode, $migrationInput.PackagePath, $migrationInput.Tenant, $migrationInput.Organization)

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
            if (-not [string]::IsNullOrWhiteSpace($migrationInput.ClientId)) {
                $arguments.ClientId = $migrationInput.ClientId
            }
            if (-not [string]::IsNullOrWhiteSpace($migrationInput.ClientSecret)) {
                $arguments.ClientSecret = $migrationInput.ClientSecret
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
        if (-not [string]::IsNullOrWhiteSpace($migrationInput.ClientId)) {
            $arguments.ClientId = $migrationInput.ClientId
        }
        if (-not [string]::IsNullOrWhiteSpace($migrationInput.ClientSecret)) {
            $arguments.ClientSecret = $migrationInput.ClientSecret
        }
        if ($migrationInput.IncludeFiles) {
            $arguments.IncludeFiles = $true
        }
        if ($migrationInput.ImportRelationships) {
            $arguments.ImportRelationships = $true
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
