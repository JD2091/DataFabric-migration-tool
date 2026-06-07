[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Test harness setup: load the migration module from the organized src folder.
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\DataFabricMigration.psm1') -Force

$script:Failures = @()

# Minimal assertion helper for Boolean checks.
function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

# Minimal assertion helper for exact value comparisons.
function Assert-Equal {
    param(
        [AllowNull()]
        [object]$Actual,

        [AllowNull()]
        [object]$Expected,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected' but got '$Actual'."
    }
}

# Executes one test case and records failures without stopping the whole harness.
function Run-Test {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$Body
    )

    try {
        & $Body
        Write-Host "PASS $Name"
    }
    catch {
        $script:Failures += [pscustomobject]@{
            Name = $Name
            Error = $_.Exception.Message
        }
        Write-Host "FAIL $Name"
        Write-Host $_.Exception.Message
    }
}

# Shared schema fixture used by export/import tests.
$schema = [pscustomobject]@{
    Name = 'Invoice'
    DisplayName = 'Invoice'
    Description = 'Invoice records'
    Fields = @(
        [pscustomobject]@{ Name = 'Id'; DisplayName = 'Id'; Type = 'UUID'; Required = $true; System = $true },
        [pscustomobject]@{ Name = 'CreateTime'; DisplayName = 'CreateTime'; Type = 'DATETIME_WITH_TZ'; Required = $true; System = $true },
        [pscustomobject]@{ Name = 'Title'; DisplayName = 'Title'; Type = 'STRING'; Required = $true; System = $false },
        [pscustomobject]@{ Name = 'Amount'; DisplayName = 'Amount'; Type = 'DECIMAL'; Required = $false; System = $false },
        [pscustomobject]@{ Name = 'Standard'; DisplayName = 'Standard'; Type = 'CHOICE_SET_SINGLE'; Required = $false; System = $false },
        [pscustomobject]@{ Name = 'Attachment'; DisplayName = 'Attachment'; Type = 'FILE'; Required = $false; System = $false },
        [pscustomobject]@{ Name = 'Parent'; DisplayName = 'Parent'; Type = 'RELATIONSHIP'; Required = $false; System = $false; ReferenceEntityName = 'ParentEntity'; ReferenceFieldName = 'Id' }
    )
}

# Dot-sources only function definitions from the runner so prompt resolution can be tested without executing the script.
function Import-RunnerFunctionsForTest {
    $runnerPath = Join-Path $projectRoot 'Run-DataFabricMigration.ps1'
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw (($errors | ForEach-Object { $_.Message }) -join [Environment]::NewLine)
    }

    $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    foreach ($function in $functions) {
        . ([scriptblock]::Create("function script:$($function.Name) $($function.Body.Extent.Text)"))
    }
}

# Project-shape tests ensure the repo stays PowerShell-only and keeps runtime artifacts isolated.
Run-Test 'RPA and HTML dependency files are removed' {
    foreach ($relativePath in @('Main.xaml', 'DataFabricMigrationInput.html', 'project.json', 'project.uiproj', 'entry-points.json')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $projectRoot $relativePath))) "$relativePath should be removed from the PowerShell-only utility."
    }

    Assert-True (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'dist'))) 'RPA package artifacts under dist should be removed.'
}

Run-Test 'Project folder structure separates source scripts tests and runtime artifacts' {
    foreach ($relativePath in @(
            'src',
            'scripts',
            'tests',
            'artifacts',
            'artifacts\packages',
            'artifacts\work',
            'artifacts\work\export',
            'artifacts\work\import',
            'artifacts\logs',
            'artifacts\reports'
        )) {
        Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot $relativePath)) "$relativePath should exist."
    }

    Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot 'src\DataFabricMigration.psm1')) 'Migration module should live under src.'
    Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot 'scripts\Export-DataFabric.ps1')) 'Advanced export wrapper should live under scripts.'
    Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot 'scripts\Import-DataFabric.ps1')) 'Advanced import wrapper should live under scripts.'
    Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot 'Run-DataFabricMigration.ps1')) 'Primary runner should remain at the project root.'
}

# Runner input tests cover parameter shape, prompt hooks, defaults, and non-interactive validation.
Run-Test 'Run script exposes PowerShell-native parameter contract' {
    $runScript = Get-Content -LiteralPath (Join-Path $projectRoot 'Run-DataFabricMigration.ps1') -Raw
    Assert-True ($runScript -match '\[ValidateSet\(''Export'',\s*''Import''\)\]\s*\[string\]\$Mode') 'Runner should expose a typed Export/Import mode parameter.'
    Assert-True ($runScript -match '\[switch\]\$IncludeFiles') 'Runner should use a native switch for IncludeFiles.'
    Assert-True ($runScript -match '\[switch\]\$ImportRelationships') 'Runner should use a native switch for ImportRelationships.'
    Assert-True ($runScript -match '\[int\]\$PageSize') 'Runner should use a native integer PageSize.'
    Assert-True ($runScript -match '\[int\]\$BatchSize') 'Runner should use a native integer BatchSize.'
    Assert-True ($runScript -match '\[switch\]\$NoPrompt') 'Runner should support non-interactive NoPrompt mode.'
    Assert-True ($runScript -match '\[string\]\$LogPath') 'Runner should support a detailed log file path.'
    Assert-True (-not ($runScript -match 'FormDataJson')) 'Runner should not accept form JSON input.'
    Assert-True (-not ($runScript -match 'IncludeFilesText|ImportRelationshipsText|PageSizeText|BatchSizeText')) 'Runner should not use HTML form text parameters.'
}

Run-Test 'Run script assigns explicit defaults to public parameters' {
    $runScript = Get-Content -LiteralPath (Join-Path $projectRoot 'Run-DataFabricMigration.ps1') -Raw
    Assert-True ($runScript -match '\[string\]\$Mode\s*=\s*\$null') 'Mode should default to null so interactive runs still prompt for Export or Import.'
    foreach ($name in @('Tenant', 'Organization', 'ClientId', 'ClientSecret', 'PackagePath', 'EntityNames', 'ReportPath', 'LogPath')) {
        Assert-True ($runScript -match "\[string\]\`$$name\s*=\s*''") "$name should default to an empty string."
    }
    Assert-True ($runScript -match '\[int\]\$PageSize\s*=\s*100') 'PageSize should default to 100.'
    Assert-True ($runScript -match '\[int\]\$BatchSize\s*=\s*50') 'BatchSize should default to 50.'
    Assert-True ($runScript -match '\[string\]\$ProjectDir\s*=\s*\$PSScriptRoot') 'ProjectDir should default to the script root.'
    foreach ($name in @('IncludeFiles', 'ImportRelationships', 'NoPrompt')) {
        Assert-True ($runScript -match "\[switch\]\`$$name\s*=\s*\`$false") "$name should default to false."
    }
}

Run-Test 'Advanced wrappers assign explicit defaults to public parameters' {
    $exportScript = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Export-DataFabric.ps1') -Raw
    foreach ($name in @('PackagePath', 'Tenant', 'Organization', 'ClientId', 'ClientSecret', 'WorkingDirectory')) {
        Assert-True ($exportScript -match "\[string\]\`$$name\s*=\s*''") "Export wrapper $name should default to an empty string."
    }
    Assert-True ($exportScript -match '\[string\[\]\]\$EntityName\s*=\s*@\(\)') 'Export wrapper EntityName should default to an empty array.'
    Assert-True ($exportScript -match '\[int\]\$PageSize\s*=\s*100') 'Export wrapper PageSize should default to 100.'
    Assert-True ($exportScript -match '\[switch\]\$IncludeFiles\s*=\s*\$false') 'Export wrapper IncludeFiles should default to false.'

    $importScript = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Import-DataFabric.ps1') -Raw
    foreach ($name in @('PackagePath', 'Tenant', 'Organization', 'ClientId', 'ClientSecret', 'WorkingDirectory')) {
        Assert-True ($importScript -match "\[string\]\`$$name\s*=\s*''") "Import wrapper $name should default to an empty string."
    }
    Assert-True ($importScript -match '\[int\]\$BatchSize\s*=\s*50') 'Import wrapper BatchSize should default to 50.'
    foreach ($name in @('IncludeFiles', 'ImportRelationships')) {
        Assert-True ($importScript -match "\[switch\]\`$$name\s*=\s*\`$false") "Import wrapper $name should default to false."
    }
}

Run-Test 'Run script exposes testable prompt resolution hooks' {
    $runScript = Get-Content -LiteralPath (Join-Path $projectRoot 'Run-DataFabricMigration.ps1') -Raw
    Assert-True ($runScript -match 'function Resolve-MigrationInput') 'Runner should have a testable input resolution function.'
    Assert-True ($runScript -match '\[scriptblock\]\$ReadText') 'Input resolution should accept a text prompt scriptblock.'
    Assert-True ($runScript -match '\[scriptblock\]\$ReadSecret') 'Input resolution should accept a secret prompt scriptblock.'
    Assert-True ($runScript -match 'Read-Host[^\r\n]+-AsSecureString') 'Client secrets should be collected with Read-Host -AsSecureString.'
}

