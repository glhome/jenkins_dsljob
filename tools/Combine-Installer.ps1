param(
    [Parameter(Mandatory = $true)]
    [string]$PartsDir,

    [Parameter(Mandatory = $true)]
    [string]$OutputExe,

    [Parameter(Mandatory = $true)]
    [string]$ShaFile
)

# Validate parts directory
if (-not (Test-Path -LiteralPath $PartsDir -PathType Container)) {
    throw "Parts directory not found: $PartsDir"
}

# Validate SHA file
if (-not (Test-Path -LiteralPath $ShaFile -PathType Leaf)) {
    throw "SHA256 file not found: $ShaFile"
}

# Find split files
$parts = Get-ChildItem -LiteralPath $PartsDir -Filter "*.part*" |
    Sort-Object Name

if ($parts.Count -eq 0) {
    throw "No split files found in: $PartsDir"
}

Write-Host "Parts directory : $PartsDir"
Write-Host "Output EXE      : $OutputExe"
Write-Host "SHA256 file     : $ShaFile"
Write-Host "Parts found     : $($parts.Count)"

# Create output directory if needed
$outputDir = Split-Path -Parent $OutputExe

if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

# Remove existing EXE
if (Test-Path -LiteralPath $OutputExe) {
    Remove-Item -LiteralPath $OutputExe -Force
}

# Combine parts
$outStream = [System.IO.File]::Create($OutputExe)

try {
    foreach ($part in $parts) {
        Write-Host "Combining: $($part.Name)"

        $inStream = [System.IO.File]::OpenRead($part.FullName)

        try {
            $inStream.CopyTo($outStream)
        }
        finally {
            $inStream.Dispose()
        }
    }
}
finally {
    $outStream.Dispose()
}

Write-Host ""
Write-Host "Combine completed."
Write-Host "Verifying SHA256..."

# Read expected SHA256
$expectedHash = (Get-Content -LiteralPath $ShaFile -Raw).Trim().Split()[0].ToUpper()

# Calculate actual SHA256
$actualHash = (Get-FileHash -LiteralPath $OutputExe -Algorithm SHA256).Hash.ToUpper()

Write-Host "Expected SHA256: $expectedHash"
Write-Host "Actual SHA256:   $actualHash"

# Verify
if ($actualHash -ne $expectedHash) {
    Write-Error "SHA256 verification FAILED!"
    Write-Error "The reconstructed EXE does NOT match the original."
    
    Remove-Item -LiteralPath $OutputExe -Force

    exit 1
}

Write-Host ""
Write-Host "SHA256 verification PASSED."
Write-Host "Reconstructed EXE is valid: $OutputExe"