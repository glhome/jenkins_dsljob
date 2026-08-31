[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfigFile
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$config =
    Get-Content $ConfigFile -Raw |
    ConvertFrom-Json

$output =
    $config.build.outputPath

New-Item `
    $output `
    -ItemType Directory `
    -Force | Out-Null

$input =
    Join-Path `
        $config.build.updatesPath `
        "download-manifest.json"

if (-not (Test-Path $input)) {
    throw "download-manifest.json missing."
}

$updates =
    @(
        Get-Content $input -Raw |
        ConvertFrom-Json
    )

$manifest = [ordered]@{

    schemaVersion = 1

    image =
        $config.image

    generatedUtc =
        (Get-Date).ToUniversalTime().ToString("o")

    updates =
        $updates
}

$manifest |
    ConvertTo-Json -Depth 10 |
    Set-Content `
        (Join-Path `
            $output `
            "update-manifest.json") `
        -Encoding UTF8

Write-Host "Generated update-manifest.json"