Run-Test 'Resolve-MigrationInput accepts mocked interactive prompt values' {
    Import-RunnerFunctionsForTest
    $answers = [System.Collections.Queue]::new()
    foreach ($answer in @('Export', 'SourceTenant', 'SourceOrg', 'source-client', '.\migration-package.zip', 'Customer,Invoice', 'yes')) {
        $answers.Enqueue($answer)
    }
    $secret = ConvertTo-SecureString 'source-secret' -AsPlainText -Force

    $result = Resolve-MigrationInput -ReadText { param($Prompt) $answers.Dequeue() } -ReadSecret { param($Prompt) $secret }

    Assert-Equal $result.Mode 'Export' 'Mode should be collected from the mocked prompt.'
    Assert-Equal $result.Tenant 'SourceTenant' 'Tenant should be collected from the mocked prompt.'
    Assert-Equal $result.Organization 'SourceOrg' 'Organization should be collected from the mocked prompt.'
    Assert-Equal $result.ClientId 'source-client' 'Client ID should be collected from the mocked prompt.'
    Assert-Equal $result.ClientSecret 'source-secret' 'Client secret should be converted from SecureString only for execution.'
    Assert-Equal $result.PackagePath '.\migration-package.zip' 'Package path should be collected from the mocked prompt.'
    Assert-Equal $result.EntityNames 'Customer,Invoice' 'Entity names should be collected for export.'
    Assert-True $result.IncludeFiles 'IncludeFiles should parse yes.'
    Assert-Equal $result.PageSize 100 'PageSize should use its explicit default when not supplied.'
}

Run-Test 'Resolve-MigrationInput defaults interactive package path under artifacts' {
    Import-RunnerFunctionsForTest
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-input-test-' + [guid]::NewGuid().ToString('N'))
    $answers = [System.Collections.Queue]::new()
    foreach ($answer in @('Export', '', '', '', '', '', 'no', '')) {
        $answers.Enqueue($answer)
    }

    $result = Resolve-MigrationInput -ProjectDir $tempRoot -ReadText { param($Prompt) $answers.Dequeue() } -ReadSecret { throw 'Secret should not be prompted when ClientId is blank.' }
    $expected = Join-Path (Join-Path $tempRoot 'artifacts\packages') 'migration-package.zip'
    Assert-Equal $result.PackagePath $expected 'Interactive default package path should live under artifacts\packages.'
}

Run-Test 'Run script NoPrompt requires mode before execution' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-runner-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $reportPath = Join-Path $tempRoot 'report.txt'
        $logPath = Join-Path $tempRoot 'migration.log'

        $runnerPath = Join-Path $projectRoot 'Run-DataFabricMigration.ps1'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ProjectDir "{1}" -NoPrompt -ReportPath "{2}" -LogPath "{3}"' -f @(
            $runnerPath.Replace('"', '""'),
            $projectRoot.Replace('"', '""'),
            $reportPath.Replace('"', '""'),
            $logPath.Replace('"', '""')
        )

        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden

        Assert-True ($process.ExitCode -ne 0) 'Runner should exit non-zero when NoPrompt required values are missing.'
        $report = Get-Content -LiteralPath $reportPath -Raw
        Assert-True ($report -match 'Data Fabric migration failed\.') 'Failure report should have a clear heading.'
        Assert-True ($report -match 'Mode is required') 'Failure report should explain that Mode is required.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

Run-Test 'Run script NoPrompt rejects partial client credentials' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-runner-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $reportPath = Join-Path $tempRoot 'report.txt'
        $logPath = Join-Path $tempRoot 'migration.log'
        $runnerPath = Join-Path $projectRoot 'Run-DataFabricMigration.ps1'
        $packagePath = Join-Path $tempRoot 'migration-package.zip'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ProjectDir "{1}" -NoPrompt -Mode Export -PackagePath "{2}" -ClientId source-client -ReportPath "{3}" -LogPath "{4}"' -f @(
            $runnerPath.Replace('"', '""'),
            $projectRoot.Replace('"', '""'),
            $packagePath.Replace('"', '""'),
            $reportPath.Replace('"', '""'),
            $logPath.Replace('"', '""')
        )

        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden

        Assert-True ($process.ExitCode -ne 0) 'Runner should exit non-zero when client credentials are incomplete.'
        $report = Get-Content -LiteralPath $reportPath -Raw
        Assert-True ($report -match 'Client credential login requires Tenant, Organization, ClientId, and ClientSecret') 'Failure report should explain the complete credential requirement.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

Run-Test 'Run script NoPrompt export accepts a single entity name' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-runner-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $fakeModulePath = Join-Path $tempRoot 'DataFabricMigration.psm1'
        Set-Content -LiteralPath $fakeModulePath -Encoding UTF8 -Value @'
function Export-DataFabricPackage {
    param(
        [string]$PackagePath,
        [string[]]$EntityName,
        [int]$PageSize,
        [scriptblock]$ProgressCallback
    )

    [pscustomobject]@{
        packagePath = $PackagePath
        workingDirectory = 'fake-work'
        entityCount = @($EntityName).Count
        skippedEntityCount = 0
        errorCount = 0
    }
}

function Import-DataFabricPackage {
    throw 'Import should not be called by this test.'
}

Export-ModuleMember -Function Export-DataFabricPackage, Import-DataFabricPackage
'@

        $reportPath = Join-Path $tempRoot 'report.txt'
        $packagePath = Join-Path $tempRoot 'migration-package.zip'
        $runnerPath = Join-Path $projectRoot 'Run-DataFabricMigration.ps1'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ProjectDir "{1}" -NoPrompt -Mode Export -PackagePath "{2}" -EntityNames ResearchData -ReportPath "{3}"' -f @(
            $runnerPath.Replace('"', '""'),
            $tempRoot.Replace('"', '""'),
            $packagePath.Replace('"', '""'),
            $reportPath.Replace('"', '""')
        )

        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden

        Assert-Equal $process.ExitCode 0 'Runner should export successfully when EntityNames contains one value.'
        $report = Get-Content -LiteralPath $reportPath -Raw
        Assert-True ($report -match 'Data Fabric export completed\.') 'Success report should be written.'
        Assert-True ($report -match 'Exported entities: 1') 'Single entity should be passed as one-element array.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

Run-Test 'Run script writes progress to terminal and detailed log file' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-runner-log-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $fakeModulePath = Join-Path $tempRoot 'DataFabricMigration.psm1'
        Set-Content -LiteralPath $fakeModulePath -Encoding UTF8 -Value @'
function Export-DataFabricPackage {
    param(
        [string]$PackagePath,
        [string[]]$EntityName,
        [int]$PageSize,
        [scriptblock]$ProgressCallback
    )

    & $ProgressCallback ([pscustomobject]@{
        Operation = 'Export'
        Stage = 'Start'
        Level = 'Info'
        Message = 'Starting export.'
        Detail = "PackagePath=$PackagePath; PageSize=$PageSize"
    })
    & $ProgressCallback ([pscustomobject]@{
        Operation = 'Export'
        Stage = 'Entity'
        Level = 'Info'
        Message = 'Processing entity 1/1: ResearchData'
        Detail = 'Records exported: 3'
    })

    [pscustomobject]@{
        packagePath = $PackagePath
        workingDirectory = 'fake-work'
        entityCount = @($EntityName).Count
        skippedEntityCount = 0
        errorCount = 0
    }
}

function Import-DataFabricPackage {
    throw 'Import should not be called by this test.'
}

Export-ModuleMember -Function Export-DataFabricPackage, Import-DataFabricPackage
'@

        $reportPath = Join-Path $tempRoot 'report.txt'
        $logPath = Join-Path $tempRoot 'logs\migration.log'
        $stdoutPath = Join-Path $tempRoot 'stdout.txt'
        $stderrPath = Join-Path $tempRoot 'stderr.txt'
        $packagePath = Join-Path $tempRoot 'migration-package.zip'
        $runnerPath = Join-Path $projectRoot 'Run-DataFabricMigration.ps1'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ProjectDir "{1}" -NoPrompt -Mode Export -PackagePath "{2}" -EntityNames ResearchData -ReportPath "{3}" -LogPath "{4}"' -f @(
            $runnerPath.Replace('"', '""'),
            $tempRoot.Replace('"', '""'),
            $packagePath.Replace('"', '""'),
            $reportPath.Replace('"', '""'),
            $logPath.Replace('"', '""')
        )

        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

        Assert-Equal $process.ExitCode 0 'Runner should finish when progress callback emits status events.'
        $stdout = Get-Content -LiteralPath $stdoutPath -Raw
        Assert-True ($stdout -match 'Starting export\.') 'Terminal output should include high-level progress.'
        Assert-True ($stdout -match 'Processing entity 1/1: ResearchData') 'Terminal output should include per-entity progress.'

        Assert-True (Test-Path -LiteralPath $logPath) 'Detailed log file should be created.'
        $log = Get-Content -LiteralPath $logPath -Raw
        Assert-True ($log -match '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}') 'Log entries should be timestamped.'
        Assert-True ($log -match 'PackagePath=.*migration-package\.zip') 'Log entries should include detailed event data.'
        Assert-True ($log -match 'Records exported: 3') 'Log entries should include detail text from progress events.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

