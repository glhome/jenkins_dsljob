[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfigFile
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$config =
    Get-Content $ConfigFile -Raw |
    ConvertFrom-Json

$wim =
    Join-Path `
        $config.build.sourcePath `
        $config.image.name

if (-not $wim.EndsWith(".wim")) {
    $wim += ".wim"
}

$output =
    $config.build.outputPath

New-Item `
    $output `
    -ItemType Directory `
    -Force | Out-Null

$hash =
    (Get-FileHash `
        $wim `
        -Algorithm SHA256).Hash

$manifest = [ordered]@{

    schemaVersion = 1

    imageName =
        $config.image.name

    os =
        $config.image.os

    release =
        $config.image.release

    architecture =
        $config.image.architecture

    sourceWim =
        $config.artifactory.sourcePath

    updatedWimSha256 =
        $hash

    jenkinsBuild =
        $env:BUILD_NUMBER

    gitCommit =
        $env:GIT_COMMIT

    generatedUtc =
        (Get-Date).ToUniversalTime().ToString("o")
}

$manifest |
    ConvertTo-Json -Depth 10 |
    Set-Content `
        (Join-Path `
            $output `
            "build-manifest.json") `
        -Encoding UTF8

Write-Host "Generated build-manifest.json"
