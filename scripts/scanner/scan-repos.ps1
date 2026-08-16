[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,

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

if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
    throw "Repository root does not exist: $RepositoryRoot"
}

$repositories = Get-ChildItem `
    -LiteralPath $RepositoryRoot `
    -Directory |
Where-Object {
    $_.Name -notin @(
        '.git',
        'node_modules',
        'build',
        'out'
    )
}

$results = @()

foreach ($repo in $repositories) {

    Write-Host "Scanning: $($repo.Name)"

    $languages = & `
        (Join-Path $PSScriptRoot 'detect-language.ps1') `
        -RepositoryPath $repo.FullName `
        -ExtensionMap $extensionMap

    $buildSystems = & `
        (Join-Path $PSScriptRoot 'detect-build-system.ps1') `
        -RepositoryPath $repo.FullName `
        -BuildMap $buildMap

    $ci = @()

    if (Test-Path (Join-Path $repo.FullName 'Jenkinsfile')) {
        $ci += 'Jenkins'
    }

    if (Test-Path (Join-Path $repo.FullName 'bitbucket-pipelines.yml')) {
        $ci += 'Bitbucket Pipelines'
    }

    if (Test-Path (Join-Path $repo.FullName '.github/workflows')) {
        $ci += 'GitHub Actions'
    }

    $results += [ordered]@{
        repository  = $repo.Name
        path        = $repo.FullName
        languages   = $languages
        buildSystems = @(
            $buildSystems |
            Sort-Object -Unique
        )
        ci          = @(
            $ci |
            Sort-Object -Unique
        )
        scannedAt   = (Get-Date).ToString('o')
    }
}

$json = $results |
    ConvertTo-Json -Depth 10

Set-Content `
    -LiteralPath $OutputFile `
    -Value $json `
    -Encoding UTF8

Write-Host ''
Write-Host "Repositories scanned: $($results.Count)"
Write-Host "Results: $OutputFile"