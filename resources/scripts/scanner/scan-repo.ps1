[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath,

    [string]$OutputFile = 'repo-scan-results.json'
)

$ErrorActionPreference = 'Stop'

$configPath = Join-Path $PSScriptRoot 'config.json'

$config = Get-Content `
    -LiteralPath $configPath `
    -Raw |
    ConvertFrom-Json

function Convert-ToHashtable {
    param(
        [Parameter(Mandatory = $true)]
        $Object
    )

    $table = @{}

    foreach ($property in $Object.PSObject.Properties) {

        $values = @(
            $property.Value |
            ForEach-Object {
                [string]$_
            }
        )

        $table[$property.Name] = $values
    }

    return $table
}

$extensionMap = Convert-ToHashtable $config.sourceExtensions
$buildMap = Convert-ToHashtable $config.buildFiles

# ---------------------------------------------------------
# Validate repository
# ---------------------------------------------------------

if (-not (Test-Path -LiteralPath $RepositoryPath -PathType Container)) {
    throw "Repository path does not exist: $RepositoryPath"
}

$repositoryPath = (Resolve-Path -LiteralPath $RepositoryPath).Path

$repositoryName = Split-Path `
    -Path $repositoryPath `
    -Leaf

Write-Host "========================================"
Write-Host "Repository Scanner"
Write-Host "========================================"
Write-Host "Repository : $repositoryName"
Write-Host "Path       : $repositoryPath"
Write-Host "========================================"

# ---------------------------------------------------------
# Detect languages
# ---------------------------------------------------------

Write-Host ""
Write-Host "Detecting languages..."

$languages = & `
    (Join-Path $PSScriptRoot 'detect-language.ps1') `
    -RepositoryPath $repositoryPath `
    -ExtensionMap $extensionMap

# ---------------------------------------------------------
# Detect build systems
# ---------------------------------------------------------

Write-Host ""
Write-Host "Detecting build systems..."

$buildSystems = & `
    (Join-Path $PSScriptRoot 'detect-build-system.ps1') `
    -RepositoryPath $repositoryPath `
    -BuildMap $buildMap

# ---------------------------------------------------------
# Detect CI systems
# ---------------------------------------------------------

$ci = @()

if (Test-Path -LiteralPath (Join-Path $repositoryPath 'Jenkinsfile')) {
    $ci += 'Jenkins'
}

if (Test-Path -LiteralPath (Join-Path $repositoryPath 'bitbucket-pipelines.yml')) {
    $ci += 'Bitbucket Pipelines'
}

if (Test-Path -LiteralPath (Join-Path $repositoryPath '.github/workflows')) {
    $ci += 'GitHub Actions'
}

# ---------------------------------------------------------
# Build result
# ---------------------------------------------------------

$result = [ordered]@{
    repository   = $repositoryName
    path         = $repositoryPath

    languages    = @(
        $languages |
        Sort-Object -Unique
    )

    buildSystems = @(
        $buildSystems |
        Sort-Object -Unique
    )

    ci           = @(
        $ci |
        Sort-Object -Unique
    )

    scannedAt    = (Get-Date).ToString('o')
}

# ---------------------------------------------------------
# Write JSON
# ---------------------------------------------------------

$json = $result |
    ConvertTo-Json -Depth 10

Set-Content `
    -LiteralPath $OutputFile `
    -Value $json `
    -Encoding UTF8

Write-Host ""
Write-Host "========================================"
Write-Host "Scan complete"
Write-Host "========================================"
Write-Host "Repository : $repositoryName"
Write-Host "Languages  : $($result.languages -join ', ')"
Write-Host "Build      : $($result.buildSystems -join ', ')"
Write-Host "CI         : $($result.ci -join ', ')"
Write-Host "Results    : $OutputFile"
Write-Host "========================================"