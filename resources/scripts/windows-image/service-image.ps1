[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [int]$ImageIndex = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)

$SourceDir   = Join-Path $WorkRoot 'source'
$MountDir    = Join-Path $WorkRoot 'mount\install'
$DownloadDir = Join-Path $WorkRoot 'download'
$UpdatesDir  = Join-Path $DownloadDir 'updates'
$Resolved    = Join-Path $DownloadDir 'resolved-updates.json'
$WimFile     = Join-Path $SourceDir 'sources\install.wim'

$DismExe = "$env:SystemRoot\System32\dism.exe"

Write-Host ''
Write-Host '============================================================'
Write-Host ' Service Windows Image'
Write-Host '============================================================'
Write-Host "WorkRoot : $WorkRoot"
Write-Host "WIM      : $WimFile"
Write-Host "Mount    : $MountDir"
Write-Host "Updates  : $UpdatesDir"
Write-Host '============================================================'

# ---------------------------------------------------------------------------
# Administrator
# ---------------------------------------------------------------------------

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)

if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw 'DISM servicing requires Administrator privileges.'
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

foreach ($path in @(
    $WimFile,
    $UpdatesDir,
    $Resolved
)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required path not found: $path"
    }
}

New-Item `
    -ItemType Directory `
    -Force `
    -Path $MountDir |
    Out-Null

# ---------------------------------------------------------------------------
# DISM wrapper
# ---------------------------------------------------------------------------

function Invoke-Dism {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Host ''
    Write-Host '------------------------------------------------------------'
    Write-Host "DISM: $Operation"
    Write-Host '------------------------------------------------------------'

    Write-Host $DismExe

    foreach ($arg in $Arguments) {
        Write-Host "  $arg"
    }

    & $DismExe @Arguments

    $code = $LASTEXITCODE

    if ($code -ne 0) {
        throw "DISM operation '$Operation' failed with exit code $code."
    }

    Write-Host "DISM '$Operation' completed successfully."
}

# ---------------------------------------------------------------------------
# Cleanup stale mounts
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Checking existing WIM mounts...'

$mounted = & $DismExe /English /Get-MountedWimInfo 2>&1

if ($LASTEXITCODE -ne 0) {
    throw 'DISM /Get-MountedWimInfo failed.'
}

$mountedText = $mounted -join "`n"

Write-Host $mountedText

