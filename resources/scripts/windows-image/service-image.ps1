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
# Mount-state inspection and recovery
# ---------------------------------------------------------------------------

function Get-MountedWimRecords {
    $output = & $DismExe /English /Get-MountedWimInfo 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "DISM /Get-MountedWimInfo failed with exit code $exitCode." }
    $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
    $records = @()
    foreach ($block in [regex]::Split($text, '(?m)(?=^\s*Mount Dir\s*:)')) {
        $m = [regex]::Match($block, '(?im)^\s*Mount Dir\s*:\s*(.+?)\s*$')
        if (-not $m.Success) { continue }
        $i = [regex]::Match($block, '(?im)^\s*Image File\s*:\s*(.+?)\s*$')
        $n = [regex]::Match($block, '(?im)^\s*Image Index\s*:\s*(\d+)\s*$')
        $s = [regex]::Match($block, '(?im)^\s*Status\s*:\s*(.+?)\s*$')
        $records += [pscustomobject]@{
            MountDir = [IO.Path]::GetFullPath($m.Groups[1].Value.Trim()).TrimEnd('\')
            ImageFile = if ($i.Success) { [IO.Path]::GetFullPath($i.Groups[1].Value.Trim()) } else { '' }
            ImageIndex = if ($n.Success) { [int]$n.Groups[1].Value } else { 0 }
            Status = if ($s.Success) { $s.Groups[1].Value.Trim() } else { 'Unknown' }
        }
    }
    return @($records)
}

function Invoke-MountDism {
    param([string]$Operation, [string[]]$Arguments)
    Write-Host "Mount recovery: $Operation"
    & $DismExe @Arguments
    return ($LASTEXITCODE -eq 0)
}