# CLI invocation tests verify shim resolution, stderr handling, and secret redaction.
Run-Test 'Invoke-UipJson resolves executable command shim and parses JSON output' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-uip-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $oldPath = $env:PATH
    try {
        $commandName = 'fakeuip' + [guid]::NewGuid().ToString('N')
        $cmdPath = Join-Path $tempRoot "$commandName.cmd"
        $psPath = Join-Path $tempRoot "$commandName.ps1"

        Set-Content -LiteralPath $cmdPath -Encoding ASCII -Value @(
            '@echo off',
            'echo {"Result":"Success","Code":"CmdShim","Data":{"First":"%~1","Second":"%~2"}}'
        )
        Set-Content -LiteralPath $psPath -Encoding UTF8 -Value "Write-Output '{`"Result`":`"Success`",`"Code`":`"PsShim`",`"Data`":{}}'"

        $env:PATH = "$tempRoot;$oldPath"
        $result = Invoke-UipJson -Command $commandName -Arguments @('alpha', 'two words')

        Assert-Equal $result.Code 'CmdShim' 'Executable command shim should be preferred over the PowerShell shim.'
        Assert-Equal $result.Data.First 'alpha' 'First argument should be passed as a separate argument.'
        Assert-Equal $result.Data.Second 'two words' 'Argument values containing spaces should stay intact.'
    }
    finally {
        $env:PATH = $oldPath
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test 'Invoke-UipJson reports stderr when command exits nonzero' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-uip-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $oldPath = $env:PATH
    try {
        $commandName = 'fakeuip' + [guid]::NewGuid().ToString('N')
        $cmdPath = Join-Path $tempRoot "$commandName.cmd"

        Set-Content -LiteralPath $cmdPath -Encoding ASCII -Value @(
            '@echo off',
            'echo noisy stdout',
            'echo fake stderr message 1>&2',
            'exit /b 23'
        )

        $env:PATH = "$tempRoot;$oldPath"
        try {
            [void](Invoke-UipJson -Command $commandName -Arguments @('df', 'entities', 'list'))
            throw 'Invoke-UipJson should throw when the command exits nonzero.'
        }
        catch {
            Assert-True ($_.Exception.Message -match 'exit code 23') 'Failure should report the process exit code.'
            Assert-True ($_.Exception.Message -match 'fake stderr message') 'Failure should include stderr output.'
        }
    }
    finally {
        $env:PATH = $oldPath
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test 'Invoke-UipJson redacts client secret in failure messages' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-uip-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $oldPath = $env:PATH
    try {
        $commandName = 'fakeuip' + [guid]::NewGuid().ToString('N')
        $cmdPath = Join-Path $tempRoot "$commandName.cmd"

        Set-Content -LiteralPath $cmdPath -Encoding ASCII -Value @(
            '@echo off',
            'echo auth failed 1>&2',
            'exit /b 1'
        )

        $env:PATH = "$tempRoot;$oldPath"
        try {
            [void](Invoke-UipJson -Command $commandName -Arguments @('login', '--client-id', 'client-one', '--client-secret', 'super-secret-value', '--output', 'json'))
            throw 'Invoke-UipJson should throw when login exits nonzero.'
        }
        catch {
            Assert-True ($_.Exception.Message -match '--client-secret \*\*\*') 'Failure should redact client secret argument values.'
            Assert-True (-not ($_.Exception.Message -match 'super-secret-value')) 'Failure should not expose the client secret value.'
        }
    }
    finally {
        $env:PATH = $oldPath
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Record/schema transformation tests cover the pure helpers that prepare export and import payloads.
Run-Test 'Remove-DataFabricSystemFields strips readonly fields' {
    $record = [pscustomobject]@{
        Id = 'source-1'
        CreatedBy = 'system-user'
        CreateTime = '2026-01-01T00:00:00Z'
        UpdatedBy = 'system-user'
        UpdateTime = '2026-01-02T00:00:00Z'
        Title = 'A'
        Amount = 10
    }

    $result = Remove-DataFabricSystemFields -Record $record
    Assert-True (-not ($result.Data.PSObject.Properties.Name -contains 'Id')) 'Id should be removed.'
    Assert-True (-not ($result.Data.PSObject.Properties.Name -contains 'CreatedBy')) 'CreatedBy should be removed.'
    Assert-Equal $result.Data.Title 'A' 'Title should remain.'
    Assert-Equal @($result.RemovedFields).Count 5 'All five system fields should be tracked.'
}

Run-Test 'New-DataFabricEntityCreateBody skips system and relationship fields by default' {
    $result = New-DataFabricEntityCreateBody -Schema $schema
    $fieldNames = @($result.Body.fields | ForEach-Object { $_.fieldName })
    Assert-True ($fieldNames -contains 'Title') 'Scalar field should be included.'
    Assert-True ($fieldNames -contains 'Attachment') 'File field should be included.'
    Assert-True (-not ($fieldNames -contains 'Id')) 'System field should be excluded.'
    Assert-True (-not ($fieldNames -contains 'Standard')) 'Choice-set field should be excluded.'
    Assert-True (-not ($fieldNames -contains 'Parent')) 'Relationship field should be excluded by default.'
    Assert-True (@($result.SkippedFields | Where-Object { $_.name -eq 'Standard' -and $_.reason -match 'Choice set fields are not supported' }).Count -eq 1) 'Skipped choice-set field should be reported.'
    Assert-True (@($result.SkippedFields | Where-Object { $_.name -eq 'Parent' }).Count -eq 1) 'Skipped relationship field should be reported.'
}

Run-Test 'ConvertTo-DataFabricExportRecord separates scalar and supported special values while skipping choice sets' {
    $record = [pscustomobject]@{
        Id = 'source-1'
        Title = 'A'
        Amount = 15
        Standard = 'Grade 10'
        Attachment = [pscustomobject]@{ FileName = 'invoice.pdf' }
        Parent = 'source-parent'
    }

    $result = ConvertTo-DataFabricExportRecord -Record $record -Schema $schema
    Assert-Equal $result.sourceRecordId 'source-1' 'Source record ID should be preserved for mapping.'
    Assert-Equal $result.data.Title 'A' 'Scalar value should be in data.'
    Assert-True (-not ($result.data.PSObject.Properties.Name -contains 'Standard')) 'Choice-set value should not be exported in record data.'
    Assert-True ($result.fileFields.PSObject.Properties.Name -contains 'Attachment') 'File field should be separated.'
    Assert-Equal $result.relationships.Parent 'source-parent' 'Relationship value should be separated.'
}

Run-Test 'ConvertTo-DataFabricImportRecord returns insert payload only' {
    $exportRecord = [pscustomobject]@{
        sourceRecordId = 'source-1'
        data = [pscustomobject]@{ Title = 'A'; Amount = 15 }
        fileFields = [pscustomobject]@{ Attachment = [pscustomobject]@{ FileName = 'invoice.pdf' } }
        relationships = [pscustomobject]@{ Parent = 'source-parent' }
    }

    $payload = ConvertTo-DataFabricImportRecord -ExportRecord $exportRecord
    Assert-Equal $payload.Title 'A' 'Scalar field should be retained.'
    Assert-True (-not $payload.Contains('Attachment')) 'File field should not be in insert payload.'
    Assert-True (-not $payload.Contains('Parent')) 'Relationship field should not be in first-pass insert payload.'
}

Run-Test 'Get-DataFabricRecordList handles wrapped Records payload' {
    $response = [pscustomobject]@{
        Result = 'Success'
        Data = [pscustomobject]@{
            Records = @(
                [pscustomobject]@{ Id = 'one' },
                [pscustomobject]@{ Id = 'two' }
            )
            HasNextPage = $false
        }
    }

    $records = Get-DataFabricRecordList -Response $response
    Assert-Equal @($records).Count 2 'Records should be extracted from Data.Records.'
    Assert-Equal $records[1].Id 'two' 'Record order should be retained.'
}

Run-Test 'Get-DataFabricInsertedRecordIds handles single insert response' {
    $response = [pscustomobject]@{
        Result = 'Success'
        Data = [pscustomobject]@{ Id = 'dest-1'; Title = 'A' }
    }

    $ids = @(Get-DataFabricInsertedRecordIds -InsertResponse $response)
    Assert-Equal @($ids).Count 1 'One inserted ID should be returned.'
    Assert-Equal $ids[0] 'dest-1' 'Inserted ID should be extracted.'
}

Run-Test 'Get-DataFabricInsertedRecordIds handles batch string ID response' {
    $response = [pscustomobject]@{
        Result = 'Success'
        Data = @('dest-1', 'dest-2', 'dest-3')
    }

    $ids = @(Get-DataFabricInsertedRecordIds -InsertResponse $response)
    Assert-Equal @($ids).Count 3 'Batch string ID responses should map every inserted record.'
    Assert-Equal $ids[2] 'dest-3' 'String IDs should be retained in source order.'
}

Run-Test 'ConvertTo-DataFabricMappedRelationshipValue maps string IDs' {
    $map = @{ 'source-parent' = 'dest-parent' }
    $result = ConvertTo-DataFabricMappedRelationshipValue -Value 'source-parent' -RecordIdMap $map
    Assert-True $result.Mapped 'Relationship should be mapped.'
    Assert-Equal $result.Value 'dest-parent' 'Destination ID should be returned.'
}

Run-Test 'ConvertTo-DataFabricMappedRelationshipValue reports unresolved IDs' {
    $map = @{ 'source-parent' = 'dest-parent' }
    $result = ConvertTo-DataFabricMappedRelationshipValue -Value 'missing-parent' -RecordIdMap $map
    Assert-True (-not $result.Mapped) 'Relationship should not map when source ID is missing.'
    Assert-Equal $result.MissingSourceIds[0] 'missing-parent' 'Missing source ID should be reported.'
}

# Package integrity tests ensure import catches missing or tampered files before writing to the destination.
Run-Test 'Package checksum validation detects tampering' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $tempRoot 'manifest.json') -Value '{"formatVersion":"1.0"}' -Encoding UTF8
        [void](New-DataFabricPackageChecksums -PackageDirectory $tempRoot)
        $valid = Test-DataFabricPackageChecksums -PackageDirectory $tempRoot
        Assert-True $valid.IsValid 'Fresh checksum should validate.'

        Set-Content -LiteralPath (Join-Path $tempRoot 'manifest.json') -Value '{"formatVersion":"tampered"}' -Encoding UTF8
        $invalid = Test-DataFabricPackageChecksums -PackageDirectory $tempRoot
        Assert-True (-not $invalid.IsValid) 'Tampered file should fail validation.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

# End-to-end fake CLI export tests verify manifest creation, progress events, and source authentication flow.
Run-Test 'Export-DataFabricPackage creates package manifest with fake CLI responses' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-export-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $packagePath = Join-Path $tempRoot 'migration-package.zip'
        $workingDirectory = Join-Path $tempRoot 'package'
        $progressEvents = [System.Collections.Generic.List[object]]::new()
        $progressCallback = {
            param($Event)

            $progressEvents.Add($Event)
        }
        $fakeInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            if ($command -eq 'login status --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = [pscustomobject]@{ Status = 'Logged in'; Organization = 'SourceOrg'; Tenant = 'SourceTenant' }
                }
            }
            if ($command -eq 'df entities list --native-only --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = @(
                        [pscustomobject]@{ Name = 'Invoice'; DisplayName = 'Invoice'; ID = 'entity-1'; Type = 'Entity'; Source = 'Native' },
                        [pscustomobject]@{ Name = 'SystemUser'; DisplayName = 'System Users'; ID = 'system-1'; Type = 'SystemEntity'; Source = 'Native' }
                    )
                }
            }
            if ($command -eq 'df entities get entity-1 --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = $schema }
            }
            if ($command -eq 'df records list entity-1 --limit 100 --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = [pscustomobject]@{
                        Records = @(
                            [pscustomobject]@{ Id = 'source-1'; Title = 'A'; Amount = 25; Attachment = $null; Parent = 'source-parent' }
                        )
                        HasNextPage = $false
                    }
                }
            }
            throw "Unexpected fake CLI command: $command"
        }

        $result = Export-DataFabricPackage -PackagePath $packagePath -WorkingDirectory $workingDirectory -Invoker $fakeInvoker -ProgressCallback $progressCallback
        Assert-True (Test-Path -LiteralPath $packagePath) 'Package ZIP should be created.'
        Assert-Equal $result.entityCount 1 'One user entity should be exported.'
        Assert-Equal $result.skippedEntityCount 1 'System entity should be reported as skipped.'
        Assert-True (@($progressEvents | Where-Object { $_.Message -match 'Discovered 2 native entity candidate' }).Count -eq 1) 'Export should report discovered entity count.'
        Assert-True (@($progressEvents | Where-Object { $_.Message -match 'Exporting entity 1/2: Invoice' }).Count -eq 1) 'Export should report per-entity progress.'
        Assert-True (@($progressEvents | Where-Object { $_.Message -match 'Exported 1 record' }).Count -eq 1) 'Export should report exported record count.'

        $manifest = Get-Content -LiteralPath (Join-Path $workingDirectory 'manifest.json') -Raw | ConvertFrom-Json
        Assert-Equal $manifest.entities[0].recordCount 1 'Record count should be recorded in manifest.'
        Assert-True (@($manifest.entities[0].relationshipFields) -contains 'Parent') 'Relationship field should be reported.'
        Assert-True (@($manifest.entities[0].skippedFields | Where-Object { $_.name -eq 'Standard' -and $_.reason -match 'Choice set fields are not supported' }).Count -eq 1) 'Choice-set field skip should be reported in the manifest.'

        $exportedSchema = Get-Content -LiteralPath (Join-Path $workingDirectory $manifest.entities[0].schemaPath) -Raw | ConvertFrom-Json
        $exportedSchemaFields = @($exportedSchema.Fields | ForEach-Object { $_.Name })
        Assert-True (-not ($exportedSchemaFields -contains 'Standard')) 'Choice-set field should be removed from exported schema.'

        $createBody = Get-Content -LiteralPath (Join-Path $workingDirectory $manifest.entities[0].createBodyPath) -Raw | ConvertFrom-Json
        $createBodyFields = @($createBody.fields | ForEach-Object { $_.fieldName })
        Assert-True (-not ($createBodyFields -contains 'Standard')) 'Choice-set field should be removed from exported create body.'

        $records = Get-Content -LiteralPath (Join-Path $workingDirectory $manifest.entities[0].recordsPath) -Raw | ConvertFrom-Json
        Assert-Equal $records.sourceRecordId 'source-1' 'Source record ID should be retained in package record metadata.'
        Assert-Equal $records.data.Title 'A' 'Sanitized record data should be written.'
        Assert-True (-not ($records.data.PSObject.Properties.Name -contains 'Standard')) 'Choice-set record value should be removed from exported records.'

        $relationshipDefinition = @($manifest.entities[0].relationshipDefinitions)[0]
        Assert-Equal $relationshipDefinition.fieldName 'Parent' 'Relationship field definition should include the field name.'
        Assert-Equal $relationshipDefinition.referenceEntityName 'ParentEntity' 'Relationship field definition should include the target entity name.'
        Assert-Equal $relationshipDefinition.referenceFieldName 'Id' 'Relationship field definition should include the target reference field.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

