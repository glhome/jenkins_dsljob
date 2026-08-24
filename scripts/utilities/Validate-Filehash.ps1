
param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [string]$Sha256File
)

$ErrorActionPreference = "Stop"

Write-Host "========================================"
Write-Host " SHA256 VALIDATION"
Write-Host "========================================"
Write-Host "Artifact : $FilePath"
Write-Host "SHA256   : $Sha256File"
Write-Host ""

# Verify artifact exists
if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
    Write-Error "Artifact not found: $FilePath"
    exit 1
}

# Verify SHA256 file exists
if (-not (Test-Path -LiteralPath $Sha256File -PathType Leaf)) {
    Write-Error "SHA256 file not found: $Sha256File"
    exit 1
}

# Read SHA256 file
$shaContent = (Get-Content -LiteralPath $Sha256File -Raw).Trim()

if ([string]::IsNullOrWhiteSpace($shaContent)) {
    Write-Error "SHA256 file is empty: $Sha256File"
    exit 1
}

# Expected format:
#   ABCDEF123...  MyInstaller.msi
# or:
#   ABCDEF123...
$expectedHash = ($shaContent -split '\s+')[0].ToUpper()

# Validate SHA256 format
if ($expectedHash -notmatch '^[A-F0-9]{64}$') {
    Write-Error "Invalid SHA256 value:"
    Write-Error "$expectedHash"
    exit 1
}

Write-Host "Expected SHA256:"
Write-Host "  $expectedHash"
Write-Host ""

# Calculate actual SHA256
Write-Host "Calculating SHA256..."
$actualHash = (
    Get-FileHash -LiteralPath $FilePath -Algorithm SHA256
).Hash.ToUpper()

Write-Host "Actual SHA256:"
Write-Host "  $actualHash"
Write-Host ""

# Compare hashes
if ($actualHash -eq $expectedHash) {

    Write-Host "========================================"
    Write-Host " SHA256 VALIDATION PASSED"
    Write-Host "========================================"

    exit 0
}

Write-Host "========================================"
Write-Host " SHA256 VALIDATION FAILED"
Write-Host "========================================"
Write-Host "Expected: $expectedHash"
Write-Host "Actual:   $actualHash"

exit 1
