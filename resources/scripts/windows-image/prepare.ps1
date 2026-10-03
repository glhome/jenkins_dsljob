```powershell
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Require Administrator
# ---------------------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity

if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw "This script must run as Administrator."
}

# ---------------------------------------------------------------------------
# Validate DISM
# ---------------------------------------------------------------------------
if (-not (Get-Command dism.exe -ErrorAction SilentlyContinue)) {
    throw "DISM was not found."
}

# ---------------------------------------------------------------------------
# Normalize WorkRoot
# ---------------------------------------------------------------------------
$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)

# ---------------------------------------------------------------------------
# Create workspace directories
# ---------------------------------------------------------------------------
$directories = @(
    $WorkRoot
    (Join-Path $WorkRoot "download")
    (Join-Path $WorkRoot "source")
    (Join-Path $WorkRoot "mount")
    (Join-Path $WorkRoot "output")
    (Join-Path $WorkRoot "logs")
)

foreach ($directory in $directories) {
    New-Item `
        -ItemType Directory `
        -Path $directory `
        -Force `
        -ErrorAction Stop | Out-Null
}

# ---------------------------------------------------------------------------
# Locate resolved update manifest
# ---------------------------------------------------------------------------
$ManifestPath = Join-Path `
    $WorkRoot `
    "download\resolved-updates.json"

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Resolved update manifest was not found: $ManifestPath"
}

Write-Host ""
Write-Host "Loading update manifest:"
Write-Host "  $ManifestPath"

# ---------------------------------------------------------------------------
# Parse manifest
# ---------------------------------------------------------------------------
try {
    $Manifest = Get-Content `
        -LiteralPath $ManifestPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    throw "Failed to parse update manifest '$ManifestPath': $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# Validate manifest structure
# ---------------------------------------------------------------------------
if ($null -eq $Manifest.packages) {
    throw "Update manifest does not contain 'packages'."
}

if ($null -eq $Manifest.installOrder) {
    throw "Update manifest does not contain 'installOrder'."
}

$Packages = @($Manifest.packages)
$InstallOrder = @($Manifest.installOrder)

if ($Packages.Count -eq 0) {
    throw "Update manifest contains no packages."
}

if ($InstallOrder.Count -eq 0) {
    throw "Update manifest contains an empty 'installOrder'."
}

# ---------------------------------------------------------------------------
# Validate packages referenced by installOrder
# ---------------------------------------------------------------------------
foreach ($packageType in $InstallOrder) {

    if ([string]::IsNullOrWhiteSpace($packageType)) {
        throw "Manifest contains an empty package type in installOrder."
    }

    $matches = @(
        $Packages |
            Where-Object { $_.type -eq $packageType }
    )

    if ($matches.Count -eq 0) {
        throw "installOrder references '$packageType', but no matching package exists."
    }

    if ($matches.Count -gt 1) {
        throw "Multiple packages exist for package type '$packageType'."
    }

    $package = $matches[0]

    if ([string]::IsNullOrWhiteSpace($package.fileName)) {
        throw "Package type '$packageType' has no fileName."
    }

    if ([string]::IsNullOrWhiteSpace($package.path)) {
        throw "Package '$($package.fileName)' has no path."
    }

    if ([string]::IsNullOrWhiteSpace($package.sha256)) {
        throw "Package '$($package.fileName)' has no SHA-256."
    }

    if ($package.sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "Invalid SHA-256 for package '$($package.fileName)'."
    }

    Write-Host ""
    Write-Host "Manifest package:"
    Write-Host "  Type:     $($package.type)"
    Write-Host "  Order:    $($package.order)"
    Write-Host "  Required: $($package.required)"
    Write-Host "  File:     $($package.fileName)"
    Write-Host "  Path:     $($package.path)"
}

# ---------------------------------------------------------------------------
# Resolve package paths and verify files
# ---------------------------------------------------------------------------
$ManifestDirectory = Split-Path -Parent $ManifestPath

Write-Host ""
Write-Host "Verifying update packages..."

foreach ($packageType in $InstallOrder) {

    $package = @(
        $Packages |
            Where-Object { $_.type -eq $packageType }
    )[0]

    if ([System.IO.Path]::IsPathRooted($package.path)) {
        $PackagePath = [System.IO.Path]::GetFullPath($package.path)
    }
    else {
        $PackagePath = [System.IO.Path]::GetFullPath(
            (Join-Path $ManifestDirectory $package.path)
        )
    }

    if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
        throw @"
Package referenced by manifest does not exist.

Type: $($package.type)
File: $($package.fileName)
Path: $PackagePath
"@
    }

    $ActualSha256 = (
        Get-FileHash `
            -LiteralPath $PackagePath `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    $ExpectedSha256 = $package.sha256.ToLowerInvariant()

    if ($ActualSha256 -ne $ExpectedSha256) {
        throw @"
SHA-256 mismatch.

Package:  $($package.fileName)
Path:     $PackagePath
Expected: $ExpectedSha256
Actual:   $ActualSha256
"@
    }

    Write-Host "  Verified: $($package.fileName)"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================"
Write-Host "Windows image workspace prepared successfully"
Write-Host "============================================================"
Write-Host "WorkRoot : $WorkRoot"
Write-Host "Manifest : $ManifestPath"
Write-Host "Packages : $($Packages.Count)"
Write-Host ""
Write-Host "Install order:"

$index = 1

foreach ($packageType in $InstallOrder) {
    $package = @(
        $Packages |
            Where-Object { $_.type -eq $packageType }
    )[0]

    Write-Host "  $index. $packageType - $($package.fileName)"
    $index++
}

Write-Host ""
Write-Host "Preparation and manifest validation complete."
```
