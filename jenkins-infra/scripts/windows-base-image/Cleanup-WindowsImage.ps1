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

$mounted = $false

& dism.exe `
    /Mount-Wim `
    /WimFile:$source `
    /Index:1 `
    /MountDir:$mount

if ($LASTEXITCODE -ne 0) {
    throw "DISM mount failed."
}

$mounted = $true

try {

    & dism.exe `
        /Image:$mount `
        /Cleanup-Image `
        /StartComponentCleanup

    if ($LASTEXITCODE -ne 0) {
        throw "Component cleanup failed."
    }

    & dism.exe `
        /Image:$mount `
        /Cleanup-Image `
        /CheckHealth

    if ($LASTEXITCODE -ne 0) {
        throw "Image health check failed."
    }
}
finally {

    if ($mounted) {

        & dism.exe `
            /Unmount-Wim `
            /MountDir:$mount `
            /Commit

        if ($LASTEXITCODE -ne 0) {
            throw "Commit failed."
        }
    }
}

Write-Host "Windows image cleanup completed."
