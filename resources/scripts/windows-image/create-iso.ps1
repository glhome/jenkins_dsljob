[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [Parameter(Mandatory = $false)]
    [string]$OutputName = "Windows-Custom"
)

$ErrorActionPreference = "Stop"

$sourceRoot = Join-Path $WorkRoot "source"
$outputRoot = Join-Path $WorkRoot "output"

$bios = Join-Path $sourceRoot "boot\etfsboot.com"
$efi  = Join-Path $sourceRoot "efi\microsoft\boot\efisys.bin"

Write-Host ""
Write-Host "============================================================"
Write-Host " Create Windows ISO"
Write-Host "============================================================"
Write-Host ""
Write-Host "WorkRoot   : $WorkRoot"
Write-Host "SourceRoot : $sourceRoot"
Write-Host "OutputRoot : $outputRoot"

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

if (-not (Test-Path -LiteralPath $bios)) {
    throw "BIOS boot image not found: $bios"
}

if (-not (Test-Path -LiteralPath $efi)) {
    throw "EFI boot image not found: $efi"
}

#
# Locate Windows ADK Oscdimg
#
$oscdimgCandidates = @()

if ($env:ProgramFiles) {
    $oscdimgCandidates += Join-Path `
        $env:ProgramFiles `
        "Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
}

if (${env:ProgramFiles(x86)}) {
    $oscdimgCandidates += Join-Path `
        ${env:ProgramFiles(x86)} `
        "Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
}

# Explicit standard locations.
$oscdimgCandidates += @(
    "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
    "C:\Program Files\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
)

Write-Host ""
Write-Host "Searching for oscdimg.exe..."

$oscdimg = $null

foreach ($candidate in ($oscdimgCandidates | Select-Object -Unique)) {

    Write-Host "  Checking: $candidate"

    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $oscdimg = (Resolve-Path -LiteralPath $candidate).Path
        break
    }
}

#
# Fall back to PATH
#
if (-not $oscdimg) {

    Write-Host "  Checking PATH..."

    $command = Get-Command oscdimg.exe -ErrorAction SilentlyContinue

    if ($command) {
        $oscdimg = $command.Source
    }
}

#
# Last resort: search Windows Kits
#
if (-not $oscdimg) {

    Write-Host "  Searching Windows Kits installation..."

    $kitsRoots = @(
        "C:\Program Files (x86)\Windows Kits",
        "C:\Program Files\Windows Kits"
    )

    foreach ($kitsRoot in $kitsRoots) {

        if (-not (Test-Path -LiteralPath $kitsRoot)) {
            continue
        }

        $found = Get-ChildItem `
            -LiteralPath $kitsRoot `
            -Filter "oscdimg.exe" `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -match "\\amd64\\Oscdimg\\oscdimg\.exe$"
            } |
            Select-Object -First 1

        if ($found) {
            $oscdimg = $found.FullName
            break
        }
    }
}

if (-not $oscdimg) {

    Write-Host ""
    Write-Host "ERROR: oscdimg.exe was not found."
    Write-Host ""
    Write-Host "ProgramFiles      : $env:ProgramFiles"
    Write-Host "ProgramFiles(x86) : ${env:ProgramFiles(x86)}"
    Write-Host ""

    throw @"
oscdimg.exe was not found.

Install Windows ADK Deployment Tools.

Expected location:
C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe
"@
}

Write-Host ""
Write-Host "Using oscdimg:"
Write-Host "  $oscdimg"

#
# Create ISO
#
$iso = Join-Path $outputRoot "$OutputName.iso"

if (Test-Path -LiteralPath $iso) {
    Remove-Item -LiteralPath $iso -Force
}

$bootData = "-bootdata:2#p0,e,b$bios#pEF,e,b$efi"

Write-Host ""
Write-Host "Creating ISO..."
Write-Host "  Source : $sourceRoot"
Write-Host "  Output : $iso"
Write-Host ""

& $oscdimg `
    -m `
    -o `
    -u2 `
    -udfver102 `
    $bootData `
    $sourceRoot `
    $iso

if ($LASTEXITCODE -ne 0) {
    throw "oscdimg failed with exit code $LASTEXITCODE."
}

#
# Verify ISO
#
if (-not (Test-Path -LiteralPath $iso)) {
    throw "oscdimg reported success but ISO was not created: $iso"
}

$isoInfo = Get-Item -LiteralPath $iso

$hash = (
    Get-FileHash `
        -LiteralPath $iso `
        -Algorithm SHA256
).Hash.ToLowerInvariant()

$hashFile = "$iso.sha256"

"$hash  $([IO.Path]::GetFileName($iso))" |
    Set-Content `
        -LiteralPath $hashFile `
        -Encoding ASCII

Write-Host ""
Write-Host "============================================================"
Write-Host " ISO Creation Complete"
Write-Host "============================================================"
Write-Host ""
Write-Host "ISO      : $iso"
Write-Host "Size     : $($isoInfo.Length) bytes"
Write-Host "SHA256   : $hash"
Write-Host "Checksum : $hashFile"
Write-Host ""