if ($mountedText -match [regex]::Escape($MountDir)) {

    Write-Host ''
    Write-Host 'Existing mount found for this workspace.'
    Write-Host 'Discarding it before servicing.'

    & $DismExe `
        /Unmount-Wim `
        /MountDir:$MountDir `
        /Discard

    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Unmount /Discard failed; attempting Cleanup-Wim.'

        & $DismExe /Cleanup-Wim

        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to clean stale WIM mount.'
        }
    }
}

& $DismExe /Cleanup-Wim

if ($LASTEXITCODE -ne 0) {
    throw 'DISM /Cleanup-Wim failed.'
}

# ---------------------------------------------------------------------------
# Load manifest
# ---------------------------------------------------------------------------

$manifest = Get-Content `
    -LiteralPath $Resolved `
    -Raw |
    ConvertFrom-Json

if (-not $manifest) {
    throw 'resolved-updates.json is empty.'
}

Write-Host ''
Write-Host 'Resolved update manifest:'
Write-Host ($manifest | ConvertTo-Json -Depth 20)

# ---------------------------------------------------------------------------
# Package verification
# ---------------------------------------------------------------------------

function Verify-Package {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Package,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not $Package.fileName) {
        throw "$Label package has no fileName."
    }

    if (-not $Package.kb) {
        throw "$Label package has no KB."
    }

    $path = Join-Path $UpdatesDir $Package.fileName

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "$Label package not found: $path"
    }

    $file = Get-Item -LiteralPath $path

    if ($file.Length -eq 0) {
        throw "$Label package is empty: $path"
    }

    $actual = (
        Get-FileHash `
            -LiteralPath $path `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    $expected = ([string]$Package.sha256).ToLowerInvariant()

    if (
        -not [string]::IsNullOrWhiteSpace($expected) -and
        $actual -ne $expected
    ) {
        throw @"
SHA256 mismatch for $Label.

KB:
  $($Package.kb)

File:
  $path

Expected:
  $expected

Actual:
  $actual
"@
    }

    Write-Host ''
    Write-Host "Verified ${Label}:"
    Write-Host "  KB     : $($Package.kb)"
    Write-Host "  File   : $($Package.fileName)"
    Write-Host "  SHA256 : $actual"

    return $path
}

# ---------------------------------------------------------------------------
# Determine package sequence
# ---------------------------------------------------------------------------

$sequence = @()

if (
    $manifest.profile -eq 'windows10-21h2' -and
    $manifest.ssuRequired -eq $true
) {
    if (-not $manifest.ssu) {
        throw 'Windows 10 manifest requires an SSU but no ssu object exists.'
    }

    $ssuPath = Verify-Package `
        -Package $manifest.ssu `
        -Label 'SSU'

    $sequence += [pscustomobject]@{
        Type = 'SSU'
        KB = $manifest.ssu.kb
        Path = $ssuPath
        ExpectedBuild = $manifest.ssu.build
    }

    if (-not $manifest.lcu) {
        throw 'Windows 10 manifest has no lcu object.'
    }

    $lcuPath = Verify-Package `
        -Package $manifest.lcu `
        -Label 'LCU'

    $sequence += [pscustomobject]@{
        Type = 'LCU'
        KB = $manifest.lcu.kb
        Path = $lcuPath
        ExpectedBuild = $manifest.lcu.build
    }
}
else {
    if (-not $manifest.lcu) {
        throw 'Windows 11 manifest has no lcu object.'
    }

    if (
        -not $manifest.lcu.packages -or
        @($manifest.lcu.packages).Count -eq 0
    ) {
        throw 'Windows 11 manifest has no LCU package set.'
    }

    # The resolver determines the prerequisite/checkpoint set from the
    # target LCU's Microsoft Update Catalog UpdateID.
    #
    # All resolved packages must already exist in download\updates.
    $allPackages = @($manifest.lcu.packages)

    $targetPackages = @(
        $allPackages |
            Where-Object {
                ([string]$_.type).ToLowerInvariant() -eq 'target'
            }
    )

    $checkpointPackages = @(
        $allPackages |
            Where-Object {
                ([string]$_.type).ToLowerInvariant() -eq 'checkpoint'
            }
    )

    if ($targetPackages.Count -ne 1) {
        throw (
            "Windows 11 manifest must contain exactly one target package. " +
            "Found $($targetPackages.Count)."
        )
    }

    # Verify all packages before mounting the WIM.
    foreach ($package in $allPackages) {
        [void](Verify-Package `
            -Package $package `
            -Label "$($package.type) $($package.kb)")
    }

    $targetPackage = $targetPackages[0]

    Write-Host ''
    Write-Host 'Windows 11 servicing package set:'
    Write-Host "  Target:"
    Write-Host "    $($targetPackage.kb)"
    Write-Host "    $($targetPackage.fileName)"

    if ($checkpointPackages.Count -gt 0) {
        Write-Host '  Checkpoint / prerequisite package(s):'

        foreach ($package in $checkpointPackages) {
            Write-Host "    $($package.kb)"
            Write-Host "    $($package.fileName)"
        }
    }
    else {
        Write-Host '  Checkpoint / prerequisite package(s): none'
    }

    # Windows 11 24H2 checkpoint servicing:
    #
    # Do NOT apply checkpoint MSUs individually.
    # Keep them beside the target MSU in download\updates and invoke DISM
    # against the target MSU. DISM discovers and applies the applicable
    # prerequisite checkpoint package(s).
    $targetPath = Join-Path `
        $UpdatesDir `
        $targetPackage.fileName

    $sequence += [pscustomobject]@{
        Type          = 'LCU'
        KB            = [string]$targetPackage.kb
        Path          = $targetPath
        ExpectedBuild = [string]$manifest.build
    }
}

# ---------------------------------------------------------------------------
# Mount
# ---------------------------------------------------------------------------

Invoke-Dism `
    -Operation 'Mount WIM' `
    -Arguments @(
        '/Mount-Wim'
        "/WimFile:$WimFile"
        "/Index:$ImageIndex"
        "/MountDir:$MountDir"
    )

$mountedByThisScript = $true

try {

    # =======================================================================
    # Apply updates
    #
    # Windows 10:
    #
    #     SSU
    #      ↓
    #     verify SSU
    #      ↓
    #     LCU
    #
    # Windows 11:
    #
    #     LCU MSU
    # =======================================================================

    foreach ($package in $sequence) {

        Write-Host ''
        Write-Host '============================================================'
        Write-Host " Applying $($package.Type)"
        Write-Host '============================================================'
        Write-Host "KB:"
        Write-Host "  $($package.KB)"
        Write-Host "Package:"
        Write-Host "  $($package.Path)"
        Write-Host '============================================================'

        Invoke-Dism `
            -Operation "Apply $($package.Type) $($package.KB)" `
            -Arguments @(
                "/Image:$MountDir"
                '/Add-Package'
                "/PackagePath:$($package.Path)"
                '/NoRestart'
            )

        # -------------------------------------------------------------------
        # Verify after every package.
        #
        # Do not wait until the LCU has been applied. The Windows 10 flow
        # specifically requires the SSU to be accepted by the image before
        # proceeding to the LCU.
        # -------------------------------------------------------------------

        Write-Host ''
        Write-Host "Verifying installed package after $($package.Type)..."

        $packageQuery = & $DismExe `
            "/Image:$MountDir" `
            '/Get-Packages' `
            '/English' `
            2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to query packages after $($package.KB)."
        }

        $packageText = $packageQuery -join "`n"

        if ($package.Type -eq 'target') {

    $expectedBuild = [string]$package.ExpectedBuild

    if (
        [string]::IsNullOrWhiteSpace($expectedBuild)
    ) {
        throw (
            "Target package $($package.KB) has no expected build."
        )
    }

    if (
        $packageText -notmatch
        [regex]::Escape($expectedBuild)
    ) {
        throw @"
DISM package verification failed.

Target KB:
  $($package.KB)

Expected image/package build:
  $expectedBuild

The target package was accepted by DISM, but the expected
build was not found in the mounted image package list.
"@
    }

    Write-Host (
        "Target $($package.KB) is present at build " +
        "$expectedBuild."
    )
}
else {
    # For checkpoint packages, successful DISM /Add-Package is
    # sufficient here. The package identity is not required to
    # contain the literal KB string.
    Write-Host (
        "Checkpoint $($package.KB) accepted by DISM."
    )
}
    }

    # -----------------------------------------------------------------------
    # Component cleanup
    # -----------------------------------------------------------------------

    Invoke-Dism `
        -Operation 'Start Component Cleanup' `
        -Arguments @(
            "/Image:$MountDir"
            '/Cleanup-Image'
            '/StartComponentCleanup'
        )

    # -----------------------------------------------------------------------
    # Commit
    # -----------------------------------------------------------------------

    Invoke-Dism `
        -Operation 'Commit WIM' `
        -Arguments @(
            '/Unmount-Wim'
            "/MountDir:$MountDir"
            '/Commit'
        )

    $mountedByThisScript = $false
}
catch {

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' Servicing FAILED'
    Write-Host '============================================================'

    Write-Host $_

    if ($mountedByThisScript) {

        Write-Host ''
        Write-Host 'Discarding failed WIM mount...'

        & $DismExe `
            /Unmount-Wim `
            /MountDir:$MountDir `
            /Discard

        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'Unable to discard failed mount.'
        }
    }

    & $DismExe /Cleanup-Wim

    throw
}

# ---------------------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $WimFile -PathType Leaf)) {
    throw "Final install.wim does not exist: $WimFile"
}

$wim = Get-Item -LiteralPath $WimFile

if ($wim.Length -eq 0) {
    throw 'Final install.wim is empty.'
}

$hash = (
    Get-FileHash `
        -LiteralPath $WimFile `
        -Algorithm SHA256
).Hash.ToLowerInvariant()

Write-Host ''
Write-Host '============================================================'
Write-Host ' Windows Image Servicing Complete'
Write-Host '============================================================'
Write-Host "WIM:"
Write-Host "  $WimFile"
Write-Host ''
Write-Host "Size:"
Write-Host "  $($wim.Length) bytes"
Write-Host ''
Write-Host "SHA256:"
Write-Host "  $hash"
Write-Host '============================================================'