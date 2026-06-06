Set-StrictMode -Version 3.0

# Data Fabric migration engine.
# Public functions at the bottom are used by the runner, advanced wrappers, and tests.
# Internal helpers normalize uip CLI responses, transform schemas/records, package artifacts, and report progress.

$script:SystemFieldNames = @('Id', 'CreatedBy', 'CreateTime', 'UpdatedBy', 'UpdateTime')
$script:ReservedFieldNames = @('Id', 'CreatedBy', 'CreateTime', 'UpdatedBy', 'UpdateTime')

# Reads a property from PSCustomObject/hashtable data using the first matching name.
function Get-PropertyValue {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string[]]$Names
    )

    if ($null -eq $InputObject) {
        return $null
    }

    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }

    return $null
}

# Checks whether a structured object has a named property without throwing under StrictMode.
function Test-PropertyExists {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $false
    }

    return $null -ne $InputObject.PSObject.Properties[$Name]
}

# Recursively converts PSCustomObject values into hashtables for safe JSON/body manipulation.
function ConvertTo-HashtableDeep {
    param(
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $table[$key] = ConvertTo-HashtableDeep -InputObject $InputObject[$key]
        }
        return $table
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ConvertTo-HashtableDeep -InputObject $item
        }
        return $items
    }

    if ($InputObject -is [pscustomobject]) {
        $table = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-HashtableDeep -InputObject $property.Value
        }
        return $table
    }

    return $InputObject
}

# Writes JSON to disk and creates the parent directory if it does not exist.
function ConvertTo-JsonFile {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $InputObject | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding UTF8
}

# Reads and parses a required JSON file from disk.
function Import-JsonFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required JSON file was not found: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

# Extracts an invokable path from PowerShell command metadata.
function Get-CommandInfoPath {
    param(
        [Parameter(Mandatory)]
        [object]$CommandInfo
    )

    foreach ($name in @('Source', 'Path', 'Definition')) {
        $value = Get-PropertyValue -InputObject $CommandInfo -Names @($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return [string]$value
        }
    }

    return $null
}

# Resolves the uip CLI command, preferring executable shims over PowerShell npm shims.
function Resolve-UipCommandPath {
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )

    $commands = @(Get-Command -Name $Command -All -ErrorAction SilentlyContinue)
    if ($commands.Count -eq 0 -and (Test-Path -LiteralPath $Command)) {
        return (Resolve-Path -LiteralPath $Command).Path
    }
    if ($commands.Count -eq 0) {
        throw "Command '$Command' was not found. Ensure the UiPath CLI is installed and available on PATH."
    }

    $applications = @($commands | Where-Object { $_.CommandType -eq 'Application' })
    foreach ($extension in @('.exe', '.cmd', '.bat', '.com')) {
        foreach ($candidate in $applications) {
            $path = Get-CommandInfoPath -CommandInfo $candidate
            if (-not [string]::IsNullOrWhiteSpace($path) -and [System.IO.Path]::GetExtension($path).ToLowerInvariant() -eq $extension) {
                return $path
            }
        }
    }

    foreach ($candidate in $applications) {
        $path = Get-CommandInfoPath -CommandInfo $candidate
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            return $path
        }
    }

    foreach ($candidate in @($commands | Where-Object { $_.CommandType -eq 'ExternalScript' })) {
        $path = Get-CommandInfoPath -CommandInfo $candidate
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            return $path
        }
    }

    foreach ($candidate in $commands) {
        $path = Get-CommandInfoPath -CommandInfo $candidate
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            return $path
        }
    }

    throw "Command '$Command' was found but no invokable path could be resolved."
}

# Builds a redacted command string for error messages so client secrets are not leaked.
function Format-UipCommandForError {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $safeArguments = @()
    $redactNext = $false
    foreach ($argument in $Arguments) {
        if ($redactNext) {
            $safeArguments += '***'
            $redactNext = $false
            continue
        }

        if ($argument -match '^(--client-secret=)(.*)$') {
            $safeArguments += ($Matches[1] + '***')
            continue
        }

        $safeArguments += $argument
        if ($argument -eq '--client-secret') {
            $redactNext = $true
        }
    }

    return "uip $($safeArguments -join ' ')"
}

# Runs uip with safe argument passing, captures stdout/stderr separately, and parses JSON output.
function Invoke-UipJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [string]$Command = 'uip'
    )

    $commandPath = Resolve-UipCommandPath -Command $Command
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        $commandOutput = @(& $commandPath @Arguments 2>&1)
        $exitCode = $global:LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $stdoutLines = @()
    $stderrLines = @()
    foreach ($item in $commandOutput) {
        if ($item -is [System.Management.Automation.ErrorRecord]) {
            $stderrLines += [string]$item
            continue
        }

        $stdoutLines += [string]$item
    }

    $stdout = $stdoutLines -join [Environment]::NewLine
    $stderr = $stderrLines -join [Environment]::NewLine

    if ($exitCode -ne 0) {
        $message = $stderr
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = $stdout
        }
        throw "$(Format-UipCommandForError -Arguments $Arguments) failed with exit code ${exitCode}: $message"
    }

    if ([string]::IsNullOrWhiteSpace($stdout)) {
        return $null
    }

    try {
        return $stdout | ConvertFrom-Json
    }
    catch {
        throw "$(Format-UipCommandForError -Arguments $Arguments) returned non-JSON output: $stdout"
    }
}

# Builds login arguments for current-session login or client-credential login.
function New-DataFabricLoginArguments {
    param(
        [string]$Tenant,

        [string]$Organization,

        [string]$ClientId,

        [string]$ClientSecret
    )

    $hasClientId = -not [string]::IsNullOrWhiteSpace($ClientId)
    $hasClientSecret = -not [string]::IsNullOrWhiteSpace($ClientSecret)
    $hasOrganization = -not [string]::IsNullOrWhiteSpace($Organization)

    if (-not $hasClientId -and -not $hasClientSecret -and -not $hasOrganization) {
        return @('login', 'status', '--output', 'json')
    }

    if (-not $hasClientId -or -not $hasClientSecret) {
        throw 'Client ID and client secret are both required for client credential login.'
    }

    if ([string]::IsNullOrWhiteSpace($Tenant)) {
        throw 'Tenant is required for client credential login.'
    }

    $arguments = @('login', '--client-id', $ClientId.Trim(), '--client-secret', $ClientSecret)
    if ($hasOrganization) {
        $arguments += @('--organization', $Organization.Trim())
    }

    $arguments += @('--tenant', $Tenant.Trim(), '--output', 'json')
    return $arguments
}

# Performs the optional login step before export or import operations.
function Invoke-DataFabricLogin {
    param(
        [string]$Tenant,

        [string]$Organization,

        [string]$ClientId,

        [string]$ClientSecret,

        [scriptblock]$Invoker
    )

    $loginArguments = New-DataFabricLoginArguments -Tenant $Tenant -Organization $Organization -ClientId $ClientId -ClientSecret $ClientSecret
    return Invoke-DataFabricCli -Arguments $loginArguments -Invoker $Invoker
}

# Invokes Data Fabric CLI commands, using a test invoker when supplied.
function Invoke-DataFabricCli {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [scriptblock]$Invoker
    )

    if ($Invoker) {
        return & $Invoker $Arguments
    }

    return Invoke-UipJson -Arguments $Arguments
}

# Sends structured progress events to the runner without coupling the module to console output.
function Send-DataFabricProgress {
    param(
        [scriptblock]$ProgressCallback,

        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [string]$Stage,

        [string]$Level = 'Info',

        [Parameter(Mandatory)]
        [string]$Message,

        [AllowNull()]
        [string]$Detail,

        [AllowNull()]
        [hashtable]$Data
    )

    if (-not $ProgressCallback) {
        return
    }

    $eventData = if ($Data) { [pscustomobject]$Data } else { $null }
    & $ProgressCallback ([pscustomobject]@{
            Timestamp = (Get-Date).ToString('o')
            Operation = $Operation
            Stage = $Stage
            Level = $Level
            Message = $Message
            Detail = $Detail
            Data = $eventData
        })
}

