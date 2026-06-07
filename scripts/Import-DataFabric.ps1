[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PackagePath = '',

    [string]$Tenant = '',

    [string]$Organization = '',

    [string]$URL = '',

    [string]$WorkingDirectory = '',

    [int]$BatchSize = 50,

    [switch]$IncludeFiles = $false,

    [switch]$ImportRelationships = $false
)

# Advanced wrapper for automation scenarios that only need the import phase.
# The root runner remains the preferred interactive entrypoint.
$projectRoot = Split-Path -Parent $PSScriptRoot

# Resolve the reusable migration module from the organized project layout.
$modulePath = Join-Path $projectRoot 'src\DataFabricMigration.psm1'
Import-Module $modulePath -Force

# Build the splatted argument set so optional credentials/features are only passed when supplied.
$arguments = @{
    PackagePath = $PackagePath
    BatchSize = $BatchSize
}

if ($Tenant) {
    $arguments.Tenant = $Tenant
}
if ($Organization) {
    $arguments.Organization = $Organization
}
if ($URL) {
    $arguments.URL = $URL
}
if ($WorkingDirectory) {
    $arguments.WorkingDirectory = $WorkingDirectory
}
if ($IncludeFiles) {
    $arguments.IncludeFiles = $true
}
if ($ImportRelationships) {
    $arguments.ImportRelationships = $true
}
if ($WhatIfPreference) {
    $arguments.WhatIf = $true
}

# Emit machine-readable JSON for scripts or CI jobs that consume this wrapper.
Import-DataFabricPackage @arguments | ConvertTo-Json -Depth 20