Run-Test 'Export-DataFabricPackage preserves inferred attachment file extension' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-export-file-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $packagePath = Join-Path $tempRoot 'migration-package.zip'
        $workingDirectory = Join-Path $tempRoot 'package'
        $pngBytes = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52)
        $fakeInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            if ($command -eq 'login status --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Status = 'Logged in' } }
            }
            if ($command -eq 'df entities list --native-only --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = @([pscustomobject]@{ Name = 'Invoice'; DisplayName = 'Invoice'; ID = 'entity-1'; Type = 'Entity'; Source = 'Native' })
                }
            }
            if ($command -eq 'df entities get entity-1 --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = $schema }
            }
            if ($command -eq 'df records list entity-1 --limit 100 --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = [pscustomobject]@{
                        Records = @([pscustomobject]@{ Id = 'source-1'; Title = 'A'; Amount = 25; Attachment = 'file-token-without-extension'; Parent = $null })
                        HasNextPage = $false
                    }
                }
            }
            if ($command -like 'df files download entity-1 source-1 Attachment --destination * --output json') {
                $destinationIndex = [Array]::IndexOf($Arguments, '--destination') + 1
                [System.IO.File]::WriteAllBytes($Arguments[$destinationIndex], $pngBytes)
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ OutputPath = $Arguments[$destinationIndex] } }
            }
            throw "Unexpected export file fake CLI command: $command"
        }

        [void](Export-DataFabricPackage -PackagePath $packagePath -WorkingDirectory $workingDirectory -IncludeFiles -Invoker $fakeInvoker)
        $manifest = Get-Content -LiteralPath (Join-Path $workingDirectory 'manifest.json') -Raw | ConvertFrom-Json
        $attachment = @($manifest.attachments)[0]

        Assert-True ($attachment.path -match '\.png$') 'Attachment package path should include the inferred PNG extension.'
        Assert-True (Test-Path -LiteralPath (Join-Path $workingDirectory $attachment.path)) 'Renamed attachment file should exist in the package.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