# Extracts the Data payload from a uip JSON response and validates Result status.
function Get-UipData {
    param(
        [AllowNull()]
        [object]$Response
    )

    if ($null -eq $Response) {
        return $null
    }

    $result = Get-PropertyValue -InputObject $Response -Names @('Result')
    if ($result -and $result -ne 'Success') {
        $message = Get-PropertyValue -InputObject $Response -Names @('Message', 'Error', 'Details')
        throw "uip returned ${result}: $message"
    }

    if (Test-PropertyExists -InputObject $Response -Name 'Data') {
        return (Get-PropertyValue -InputObject $Response -Names @('Data'))
    }

    return $Response
}

# Appends a tenant argument to a uip command when a tenant was explicitly selected.
function Add-TenantArgument {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [string]$Tenant
    )

    $result = @($Arguments)
    if (-not [string]::IsNullOrWhiteSpace($Tenant)) {
        $result += @('--tenant', $Tenant)
    }
    return $result
}

# Normalizes entity-list responses across possible CLI payload shapes.
function Get-DataFabricEntityList {
    param(
        [AllowNull()]
        [object]$Response
    )

    $data = Get-UipData -Response $Response
    if ($null -eq $data) {
        return @()
    }

    if ($data -is [System.Collections.IEnumerable] -and $data -isnot [string]) {
        return @($data)
    }

    foreach ($name in @('Entities', 'Items', 'Value')) {
        $items = Get-PropertyValue -InputObject $data -Names @($name)
        if ($null -ne $items) {
            return @($items)
        }
    }

    return @($data)
}

# Normalizes record-list responses across possible CLI payload shapes.
function Get-DataFabricRecordList {
    param(
        [AllowNull()]
        [object]$Response
    )

    $data = Get-UipData -Response $Response
    if ($null -eq $data) {
        return @()
    }

    foreach ($name in @('Records', 'Items', 'Value')) {
        $items = Get-PropertyValue -InputObject $data -Names @($name)
        if ($null -ne $items) {
            return @($items)
        }
    }

    if ($data -is [System.Collections.IEnumerable] -and $data -isnot [string]) {
        return @($data)
    }

    return @($data)
}

# Gets the canonical object ID from entity, record, or response payloads.
function Get-DataFabricObjectId {
    param(
        [AllowNull()]
        [object]$InputObject
    )

    return Get-PropertyValue -InputObject $InputObject -Names @('ID', 'Id', 'id')
}

# Gets the canonical entity name from entity metadata.
function Get-DataFabricEntityName {
    param(
        [AllowNull()]
        [object]$Entity
    )

    return Get-PropertyValue -InputObject $Entity -Names @('Name', 'EntityName', 'LogicalName')
}

# Gets the canonical field name from schema field metadata.
function Get-DataFabricFieldName {
    param(
        [AllowNull()]
        [object]$Field
    )

    return Get-PropertyValue -InputObject $Field -Names @('Name', 'FieldName', 'fieldName')
}

# Gets the canonical field type from schema field metadata.
function Get-DataFabricFieldType {
    param(
        [AllowNull()]
        [object]$Field
    )

    $type = Get-PropertyValue -InputObject $Field -Names @('Type', 'type', 'DataType', 'dataType')
    if ($null -eq $type) {
        return $null
    }
    return ([string]$type).ToUpperInvariant()
}

# Determines whether an entity is a user-created native Data Fabric entity.
function Test-DataFabricNativeEntity {
    param(
        [AllowNull()]
        [object]$Entity
    )

    $type = Get-PropertyValue -InputObject $Entity -Names @('Type')
    $source = Get-PropertyValue -InputObject $Entity -Names @('Source')

    if ($source -and $source -ne 'Native') {
        return $false
    }

    if ($type -and $type -ne 'Entity') {
        return $false
    }

    return $true
}

# Extracts field definitions from possible schema payload shapes.
function Get-DataFabricFields {
    param(
        [AllowNull()]
        [object]$Schema
    )

    $fields = Get-PropertyValue -InputObject $Schema -Names @('Fields', 'fields')
    if ($null -eq $fields) {
        return @()
    }
    return @($fields)
}

# Detects system or reserved fields that must not be created or inserted manually.
function Test-DataFabricSystemField {
    param(
        [AllowNull()]
        [object]$Field
    )

    $isSystem = Get-PropertyValue -InputObject $Field -Names @('System', 'IsSystem', 'system', 'isSystem')
    if ($isSystem -eq $true) {
        return $true
    }

    $name = Get-DataFabricFieldName -Field $Field
    if ($script:SystemFieldNames -contains $name) {
        return $true
    }

    return $false
}

# Detects Data Fabric FILE fields for separate attachment handling.
function Test-DataFabricFileField {
    param(
        [AllowNull()]
        [object]$Field
    )

    return (Get-DataFabricFieldType -Field $Field) -eq 'FILE'
}

# Detects relationship fields that must be populated after first-pass record insertion.
function Test-DataFabricRelationshipField {
    param(
        [AllowNull()]
        [object]$Field
    )

    return (Get-DataFabricFieldType -Field $Field) -eq 'RELATIONSHIP'
}

# Returns migratable field names matching a specific Data Fabric field type.
function Get-MigratableFieldNamesByType {
    param(
        [Parameter(Mandatory)]
        [object]$Schema,

        [Parameter(Mandatory)]
        [ValidateSet('FILE', 'RELATIONSHIP')]
        [string]$Type
    )

    $names = @()
    foreach ($field in (Get-DataFabricFields -Schema $Schema)) {
        if (Test-DataFabricSystemField -Field $field) {
            continue
        }
        if ((Get-DataFabricFieldType -Field $field) -eq $Type) {
            $names += (Get-DataFabricFieldName -Field $field)
        }
    }
    return $names
}

# Removes readonly system fields from a record before insert payload creation.
function Remove-DataFabricSystemFields {
    param(
        [Parameter(Mandatory)]
        [object]$Record
    )

    $result = [ordered]@{}
    $removed = @()

    foreach ($property in $Record.PSObject.Properties) {
        if ($script:SystemFieldNames -contains $property.Name) {
            $removed += $property.Name
            continue
        }
        $result[$property.Name] = ConvertTo-HashtableDeep -InputObject $property.Value
    }

    [pscustomobject]@{
        Data = [pscustomobject]$result
        RemovedFields = $removed
    }
}

# Builds a sanitized entity-create body from source schema while skipping unsupported fields.
function New-DataFabricEntityCreateBody {
    param(
        [Parameter(Mandatory)]
        [object]$Schema,

        [switch]$IncludeRelationshipFields
    )

    $body = [ordered]@{}
    $displayName = Get-PropertyValue -InputObject $Schema -Names @('DisplayName', 'displayName')
    $description = Get-PropertyValue -InputObject $Schema -Names @('Description', 'description')
    $isRbacEnabled = Get-PropertyValue -InputObject $Schema -Names @('IsRbacEnabled', 'isRbacEnabled')

    if ($displayName) {
        $body.displayName = $displayName
    }
    if ($null -ne $description) {
        $body.description = $description
    }
    if ($null -ne $isRbacEnabled) {
        $body.isRbacEnabled = $isRbacEnabled
    }

    $fields = @()
    $skippedFields = @()

    foreach ($field in (Get-DataFabricFields -Schema $Schema)) {
        $name = Get-DataFabricFieldName -Field $field
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        if (Test-DataFabricSystemField -Field $field) {
            $skippedFields += [pscustomobject]@{
                name = $name
                reason = 'system field'
            }
            continue
        }

        if ($script:ReservedFieldNames -contains $name) {
            $skippedFields += [pscustomobject]@{
                name = $name
                reason = 'reserved field name'
            }
            continue
        }

        if ((Test-DataFabricRelationshipField -Field $field) -and -not $IncludeRelationshipFields) {
            $skippedFields += [pscustomobject]@{
                name = $name
                reason = 'relationship field skipped by default'
            }
            continue
        }

        $fieldBody = [ordered]@{
            fieldName = $name
            type = (Get-DataFabricFieldType -Field $field)
        }

        foreach ($pair in @(
            @{ Source = @('DisplayName', 'displayName'); Target = 'displayName' },
            @{ Source = @('Description', 'description'); Target = 'description' },
            @{ Source = @('Required', 'IsRequired', 'isRequired'); Target = 'isRequired' },
            @{ Source = @('Unique', 'IsUnique', 'isUnique'); Target = 'isUnique' },
            @{ Source = @('DefaultValue', 'defaultValue'); Target = 'defaultValue' },
            @{ Source = @('MaxLength', 'maxLength'); Target = 'maxLength' },
            @{ Source = @('Precision', 'precision'); Target = 'precision' },
            @{ Source = @('Scale', 'scale'); Target = 'scale' },
            @{ Source = @('Options', 'options', 'Choices', 'choices'); Target = 'options' },
            @{ Source = @('TargetEntityId', 'targetEntityId'); Target = 'targetEntityId' },
            @{ Source = @('TargetEntityName', 'targetEntityName'); Target = 'targetEntityName' }
        )) {
            $value = Get-PropertyValue -InputObject $field -Names $pair.Source
            if ($null -ne $value) {
                $fieldBody[$pair.Target] = ConvertTo-HashtableDeep -InputObject $value
            }
        }

        $fields += [pscustomobject]$fieldBody
    }

    $body.fields = $fields

    [pscustomobject]@{
        Body = [pscustomobject]$body
        SkippedFields = $skippedFields
    }
}

