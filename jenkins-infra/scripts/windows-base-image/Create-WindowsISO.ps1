[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfigFile,
    [string]$OscdimgPath = $env:OSCDIMG_PATH
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$config =
    Get-Content $ConfigFile -Raw |
    ConvertFrom-Json

if (-not $OscdimgPath) {

    $OscdimgPath =
        "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
}

if (-not (Test-Path $OscdimgPath)) {
    throw "oscdimg.exe not found."
}

if (-not $config.isoMediaPath) {
    throw "isoMediaPath must point to complete Windows installation media."
}

$wim =
    Join-Path `
        $config.build.sourcePath `
        $config.image.name

if (-not $wim.EndsWith(".wim")) {
    $wim += ".wim"
}

$stage =
    Join-Path `
        $config.build.workspace `
        "iso"

$output =
    $config.build.outputPath

if (Test-Path $stage) {
    Remove-Item `
        $stage `
        -Recurse `
        -Force
}

New-Item `
    "$stage\sources" `
    -ItemType Directory `
    -Force | Out-Null

Copy-Item `
    "$($config.isoMediaPath)\*" `
    $stage `
    -Recurse `
    -Force

Copy-Item `
    $wim `
    "$stage\sources\install.wim" `
    -Force

$iso =
    Join-Path `
        $output `
        "$($config.image.name).iso"

& $OscdimgPath `
    -m `
    -o `
    -u2 `
    -udfver102 `
    $stage `
    $iso

if ($LASTEXITCODE -ne 0) {
    throw "oscdimg failed."
}

Write-Host "Created ISO: $iso"