Run-Test 'Export-DataFabricPackage logs in with client credentials before source reads' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-export-auth-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $packagePath = Join-Path $tempRoot 'migration-package.zip'
        $workingDirectory = Join-Path $tempRoot 'package'
        $calls = [System.Collections.Generic.List[string]]::new()
        $fakeInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            $calls.Add($command)
            if ($command -eq 'login --client-id export-client --client-secret export-secret --organization SourceOrg --tenant SourceTenant --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = [pscustomobject]@{ Status = 'Logged in'; Organization = 'SourceOrg'; Tenant = 'SourceTenant' }
                }
            }
            if ($command -eq 'df entities list --native-only --output json --tenant SourceTenant') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = @([pscustomobject]@{ Name = 'Invoice'; DisplayName = 'Invoice'; ID = 'entity-1'; Type = 'Entity'; Source = 'Native' })
                }
            }
            if ($command -eq 'df entities get entity-1 --output json --tenant SourceTenant') {
                return [pscustomobject]@{ Result = 'Success'; Data = $schema }
            }
            if ($command -eq 'df records list entity-1 --limit 100 --output json --tenant SourceTenant') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = [pscustomobject]@{
                        Records = @([pscustomobject]@{ Id = 'source-1'; Title = 'A'; Amount = 25; Attachment = $null; Parent = $null })
                        HasNextPage = $false
                    }
                }
            }
            throw "Unexpected export auth fake CLI command: $command"
        }

        [void](Export-DataFabricPackage -PackagePath $packagePath -WorkingDirectory $workingDirectory -Tenant SourceTenant -Organization SourceOrg -ClientId export-client -ClientSecret export-secret -Invoker $fakeInvoker)
        Assert-Equal $calls[0] 'login --client-id export-client --client-secret export-secret --organization SourceOrg --tenant SourceTenant --output json' 'Export should log in with source client credentials before Data Fabric reads.'
        Assert-True ($calls[1] -match '^df entities list') 'Export should read entities only after logging in.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

# End-to-end fake CLI import tests verify entity creation/reuse, record insertion, and destination authentication flow.
Run-Test 'Import-DataFabricPackage creates missing entity and report with fake CLI responses' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-import-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $packagePath = Join-Path $tempRoot 'migration-package.zip'
        $exportDirectory = Join-Path $tempRoot 'package'
        $importDirectory = Join-Path $tempRoot 'import'

        $exportInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            if ($command -eq 'login status --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Status = 'Logged in' } }
            }
            if ($command -eq 'df entities list --native-only --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = @([pscustomobject]@{ Name = 'Invoice'; DisplayName = 'Invoice'; ID = 'entity-1'; Type = 'Entity'; Source = 'Native' })
                }
            }
            if ($command -eq 'df entities get entity-1 --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = $schema }
            }
            if ($command -eq 'df records list entity-1 --limit 100 --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = [pscustomobject]@{
                        Records = @([pscustomobject]@{ Id = 'source-1'; Title = 'A'; Amount = 25; Attachment = $null; Parent = $null })
                        HasNextPage = $false
                    }
                }
            }
            throw "Unexpected export fake CLI command: $command"
        }

        [void](Export-DataFabricPackage -PackagePath $packagePath -WorkingDirectory $exportDirectory -Invoker $exportInvoker)

        $importInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            if ($command -eq 'login status --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Status = 'Logged in' } }
            }
            if ($command -eq 'df entities list --native-only --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = @() }
            }
            if ($command -like 'df entities create Invoice --file * --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Name = 'Invoice'; ID = 'dest-entity-1' } }
            }
            if ($command -like 'df records insert dest-entity-1 --file * --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Id = 'dest-record-1'; Title = 'A' } }
            }
            throw "Unexpected import fake CLI command: $command"
        }

        $result = Import-DataFabricPackage -PackagePath $packagePath -WorkingDirectory $importDirectory -Invoker $importInvoker
        Assert-Equal $result.createdEntityCount 1 'Missing entity should be created.'
        Assert-Equal $result.insertedRecordCount 1 'One record should be inserted.'
        Assert-Equal $result.failureCount 0 'Import should not report failures.'
        Assert-True (Test-Path -LiteralPath $result.reportPath) 'Import report should be written.'

        $report = Get-Content -LiteralPath $result.reportPath -Raw | ConvertFrom-Json
        Assert-Equal $report.entityIdMap.'entity-1' 'dest-entity-1' 'Entity ID map should be written.'
        Assert-Equal $report.recordIdMap.'source-1' 'dest-record-1' 'Record ID map should be written.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

Run-Test 'Import-DataFabricPackage skips choice-set fields from legacy package schema and records' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-import-choice-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $packagePath = Join-Path $tempRoot 'migration-package.zip'
        $packageDirectory = Join-Path $tempRoot 'package'
        $entityDirectory = Join-Path $packageDirectory 'entities\Invoice'
        New-Item -ItemType Directory -Path $entityDirectory -Force | Out-Null

        $legacyCreateBody = [pscustomobject]@{
            displayName = 'Invoice'
            fields = @(
                [pscustomobject]@{ fieldName = 'Title'; type = 'STRING'; isRequired = $true },
                [pscustomobject]@{ fieldName = 'Standard'; type = 'CHOICE_SET_SINGLE'; isRequired = $false }
            )
        }
        $legacyRecords = @(
            [pscustomobject]@{
                sourceRecordId = 'source-1'
                data = [pscustomobject]@{ Title = 'A'; Standard = 'Grade 10' }
                fileFields = [pscustomobject]@{}
                relationships = [pscustomobject]@{}
                removedSystemFields = @('Id')
            }
        )
        $manifest = [pscustomobject]@{
            formatVersion = '1.0'
            exportedUtc = '2026-06-07T00:00:00.0000000Z'
            source = [pscustomobject]@{}
            tenant = ''
            entities = @(
                [pscustomobject]@{
                    name = 'Invoice'
                    displayName = 'Invoice'
                    sourceEntityId = 'entity-1'
                    type = 'Entity'
                    source = 'Native'
                    schemaPath = 'entities\Invoice\schema.json'
                    createBodyPath = 'entities\Invoice\create-body.json'
                    recordsPath = 'entities\Invoice\records.json'
                    recordCount = 1
                    fileFields = @()
                    relationshipFields = @()
                    skippedFields = @()
                }
            )
            skippedEntities = @()
            attachments = @()
            errors = @()
        }

        $schema | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $entityDirectory 'schema.json') -Encoding UTF8
        $legacyCreateBody | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $entityDirectory 'create-body.json') -Encoding UTF8
        $legacyRecords | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $entityDirectory 'records.json') -Encoding UTF8
        $manifest | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $packageDirectory 'manifest.json') -Encoding UTF8
        [void](New-DataFabricPackageChecksums -PackageDirectory $packageDirectory)
        Compress-Archive -Path (Join-Path $packageDirectory '*') -DestinationPath $packagePath -Force

        $createdBodyPath = $null
        $insertBodyPath = $null
        $importInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            if ($command -eq 'login status --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Status = 'Logged in' } }
            }
            if ($command -eq 'df entities list --native-only --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = @() }
            }
            if ($command -like 'df entities create Invoice --file * --output json') {
                $script:createdBodyPath = $Arguments[[Array]::IndexOf($Arguments, '--file') + 1]
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Name = 'Invoice'; ID = 'dest-entity-1' } }
            }
            if ($command -like 'df records insert dest-entity-1 --file * --output json') {
                $script:insertBodyPath = $Arguments[[Array]::IndexOf($Arguments, '--file') + 1]
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Id = 'dest-record-1'; Title = 'A' } }
            }
            throw "Unexpected import choice fake CLI command: $command"
        }

        $script:createdBodyPath = $null
        $script:insertBodyPath = $null
        $result = Import-DataFabricPackage -PackagePath $packagePath -WorkingDirectory (Join-Path $tempRoot 'import') -Invoker $importInvoker
        $createBody = Get-Content -LiteralPath $script:createdBodyPath -Raw | ConvertFrom-Json
        $insertPayload = Get-Content -LiteralPath $script:insertBodyPath -Raw | ConvertFrom-Json
        $report = Get-Content -LiteralPath $result.reportPath -Raw | ConvertFrom-Json

        Assert-True (-not (@($createBody.fields | ForEach-Object { $_.fieldName }) -contains 'Standard')) 'Legacy choice-set field should be removed before entity create.'
        Assert-True (-not ($insertPayload[0].PSObject.Properties.Name -contains 'Standard')) 'Legacy choice-set value should be removed before record insert.'
        Assert-True (@($report.skippedItems | Where-Object { $_.entity -eq 'Invoice' -and $_.field -eq 'Standard' -and $_.reason -match 'Choice set fields are not supported' }).Count -ge 1) 'Import report should list skipped choice-set field.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