# Converts a source record into export metadata: insert data, file fields, relationships, and ID mapping.
function ConvertTo-DataFabricExportRecord {
    param(
        [Parameter(Mandatory)]
        [object]$Record,

        [Parameter(Mandatory)]
        [object]$Schema
    )

    $sourceRecordId = Get-DataFabricObjectId -InputObject $Record
    $systemClean = Remove-DataFabricSystemFields -Record $Record
    $fileFields = Get-MigratableFieldNamesByType -Schema $Schema -Type FILE
    $relationshipFields = Get-MigratableFieldNamesByType -Schema $Schema -Type RELATIONSHIP

    $data = [ordered]@{}
    $files = [ordered]@{}
    $relationships = [ordered]@{}

    foreach ($property in $systemClean.Data.PSObject.Properties) {
        if ($fileFields -contains $property.Name) {
            if ($null -ne $property.Value) {
                $files[$property.Name] = ConvertTo-HashtableDeep -InputObject $property.Value
            }
            continue
        }

        if ($relationshipFields -contains $property.Name) {
            if ($null -ne $property.Value) {
                $relationships[$property.Name] = ConvertTo-HashtableDeep -InputObject $property.Value
            }
            continue
        }

        $data[$property.Name] = ConvertTo-HashtableDeep -InputObject $property.Value
    }

    [pscustomobject]@{
        sourceRecordId = $sourceRecordId
        data = [pscustomobject]$data
        fileFields = [pscustomobject]$files
        relationships = [pscustomobject]$relationships
        removedSystemFields = $systemClean.RemovedFields
    }
}

# Converts an exported record back into a destination insert payload.
function ConvertTo-DataFabricImportRecord {
    param(
        [Parameter(Mandatory)]
        [object]$ExportRecord
    )

    if (Test-PropertyExists -InputObject $ExportRecord -Name 'data') {
        return ConvertTo-HashtableDeep -InputObject (Get-PropertyValue -InputObject $ExportRecord -Names @('data'))
    }

    return (Remove-DataFabricSystemFields -Record $ExportRecord).Data
}

# Extracts destination record IDs from insert responses for source-to-destination mapping.
function Get-DataFabricInsertedRecordIds {
    param(
        [AllowNull()]
        [object]$InsertResponse
    )

    $data = Get-UipData -Response $InsertResponse
    if ($null -eq $data) {
        return @()
    }

    $records = @()
    if ($data -is [System.Collections.IEnumerable] -and $data -isnot [string]) {
        $records = @($data)
    }
    else {
        foreach ($name in @('Records', 'records', 'Items', 'items', 'Value', 'value', 'Values', 'values', 'Ids', 'ids', 'ID', 'RecordIds', 'recordIds', 'InsertedIds', 'insertedIds')) {
            $items = Get-PropertyValue -InputObject $data -Names @($name)
            if ($null -ne $items) {
                $records = @($items)
                break
            }
        }
        if ($records.Count -eq 0) {
            $records = @($data)
        }
    }

    $ids = @()
    foreach ($record in $records) {
        $id = if ($record -is [string]) {
            [string]$record
        }
        else {
            Get-DataFabricObjectId -InputObject $record
        }
        if ($id) {
            $ids += $id
        }
    }
    return $ids
}

# Resolves the source record ID represented by a relationship value.
function Resolve-DataFabricRelationshipSourceId {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        return $Value
    }

    return Get-DataFabricObjectId -InputObject $Value
}

# Converts source relationship values to destination IDs using the record ID map.
function ConvertTo-DataFabricMappedRelationshipValue {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [hashtable]$RecordIdMap
    )

    if ($null -eq $Value) {
        return [pscustomobject]@{
            Mapped = $true
            Value = $null
            MissingSourceIds = @()
        }
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [pscustomobject]) {
        $mappedItems = @()
        $missing = @()
        foreach ($item in $Value) {
            $mapped = ConvertTo-DataFabricMappedRelationshipValue -Value $item -RecordIdMap $RecordIdMap
            if (-not $mapped.Mapped) {
                $missing += $mapped.MissingSourceIds
                continue
            }
            $mappedItems += $mapped.Value
        }
        return [pscustomobject]@{
            Mapped = $missing.Count -eq 0
            Value = $mappedItems
            MissingSourceIds = $missing
        }
    }

    $sourceId = Resolve-DataFabricRelationshipSourceId -Value $Value
    if ([string]::IsNullOrWhiteSpace($sourceId) -or -not $RecordIdMap.ContainsKey($sourceId)) {
        return [pscustomobject]@{
            Mapped = $false
            Value = $null
            MissingSourceIds = @($sourceId)
        }
    }

    $destinationId = $RecordIdMap[$sourceId]
    if ($Value -is [string]) {
        return [pscustomobject]@{
            Mapped = $true
            Value = $destinationId
            MissingSourceIds = @()
        }
    }

    $clone = ConvertTo-HashtableDeep -InputObject $Value
    if ($clone -is [System.Collections.IDictionary]) {
        foreach ($name in @('ID', 'Id', 'id')) {
            if ($clone.Contains($name)) {
                $clone[$name] = $destinationId
                break
            }
        }
    }

    return [pscustomobject]@{
        Mapped = $true
        Value = $clone
        MissingSourceIds = @()
    }
}

# Makes entity and record names safe for use as folder/file names inside the package.
function ConvertTo-SafeFileName {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $safe = $Name
    foreach ($char in $invalid) {
        $safe = $safe.Replace([string]$char, '_')
    }
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return 'unnamed'
    }
    return $safe
}

# Derives a usable attachment file name from Data Fabric file metadata.
function Get-AttachmentFileName {
    param(
        [AllowNull()]
        [object]$FieldValue,

        [Parameter(Mandatory)]
        [string]$DefaultName
    )

    foreach ($name in @('FileName', 'fileName', 'Name', 'name', 'DisplayName', 'displayName')) {
        $value = Get-PropertyValue -InputObject $FieldValue -Names @($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return ConvertTo-SafeFileName -Name ([string]$value)
        }
    }

    if ($FieldValue -is [string] -and -not [string]::IsNullOrWhiteSpace($FieldValue)) {
        return ConvertTo-SafeFileName -Name $FieldValue
    }

    return ConvertTo-SafeFileName -Name $DefaultName
}

