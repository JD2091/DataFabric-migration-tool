[CmdletBinding()]
param(
    [string]$PackagePath = '',

    [string]$Tenant = '',

    [string]$Organization = '',

    [string]$ClientId = '',

    [string]$ClientSecret = '',

    [string[]]$EntityName = @(),

    [int]$PageSize = 100,

    [string]$WorkingDirectory = '',

    [switch]$IncludeFiles = $false
)

# Advanced wrapper for automation scenarios that only need the export phase.
# The root runner remains the preferred interactive entrypoint.
$projectRoot = Split-Path -Parent $PSScriptRoot

# Resolve the reusable migration module from the organized project layout.
$modulePath = Join-Path $projectRoot 'src\DataFabricMigration.psm1'
Import-Module $modulePath -Force

# Build the splatted argument set so optional credentials/files are only passed when supplied.
$arguments = @{
    PackagePath = $PackagePath
    PageSize = $PageSize
}

if ($Tenant) {
    $arguments.Tenant = $Tenant
}
if ($Organization) {
    $arguments.Organization = $Organization
}
if ($ClientId) {
    $arguments.ClientId = $ClientId
}
if ($ClientSecret) {
    $arguments.ClientSecret = $ClientSecret
}
if ($EntityName) {
    $arguments.EntityName = $EntityName
}
if ($WorkingDirectory) {
    $arguments.WorkingDirectory = $WorkingDirectory
}
if ($IncludeFiles) {
    $arguments.IncludeFiles = $true
}

# Emit machine-readable JSON for scripts or CI jobs that consume this wrapper.
Export-DataFabricPackage @arguments | ConvertTo-Json -Depth 20
