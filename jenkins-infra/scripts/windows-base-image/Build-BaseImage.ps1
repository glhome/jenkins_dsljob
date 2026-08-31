[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfigFile,
    [switch]$InitializeOnly,
    [switch]$DownloadBaseImage,
    [switch]$Inspect
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

foreach ($d in @(
    $config.build.workspace,
    $config.build.sourcePath,
    $config.build.mountPath,
    $config.build.updatesPath,
    $config.build.outputPath
)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

$wim = Join-Path $config.build.sourcePath $config.image.name
if (-not $wim.EndsWith(".wim")) {
    $wim += ".wim"
}

if ($InitializeOnly) {
    Write-Host "Workspace initialized: $($config.build.workspace)"
    exit 0
}

if ($DownloadBaseImage) {
    $jfrog = if ($env:JFROG_CLI) { $env:JFROG_CLI } else { "jfrog" }
    $src = "$($config.artifactory.sourceRepository)/$($config.artifactory.sourcePath)"

    if (Test-Path $wim) {
        Remove-Item $wim -Force
    }

    Write-Host "Downloading $src"

    & $jfrog rt download `
        $src `
        $wim `
        --flat=true `
        --fail-no-op=true `
        --detailed-summary

    if ($LASTEXITCODE -ne 0) {
        throw "JFrog download failed."
    }
}

if ($Inspect) {
    if (-not (Test-Path $wim)) {
        throw "Base WIM not found: $wim"
    }

    & dism.exe /Get-WimInfo /WimFile:$wim

    if ($LASTEXITCODE -ne 0) {
        throw "DISM inspection failed."
    }

    exit 0
}

if (-not (Test-Path $wim)) {
    throw "Base WIM not found: $wim"
}

Write-Host "Base WIM ready: $wim"
