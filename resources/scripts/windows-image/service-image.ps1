[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [int]$ImageIndex = 1
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Paths
# ============================================================

$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)

$SourceDir  = Join-Path $WorkRoot 'source'
$WimFile    = Join-Path $SourceDir 'sources\install.wim'
$MountDir   = Join-Path $WorkRoot 'mount\install'
$UpdateDir  = Join-Path $WorkRoot 'download\updates'
$Resolved   = Join-Path $WorkRoot 'download\resolved-updates.json'

Write-Host ''
Write-Host '============================================================'
Write-Host ' Windows Image Servicing'
Write-Host '============================================================'
Write-Host "Work root       : $WorkRoot"
Write-Host "Source          : $SourceDir"
Write-Host "WIM             : $WimFile"
Write-Host "Mount           : $MountDir"
Write-Host "Updates         : $UpdateDir"
Write-Host "Resolved        : $Resolved"
Write-Host "Image index     : $ImageIndex"
Write-Host '============================================================'
Write-Host ''

# ============================================================
# Helper
# ============================================================

function Invoke-Dism {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Host ''
    Write-Host "DISM: $Operation"
    Write-Host 'Arguments:'

    foreach ($arg in $Arguments) {
        Write-Host "  [$arg]"
    }

    & "$env:SystemRoot\System32\dism.exe" @Arguments

    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "DISM failed during '$Operation'. Exit code: $exitCode"
    }

    Write-Host "DISM completed: $Operation"
}
# ============================================================
# 1. Administrator check
# ============================================================

Write-Host 'Checking administrator privileges...'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()

$principal = New-Object Security.Principal.WindowsPrincipal($identity)

$isAdministrator = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

Write-Host "Running as      : $($identity.Name)"
Write-Host "Administrator   : $isAdministrator"

if (-not $isAdministrator) {
    throw @"
Jenkins is not running with Administrator privileges.

Account:
    $($identity.Name)

DISM requires an elevated process to mount and modify a WIM.

Configure the Jenkins Windows service to run under an account
with the required administrative privileges.
"@
}

# ============================================================
# 2. Validate WorkRoot
# ============================================================

if (-not (Test-Path -LiteralPath $WorkRoot -PathType Container)) {
    throw "WorkRoot does not exist: $WorkRoot"
}

# ============================================================
# 3. Validate WIM
# ============================================================

Write-Host ''
Write-Host 'Checking install.wim...'

if (-not (Test-Path -LiteralPath $WimFile -PathType Leaf)) {
    throw "install.wim not found: $WimFile"
}

$wimItem = Get-Item -LiteralPath $WimFile

Write-Host "WIM size        : $([math]::Round($wimItem.Length / 1GB, 2)) GB"
Write-Host "WIM attributes  : $($wimItem.Attributes)"
Write-Host "WIM read-only   : $($wimItem.IsReadOnly)"

# ============================================================
# 4. Make sure WIM is writable
# ============================================================

if ($wimItem.IsReadOnly) {

    Write-Host 'Removing ReadOnly attribute from install.wim...'

    attrib.exe -R $WimFile

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to remove ReadOnly attribute from WIM."
    }

    $wimItem = Get-Item -LiteralPath $WimFile

    if ($wimItem.IsReadOnly) {
        throw "install.wim is still read-only: $WimFile"
    }
}

# ============================================================
# 5. Test filesystem write access
# ============================================================

Write-Host ''
Write-Host 'Testing workspace write access...'

$writeTest = Join-Path $WorkRoot '.jenkins-write-test.txt'

try {

    'Jenkins DISM write test' |
        Set-Content `
            -LiteralPath $writeTest `
            -Encoding UTF8 `
            -Force

    if (-not (Test-Path -LiteralPath $writeTest -PathType Leaf)) {
        throw "Write test file was not created."
    }

}
catch {

    throw @"
Jenkins cannot write to the Windows image workspace.

WorkRoot:
    $WorkRoot

Account:
    $($identity.Name)

Original error:
    $($_.Exception.Message)
"@

}
finally {

    Remove-Item `
        -LiteralPath $writeTest `
        -Force `
        -ErrorAction SilentlyContinue
}

