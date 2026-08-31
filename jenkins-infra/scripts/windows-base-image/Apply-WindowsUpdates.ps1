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

$mount =
    $config.build.mountPath

$updates =
    $config.build.updatesPath

New-Item `
    -Path $mount `
    -ItemType Directory `
    -Force | Out-Null

& dism.exe `
    /Mount-Wim `
    /WimFile:$source `
    /Index:1 `
    /MountDir:$mount

if ($LASTEXITCODE -ne 0) {
    throw "DISM mount failed."
}

try {

    $manifest =
        Join-Path `
            $updates `
            "download-manifest.json"

    if (-not (Test-Path $manifest)) {
        throw "download-manifest.json missing."
    }

    $packages =
        Get-Content `
            $manifest `
            -Raw |
        ConvertFrom-Json

    foreach ($u in $packages) {

        $packagePath =
            Join-Path `
                $updates `
                $u.package

        if (-not (Test-Path $packagePath)) {
            throw "Missing package: $packagePath"
        }

        Write-Host `
            "Applying $($u.kb) [$($u.type)]"

        & dism.exe `
            /Image:$mount `
            /Add-Package `
            /PackagePath:$packagePath `
            /NoRestart

        if ($LASTEXITCODE -ne 0) {
            throw "Failed applying $($u.kb)."
        }
    }

    & dism.exe `
        /Image:$mount `
        /Get-Packages

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to enumerate installed packages."
    }
}
finally {

    $mountedInfo =
        (& dism.exe /Get-MountedWimInfo 2>&1) `
        -join "`n"

    if ($mountedInfo -match [regex]::Escape($mount)) {

        & dism.exe `
            /Unmount-Wim `
            /MountDir:$mount `
            /Commit

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to commit WIM."
        }
    }
}