# Infers a practical file extension from binary signatures when Data Fabric only exposes a file token.
function Get-FileExtensionFromContent {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    $stream = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        $buffer = New-Object byte[] 16
        $read = $stream.Read($buffer, 0, $buffer.Length)
    }
    finally {
        $stream.Dispose()
    }

    if ($read -ge 8 -and $buffer[0] -eq 0x89 -and $buffer[1] -eq 0x50 -and $buffer[2] -eq 0x4E -and $buffer[3] -eq 0x47 -and $buffer[4] -eq 0x0D -and $buffer[5] -eq 0x0A -and $buffer[6] -eq 0x1A -and $buffer[7] -eq 0x0A) {
        return '.png'
    }
    if ($read -ge 3 -and $buffer[0] -eq 0xFF -and $buffer[1] -eq 0xD8 -and $buffer[2] -eq 0xFF) {
        return '.jpg'
    }
    if ($read -ge 6) {
        $signature6 = [System.Text.Encoding]::ASCII.GetString($buffer, 0, 6)
        if ($signature6 -eq 'GIF87a' -or $signature6 -eq 'GIF89a') {
            return '.gif'
        }
    }
    if ($read -ge 4) {
        $signature4 = [System.Text.Encoding]::ASCII.GetString($buffer, 0, 4)
        if ($signature4 -eq '%PDF') {
            return '.pdf'
        }
        if ($signature4 -eq 'PK' + [char]0x03 + [char]0x04) {
            return '.zip'
        }
    }
    if ($read -ge 2 -and $buffer[0] -eq 0x42 -and $buffer[1] -eq 0x4D) {
        return '.bmp'
    }
    if ($read -ge 12) {
        $riff = [System.Text.Encoding]::ASCII.GetString($buffer, 0, 4)
        $webp = [System.Text.Encoding]::ASCII.GetString($buffer, 8, 4)
        if ($riff -eq 'RIFF' -and $webp -eq 'WEBP') {
            return '.webp'
        }
    }

    return ''
}

# Adds an inferred extension to an extensionless downloaded attachment and returns the final path.
function Add-InferredFileExtension {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $Path
    }

    if (-not [string]::IsNullOrWhiteSpace([System.IO.Path]::GetExtension($Path))) {
        return $Path
    }

    $extension = Get-FileExtensionFromContent -Path $Path
    if ([string]::IsNullOrWhiteSpace($extension)) {
        return $Path
    }

    $targetPath = "$Path$extension"
    $counter = 1
    while (Test-Path -LiteralPath $targetPath) {
        $targetPath = "{0}-{1}{2}" -f $Path, $counter, $extension
        $counter++
    }

    Move-Item -LiteralPath $Path -Destination $targetPath
    return $targetPath
}

