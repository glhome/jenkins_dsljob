[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [Parameter(Mandatory = $false)]
    [int]$ImageIndex = 1
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Service Windows Image
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Service Windows Image"
Write-Host "============================================================"

# ------------------------------------------------------------
# Normalize paths
# ------------------------------------------------------------

$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)

$SourceDir   = Join-Path $WorkRoot 'source'
$MountDir    = Join-Path $WorkRoot 'mount\install'
$DownloadDir = Join-Path $WorkRoot 'download'
$UpdatesDir  = Join-Path $DownloadDir 'updates'
$ResolvedFile = Join-Path $DownloadDir 'resolved-updates.json'
$WimFile     = Join-Path $SourceDir 'sources\install.wim'

Write-Host "WorkRoot:"
Write-Host "  $WorkRoot"

Write-Host "WIM:"
Write-Host "  $WimFile"

Write-Host "Mount:"
Write-Host "  $MountDir"

Write-Host "Updates:"
Write-Host "  $UpdatesDir"

Write-Host "Manifest:"
Write-Host "  $ResolvedFile"

Write-Host "============================================================"

# ------------------------------------------------------------
# Administrator check
# ------------------------------------------------------------

$currentIdentity =
    [Security.Principal.WindowsIdentity]::GetCurrent()

$currentPrincipal =
    New-Object Security.Principal.WindowsPrincipal($currentIdentity)

$isAdmin =
    $currentPrincipal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )

Write-Host ""
Write-Host "Running as:"
Write-Host "  $($currentIdentity.Name)"

if (-not $isAdmin) {
    throw "DISM servicing requires Administrator privileges."
}

# ------------------------------------------------------------
# Validate files/directories
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $WimFile)) {
    throw "install.wim not found: $WimFile"
}

if (-not (Test-Path -LiteralPath $UpdatesDir)) {
    throw "Updates directory not found: $UpdatesDir"
}

if (-not (Test-Path -LiteralPath $ResolvedFile)) {
    throw "resolved-updates.json not found: $ResolvedFile"
}

New-Item `
    -ItemType Directory `
    -Force `
    -Path $MountDir | Out-Null

# ------------------------------------------------------------
# DISM helper
# ------------------------------------------------------------

$DismExe = "$env:SystemRoot\System32\dism.exe"

function Invoke-DismCommand {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Host ""
    Write-Host "------------------------------------------------------------"
    Write-Host "DISM: $Operation"
    Write-Host "------------------------------------------------------------"

    Write-Host "Command:"
    Write-Host "  $DismExe"

    foreach ($arg in $Arguments) {
        Write-Host "  $arg"
    }

    & $DismExe @Arguments

    if ($LASTEXITCODE -ne 0) {

        $exitCode = $LASTEXITCODE

        throw `
            "DISM operation '$Operation' failed with exit code $exitCode."
    }

    Write-Host ""
    Write-Host "DISM operation completed successfully."
}

# ------------------------------------------------------------
# Check existing mounts
# ------------------------------------------------------------

Write-Host ""
Write-Host "Checking for existing DISM mounts..."

$dismInfo = & $DismExe /English /Get-MountedWimInfo 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Unable to query mounted WIM information."
}

$dismText = $dismInfo -join "`n"

Write-Host $dismText

# ------------------------------------------------------------
# If this workspace is already mounted, clean it
# ------------------------------------------------------------