Write-Host 'Workspace write test passed.'

# ============================================================
# 6. Validate update manifest
# ============================================================

Write-Host ''
Write-Host 'Checking resolved update manifest...'

if (-not (Test-Path -LiteralPath $Resolved -PathType Leaf)) {
    throw "Resolved update manifest not found: $Resolved"
}

try {

    $updates = @(
        Get-Content `
            -LiteralPath $Resolved `
            -Raw |
        ConvertFrom-Json
    )

}
catch {

    throw "Unable to parse resolved update manifest: $Resolved. $($_.Exception.Message)"
}

if ($updates.Count -eq 0) {
    throw "Resolved update manifest contains no updates."
}

Write-Host "Resolved updates: $($updates.Count)"

# ============================================================
# 7. Validate update packages
# ============================================================

if (-not (Test-Path -LiteralPath $UpdateDir -PathType Container)) {
    throw "Update directory not found: $UpdateDir"
}

foreach ($update in $updates) {

    if (-not $update.fileName) {
        throw 'Update manifest entry does not contain fileName.'
    }

    $package = Join-Path $UpdateDir $update.fileName

    Write-Host ''
    Write-Host "Update package:"
    Write-Host "  Type       : $($update.type)"
    Write-Host "  KB         : $($update.kb)"
    Write-Host "  File       : $package"

    if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
        throw "Update package not found: $package"
    }

    $packageItem = Get-Item -LiteralPath $package

    if ($packageItem.Length -eq 0) {
        throw "Update package is empty: $package"
    }

    Write-Host "  Size       : $([math]::Round($packageItem.Length / 1MB, 2)) MB"

    if ($update.sha256) {

        $actualHash = (
            Get-FileHash `
                -LiteralPath $package `
                -Algorithm SHA256
        ).Hash.ToUpperInvariant()

        $expectedHash = $update.sha256.ToString().ToUpperInvariant()

        Write-Host "  SHA256     : $actualHash"

        if ($actualHash -ne $expectedHash) {
            throw @"
SHA-256 mismatch for update package.

File:
    $package

Expected:
    $expectedHash

Actual:
    $actualHash
"@
        }
    }
}

# ============================================================
# 8. Check existing DISM mounts
# ============================================================

Write-Host ''
Write-Host 'Checking existing mounted WIM images...'

& dism.exe /Get-MountedWimInfo

$getMountedExit = $LASTEXITCODE

if ($getMountedExit -ne 0) {
    Write-Warning "DISM /Get-MountedWimInfo returned 0x{0:X8}" -f $getMountedExit
}

# ============================================================
# 9. Check whether our mount directory is already mounted
# ============================================================

$existingMount = $false

$mountedInfo = & dism.exe /Get-MountedWimInfo 2>&1

foreach ($line in $mountedInfo) {

    if (
        $line.ToString().Trim() -ieq
        "Mount Dir : $MountDir"
    ) {
        $existingMount = $true
        break
    }
}

if ($existingMount) {

    Write-Warning "Mount directory is already registered with DISM:"
    Write-Warning "  $MountDir"

    Write-Host 'Attempting to discard the existing mount...'

    & dism.exe /Unmount-Wim `
        /MountDir:$MountDir `
        /Discard

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to discard existing DISM mount: $MountDir"
    }
}

# ============================================================
# 10. Prepare mount directory
# ============================================================

Write-Host ''
Write-Host 'Preparing mount directory...'