# Converts an absolute path into a package-relative path.
function Get-RelativePath {
    param(
        [Parameter(Mandatory)]
        [string]$BasePath,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $baseUri = [System.Uri]::new((Resolve-Path -LiteralPath $BasePath).Path.TrimEnd('\') + '\')
    $pathUri = [System.Uri]::new((Resolve-Path -LiteralPath $Path).Path)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString()).Replace('/', '\')
}

# Creates SHA-256 checksums for every packaged file so imports can validate integrity.
function New-DataFabricPackageChecksums {
    param(
        [Parameter(Mandatory)]
        [string]$PackageDirectory
    )

    $checksums = [ordered]@{}
    $files = Get-ChildItem -LiteralPath $PackageDirectory -Recurse -File |
        Where-Object { $_.Name -ne 'checksums.json' } |
        Sort-Object FullName

    foreach ($file in $files) {
        $relativePath = Get-RelativePath -BasePath $PackageDirectory -Path $file.FullName
        $checksums[$relativePath] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }

    $checksumPath = Join-Path $PackageDirectory 'checksums.json'
    ConvertTo-JsonFile -InputObject ([pscustomobject]$checksums) -Path $checksumPath
    return [pscustomobject]$checksums
}

# Validates package checksums before import to detect missing or modified files.
function Test-DataFabricPackageChecksums {
    param(
        [Parameter(Mandatory)]
        [string]$PackageDirectory
    )

    $checksumPath = Join-Path $PackageDirectory 'checksums.json'
    if (-not (Test-Path -LiteralPath $checksumPath)) {
        throw "Package checksum file is missing: $checksumPath"
    }

    $checksums = Import-JsonFile -Path $checksumPath
    $failures = @()

    foreach ($property in $checksums.PSObject.Properties) {
        $path = Join-Path $PackageDirectory $property.Name
        if (-not (Test-Path -LiteralPath $path)) {
            $failures += [pscustomobject]@{
                path = $property.Name
                reason = 'missing'
            }
            continue
        }

        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actual -ne $property.Value) {
            $failures += [pscustomobject]@{
                path = $property.Name
                reason = 'hash mismatch'
            }
        }
    }

    [pscustomobject]@{
        IsValid = $failures.Count -eq 0
        Failures = $failures
    }
}

# Expands a ZIP package into a working directory or reuses an already-expanded package folder.
function Expand-DataFabricPackage {
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [string]$DestinationRoot
    )

    if (-not (Test-Path -LiteralPath $PackagePath)) {
        throw "Package path was not found: $PackagePath"
    }

    if (-not (Test-Path -LiteralPath $DestinationRoot)) {
        New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
    }

    $resolvedPackage = (Resolve-Path -LiteralPath $PackagePath).Path
    if ((Get-Item -LiteralPath $resolvedPackage).PSIsContainer) {
        return $resolvedPackage
    }

    $extractDirectory = Join-Path $DestinationRoot ([System.IO.Path]::GetFileNameWithoutExtension($resolvedPackage))
    if (Test-Path -LiteralPath $extractDirectory) {
        $extractDirectory = Join-Path $DestinationRoot ("{0}_{1}" -f ([System.IO.Path]::GetFileNameWithoutExtension($resolvedPackage)), (Get-Date -Format 'yyyyMMddHHmmss'))
    }
    New-Item -ItemType Directory -Path $extractDirectory -Force | Out-Null
    Expand-Archive -LiteralPath $resolvedPackage -DestinationPath $extractDirectory -Force
    return $extractDirectory
}

# Loads the package manifest that drives import behavior.
function Get-DataFabricManifest {
    param(
        [Parameter(Mandatory)]
        [string]$PackageDirectory
    )

    $manifestPath = Join-Path $PackageDirectory 'manifest.json'
    return Import-JsonFile -Path $manifestPath
}

# Exports selected native entities, records, relationships, and optional files into a ZIP package.
function Export-DataFabricPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [string]$Tenant,

        [string]$Organization,

        [string]$ClientId,

        [string]$ClientSecret,

        [string[]]$EntityName,

        [int]$PageSize = 100,

        [string]$WorkingDirectory,

        [switch]$IncludeFiles,

        [scriptblock]$Invoker,

        [scriptblock]$ProgressCallback
    )

    if ($PageSize -lt 1) {
        throw 'PageSize must be at least 1.'
    }

    $resolvedPackagePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PackagePath)
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $parent = Split-Path -Parent $resolvedPackagePath
        if ([string]::IsNullOrWhiteSpace($parent)) {
            $parent = (Get-Location).Path
        }
        $WorkingDirectory = Join-Path $parent ([System.IO.Path]::GetFileNameWithoutExtension($resolvedPackagePath))
    }

    if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
        New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null
    }

    # Export phase 1: authenticate and discover native entity candidates from the source tenant.
    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Export' -Stage 'Start' -Message 'Starting export.' -Detail "PackagePath=$resolvedPackagePath; WorkingDirectory=$WorkingDirectory; PageSize=$PageSize; IncludeFiles=$IncludeFiles" -Data @{
        packagePath = $resolvedPackagePath
        workingDirectory = $WorkingDirectory
        pageSize = $PageSize
        includeFiles = [bool]$IncludeFiles
        selectedEntities = @($EntityName)
    }

    $login = Invoke-DataFabricLogin -Tenant $Tenant -Organization $Organization -ClientId $ClientId -ClientSecret $ClientSecret -Invoker $Invoker
    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Export' -Stage 'Authentication' -Message 'Authentication ready for source tenant.' -Detail "Tenant=$Tenant; Organization=$Organization"

    $entitiesArgs = Add-TenantArgument -Arguments @('df', 'entities', 'list', '--native-only', '--output', 'json') -Tenant $Tenant
    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Export' -Stage 'Discovery' -Message 'Listing native entity candidates.'
    $entityResponse = Invoke-DataFabricCli -Arguments $entitiesArgs -Invoker $Invoker
    $entities = @(Get-DataFabricEntityList -Response $entityResponse)
    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Export' -Stage 'Discovery' -Message "Discovered $($entities.Count) native entity candidate(s)." -Data @{
        entityCount = $entities.Count
    }

    $manifest = [ordered]@{
        formatVersion = '1.0'
        exportedUtc = (Get-Date).ToUniversalTime().ToString('o')
        source = ConvertTo-HashtableDeep -InputObject (Get-UipData -Response $login)
        tenant = $Tenant
        entities = @()
        skippedEntities = @()
        attachments = @()
        errors = @()
    }

    $entityIndex = 0
    foreach ($entity in $entities) {
        $entityIndex++
        $name = Get-DataFabricEntityName -Entity $entity
        $entityId = Get-DataFabricObjectId -InputObject $entity

        if ($EntityName -and ($EntityName -notcontains $name)) {
            Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Export' -Stage 'Skip' -Message "Skipping entity $entityIndex/$($entities.Count): $name (not selected)." -Data @{
                entity = $name
                entityId = $entityId
                reason = 'not selected'
            }
            $manifest.skippedEntities += [pscustomobject]@{
                name = $name
                id = $entityId
                reason = 'not selected'
            }
            continue
        }

        if (-not (Test-DataFabricNativeEntity -Entity $entity)) {
            Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Export' -Stage 'Skip' -Message "Skipping entity $entityIndex/$($entities.Count): $name (non-user or non-native entity)." -Data @{
                entity = $name
                entityId = $entityId
                reason = 'non-user or non-native entity'
            }
            $manifest.skippedEntities += [pscustomobject]@{
                name = $name
                id = $entityId
                reason = 'non-user or non-native entity'
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($entityId)) {
            Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Export' -Stage 'Skip' -Level 'Warn' -Message "Skipping entity $entityIndex/$($entities.Count): $name (missing entity ID)." -Data @{
                entity = $name
                reason = 'missing entity ID'
            }
            $manifest.skippedEntities += [pscustomobject]@{
                name = $name
                id = $null
                reason = 'missing entity ID'
            }
            continue
        }

        $safeName = ConvertTo-SafeFileName -Name $name
        $entityDirectory = Join-Path (Join-Path $WorkingDirectory 'entities') $safeName
        New-Item -ItemType Directory -Path $entityDirectory -Force | Out-Null

        try {
            # Export phase 2: capture schema/create-body metadata and page through all records for this entity.
            Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Export' -Stage 'Entity' -Message "Exporting entity $entityIndex/$($entities.Count): $name" -Data @{
                entity = $name
                entityId = $entityId
            }
            $schemaArgs = Add-TenantArgument -Arguments @('df', 'entities', 'get', $entityId, '--output', 'json') -Tenant $Tenant
            $schemaResponse = Invoke-DataFabricCli -Arguments $schemaArgs -Invoker $Invoker
            $schema = Get-UipData -Response $schemaResponse
            $schemaPath = Join-Path $entityDirectory 'schema.json'
            ConvertTo-JsonFile -InputObject $schema -Path $schemaPath

            $createBodyResult = New-DataFabricEntityCreateBody -Schema $schema
            $createBodyPath = Join-Path $entityDirectory 'create-body.json'
            ConvertTo-JsonFile -InputObject $createBodyResult.Body -Path $createBodyPath

            $records = @()
            $cursor = $null
            $hasNextPage = $true
            $pageNumber = 0
            do {
                $pageNumber++
                $recordArgs = @('df', 'records', 'list', $entityId, '--limit', ([string]$PageSize), '--output', 'json')
                if ($cursor) {
                    $recordArgs += @('--cursor', $cursor)
                }
                $recordArgs = Add-TenantArgument -Arguments $recordArgs -Tenant $Tenant

                $recordResponse = Invoke-DataFabricCli -Arguments $recordArgs -Invoker $Invoker
                $pageRecords = @(Get-DataFabricRecordList -Response $recordResponse)
                Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Export' -Stage 'Records' -Message "Read $($pageRecords.Count) record(s) from $name (page $pageNumber)." -Data @{
                    entity = $name
                    entityId = $entityId
                    page = $pageNumber
                    recordCount = $pageRecords.Count
                }
                foreach ($record in $pageRecords) {
                    $exportRecord = ConvertTo-DataFabricExportRecord -Record $record -Schema $schema
                    $records += $exportRecord

                    if ($IncludeFiles) {
                        # File fields are exported separately because record insert payloads cannot carry file binaries.
                        foreach ($fileProperty in $exportRecord.fileFields.PSObject.Properties) {
                            if ([string]::IsNullOrWhiteSpace($exportRecord.sourceRecordId)) {
                                $manifest.errors += [pscustomobject]@{
                                    entity = $name
                                    recordId = $null
                                    field = $fileProperty.Name
                                    message = 'Cannot download file attachment because source record ID is missing.'
                                }
                                continue
                            }

                            $attachmentName = Get-AttachmentFileName -FieldValue $fileProperty.Value -DefaultName "$($fileProperty.Name).bin"
                            $attachmentRelativeDirectory = Join-Path (Join-Path 'files' $safeName) $exportRecord.sourceRecordId
                            $attachmentDirectory = Join-Path $WorkingDirectory $attachmentRelativeDirectory
                            New-Item -ItemType Directory -Path $attachmentDirectory -Force | Out-Null
                            $attachmentRelativePath = Join-Path $attachmentRelativeDirectory ("{0}_{1}" -f $fileProperty.Name, $attachmentName)
                            $attachmentPath = Join-Path $WorkingDirectory $attachmentRelativePath

                            try {
                                $fileArgs = Add-TenantArgument -Arguments @('df', 'files', 'download', $entityId, $exportRecord.sourceRecordId, $fileProperty.Name, '--destination', $attachmentPath, '--output', 'json') -Tenant $Tenant
                                [void](Invoke-DataFabricCli -Arguments $fileArgs -Invoker $Invoker)
                                $attachmentPath = Add-InferredFileExtension -Path $attachmentPath
                                $attachmentRelativePath = Get-RelativePath -BasePath $WorkingDirectory -Path $attachmentPath
                                Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Export' -Stage 'Files' -Message "Downloaded attachment for $name/$($exportRecord.sourceRecordId): $($fileProperty.Name)" -Data @{
                                    entity = $name
                                    recordId = $exportRecord.sourceRecordId
                                    field = $fileProperty.Name
                                    path = $attachmentRelativePath
                                }
                                $manifest.attachments += [pscustomobject]@{
                                    entityName = $name
                                    sourceEntityId = $entityId
                                    sourceRecordId = $exportRecord.sourceRecordId
                                    fieldName = $fileProperty.Name
                                    path = $attachmentRelativePath
                                    sha256 = (Get-FileHash -LiteralPath $attachmentPath -Algorithm SHA256).Hash
                                    bytes = (Get-Item -LiteralPath $attachmentPath).Length
                                }
                            }
                            catch {
                                Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Export' -Stage 'Files' -Level 'Warn' -Message "Could not download attachment for $name/$($exportRecord.sourceRecordId): $($fileProperty.Name)" -Detail $_.Exception.Message -Data @{
                                    entity = $name
                                    recordId = $exportRecord.sourceRecordId
                                    field = $fileProperty.Name
                                }
                                $manifest.errors += [pscustomobject]@{
                                    entity = $name
                                    recordId = $exportRecord.sourceRecordId
                                    field = $fileProperty.Name
                                    message = $_.Exception.Message
                                }
                            }
                        }
                    }
                }

                $recordData = Get-UipData -Response $recordResponse
                $hasNextPageValue = Get-PropertyValue -InputObject $recordData -Names @('HasNextPage', 'hasNextPage')
                $hasNextPage = $hasNextPageValue -eq $true
                $cursor = Get-PropertyValue -InputObject $recordData -Names @('NextCursor', 'nextCursor')
            }
            while ($hasNextPage -and -not [string]::IsNullOrWhiteSpace($cursor))

            $recordsPath = Join-Path $entityDirectory 'records.json'
            ConvertTo-JsonFile -InputObject $records -Path $recordsPath
            Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Export' -Stage 'Entity' -Message "Exported $($records.Count) record(s) from $name." -Data @{
                entity = $name
                entityId = $entityId
                recordCount = $records.Count
            }

            $manifest.entities += [pscustomobject]@{
                name = $name
                displayName = Get-PropertyValue -InputObject $schema -Names @('DisplayName', 'displayName')
                sourceEntityId = $entityId
                type = Get-PropertyValue -InputObject $entity -Names @('Type')
                source = Get-PropertyValue -InputObject $entity -Names @('Source')
                schemaPath = Get-RelativePath -BasePath $WorkingDirectory -Path $schemaPath
                createBodyPath = Get-RelativePath -BasePath $WorkingDirectory -Path $createBodyPath
                recordsPath = Get-RelativePath -BasePath $WorkingDirectory -Path $recordsPath
                recordCount = $records.Count
                fileFields = Get-MigratableFieldNamesByType -Schema $schema -Type FILE
                relationshipFields = Get-MigratableFieldNamesByType -Schema $schema -Type RELATIONSHIP
                skippedFields = $createBodyResult.SkippedFields
            }
        }
        catch {
            Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Export' -Stage 'Entity' -Level 'Error' -Message "Export failed for entity $name." -Detail $_.Exception.Message -Data @{
                entity = $name
                entityId = $entityId
            }
            $manifest.errors += [pscustomobject]@{
                entity = $name
                id = $entityId
                message = $_.Exception.Message
            }
        }
    }

    $manifestPath = Join-Path $WorkingDirectory 'manifest.json'
    ConvertTo-JsonFile -InputObject ([pscustomobject]$manifest) -Path $manifestPath
    [void](New-DataFabricPackageChecksums -PackageDirectory $WorkingDirectory)

    # Export phase 3: finalize the working directory into a portable migration ZIP.
    $packageParent = Split-Path -Parent $resolvedPackagePath
    if ($packageParent -and -not (Test-Path -LiteralPath $packageParent)) {
        New-Item -ItemType Directory -Path $packageParent -Force | Out-Null
    }

    if (Test-Path -LiteralPath $resolvedPackagePath) {
        Remove-Item -LiteralPath $resolvedPackagePath -Force
    }
    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Export' -Stage 'Package' -Message 'Creating migration ZIP package.' -Detail "PackagePath=$resolvedPackagePath"
    Compress-Archive -Path (Join-Path $WorkingDirectory '*') -DestinationPath $resolvedPackagePath -Force
    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Export' -Stage 'Complete' -Message "Export complete. Entities: $(@($manifest.entities).Count); skipped: $(@($manifest.skippedEntities).Count); errors: $(@($manifest.errors).Count)." -Data @{
        entityCount = @($manifest.entities).Count
        skippedEntityCount = @($manifest.skippedEntities).Count
        errorCount = @($manifest.errors).Count
        packagePath = $resolvedPackagePath
    }

    [pscustomobject]@{
        packagePath = $resolvedPackagePath
        workingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
        entityCount = @($manifest.entities).Count
        skippedEntityCount = @($manifest.skippedEntities).Count
        errorCount = @($manifest.errors).Count
    }
}

