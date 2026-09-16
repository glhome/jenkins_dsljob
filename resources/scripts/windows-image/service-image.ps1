[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [int]$ImageIndex = 1
)

$ErrorActionPreference = "Stop"

# ============================================================
# Normalize WorkRoot
# ============================================================

$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)

$SourceDir   = Join-Path $WorkRoot "source"
$MountDir    = Join-Path $WorkRoot "mount\install"
$DownloadDir = Join-Path $WorkRoot "download"
$UpdatesDir  = Join-Path $DownloadDir "updates"
$ResolvedFile = Join-Path $DownloadDir "resolved-updates.json"
$WimFile     = Join-Path $SourceDir "sources\install.wim"

$DismExe = Join-Path $env:SystemRoot "System32\dism.exe"

Write-Host ""
Write-Host "============================================================"
Write-Host " Service Windows Image"
Write-Host "============================================================"
Write-Host "WorkRoot:"
Write-Host "  $WorkRoot"
Write-Host ""
Write-Host "WIM:"
Write-Host "  $WimFile"
Write-Host ""
Write-Host "Mount:"
Write-Host "  $MountDir"
Write-Host ""
Write-Host "Updates:"
Write-Host "  $UpdatesDir"
Write-Host ""
Write-Host "Manifest:"
Write-Host "  $ResolvedFile"
Write-Host "============================================================"
Write-Host ""

# ============================================================
# Validation
# ============================================================

if (!(Test-Path -LiteralPath $DismExe -PathType Leaf)) {
    throw "DISM not found: $DismExe"
}

if (!(Test-Path -LiteralPath $WimFile -PathType Leaf)) {
    throw "install.wim not found: $WimFile"
}

if (!(Test-Path -LiteralPath $ResolvedFile -PathType Leaf)) {
    throw "Resolved update manifest not found: $ResolvedFile"
}

if (!(Test-Path -LiteralPath $UpdatesDir -PathType Container)) {
    throw "Updates directory not found: $UpdatesDir"
}

# ============================================================
# Verify administrator privileges
# ============================================================

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

$principal = New-Object `
    Security.Principal.WindowsPrincipal($currentIdentity)

$isAdmin = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (!$isAdmin) {
    throw "Jenkins agent is not running with Administrator privileges."
}

Write-Host "Running as:"
Write-Host "  $($currentIdentity.Name)"

# ============================================================
# Create mount directory
# ============================================================

New-Item `
    -ItemType Directory `
    -Force `
    -Path $MountDir |
    Out-Null

# ============================================================
# Check for existing mounted images
# ============================================================

Write-Host ""
Write-Host "Checking for existing DISM mounts..."

& $DismExe /Get-MountedWimInfo

$mountedCheckExitCode = $LASTEXITCODE

if ($mountedCheckExitCode -ne 0) {
    Write-Warning "DISM /Get-MountedWimInfo returned $mountedCheckExitCode"
}

# ============================================================
# Load resolved updates
# ============================================================

Write-Host ""
Write-Host "Loading resolved update manifest..."

$updates = @(
    Get-Content `
        -LiteralPath $ResolvedFile `
        -Raw |
    ConvertFrom-Json
)

if ($updates.Count -eq 0) {
    throw "Resolved update manifest contains no updates."
}

Write-Host ""
Write-Host "Resolved updates:"
Write-Host ""

foreach ($update in $updates) {

    Write-Host "  Type : $($update.type)"
    Write-Host "  KB   : $($update.kb)"
    Write-Host "  File : $($update.fileName)"
    Write-Host ""
}

# ============================================================
# DISM helper
#
# IMPORTANT:
# DISM requires arguments such as:
#
#   /Image:C:\mount
#   /PackagePath:C:\foo.msu
#
# They must NOT be split into:
#
#   /Image
#   C:\mount
#
# ============================================================

function Invoke-DismCommand {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " DISM: $Operation"
    Write-Host "============================================================"

    Write-Host "Command:"
    Write-Host "  $DismExe"

    Write-Host ""
    Write-Host "Arguments:"

    foreach ($argument in $Arguments) {
        Write-Host "  [$argument]"
    }

    Write-Host ""

    # IMPORTANT:
    # PowerShell splatting passes every array element as a
    # separate command-line argument while preserving the
    # required DISM /Switch:value format.
    & $DismExe @Arguments

    $exitCode = $LASTEXITCODE

    Write-Host ""
    Write-Host "DISM exit code: $exitCode"

    if ($exitCode -ne 0) {
        throw "DISM failed during '$Operation'. Exit code: $exitCode"
    }
}

# ============================================================
# Mount WIM
# ============================================================

$mounted = $false