if (Test-Path -LiteralPath $MountDir) {

    $mountContents = @(
        Get-ChildItem `
            -LiteralPath $MountDir `
            -Force `
            -ErrorAction SilentlyContinue
    )

    if ($mountContents.Count -gt 0) {

        Write-Warning "Mount directory contains existing files."

        foreach ($item in $mountContents) {
            Write-Warning "  $($item.FullName)"
        }

        Remove-Item `
            -LiteralPath $MountDir `
            -Recurse `
            -Force `
            -ErrorAction Stop
    }
}

New-Item `
    -ItemType Directory `
    -Path $MountDir `
    -Force |
    Out-Null

# ============================================================
# 11. Test mount directory write access
# ============================================================

$mountWriteTest = Join-Path $MountDir '.mount-write-test.txt'

try {

    'DISM mount write test' |
        Set-Content `
            -LiteralPath $mountWriteTest `
            -Encoding UTF8 `
            -Force

    Remove-Item `
        -LiteralPath $mountWriteTest `
        -Force

}
catch {

    throw @"
Jenkins cannot write to the DISM mount directory.

Mount:
    $MountDir

Account:
    $($identity.Name)

Error:
    $($_.Exception.Message)
"@
}

Write-Host 'Mount directory write test passed.'

# ============================================================
# 12. Mount WIM
# ============================================================

$mounted = $false

try {

    Invoke-Dism `
        -Operation 'Mount WIM' `
        -Arguments @(
            '/Mount-Wim',
            "/WimFile:$WimFile",
            "/Index:$ImageIndex",
            "/MountDir:$MountDir"
        )

    $mounted = $true

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' WIM mounted successfully'
    Write-Host '============================================================'

    # ========================================================
    # 13. Apply updates
    # ========================================================

    foreach ($update in $updates) {

        $package = Join-Path $UpdateDir $update.fileName

        Write-Host ''
        Write-Host '------------------------------------------------------------'
        Write-Host "Applying update: $($update.fileName)"
        Write-Host "Type           : $($update.type)"
        Write-Host "KB             : $($update.kb)"
        Write-Host "Package        : $package"
        Write-Host '------------------------------------------------------------'

        if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
            throw "Update package not found: $package"
        }

        $dismArgs = @(
            "/Image:$MountDir"
            '/Add-Package'
            "/PackagePath:$package"
            '/NoRestart'
        )

        Invoke-Dism `
            -Operation "Apply $($update.fileName)" `
            -Arguments $dismArgs
    }
    
    # ========================================================
    # 14. Component cleanup
    # ========================================================

    Write-Host ''
    Write-Host 'Running component cleanup...'

    Invoke-Dism `
        -Operation 'Component cleanup' `
        -Arguments @(
            '/Image:' + $MountDir,
            '/Cleanup-Image',
            '/StartComponentCleanup'
        )

    # ========================================================
    # 15. Commit WIM
    # ========================================================

    Write-Host ''
    Write-Host 'Committing serviced WIM...'

    Invoke-Dism `
        -Operation 'Unmount WIM / Commit' `
        -Arguments @(
            '/Unmount-Wim',
            "/MountDir:$MountDir",
            '/Commit'
        )

    $mounted = $false

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' Windows image servicing completed successfully'
    Write-Host '============================================================'
    Write-Host ''

}
catch {

    Write-Error ''
    Write-Error '============================================================'
    Write-Error ' Windows image servicing FAILED'
    Write-Error '============================================================'
    Write-Error $_.Exception.Message

    # ========================================================
    # Failure recovery
    # ========================================================

    if ($mounted) {

        Write-Warning ''
        Write-Warning 'Discarding mounted WIM because servicing failed...'

        & dism.exe /Unmount-Wim `
            /MountDir:$MountDir `
            /Discard

        $discardExit = $LASTEXITCODE

        if ($discardExit -ne 0) {

            Write-Warning (
                "Failed to discard mounted WIM. " +
                "DISM exit code: 0x{0:X8}" -f $discardExit
            )
        }
        else {

            Write-Host 'Mounted WIM discarded successfully.'
        }
    }

    throw
}

# ============================================================
# 16. Final verification
# ============================================================

Write-Host ''
Write-Host 'Performing final WIM verification...'

if (-not (Test-Path -LiteralPath $WimFile -PathType Leaf)) {
    throw "Serviced install.wim not found after commit: $WimFile"
}

$finalWim = Get-Item -LiteralPath $WimFile

Write-Host "Final WIM size: $([math]::Round($finalWim.Length / 1GB, 2)) GB"

$finalHash = Get-FileHash `
    -LiteralPath $WimFile `
    -Algorithm SHA256

Write-Host "Final WIM SHA256: $($finalHash.Hash)"

Write-Host ''
Write-Host '============================================================'
Write-Host ' SERVICE COMPLETE'
Write-Host '============================================================'