Run-Test 'Import-DataFabricPackage adds relationship fields and updates mapped records' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-import-relationship-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $packagePath = Join-Path $tempRoot 'migration-package.zip'
        $exportDirectory = Join-Path $tempRoot 'package'
        $importDirectory = Join-Path $tempRoot 'import'
        $studentSchema = [pscustomobject]@{
            Name = 'schoolStudent'
            DisplayName = 'School Student'
            Fields = @(
                [pscustomobject]@{ Name = 'Id'; DisplayName = 'Id'; Type = 'UUID'; Required = $true; System = $true },
                [pscustomobject]@{ Name = 'Name'; DisplayName = 'Name'; Type = 'STRING'; Required = $true; System = $false }
            )
        }
        $marksheetSchema = [pscustomobject]@{
            Name = 'schoolmarksheet'
            DisplayName = 'School Marksheet'
            Fields = @(
                [pscustomobject]@{ Name = 'Id'; DisplayName = 'Id'; Type = 'UUID'; Required = $true; System = $true },
                [pscustomobject]@{ Name = 'Score'; DisplayName = 'Score'; Type = 'INTEGER'; Required = $false; System = $false },
                [pscustomobject]@{ Name = 'Student'; DisplayName = 'Student'; Type = 'RELATIONSHIP'; Required = $true; System = $false; ReferenceFieldName = 'Id' }
            )
        }

        $exportInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            if ($command -eq 'login status --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Status = 'Logged in' } }
            }
            if ($command -eq 'df entities list --native-only --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = @(
                        [pscustomobject]@{ Name = 'schoolStudent'; DisplayName = 'School Student'; ID = 'source-student-entity'; Type = 'Entity'; Source = 'Native' },
                        [pscustomobject]@{ Name = 'schoolmarksheet'; DisplayName = 'School Marksheet'; ID = 'source-marksheet-entity'; Type = 'Entity'; Source = 'Native' }
                    )
                }
            }
            if ($command -eq 'df entities get source-student-entity --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = $studentSchema }
            }
            if ($command -eq 'df entities get source-marksheet-entity --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = $marksheetSchema }
            }
            if ($command -eq 'df records list source-student-entity --limit 100 --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Records = @([pscustomobject]@{ Id = 'source-student-1'; Name = 'Asha' }); HasNextPage = $false } }
            }
            if ($command -eq 'df records list source-marksheet-entity --limit 100 --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Records = @([pscustomobject]@{ Id = 'source-marksheet-1'; Score = 95; Student = 'source-student-1' }); HasNextPage = $false } }
            }
            throw "Unexpected relationship export fake CLI command: $command"
        }

        [void](Export-DataFabricPackage -PackagePath $packagePath -WorkingDirectory $exportDirectory -Invoker $exportInvoker)
        $exportManifest = Get-Content -LiteralPath (Join-Path $exportDirectory 'manifest.json') -Raw | ConvertFrom-Json
        $marksheetManifest = @($exportManifest.entities | Where-Object { $_.name -eq 'schoolmarksheet' })[0]
        $inferredDefinition = @($marksheetManifest.relationshipDefinitions)[0]
        Assert-Equal $inferredDefinition.referenceEntityName 'schoolStudent' 'Export should infer missing relationship target entity name from relationship record values.'
        $inferredDefinition.referenceEntityName = $null
        $exportManifest | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $exportDirectory 'manifest.json') -Encoding UTF8
        [void](New-DataFabricPackageChecksums -PackageDirectory $exportDirectory)
        Compress-Archive -Path (Join-Path $exportDirectory '*') -DestinationPath $packagePath -Force

        $calls = [System.Collections.Generic.List[string]]::new()
        $script:relationshipFieldAdded = $false
        $importInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            $calls.Add($command)
            if ($command -eq 'login status --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Status = 'Logged in' } }
            }
            if ($command -eq 'df entities list --native-only --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = @() }
            }
            if ($command -like 'df entities create schoolStudent --file * --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Name = 'schoolStudent'; ID = 'dest-student-entity' } }
            }
            if ($command -like 'df entities create schoolmarksheet --file * --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Name = 'schoolmarksheet'; ID = 'dest-marksheet-entity' } }
            }
            if ($command -eq 'df entities get dest-student-entity --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Name = 'schoolStudent'; Fields = @([pscustomobject]@{ Name = 'Name'; Type = 'STRING'; Required = $true; System = $false }) } }
            }
            if ($command -eq 'df entities get dest-marksheet-entity --output json') {
                $fields = @([pscustomobject]@{ Name = 'Score'; Type = 'INTEGER'; Required = $false; System = $false })
                if ($script:relationshipFieldAdded) {
                    $fields += [pscustomobject]@{ ID = 'relationship-field-student'; Name = 'Student'; Type = 'RELATIONSHIP'; Required = $false; System = $false; ReferenceEntityName = 'schoolStudent'; ReferenceFieldName = 'Id' }
                }
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Name = 'schoolmarksheet'; Fields = $fields } }
            }
            if ($command -like 'df entities update dest-marksheet-entity --file * --output json') {
                $fileIndex = [Array]::IndexOf($Arguments, '--file') + 1
                $body = Get-Content -LiteralPath $Arguments[$fileIndex] -Raw | ConvertFrom-Json
                if ($body.PSObject.Properties.Name -contains 'addFields') {
                    Assert-Equal $body.addFields[0].fieldName 'Student' 'Relationship add field payload should target the Student field.'
                    Assert-Equal $body.addFields[0].type 'RELATIONSHIP' 'Relationship add field payload should use RELATIONSHIP type.'
                    Assert-Equal $body.addFields[0].referenceEntityName 'schoolStudent' 'Relationship add field payload should reference the destination target entity name.'
                    Assert-Equal $body.addFields[0].referenceFieldName 'Id' 'Relationship add field payload should reference the target Id field.'
                    Assert-True (-not $body.addFields[0].isRequired) 'Relationship add field should be temporarily optional while records are inserted.'
                    $script:relationshipFieldAdded = $true
                }
                elseif ($body.PSObject.Properties.Name -contains 'updateFields') {
                    Assert-Equal $body.updateFields[0].id 'relationship-field-student' 'Relationship restore payload should use the destination field ID.'
                    Assert-True $body.updateFields[0].isRequired 'Relationship restore payload should restore the required flag.'
                }
                else {
                    throw 'Relationship schema update payload should add or update fields.'
                }
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Name = 'schoolmarksheet'; ID = 'dest-marksheet-entity' } }
            }
            if ($command -like 'df records insert dest-student-entity --file * --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = @('dest-student-1') }
            }
            if ($command -like 'df records insert dest-marksheet-entity --file * --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = @('dest-marksheet-1') }
            }
            if ($command -like 'df records update dest-marksheet-entity --file * --output json') {
                $fileIndex = [Array]::IndexOf($Arguments, '--file') + 1
                $body = Get-Content -LiteralPath $Arguments[$fileIndex] -Raw | ConvertFrom-Json
                Assert-Equal $body.Id 'dest-marksheet-1' 'Relationship update should target the destination marksheet record.'
                Assert-Equal $body.Student 'dest-student-1' 'Relationship update should map the source student ID to the destination student ID.'
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Id = 'dest-marksheet-1' } }
            }
            throw "Unexpected relationship import fake CLI command: $command"
        }

        $result = Import-DataFabricPackage -PackagePath $packagePath -WorkingDirectory $importDirectory -ImportRelationships -Invoker $importInvoker
        $relationshipFieldAdds = @($calls | Where-Object { $_ -like '*add-Student.json*' })
        $relationshipFieldRestores = @($calls | Where-Object { $_ -like '*restore-Student.json*' })
        $relationshipRecordUpdates = @($calls | Where-Object { $_ -like 'df records update dest-marksheet-entity *' })
        $report = Get-Content -LiteralPath $result.reportPath -Raw | ConvertFrom-Json

        Assert-Equal $relationshipFieldAdds.Count 1 'Import should add the missing relationship field before relationship record updates.'
        Assert-Equal $relationshipFieldRestores.Count 1 'Import should restore the required relationship flag after relationship record updates.'
        Assert-Equal $relationshipRecordUpdates.Count 1 'Import should update the relationship value after records are mapped.'
        Assert-Equal @($report.relationshipFieldsAdded).Count 1 'Import report should record added relationship fields.'
        Assert-Equal @($report.relationshipFieldsRestored).Count 1 'Import report should record restored relationship fields.'
        Assert-Equal @($report.relationshipUpdates).Count 1 'Import report should record relationship value updates.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

