[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [Parameter(Mandatory = $false)]
    [int]$ImageIndex = 1
)

$ErrorActionPreference = 'Stop'

$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)

$SourceDir = Join-Path $WorkRoot 'source'
$MountDir  = Join-Path $WorkRoot 'mount\install'

$BaseIso = Join-Path $WorkRoot 'download\base.iso'
$WimFile = Join-Path $SourceDir 'sources\install.wim'

Write-Host ""
Write-Host "============================================================"
Write-Host " Extract Windows Image"
Write-Host "============================================================"
Write-Host "WorkRoot:"
Write-Host "  $WorkRoot"
Write-Host ""
Write-Host "Base ISO:"
Write-Host "  $BaseIso"
Write-Host ""
Write-Host "Source:"
Write-Host "  $SourceDir"
Write-Host "============================================================"

if (-not (Test-Path -LiteralPath $BaseIso)) {
    throw "Base ISO not found: $BaseIso"
}

New-Item `
    -ItemType Directory `
    -Force `
    -Path $SourceDir | Out-Null

# ------------------------------------------------------------
# Mount ISO
# ------------------------------------------------------------

Write-Host ""
Write-Host "Mounting ISO..."

$diskImage = Mount-DiskImage `
    -ImagePath $BaseIso `
    -PassThru

Start-Sleep -Seconds 2

$volume = $diskImage |
    Get-Volume |
    Select-Object -First 1

if (-not $volume) {
    throw "Unable to determine mounted ISO volume."
}

$isoDrive = "$($volume.DriveLetter):"

Write-Host "ISO mounted at:"
Write-Host "  $isoDrive"

# ------------------------------------------------------------
# Copy ISO contents
# ------------------------------------------------------------

Write-Host ""
Write-Host "Copying ISO contents..."

robocopy `
    "$isoDrive\" `
    $SourceDir `
    /E `
    /COPY:DAT `
    /R:2 `
    /W:2 `
    /NFL `
    /NDL

$robocopyCode = $LASTEXITCODE

if ($robocopyCode -ge 8) {
    throw "Robocopy failed with exit code $robocopyCode."
}

# ------------------------------------------------------------
# Dismount ISO
# ------------------------------------------------------------

Write-Host ""
Write-Host "Dismounting ISO..."

Dismount-DiskImage `
    -ImagePath $BaseIso

# ------------------------------------------------------------
# Verify WIM
# ------------------------------------------------------------

$WimFile = Join-Path $SourceDir 'sources\install.wim'

if (-not (Test-Path -LiteralPath $WimFile)) {

    $EsdFile = Join-Path $SourceDir 'sources\install.esd'

    if (Test-Path -LiteralPath $EsdFile) {

        Write-Host "install.esd detected."

        throw @"
The ISO contains install.esd instead of install.wim.

The current image factory expects install.wim.
Convert install.esd to install.wim before continuing.
"@
    }

    throw "install.wim not found: $WimFile"
}

# ------------------------------------------------------------
# Display image information
# ------------------------------------------------------------

Write-Host ""
Write-Host "Windows image information:"

& dism.exe `
    /English `
    /Get-WimInfo `
    "/WimFile:$WimFile"

if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect install.wim."
}

Write-Host ""
Write-Host "Extraction completed successfully."
Write-Host "WIM:"
Write-Host "  $WimFile"
Write-Host "============================================================"