try {

    Write-Host ""
    Write-Host "Mounting WIM..."
    Write-Host "  WIM:"
    Write-Host "    $WimFile"
    Write-Host ""
    Write-Host "  Index:"
    Write-Host "    $ImageIndex"
    Write-Host ""
    Write-Host "  Mount:"
    Write-Host "    $MountDir"

    $mountArgs = @(
        "/Mount-Wim"
        "/WimFile:$WimFile"
        "/Index:$ImageIndex"
        "/MountDir:$MountDir"
    )

    Invoke-DismCommand `
        -Operation "Mount WIM" `
        -Arguments $mountArgs

    $mounted = $true

    Write-Host ""
    Write-Host "WIM mounted successfully."

    # ========================================================
    # Apply updates
    # ========================================================

    foreach ($update in $updates) {

        $packageName = [string]$update.fileName

        if ([string]::IsNullOrWhiteSpace($packageName)) {
            throw "Update manifest contains an empty fileName."
        }

        $packagePath = Join-Path `
            $UpdatesDir `
            $packageName

        if (!(Test-Path -LiteralPath $packagePath -PathType Leaf)) {

            throw @"
Update package not found.

KB:
  $($update.kb)

File:
  $packageName

Expected:
  $packagePath
"@
        }

        # ----------------------------------------------------
        # Verify package hash if manifest has one
        # ----------------------------------------------------

        if (![string]::IsNullOrWhiteSpace([string]$update.sha256)) {

            Write-Host ""
            Write-Host "Verifying SHA-256:"
            Write-Host "  $packageName"

            $actualHash = (
                Get-FileHash `
                    -LiteralPath $packagePath `
                    -Algorithm SHA256
            ).Hash.ToLowerInvariant()

            $expectedHash = (
                [string]$update.sha256
            ).ToLowerInvariant()

            Write-Host "  Expected: $expectedHash"
            Write-Host "  Actual  : $actualHash"

            if ($actualHash -ne $expectedHash) {

                throw @"
SHA-256 mismatch.

Package:
  $packageName

Expected:
  $expectedHash

Actual:
  $actualHash
"@
            }

            Write-Host "  SHA-256 verified."
        }

        # ----------------------------------------------------
        # Apply MSU
        # ----------------------------------------------------

        Write-Host ""
        Write-Host "Applying update:"
        Write-Host "  Type:"
        Write-Host "    $($update.type)"
        Write-Host ""
        Write-Host "  KB:"
        Write-Host "    $($update.kb)"
        Write-Host ""
        Write-Host "  Package:"
        Write-Host "    $packagePath"

        # CRITICAL:
        #
        # Correct:
        #
        #   /Image:C:\...\mount\install
        #   /Add-Package
        #   /PackagePath:C:\...\foo.msu
        #   /NoRestart
        #
        # NOT:
        #
        #   /Image
        #   C:\...\mount\install
        #
        # and NOT:
        #
        #   /PackagePath
        #   C:\...\foo.msu

        $packageArgs = @(
            "/Image:$MountDir"
            "/Add-Package"
            "/PackagePath:$packagePath"
            "/NoRestart"
        )

        Invoke-DismCommand `
            -Operation "Apply $($update.kb)" `
            -Arguments $packageArgs

        Write-Host ""
        Write-Host "Successfully applied $($update.kb)."
    }

    # ========================================================
    # Component cleanup
    # ========================================================

    Write-Host ""
    Write-Host "Running component cleanup..."

    $cleanupArgs = @(
        "/Image:$MountDir"
        "/Cleanup-Image"
        "/StartComponentCleanup"
    )

    Invoke-DismCommand `
        -Operation "Component Cleanup" `
        -Arguments $cleanupArgs

    # ========================================================
    # Commit WIM
    # ========================================================

    Write-Host ""
    Write-Host "Committing WIM..."

    $commitArgs = @(
        "/Unmount-Wim"
        "/MountDir:$MountDir"
        "/Commit"
    )

    Invoke-DismCommand `
        -Operation "Unmount WIM / Commit" `
        -Arguments $commitArgs

    $mounted = $false

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " WIM servicing completed successfully"
    Write-Host "============================================================"
    Write-Host ""

}
catch {

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " WIM servicing FAILED"
    Write-Host "============================================================"
    Write-Host $_.Exception.Message
    Write-Host "============================================================"
    Write-Host ""

    # ========================================================
    # Discard mounted image after failure
    # ========================================================

    if ($mounted) {

        Write-Host ""
        Write-Host "Attempting to discard mounted WIM..."

        try {

            $discardArgs = @(
                "/Unmount-Wim"
                "/MountDir:$MountDir"
                "/Discard"
            )

            & $DismExe @discardArgs

            $discardExitCode = $LASTEXITCODE

            Write-Host ""
            Write-Host "Discard exit code: $discardExitCode"
        }
        catch {

            Write-Warning `
                "Unable to discard mounted WIM: $($_.Exception.Message)"
        }
    }

    throw
}

# ============================================================
# Verify final WIM
# ============================================================

if (!(Test-Path -LiteralPath $WimFile -PathType Leaf)) {
    throw "Final install.wim does not exist: $WimFile"
}

$finalWimInfo = Get-Item -LiteralPath $WimFile

$finalWimHash = (
    Get-FileHash `
        -LiteralPath $WimFile `
        -Algorithm SHA256
).Hash.ToLowerInvariant()

Write-Host ""
Write-Host "============================================================"
Write-Host " Final WIM"
Write-Host "============================================================"
Write-Host "Path:"
Write-Host "  $WimFile"
Write-Host ""
Write-Host "Size:"
Write-Host "  $($finalWimInfo.Length) bytes"
Write-Host ""
Write-Host "SHA-256:"
Write-Host "  $finalWimHash"
Write-Host "============================================================"
Write-Host ""

exit 0