if ($dismText -match [regex]::Escape($MountDir)) {

    Write-Host ""
    Write-Host "Existing mount found for current WorkRoot:"
    Write-Host "  $MountDir"

    Write-Host ""
    Write-Host "Discarding existing mount to guarantee a clean servicing operation..."

    & $DismExe `
        /Unmount-Wim `
        /MountDir:$MountDir `
        /Discard

    if ($LASTEXITCODE -ne 0) {

        Write-Warning "Unmount /Discard failed."

        & $DismExe /Cleanup-Wim

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to clean existing WIM mount."
        }
    }
}

# ------------------------------------------------------------
# Final cleanup
# ------------------------------------------------------------

& $DismExe /Cleanup-Wim

if ($LASTEXITCODE -ne 0) {
    throw "DISM cleanup failed."
}

# ------------------------------------------------------------
# Load update manifest
# ------------------------------------------------------------

Write-Host ""
Write-Host "Loading update manifest..."

$manifest = Get-Content `
    -LiteralPath $ResolvedFile `
    -Raw |
    ConvertFrom-Json

if (-not $manifest) {
    throw "Update manifest is empty."
}

$updates = @($manifest.updates)

if ($updates.Count -eq 0) {
    throw "No updates found in resolved-updates.json."
}

Write-Host ""
Write-Host "Updates selected:"
foreach ($update in $updates) {
    Write-Host "  KB:       $($update.kb)"
    Write-Host "  Build:    $($update.build)"
    Write-Host "  File:     $($update.fileName)"
    Write-Host "  SHA256:   $($update.sha256)"
    Write-Host "  SSU incl: $($update.ssuIncluded)"
    Write-Host ""
}

# ------------------------------------------------------------
# Verify package files and hashes BEFORE mounting
# ------------------------------------------------------------

foreach ($update in $updates) {

    if (-not $update.fileName) {
        throw "Update manifest contains an update without fileName."
    }

    if (-not $update.kb) {
        throw "Update manifest contains an update without KB."
    }

    $packagePath =
        Join-Path $UpdatesDir $update.fileName

    if (-not (Test-Path -LiteralPath $packagePath)) {
        throw "Update package not found: $packagePath"
    }

    $actualHash =
        (Get-FileHash `
            -LiteralPath $packagePath `
            -Algorithm SHA256).Hash.ToLowerInvariant()

    $expectedHash =
        ([string]$update.sha256).ToLowerInvariant()

    if ($expectedHash -and $actualHash -ne $expectedHash) {

        throw @"
SHA256 mismatch for $($update.kb)

File:
  $packagePath

Expected:
  $expectedHash

Actual:
  $actualHash
"@
    }

    Write-Host "Verified:"
    Write-Host "  $($update.kb)"
    Write-Host "  $($update.fileName)"
}

# ------------------------------------------------------------
# Mount WIM
# ------------------------------------------------------------

$mountArgs = @(
    "/Mount-Wim"
    "/WimFile:$WimFile"
    "/Index:$ImageIndex"
    "/MountDir:$MountDir"
)

Invoke-DismCommand `
    -Operation "Mount WIM" `
    -Arguments $mountArgs

# ------------------------------------------------------------
# Apply updates
# ------------------------------------------------------------

$mountSuccessful = $true

try {

    foreach ($update in $updates) {

        $packagePath =
            Join-Path $UpdatesDir $update.fileName

        Write-Host ""
        Write-Host "============================================================"
        Write-Host " Applying update"
        Write-Host "============================================================"
        Write-Host "KB:"
        Write-Host "  $($update.kb)"
        Write-Host "Build:"
        Write-Host "  $($update.build)"
        Write-Host "Package:"
        Write-Host "  $packagePath"
        Write-Host "============================================================"

        # IMPORTANT:
        # /Image:<path> MUST be one argument.
        # /PackagePath:<path> MUST be one argument.

        $packageArgs = @(
            "/Image:$MountDir"
            "/Add-Package"
            "/PackagePath:$packagePath"
            "/NoRestart"
        )

        Invoke-DismCommand `
            -Operation "Apply $($update.kb)" `
            -Arguments $packageArgs
    }

    # --------------------------------------------------------
    # Component cleanup
    # --------------------------------------------------------

    $cleanupArgs = @(
        "/Image:$MountDir"
        "/Cleanup-Image"
        "/StartComponentCleanup"
    )

    Invoke-DismCommand `
        -Operation "Component Cleanup" `
        -Arguments $cleanupArgs

    # --------------------------------------------------------
    # Commit
    # --------------------------------------------------------

    $commitArgs = @(
        "/Unmount-Wim"
        "/MountDir:$MountDir"
        "/Commit"
    )

    Invoke-DismCommand `
        -Operation "Commit WIM" `
        -Arguments $commitArgs

    $mountSuccessful = $false
}
catch {

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " Servicing failed"
    Write-Host "============================================================"

    Write-Host $_

    Write-Host ""
    Write-Host "Attempting to discard mounted WIM..."

    & $DismExe `
        /Unmount-Wim `
        /MountDir:$MountDir `
        /Discard

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Unable to discard mounted WIM."
    }

    & $DismExe /Cleanup-Wim

    throw
}

# ------------------------------------------------------------
# Final validation
# ------------------------------------------------------------

if ($mountSuccessful) {
    throw "WIM still appears to be mounted after servicing."
}

Write-Host ""
Write-Host "Verifying final WIM..."

if (-not (Test-Path -LiteralPath $WimFile)) {
    throw "Final install.wim does not exist."
}

$wimHash =
    Get-FileHash `
        -LiteralPath $WimFile `
        -Algorithm SHA256

$wimSize =
    (Get-Item -LiteralPath $WimFile).Length

Write-Host ""
Write-Host "============================================================"
Write-Host " Windows Image Servicing Complete"
Write-Host "============================================================"
Write-Host "WIM:"
Write-Host "  $WimFile"
Write-Host ""
Write-Host "Size:"
Write-Host "  $wimSize bytes"
Write-Host ""
Write-Host "SHA256:"
Write-Host "  $($wimHash.Hash)"
Write-Host "============================================================"