Run-Test 'Import-DataFabricPackage reports unresolved inferred relationship target' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-import-unresolved-relationship-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $packagePath = Join-Path $tempRoot 'migration-package.zip'
        $packageDirectory = Join-Path $tempRoot 'package'
        $entityDirectory = Join-Path $packageDirectory 'entities\schoolmarksheet'
        New-Item -ItemType Directory -Path $entityDirectory -Force | Out-Null

        $marksheetSchema = [pscustomobject]@{
            Name = 'schoolmarksheet'
            DisplayName = 'School Marksheet'
            Fields = @(
                [pscustomobject]@{ Name = 'Id'; DisplayName = 'Id'; Type = 'UUID'; Required = $true; System = $true },
                [pscustomobject]@{ Name = 'Score'; DisplayName = 'Score'; Type = 'INTEGER'; Required = $false; System = $false },
                [pscustomobject]@{ Name = 'Student'; DisplayName = 'Student'; Type = 'RELATIONSHIP'; Required = $false; System = $false; ReferenceFieldName = 'Id' }
            )
        }
        $createBody = [pscustomobject]@{
            displayName = 'School Marksheet'
            fields = @([pscustomobject]@{ fieldName = 'Score'; type = 'INTEGER'; isRequired = $false })
        }
        $records = @(
            [pscustomobject]@{
                sourceRecordId = 'source-marksheet-1'
                data = [pscustomobject]@{ Score = 95 }
                fileFields = [pscustomobject]@{}
                relationships = [pscustomobject]@{ Student = 'missing-student-1' }
                removedSystemFields = @('Id')
            }
        )
        $manifest = [pscustomobject]@{
            formatVersion = '1.0'
            exportedUtc = '2026-06-07T00:00:00.0000000Z'
            source = [pscustomobject]@{}
            tenant = ''
            entities = @(
                [pscustomobject]@{
                    name = 'schoolmarksheet'
                    displayName = 'School Marksheet'
                    sourceEntityId = 'source-marksheet-entity'
                    type = 'Entity'
                    source = 'Native'
                    schemaPath = 'entities\schoolmarksheet\schema.json'
                    createBodyPath = 'entities\schoolmarksheet\create-body.json'
                    recordsPath = 'entities\schoolmarksheet\records.json'
                    recordCount = 1
                    fileFields = @()
                    relationshipFields = @('Student')
                    relationshipDefinitions = @([pscustomobject]@{
                            fieldName = 'Student'
                            type = 'RELATIONSHIP'
                            referenceEntityName = $null
                            referenceFieldName = 'Id'
                            displayName = 'Student'
                            isRequired = $false
                        })
                    skippedFields = @()
                }
            )
            skippedEntities = @()
            attachments = @()
            errors = @()
        }

        $marksheetSchema | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $entityDirectory 'schema.json') -Encoding UTF8
        $createBody | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $entityDirectory 'create-body.json') -Encoding UTF8
        $records | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $entityDirectory 'records.json') -Encoding UTF8
        $manifest | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $packageDirectory 'manifest.json') -Encoding UTF8
        [void](New-DataFabricPackageChecksums -PackageDirectory $packageDirectory)
        Compress-Archive -Path (Join-Path $packageDirectory '*') -DestinationPath $packagePath -Force

        $importInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            if ($command -eq 'login status --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Status = 'Logged in' } }
            }
            if ($command -eq 'df entities list --native-only --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = @() }
            }
            if ($command -like 'df entities create schoolmarksheet --file * --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Name = 'schoolmarksheet'; ID = 'dest-marksheet-entity' } }
            }
            if ($command -eq 'df entities get dest-marksheet-entity --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Name = 'schoolmarksheet'; Fields = @([pscustomobject]@{ Name = 'Score'; Type = 'INTEGER'; Required = $false; System = $false }) } }
            }
            if ($command -like 'df entities update dest-marksheet-entity --file * --output json') {
                throw 'Relationship field should not be added when target inference fails.'
            }
            if ($command -like 'df records insert dest-marksheet-entity --file * --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = @('dest-marksheet-1') }
            }
            throw "Unexpected unresolved relationship import fake CLI command: $command"
        }

        $result = Import-DataFabricPackage -PackagePath $packagePath -WorkingDirectory (Join-Path $tempRoot 'import') -ImportRelationships -Invoker $importInvoker
        $report = Get-Content -LiteralPath $result.reportPath -Raw | ConvertFrom-Json

        Assert-True (@($report.skippedItems | Where-Object { $_.entity -eq 'schoolmarksheet' -and $_.field -eq 'Student' -and $_.reason -eq 'relationship field skipped because target entity could not be inferred' }).Count -eq 1) 'Unresolved relationship target inference should be reported clearly.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

Run-Test 'Import-DataFabricPackage uploads attachments after batch string ID response' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-import-file-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $packagePath = Join-Path $tempRoot 'migration-package.zip'
        $exportDirectory = Join-Path $tempRoot 'package'
        $importDirectory = Join-Path $tempRoot 'import'
        $pngBytes = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52)

        $exportInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            if ($command -eq 'login status --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Status = 'Logged in' } }
            }
            if ($command -eq 'df entities list --native-only --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = @([pscustomobject]@{ Name = 'Invoice'; DisplayName = 'Invoice'; ID = 'entity-1'; Type = 'Entity'; Source = 'Native' })
                }
            }
            if ($command -eq 'df entities get entity-1 --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = $schema }
            }
            if ($command -eq 'df records list entity-1 --limit 100 --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = [pscustomobject]@{
                        Records = @([pscustomobject]@{ Id = 'source-1'; Title = 'A'; Amount = 25; Attachment = 'file-token-without-extension'; Parent = $null })
                        HasNextPage = $false
                    }
                }
            }
            if ($command -like 'df files download entity-1 source-1 Attachment --destination * --output json') {
                $destinationIndex = [Array]::IndexOf($Arguments, '--destination') + 1
                [System.IO.File]::WriteAllBytes($Arguments[$destinationIndex], $pngBytes)
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ OutputPath = $Arguments[$destinationIndex] } }
            }
            throw "Unexpected import file export fake CLI command: $command"
        }

        [void](Export-DataFabricPackage -PackagePath $packagePath -WorkingDirectory $exportDirectory -IncludeFiles -Invoker $exportInvoker)

        $calls = [System.Collections.Generic.List[string]]::new()
        $importInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            $calls.Add($command)
            if ($command -eq 'login status --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Status = 'Logged in' } }
            }
            if ($command -eq 'df entities list --native-only --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = @() }
            }
            if ($command -like 'df entities create Invoice --file * --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Name = 'Invoice'; ID = 'dest-entity-1' } }
            }
            if ($command -like 'df records insert dest-entity-1 --file * --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = @('dest-record-1') }
            }
            if ($command -like 'df files upload dest-entity-1 dest-record-1 Attachment --file * --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ FileName = 'file-token-without-extension.png' } }
            }
            throw "Unexpected import file fake CLI command: $command"
        }

        $result = Import-DataFabricPackage -PackagePath $packagePath -WorkingDirectory $importDirectory -IncludeFiles -Invoker $importInvoker
        $uploadCalls = @($calls | Where-Object { $_ -like 'df files upload *' })

        Assert-Equal $result.uploadedFileCount 1 'One exported attachment should be uploaded after destination record IDs are mapped.'
        Assert-True ($uploadCalls[0] -match '\.png --output json$') 'Upload should use the extension-preserved package file path.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

