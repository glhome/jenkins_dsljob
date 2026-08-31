[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfigFile
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$config =
    Get-Content $ConfigFile -Raw |
    ConvertFrom-Json

$source =
    Join-Path `
        $config.build.sourcePath `
        $config.image.name

if (-not $source.EndsWith(".wim")) {
    $source += ".wim"
}

$output =
    $config.build.outputPath

New-Item `
    $output `
    -ItemType Directory `
    -Force | Out-Null

$version =
    "$(Get-Date -Format yyyy.MM.dd)-$env:BUILD_NUMBER"

$wimName =
    "$($config.image.name)-$version.wim"

Copy-Item `
    $source `
    (Join-Path $output $wimName) `
    -Force

Get-ChildItem `
    $output `
    -File |
    Where-Object {
        $_.Extension -ne ".sha256"
    } |
    ForEach-Object {

        $hash =
            Get-FileHash `
                $_.FullName `
                -Algorithm SHA256

        "$($hash.Hash) *$($_.Name)" |
            Set-Content `
                "$($_.FullName).sha256" `
                -Encoding ASCII
    }

$jfrog =
    if ($env:JFROG_CLI) {
        $env:JFROG_CLI
    }
    else {
        "jfrog"
    }

$destination =
    "$($config.artifactory.destinationRepository)/$($config.artifactory.destinationPath)/$version/"

Write-Host "Publishing to $destination"

& $jfrog rt upload `
    "$output\*" `
    $destination `
    --flat=true `
    --detailed-summary

if ($LASTEXITCODE -ne 0) {
    throw "JFrog upload failed."
}

Write-Host "Published base image version $version"