# Imports a package into the destination tenant, creating missing entities and replaying records.
function Import-DataFabricPackage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [string]$Tenant,

        [string]$Organization,

        [string]$ClientId,

        [string]$ClientSecret,

        [string]$WorkingDirectory,

        [int]$BatchSize = 50,

        [switch]$IncludeFiles,

        [switch]$ImportRelationships,

        [scriptblock]$Invoker,

        [scriptblock]$ProgressCallback
    )

    if ($BatchSize -lt 1) {
        throw 'BatchSize must be at least 1.'
    }

    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $WorkingDirectory = Join-Path (Get-Location).Path 'import-work'
    }

    # Import phase 1: expand and validate the package before any destination writes are attempted.
    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Start' -Message 'Starting import.' -Detail "PackagePath=$PackagePath; WorkingDirectory=$WorkingDirectory; BatchSize=$BatchSize; IncludeFiles=$IncludeFiles; ImportRelationships=$ImportRelationships" -Data @{
        packagePath = $PackagePath
        workingDirectory = $WorkingDirectory
        batchSize = $BatchSize
        includeFiles = [bool]$IncludeFiles
        importRelationships = [bool]$ImportRelationships
    }

    $packageDirectory = Expand-DataFabricPackage -PackagePath $PackagePath -DestinationRoot $WorkingDirectory
    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Package' -Message 'Package expanded for import.' -Detail "PackageDirectory=$packageDirectory"
    $checksumResult = Test-DataFabricPackageChecksums -PackageDirectory $packageDirectory
    if (-not $checksumResult.IsValid) {
        throw "Package checksum validation failed: $($checksumResult.Failures | ConvertTo-Json -Depth 10)"
    }
    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Package' -Message 'Package checksum validation passed.'

    $manifest = Get-DataFabricManifest -PackageDirectory $packageDirectory
    [void](Invoke-DataFabricLogin -Tenant $Tenant -Organization $Organization -ClientId $ClientId -ClientSecret $ClientSecret -Invoker $Invoker)
    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Authentication' -Message 'Authentication ready for destination tenant.' -Detail "Tenant=$Tenant; Organization=$Organization"

    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Discovery' -Message 'Listing destination native entities.'
    $destinationEntitiesResponse = Invoke-DataFabricCli -Arguments (Add-TenantArgument -Arguments @('df', 'entities', 'list', '--native-only', '--output', 'json') -Tenant $Tenant) -Invoker $Invoker
    $destinationEntities = @(Get-DataFabricEntityList -Response $destinationEntitiesResponse)
    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Discovery' -Message "Found $($destinationEntities.Count) destination native entity candidate(s)." -Data @{
        entityCount = $destinationEntities.Count
    }
    $destinationByName = @{}
    foreach ($entity in $destinationEntities) {
        $name = Get-DataFabricEntityName -Entity $entity
        if ($name) {
            $destinationByName[$name] = $entity
        }
    }

    $report = [ordered]@{
        importedUtc = (Get-Date).ToUniversalTime().ToString('o')
        packagePath = $PackagePath
        tenant = $Tenant
        createdEntities = @()
        reusedEntities = @()
        insertedRecords = @()
        uploadedFiles = @()
        relationshipUpdates = @()
        skippedItems = @()
        failures = @()
        entityIdMap = [ordered]@{}
        recordIdMap = [ordered]@{}
    }

    $entityManifests = @($manifest.entities)
    $entityIndex = 0
    foreach ($entityManifest in $entityManifests) {
        $entityIndex++
        $entityName = $entityManifest.name
        $destinationEntity = $null

        try {
            # Import phase 2: create or reuse the destination entity, then insert exported records in batches.
            Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Entity' -Message "Importing entity $entityIndex/$($entityManifests.Count): $entityName" -Data @{
                entity = $entityName
                sourceEntityId = $entityManifest.sourceEntityId
            }
            if ($destinationByName.ContainsKey($entityName)) {
                $destinationEntity = $destinationByName[$entityName]
                $destinationEntityId = Get-DataFabricObjectId -InputObject $destinationEntity
                Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Entity' -Message "Reusing destination entity: $entityName" -Data @{
                    entity = $entityName
                    destinationEntityId = $destinationEntityId
                }
                $report.reusedEntities += [pscustomobject]@{
                    name = $entityName
                    sourceEntityId = $entityManifest.sourceEntityId
                    destinationEntityId = $destinationEntityId
                }
            }
            else {
                $createBodyPath = Join-Path $packageDirectory $entityManifest.createBodyPath
                $createArgs = Add-TenantArgument -Arguments @('df', 'entities', 'create', $entityName, '--file', $createBodyPath, '--output', 'json') -Tenant $Tenant
                if ($PSCmdlet.ShouldProcess($entityName, 'Create Data Fabric entity')) {
                    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Entity' -Message "Creating destination entity: $entityName" -Detail "CreateBodyPath=$createBodyPath"
                    $createResponse = Invoke-DataFabricCli -Arguments $createArgs -Invoker $Invoker
                    $destinationEntity = Get-UipData -Response $createResponse
                    $destinationEntityId = Get-DataFabricObjectId -InputObject $destinationEntity
                    $destinationByName[$entityName] = $destinationEntity
                    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Entity' -Message "Created destination entity: $entityName" -Data @{
                        entity = $entityName
                        destinationEntityId = $destinationEntityId
                    }
                    $report.createdEntities += [pscustomobject]@{
                        name = $entityName
                        sourceEntityId = $entityManifest.sourceEntityId
                        destinationEntityId = $destinationEntityId
                    }
                }
                else {
                    $report.skippedItems += [pscustomobject]@{
                        entity = $entityName
                        reason = 'WhatIf: entity create skipped'
                    }
                    continue
                }
            }

            $destinationEntityId = Get-DataFabricObjectId -InputObject $destinationEntity
            $report.entityIdMap[$entityManifest.sourceEntityId] = $destinationEntityId

            $recordsPath = Join-Path $packageDirectory $entityManifest.recordsPath
            $records = @(Import-JsonFile -Path $recordsPath)
            if ($records.Count -eq 1 -and (Test-PropertyExists -InputObject $records[0] -Name 'sourceRecordId') -eq $false -and $records[0] -is [System.Collections.IEnumerable]) {
                $records = @($records[0])
            }

            $entityAttachments = @($manifest.attachments | Where-Object { $_.sourceEntityId -eq $entityManifest.sourceEntityId -or $_.entityName -eq $entityName })
            $requiresDestinationRecordIds = ($IncludeFiles -and $entityAttachments.Count -gt 0) -or ($ImportRelationships -and @($entityManifest.relationshipFields).Count -gt 0)
            $effectiveBatchSize = if ($requiresDestinationRecordIds) { 1 } else { $BatchSize }
            Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Records' -Message "Preparing to import $($records.Count) record(s) for $entityName." -Data @{
                entity = $entityName
                recordCount = $records.Count
                batchSize = $effectiveBatchSize
                requestedBatchSize = $BatchSize
                requiresDestinationRecordIds = [bool]$requiresDestinationRecordIds
            }
            if ($requiresDestinationRecordIds -and $BatchSize -ne 1) {
                Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Records' -Message "Using single-record inserts for $entityName so destination record IDs are available for attachments or relationships." -Data @{
                    entity = $entityName
                    attachmentCount = $entityAttachments.Count
                    relationshipFieldCount = @($entityManifest.relationshipFields).Count
                }
            }

            for ($index = 0; $index -lt $records.Count; $index += $effectiveBatchSize) {
                $batch = @($records[$index..([Math]::Min($index + $effectiveBatchSize - 1, $records.Count - 1))])
                $batchNumber = [Math]::Floor($index / $effectiveBatchSize) + 1
                $batchTotal = [Math]::Ceiling($records.Count / [double]$effectiveBatchSize)
                $payload = @()
                foreach ($record in $batch) {
                    $payload += [pscustomobject](ConvertTo-DataFabricImportRecord -ExportRecord $record)
                }

                $batchDirectory = Join-Path (Join-Path $packageDirectory 'import-batches') (ConvertTo-SafeFileName -Name $entityName)
                New-Item -ItemType Directory -Path $batchDirectory -Force | Out-Null
                $batchPath = Join-Path $batchDirectory ("batch-{0}.json" -f $index)
                ConvertTo-JsonFile -InputObject $payload -Path $batchPath

                $insertArgs = Add-TenantArgument -Arguments @('df', 'records', 'insert', $destinationEntityId, '--file', $batchPath, '--output', 'json') -Tenant $Tenant
                if ($PSCmdlet.ShouldProcess($entityName, "Insert $($batch.Count) record(s)")) {
                    try {
                        Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Records' -Message "Inserting batch $batchNumber/$batchTotal for $entityName ($($batch.Count) record(s))." -Detail "BatchPath=$batchPath" -Data @{
                            entity = $entityName
                            batchNumber = $batchNumber
                            batchTotal = $batchTotal
                            recordCount = $batch.Count
                        }
                        $insertResponse = Invoke-DataFabricCli -Arguments $insertArgs -Invoker $Invoker
                        $insertedIds = @(Get-DataFabricInsertedRecordIds -InsertResponse $insertResponse)
                        for ($recordIndex = 0; $recordIndex -lt $batch.Count; $recordIndex++) {
                            $sourceRecordId = $batch[$recordIndex].sourceRecordId
                            $destinationRecordId = if ($recordIndex -lt $insertedIds.Count) { $insertedIds[$recordIndex] } else { $null }
                            if ($sourceRecordId -and $destinationRecordId) {
                                $report.recordIdMap[$sourceRecordId] = $destinationRecordId
                            }
                            $report.insertedRecords += [pscustomobject]@{
                                entity = $entityName
                                sourceRecordId = $sourceRecordId
                                destinationRecordId = $destinationRecordId
                            }
                        }
                        Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Records' -Message "Inserted batch $batchNumber/$batchTotal for $entityName." -Data @{
                            entity = $entityName
                            batchNumber = $batchNumber
                            batchTotal = $batchTotal
                            insertedIdCount = $insertedIds.Count
                        }
                    }
                    catch {
                        Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Records' -Level 'Error' -Message "Failed to insert batch $batchNumber/$batchTotal for $entityName." -Detail $_.Exception.Message -Data @{
                            entity = $entityName
                            batchNumber = $batchNumber
                            batchTotal = $batchTotal
                            recordCount = $batch.Count
                        }
                        $report.failures += [pscustomobject]@{
                            entity = $entityName
                            operation = 'insert records'
                            batchStart = $index
                            message = $_.Exception.Message
                        }
                    }
                }
            }

            if ($ImportRelationships) {
                # Relationship fields require destination record IDs, so they are updated after first-pass inserts.
                Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Relationships' -Message "Updating relationship fields for $entityName."
                foreach ($record in $records) {
                    $relationships = Get-PropertyValue -InputObject $record -Names @('relationships')
                    if ($null -eq $relationships) {
                        continue
                    }

                    $destinationRecordId = $report.recordIdMap[$record.sourceRecordId]
                    if ([string]::IsNullOrWhiteSpace($destinationRecordId)) {
                        $report.skippedItems += [pscustomobject]@{
                            entity = $entityName
                            sourceRecordId = $record.sourceRecordId
                            reason = 'relationship update skipped because destination record ID is missing'
                        }
                        continue
                    }

                    $update = [ordered]@{ Id = $destinationRecordId }
                    $missing = @()
                    foreach ($relationshipProperty in $relationships.PSObject.Properties) {
                        $mapped = ConvertTo-DataFabricMappedRelationshipValue -Value $relationshipProperty.Value -RecordIdMap $report.recordIdMap
                        if (-not $mapped.Mapped) {
                            $missing += $mapped.MissingSourceIds
                            continue
                        }
                        $update[$relationshipProperty.Name] = $mapped.Value
                    }

                    if ($missing.Count -gt 0) {
                        $report.skippedItems += [pscustomobject]@{
                            entity = $entityName
                            sourceRecordId = $record.sourceRecordId
                            reason = 'unresolved relationship source record IDs'
                            missingSourceIds = $missing
                        }
                        continue
                    }

                    if ($update.Keys.Count -le 1) {
                        continue
                    }

                    $relationshipDirectory = Join-Path (Join-Path $packageDirectory 'relationship-updates') (ConvertTo-SafeFileName -Name $entityName)
                    New-Item -ItemType Directory -Path $relationshipDirectory -Force | Out-Null
                    $relationshipPath = Join-Path $relationshipDirectory ("$($record.sourceRecordId).json")
                    ConvertTo-JsonFile -InputObject ([pscustomobject]$update) -Path $relationshipPath

                    $updateArgs = Add-TenantArgument -Arguments @('df', 'records', 'update', $destinationEntityId, '--file', $relationshipPath, '--output', 'json') -Tenant $Tenant
                    if ($PSCmdlet.ShouldProcess($entityName, "Update relationships for record $destinationRecordId")) {
                        try {
                            [void](Invoke-DataFabricCli -Arguments $updateArgs -Invoker $Invoker)
                            Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Relationships' -Message "Updated relationships for $entityName/$destinationRecordId." -Data @{
                                entity = $entityName
                                sourceRecordId = $record.sourceRecordId
                                destinationRecordId = $destinationRecordId
                            }
                            $report.relationshipUpdates += [pscustomobject]@{
                                entity = $entityName
                                sourceRecordId = $record.sourceRecordId
                                destinationRecordId = $destinationRecordId
                            }
                        }
                        catch {
                            Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Relationships' -Level 'Error' -Message "Failed to update relationships for $entityName/$destinationRecordId." -Detail $_.Exception.Message -Data @{
                                entity = $entityName
                                sourceRecordId = $record.sourceRecordId
                                destinationRecordId = $destinationRecordId
                            }
                            $report.failures += [pscustomobject]@{
                                entity = $entityName
                                sourceRecordId = $record.sourceRecordId
                                operation = 'update relationships'
                                message = $_.Exception.Message
                            }
                        }
                    }
                }
            }
            elseif (@($entityManifest.relationshipFields).Count -gt 0) {
                Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Relationships' -Level 'Warn' -Message "Skipping relationship fields for $entityName because -ImportRelationships was not specified." -Data @{
                    entity = $entityName
                    fields = @($entityManifest.relationshipFields)
                }
                $report.skippedItems += [pscustomobject]@{
                    entity = $entityName
                    reason = 'relationship fields were skipped; rerun with -ImportRelationships after confirming destination relationship schema'
                    fields = @($entityManifest.relationshipFields)
                }
            }
        }
        catch {
            Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Entity' -Level 'Error' -Message "Import failed for entity $entityName." -Detail $_.Exception.Message -Data @{
                entity = $entityName
            }
            $report.failures += [pscustomobject]@{
                entity = $entityName
                operation = 'entity import'
                message = $_.Exception.Message
            }
        }
    }

    if ($IncludeFiles) {
        # Import phase 3: upload exported file attachments after records exist in the destination.
        Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Files' -Message "Uploading $(@($manifest.attachments).Count) exported file attachment(s)."
        foreach ($attachment in @($manifest.attachments)) {
            $destinationEntityId = $report.entityIdMap[$attachment.sourceEntityId]
            $destinationRecordId = $report.recordIdMap[$attachment.sourceRecordId]
            $filePath = Join-Path $packageDirectory $attachment.path
            $uploadRelativePath = $attachment.path
            if (Test-Path -LiteralPath $filePath) {
                $filePath = Add-InferredFileExtension -Path $filePath
                $uploadRelativePath = Get-RelativePath -BasePath $packageDirectory -Path $filePath
            }

            if ([string]::IsNullOrWhiteSpace($destinationEntityId) -or [string]::IsNullOrWhiteSpace($destinationRecordId) -or -not (Test-Path -LiteralPath $filePath)) {
                $report.skippedItems += [pscustomobject]@{
                    entity = $attachment.entityName
                    sourceRecordId = $attachment.sourceRecordId
                    field = $attachment.fieldName
                    reason = 'file upload skipped because entity, record, or file mapping is missing'
                }
                continue
            }

            $uploadArgs = Add-TenantArgument -Arguments @('df', 'files', 'upload', $destinationEntityId, $destinationRecordId, $attachment.fieldName, '--file', $filePath, '--output', 'json') -Tenant $Tenant
            if ($PSCmdlet.ShouldProcess($attachment.entityName, "Upload file for $($attachment.fieldName)")) {
                try {
                    [void](Invoke-DataFabricCli -Arguments $uploadArgs -Invoker $Invoker)
                    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Files' -Message "Uploaded attachment for $($attachment.entityName)/$($destinationRecordId): $($attachment.fieldName)" -Data @{
                        entity = $attachment.entityName
                        sourceRecordId = $attachment.sourceRecordId
                        destinationRecordId = $destinationRecordId
                        field = $attachment.fieldName
                        path = $uploadRelativePath
                    }
                    $report.uploadedFiles += [pscustomobject]@{
                        entity = $attachment.entityName
                        sourceRecordId = $attachment.sourceRecordId
                        destinationRecordId = $destinationRecordId
                        field = $attachment.fieldName
                        path = $uploadRelativePath
                    }
                }
                catch {
                    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Files' -Level 'Error' -Message "Failed to upload attachment for $($attachment.entityName)/$($destinationRecordId): $($attachment.fieldName)" -Detail $_.Exception.Message -Data @{
                        entity = $attachment.entityName
                        sourceRecordId = $attachment.sourceRecordId
                        destinationRecordId = $destinationRecordId
                        field = $attachment.fieldName
                    }
                    $report.failures += [pscustomobject]@{
                        entity = $attachment.entityName
                        sourceRecordId = $attachment.sourceRecordId
                        field = $attachment.fieldName
                        operation = 'upload file'
                        message = $_.Exception.Message
                    }
                }
            }
        }
    }
    elseif (@($manifest.attachments).Count -gt 0) {
        Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Files' -Level 'Warn' -Message "Skipping $(@($manifest.attachments).Count) exported file attachment(s) because -IncludeFiles was not specified."
        $report.skippedItems += [pscustomobject]@{
            reason = 'file attachments were skipped; rerun with -IncludeFiles to upload them'
            count = @($manifest.attachments).Count
        }
    }

    $reportPath = Join-Path $packageDirectory 'import-report.json'
    ConvertTo-JsonFile -InputObject ([pscustomobject]$report) -Path $reportPath
    Send-DataFabricProgress -ProgressCallback $ProgressCallback -Operation 'Import' -Stage 'Complete' -Message "Import complete. Created: $(@($report.createdEntities).Count); reused: $(@($report.reusedEntities).Count); inserted: $(@($report.insertedRecords).Count); failures: $(@($report.failures).Count)." -Data @{
        createdEntityCount = @($report.createdEntities).Count
        reusedEntityCount = @($report.reusedEntities).Count
        insertedRecordCount = @($report.insertedRecords).Count
        uploadedFileCount = @($report.uploadedFiles).Count
        failureCount = @($report.failures).Count
        skippedItemCount = @($report.skippedItems).Count
        reportPath = $reportPath
    }

    return [pscustomobject]@{
        packageDirectory = $packageDirectory
        reportPath = $reportPath
        createdEntityCount = @($report.createdEntities).Count
        reusedEntityCount = @($report.reusedEntities).Count
        insertedRecordCount = @($report.insertedRecords).Count
        uploadedFileCount = @($report.uploadedFiles).Count
        failureCount = @($report.failures).Count
        skippedItemCount = @($report.skippedItems).Count
    }
}

# Export the public API used by the runner, wrappers, and test harness.
Export-ModuleMember -Function @(
    'Invoke-UipJson',
    'Get-UipData',
    'Add-TenantArgument',
    'Get-DataFabricEntityList',
    'Get-DataFabricRecordList',
    'Get-DataFabricObjectId',
    'Get-DataFabricEntityName',
    'Get-DataFabricFieldName',
    'Get-DataFabricFieldType',
    'Test-DataFabricNativeEntity',
    'Get-DataFabricFields',
    'Test-DataFabricSystemField',
    'Test-DataFabricFileField',
    'Test-DataFabricRelationshipField',
    'Get-MigratableFieldNamesByType',
    'Remove-DataFabricSystemFields',
    'New-DataFabricEntityCreateBody',
    'ConvertTo-DataFabricExportRecord',
    'ConvertTo-DataFabricImportRecord',
    'Get-DataFabricInsertedRecordIds',
    'ConvertTo-DataFabricMappedRelationshipValue',
    'ConvertTo-SafeFileName',
    'Get-AttachmentFileName',
    'New-DataFabricPackageChecksums',
    'Test-DataFabricPackageChecksums',
    'Export-DataFabricPackage',
    'Import-DataFabricPackage'
)