Run-Test 'Import-DataFabricPackage inserts attachment records one at a time when batch response omits IDs' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-import-single-file-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $packagePath = Join-Path $tempRoot 'migration-package.zip'
        $exportDirectory = Join-Path $tempRoot 'package'
        $importDirectory = Join-Path $tempRoot 'import'
        $pngBytes = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52)

        $exportInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            if ($command -eq 'login status --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Status = 'Logged in' } }
            }
            if ($command -eq 'df entities list --native-only --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = @([pscustomobject]@{ Name = 'Invoice'; DisplayName = 'Invoice'; ID = 'entity-1'; Type = 'Entity'; Source = 'Native' })
                }
            }
            if ($command -eq 'df entities get entity-1 --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = $schema }
            }
            if ($command -eq 'df records list entity-1 --limit 100 --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = [pscustomobject]@{
                        Records = @(
                            [pscustomobject]@{ Id = 'source-1'; Title = 'A'; Amount = 25; Attachment = 'file-token-1'; Parent = $null },
                            [pscustomobject]@{ Id = 'source-2'; Title = 'B'; Amount = 35; Attachment = 'file-token-2'; Parent = $null }
                        )
                        HasNextPage = $false
                    }
                }
            }
            if ($command -like 'df files download entity-1 * Attachment --destination * --output json') {
                $destinationIndex = [Array]::IndexOf($Arguments, '--destination') + 1
                [System.IO.File]::WriteAllBytes($Arguments[$destinationIndex], $pngBytes)
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ OutputPath = $Arguments[$destinationIndex] } }
            }
            throw "Unexpected single-file export fake CLI command: $command"
        }

        [void](Export-DataFabricPackage -PackagePath $packagePath -WorkingDirectory $exportDirectory -IncludeFiles -Invoker $exportInvoker)

        $calls = [System.Collections.Generic.List[string]]::new()
        $importInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            $calls.Add($command)
            if ($command -eq 'login status --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Status = 'Logged in' } }
            }
            if ($command -eq 'df entities list --native-only --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = @() }
            }
            if ($command -like 'df entities create Invoice --file * --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Name = 'Invoice'; ID = 'dest-entity-1' } }
            }
            if ($command -like 'df records insert dest-entity-1 --file * --output json') {
                $fileIndex = [Array]::IndexOf($Arguments, '--file') + 1
                $payload = @(Get-Content -LiteralPath $Arguments[$fileIndex] -Raw | ConvertFrom-Json)
                if ($payload.Count -gt 1) {
                    return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Inserted = $payload.Count } }
                }

                $destinationId = if ($payload[0].Title -eq 'A') { 'dest-record-1' } else { 'dest-record-2' }
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Id = $destinationId } }
            }
            if ($command -like 'df files upload dest-entity-1 dest-record-* Attachment --file * --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ FileName = 'attachment.png' } }
            }
            throw "Unexpected single-file import fake CLI command: $command"
        }

        $result = Import-DataFabricPackage -PackagePath $packagePath -WorkingDirectory $importDirectory -IncludeFiles -Invoker $importInvoker
        $insertCalls = @($calls | Where-Object { $_ -like 'df records insert *' })
        $uploadCalls = @($calls | Where-Object { $_ -like 'df files upload *' })
        $report = Get-Content -LiteralPath $result.reportPath -Raw | ConvertFrom-Json
        $mappedRecordCount = @($report.insertedRecords | Where-Object { -not [string]::IsNullOrWhiteSpace($_.destinationRecordId) }).Count

        Assert-Equal $insertCalls.Count 2 'Attachment-bearing records should be inserted one at a time to capture destination IDs.'
        Assert-Equal $mappedRecordCount 2 'Single-record inserts should populate destination record IDs in the import report.'
        Assert-Equal $uploadCalls.Count 2 'Each attachment should be uploaded to its mapped destination record.'
        Assert-Equal $result.uploadedFileCount 2 'Both exported attachments should be uploaded after single-record insert mapping.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

Run-Test 'Import-DataFabricPackage infers extension for legacy extensionless attachment package' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-import-legacy-file-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $packagePath = Join-Path $tempRoot 'migration-package.zip'
        $exportDirectory = Join-Path $tempRoot 'package'
        $importDirectory = Join-Path $tempRoot 'import'
        $pngBytes = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52)

        $exportInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            if ($command -eq 'login status --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Status = 'Logged in' } }
            }
            if ($command -eq 'df entities list --native-only --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = @([pscustomobject]@{ Name = 'Invoice'; DisplayName = 'Invoice'; ID = 'entity-1'; Type = 'Entity'; Source = 'Native' })
                }
            }
            if ($command -eq 'df entities get entity-1 --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = $schema }
            }
            if ($command -eq 'df records list entity-1 --limit 100 --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = [pscustomobject]@{
                        Records = @([pscustomobject]@{ Id = 'source-1'; Title = 'A'; Amount = 25; Attachment = 'file-token-without-extension'; Parent = $null })
                        HasNextPage = $false
                    }
                }
            }
            if ($command -like 'df files download entity-1 source-1 Attachment --destination * --output json') {
                $destinationIndex = [Array]::IndexOf($Arguments, '--destination') + 1
                [System.IO.File]::WriteAllBytes($Arguments[$destinationIndex], $pngBytes)
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ OutputPath = $Arguments[$destinationIndex] } }
            }
            throw "Unexpected legacy import export fake CLI command: $command"
        }

        [void](Export-DataFabricPackage -PackagePath $packagePath -WorkingDirectory $exportDirectory -IncludeFiles -Invoker $exportInvoker)

        $manifestPath = Join-Path $exportDirectory 'manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $attachment = @($manifest.attachments)[0]
        $extensionPath = Join-Path $exportDirectory $attachment.path
        $extensionlessRelativePath = $attachment.path -replace '\.png$', ''
        $extensionlessPath = Join-Path $exportDirectory $extensionlessRelativePath
        Move-Item -LiteralPath $extensionPath -Destination $extensionlessPath
        $manifest.attachments[0].path = $extensionlessRelativePath
        $manifest | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        [void](New-DataFabricPackageChecksums -PackageDirectory $exportDirectory)
        Compress-Archive -Path (Join-Path $exportDirectory '*') -DestinationPath $packagePath -Force

        $calls = [System.Collections.Generic.List[string]]::new()
        $importInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            $calls.Add($command)
            if ($command -eq 'login status --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Status = 'Logged in' } }
            }
            if ($command -eq 'df entities list --native-only --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = @() }
            }
            if ($command -like 'df entities create Invoice --file * --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Name = 'Invoice'; ID = 'dest-entity-1' } }
            }
            if ($command -like 'df records insert dest-entity-1 --file * --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = @('dest-record-1') }
            }
            if ($command -like 'df files upload dest-entity-1 dest-record-1 Attachment --file * --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ FileName = 'file-token-without-extension.png' } }
            }
            throw "Unexpected legacy import fake CLI command: $command"
        }

        $result = Import-DataFabricPackage -PackagePath $packagePath -WorkingDirectory $importDirectory -IncludeFiles -Invoker $importInvoker
        $uploadCalls = @($calls | Where-Object { $_ -like 'df files upload *' })

        Assert-Equal $result.uploadedFileCount 1 'Legacy extensionless attachments should still be uploaded.'
        Assert-True ($uploadCalls[0] -match '\.png --output json$') 'Legacy extensionless package files should be renamed before upload.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

Run-Test 'Import-DataFabricPackage logs in with client credentials before destination writes' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('df-migration-import-auth-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        $packagePath = Join-Path $tempRoot 'migration-package.zip'
        $exportDirectory = Join-Path $tempRoot 'package'
        $importDirectory = Join-Path $tempRoot 'import'

        $exportInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            if ($command -eq 'login status --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Status = 'Logged in' } }
            }
            if ($command -eq 'df entities list --native-only --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = @([pscustomobject]@{ Name = 'Invoice'; DisplayName = 'Invoice'; ID = 'entity-1'; Type = 'Entity'; Source = 'Native' })
                }
            }
            if ($command -eq 'df entities get entity-1 --output json') {
                return [pscustomobject]@{ Result = 'Success'; Data = $schema }
            }
            if ($command -eq 'df records list entity-1 --limit 100 --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = [pscustomobject]@{
                        Records = @([pscustomobject]@{ Id = 'source-1'; Title = 'A'; Amount = 25; Attachment = $null; Parent = $null })
                        HasNextPage = $false
                    }
                }
            }
            throw "Unexpected export fake CLI command: $command"
        }

        [void](Export-DataFabricPackage -PackagePath $packagePath -WorkingDirectory $exportDirectory -Invoker $exportInvoker)

        $calls = [System.Collections.Generic.List[string]]::new()
        $importInvoker = {
            param([string[]]$Arguments)

            $command = $Arguments -join ' '
            $calls.Add($command)
            if ($command -eq 'login --client-id import-client --client-secret import-secret --organization DestOrg --tenant DestTenant --output json') {
                return [pscustomobject]@{
                    Result = 'Success'
                    Data = [pscustomobject]@{ Status = 'Logged in'; Organization = 'DestOrg'; Tenant = 'DestTenant' }
                }
            }
            if ($command -eq 'df entities list --native-only --output json --tenant DestTenant') {
                return [pscustomobject]@{ Result = 'Success'; Data = @() }
            }
            if ($command -like 'df entities create Invoice --file * --output json --tenant DestTenant') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Name = 'Invoice'; ID = 'dest-entity-1' } }
            }
            if ($command -like 'df records insert dest-entity-1 --file * --output json --tenant DestTenant') {
                return [pscustomobject]@{ Result = 'Success'; Data = [pscustomobject]@{ Id = 'dest-record-1'; Title = 'A' } }
            }
            throw "Unexpected import auth fake CLI command: $command"
        }

        [void](Import-DataFabricPackage -PackagePath $packagePath -WorkingDirectory $importDirectory -Tenant DestTenant -Organization DestOrg -ClientId import-client -ClientSecret import-secret -Invoker $importInvoker)
        Assert-Equal $calls[0] 'login --client-id import-client --client-secret import-secret --organization DestOrg --tenant DestTenant --output json' 'Import should log in with destination client credentials before Data Fabric writes.'
        Assert-True ($calls[1] -match '^df entities list') 'Import should read destination entities only after logging in.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

if ($script:Failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'Failures:'
    $script:Failures | ConvertTo-Json -Depth 5 | Write-Host
    exit 1
}

Write-Host ''
Write-Host 'All Data Fabric migration tests passed.'