function Ensure-CleanMountPoint {
    $mount = [IO.Path]::GetFullPath($MountDir).TrimEnd('\')
    $wim = [IO.Path]::GetFullPath($WimFile)
    $records = @(Get-MountedWimRecords)
    $atMount = @($records | Where-Object { $_.MountDir -ieq $mount })
    $sameWim = @($records | Where-Object { $_.ImageFile -ieq $wim })
    $other = @($sameWim | Where-Object { $_.MountDir -ine $mount })
    if ($other.Count) { throw "Target WIM is already registered at another mount path; refusing concurrent mount." }
    if ($atMount.Count -gt 1) { throw "Multiple DISM records exist for '$mount'; manual recovery required." }

    if ($atMount.Count -eq 1) {
        $record = $atMount[0]
        if ($record.ImageFile -ine $wim -or $record.ImageIndex -ne $ImageIndex) {
            throw "Mount path '$mount' belongs to a different WIM/index; refusing to discard it."
        }
        Write-Host "Existing mount status: $($record.Status)"
        if ($record.Status -match '(?i)Needs Remount|Invalid|Unknown') {
            [void](Invoke-MountDism 'Remount image' @('/Remount-Image', "/MountDir:$MountDir"))
            $records = @(Get-MountedWimRecords)
            $atMount = @($records | Where-Object { $_.MountDir -ieq $mount })
            if (-not ($atMount.Count -eq 1 -and $atMount[0].Status -match '(?i)^OK$')) {
                [void](Invoke-MountDism 'Cleanup mountpoints' @('/Cleanup-Mountpoints'))
                $records = @(Get-MountedWimRecords)
                $atMount = @($records | Where-Object { $_.MountDir -ieq $mount })
                if ($atMount.Count) { throw "DISM still registers '$mount' after remount/cleanup. Refusing another Mount-Wim." }
            }
        }
        $records = @(Get-MountedWimRecords)
        $atMount = @($records | Where-Object { $_.MountDir -ieq $mount })
        if ($atMount.Count -eq 1) {
            if (-not (Invoke-MountDism 'Discard existing workspace mount' @('/Unmount-Wim', "/MountDir:$MountDir", '/Discard'))) {
                throw "DISM could not discard '$MountDir'. Check open handles and C:\Windows\Logs\DISM\dism.log. No new mount will be attempted."
            }
            $records = @(Get-MountedWimRecords)
            if (@($records | Where-Object { $_.MountDir -ieq $mount }).Count) { throw "DISM still registers '$mount' after unmount. Refusing another Mount-Wim." }
        }
    }

    $records = @(Get-MountedWimRecords)
    if (@($records | Where-Object { $_.MountDir -ieq $mount -or $_.ImageFile -ieq $wim }).Count) {
        throw 'DISM still has a mount registered for the target WIM/workspace. Refusing Mount-Wim.'
    }
    if (-not (Test-Path -LiteralPath $MountDir -PathType Container)) { New-Item -ItemType Directory -Path $MountDir -Force | Out-Null }
    $leftovers = @(Get-ChildItem -LiteralPath $MountDir -Force -ErrorAction Stop)
    if ($leftovers.Count) { throw "Mount directory '$MountDir' is not empty although DISM has no mount record. Inspect it before deleting files." }
    Write-Host 'Mount preflight passed: no registered mount and mount directory is empty.'
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

if ($manifest.profile -eq 'windows10-21h2') {

    if (-not $manifest.ssu) {
        throw 'Windows 10 manifest has no SSU package.'
    }

    if (-not $manifest.lcu) {
        throw 'Windows 10 manifest has no LCU object.'
    }

    if (-not $manifest.lcu.msu) {
        throw 'Windows 10 manifest has no LCU MSU.'
    }

    $ssuPath = Verify-Package `
        -Package $manifest.ssu `
        -Label "SSU $($manifest.ssu.kb)"

    $sequence += [pscustomobject]@{
        Type          = 'SSU'
        KB            = [string]$manifest.ssu.kb
        Path          = $ssuPath
        ExpectedBuild = ''
    }

    $lcuPackage = $manifest.lcu.msu

    $lcuPath = Verify-Package `
        -Package $lcuPackage `
        -Label "LCU $($lcuPackage.kb)"

    $sequence += [pscustomobject]@{
        Type          = 'LCU'
        KB            = [string]$lcuPackage.kb
        Path          = $lcuPath
        ExpectedBuild = [string]$manifest.lcu.build
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

    # The manifest must enumerate only known MSU roles. A required update
    # must not be silently skipped or treated as an arbitrary package.
    $invalidPackages = @(
        $allPackages | Where-Object {
            $packageRole = ([string]$_.type).ToLowerInvariant()
            $packageExtension = [System.IO.Path]::GetExtension([string]$_.fileName)

            ($packageRole -ne 'target' -and $packageRole -ne 'checkpoint') -or
            $packageExtension -ine '.msu'
        }
    )

    if ($invalidPackages.Count -gt 0) {
        $invalidPackageText = @(
            $invalidPackages | ForEach-Object {
                "  type=$($_.type) kb=$($_.kb) file=$($_.fileName)"
            }
        ) -join "`r`n"

        throw @"
Windows 11 LCU manifest contains unsupported package entries.
Every required package must be a target/checkpoint MSU.

$invalidPackageText
"@
    }

    $duplicateFileNames = @(
        $allPackages |
            Group-Object -Property fileName |
            Where-Object { $_.Count -gt 1 }
    )

    if ($duplicateFileNames.Count -gt 0) {
        $duplicateNames = @(
            $duplicateFileNames | ForEach-Object { "  $($_.Name)" }
        ) -join "`r`n"

        throw "Windows 11 LCU manifest contains duplicate package filenames:`r`n$duplicateNames"
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
    # Microsoft requires the checkpoint MSU(s) and target MSU to be in one
    # folder with no unrelated files. download\updates is a persistent cache
    # and can contain packages from other image builds, so stage the manifest's
    # complete package set in a clean folder without modifying the download cache.
    $servicingRoot = Join-Path $WorkRoot 'servicing'
    $servicingPackageDir = Join-Path `
        $servicingRoot `
        "LCU-$($targetPackage.kb)"

    if (Test-Path -LiteralPath $servicingPackageDir) {
        Remove-Item `
            -LiteralPath $servicingPackageDir `
            -Recurse `
            -Force
    }

    New-Item `
        -ItemType Directory `
        -Path $servicingPackageDir `
        -Force | Out-Null

    $expectedFileNames = @(
        $allPackages | ForEach-Object { [string]$_.fileName }
    )

    foreach ($package in $allPackages) {
        $fileName = [string]$package.fileName
        $sourcePath = Join-Path $UpdatesDir $fileName
        $stagedPath = Join-Path $servicingPackageDir $fileName

        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Required LCU package is missing before staging: $sourcePath"
        }

        $sourceHash = (
            Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256
        ).Hash.ToLowerInvariant()

        $expectedHash = ([string]$package.sha256).Trim().ToLowerInvariant()

        if (
            -not [string]::IsNullOrWhiteSpace($expectedHash) -and
            $sourceHash -ne $expectedHash
        ) {
            throw @"
Required LCU package checksum changed before staging.

KB:       $($package.kb)
File:     $fileName
Expected: $expectedHash
Actual:   $sourceHash
"@
        }

        Copy-Item `
            -LiteralPath $sourcePath `
            -Destination $stagedPath `
            -Force

        $stagedHash = (
            Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()

        if ($stagedHash -ne $sourceHash) {
            throw "Staged package hash mismatch for '$fileName'. Source=$sourceHash Staged=$stagedHash"
        }
    }

    # Confirm the folder contains exactly the manifest's MSUs and nothing else.
    $stagedItems = @(Get-ChildItem -LiteralPath $servicingPackageDir -Force)

    if ($stagedItems.Count -ne $expectedFileNames.Count) {
        throw (
            "Staged LCU package count mismatch. Expected $($expectedFileNames.Count), " +
            "found $($stagedItems.Count) in '$servicingPackageDir'."
        )
    }

    foreach ($item in $stagedItems) {
        if ($item.PSIsContainer -or $expectedFileNames -notcontains $item.Name) {
            throw "Unexpected item in isolated LCU servicing folder: $($item.FullName)"
        }
    }

    foreach ($fileName in $expectedFileNames) {
        if ($stagedItems.Name -notcontains $fileName) {
            throw "Required package was not staged for DISM: $fileName"
        }
    }

    $targetPath = Join-Path $servicingPackageDir $targetPackage.fileName

    if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
        throw "Target LCU package was not staged for DISM: $targetPath"
    }

    Write-Host ''
    Write-Host 'Isolated DISM package directory verified:'
    Write-Host "  Directory: $servicingPackageDir"
    Write-Host "  MSU count: $($stagedItems.Count)"
    foreach ($item in $stagedItems) {
        Write-Host "    $($item.Name) ($($item.Length) bytes)"
    }

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

# Never attempt a new mount until DISM confirms the prior mount is cleared.
Ensure-CleanMountPoint

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
    #      â†“
    #     verify SSU
    #      â†“
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

        # if ($package.Type -eq 'target') {
        if ($package.Type -eq 'LCU') {

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