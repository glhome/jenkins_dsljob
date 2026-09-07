[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryUrl,

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
$buildMap     = Convert-ToHashtable $config.buildFiles


if (-not (Test-Path -LiteralPath $RepositoryPath -PathType Container)) {
    throw "Repository path does not exist: $RepositoryPath"
}


$repositoryPath = (Resolve-Path -LiteralPath $RepositoryPath).Path


# Get repository name from the Git URL
$repositoryName = $RepositoryUrl `
    -replace '\\.git$', '' `
    -replace '.*/', ''


Write-Host "========================================"
Write-Host "Repository Scan"
Write-Host "========================================"
Write-Host "Repository : $repositoryName"
Write-Host "URL        : $RepositoryUrl"
Write-Host "Path       : $repositoryPath"
Write-Host "========================================"


$languages = & `
    (Join-Path $PSScriptRoot 'detect-language.ps1') `
    -RepositoryPath $repositoryPath `
    -ExtensionMap $extensionMap


$buildSystems = & `
    (Join-Path $PSScriptRoot 'detect-build-system.ps1') `
    -RepositoryPath $repositoryPath `
    -BuildMap $buildMap


$ci = @()


if (Test-Path (Join-Path $repositoryPath 'Jenkinsfile')) {
    $ci += 'Jenkins'
}


if (Test-Path (Join-Path $repositoryPath 'bitbucket-pipelines.yml')) {
    $ci += 'Bitbucket Pipelines'
}


if (Test-Path (Join-Path $repositoryPath '.github/workflows')) {
    $ci += 'GitHub Actions'
}


$result = [ordered]@{
    repository   = $repositoryName
    repositoryUrl = $RepositoryUrl
    branch       = $env:REPOSITORY_BRANCH
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


$json = $result |
    ConvertTo-Json -Depth 10


Set-Content `
    -LiteralPath $OutputFile `
    -Value $json `
    -Encoding UTF8


Write-Host ""
Write-Host "Target repository: $repositoryName"
Write-Host "Results: $OutputFile"