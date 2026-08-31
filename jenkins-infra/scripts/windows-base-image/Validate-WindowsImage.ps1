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

if (-not (Test-Path $source)) {
    throw "WIM not found: $source"
}

Write-Host "Validating WIM metadata..."

& dism.exe `
    /Get-WimInfo `
    /WimFile:$source

if ($LASTEXITCODE -ne 0) {
    throw "Get-WimInfo failed."
}

Write-Host "Validating WIM integrity..."

& dism.exe `
    /Check-Integrity `
    /ImageFile:$source

if ($LASTEXITCODE -ne 0) {
    throw "WIM integrity check failed."
}

New-Item `
    $config.build.outputPath `
    -ItemType Directory `
    -Force | Out-Null

$info =
    & dism.exe `
        /Get-WimInfo `
        /WimFile:$source 2>&1

$info |
    Set-Content `
        (Join-Path `
            $config.build.outputPath `
            "wim-info.txt") `
        -Encoding UTF8

Write-Host "WIM validation passed."
