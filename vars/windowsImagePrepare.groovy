def call(Map cfg = [:]) {

    def workRoot = cfg.workRoot

    if (!workRoot?.trim()) {
        error 'workRoot is required'
    }

    echo "Prepare WorkRoot: ${workRoot}"

    powershell(
        '''
$ErrorActionPreference = 'Stop'

$workRoot = '__WORK_ROOT__'

Write-Host ""
Write-Host "============================================================"
Write-Host " Prepare Windows Image Workspace"
Write-Host "============================================================"
Write-Host "WorkRoot:"
Write-Host "  $workRoot"
Write-Host ""

$workRoot = [System.IO.Path]::GetFullPath($workRoot)

Write-Host "Normalized WorkRoot:"
Write-Host "  $workRoot"
Write-Host ""

$sourceDir   = Join-Path $workRoot 'source'
$mountRoot   = Join-Path $workRoot 'mount'
$mountDir    = Join-Path $mountRoot 'install'
$downloadDir = Join-Path $workRoot 'download'
$updatesDir  = Join-Path $downloadDir 'updates'
$outputDir   = Join-Path $workRoot 'output'

Write-Host "Checking for existing DISM mounts..."

$dismOutput = & dism.exe /English /Get-MountedWimInfo 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "DISM /Get-MountedWimInfo failed."
}

$dismText = $dismOutput -join "`n"
Write-Host $dismText
Write-Host ""

if ($dismText -match [regex]::Escape($mountDir)) {

    Write-Host "Existing DISM mount detected:"
    Write-Host "  $mountDir"
    Write-Host ""

    $needsRemount = $dismText -match '(?i)Status\\s*:\\s*Needs Remount'
    $isInvalid    = $dismText -match '(?i)Status\\s*:\\s*Invalid'

    if ($needsRemount -or $isInvalid) {
        Write-Host "Mount is stale or requires remount."
        Write-Host "Discarding existing mount to guarantee a clean build..."

        & dism.exe /Unmount-Wim /MountDir:$mountDir /Discard

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "DISM /Unmount-Wim /Discard failed."
            Write-Host "Attempting DISM cleanup..."
            & dism.exe /Cleanup-Wim
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to clean existing DISM mount."
            }
        }
    }
    else {
        Write-Host "An active mount exists at this workspace."
        Write-Host "Discarding it because every Jenkins image build must start clean."

        & dism.exe /Unmount-Wim /MountDir:$mountDir /Discard

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to discard existing DISM mount."
        }
    }
}

Write-Host ""
Write-Host "Running DISM cleanup..."

& dism.exe /Cleanup-Wim

if ($LASTEXITCODE -ne 0) {
    throw "DISM /Cleanup-Wim failed."
}

Write-Host ""
Write-Host "Creating workspace directories..."

New-Item -ItemType Directory -Force -Path $workRoot    | Out-Null
New-Item -ItemType Directory -Force -Path $sourceDir   | Out-Null
New-Item -ItemType Directory -Force -Path $mountRoot   | Out-Null
New-Item -ItemType Directory -Force -Path $mountDir    | Out-Null
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
New-Item -ItemType Directory -Force -Path $updatesDir  | Out-Null
New-Item -ItemType Directory -Force -Path $outputDir   | Out-Null

# ------------------------------------------------------------
# Normalize DISM workspace permissions
# ------------------------------------------------------------

Write-Host ""
Write-Host "Normalizing DISM workspace permissions..."

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$jenkinsIdentity = $currentIdentity.Name

Write-Host "Running as:"
Write-Host "  $jenkinsIdentity"

& icacls.exe $sourceDir /grant "${jenkinsIdentity}:(OI)(CI)(M)" /T /C

if ($LASTEXITCODE -ne 0) {
    throw "Failed to grant Modify permission on source directory."
}

& icacls.exe $mountRoot /grant "${jenkinsIdentity}:(OI)(CI)(M)" /T /C

if ($LASTEXITCODE -ne 0) {
    throw "Failed to grant Modify permission on mount directory."
}

$wimFile = Join-Path $sourceDir 'sources\\install.wim'

if (Test-Path -LiteralPath $wimFile) {
    Write-Host "Existing install.wim detected. Removing read-only attribute..."
    & attrib.exe -R $wimFile
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to remove read-only attribute from install.wim."
    }
}

Write-Host "DISM workspace permissions normalized."

$nestedRoot = Join-Path $workRoot 'windows-image'

if (Test-Path -LiteralPath $nestedRoot) {
    Write-Warning "Nested windows-image directory exists:"
    Write-Warning "  $nestedRoot"
    Write-Warning "This directory should not be used by the pipeline."
}

Write-Host ""
Write-Host "Prepared directories:"
Write-Host "  WorkRoot : $workRoot"
Write-Host "  Source   : $sourceDir"
Write-Host "  Mount    : $mountDir"
Write-Host "  Download : $downloadDir"
Write-Host "  Updates  : $updatesDir"
Write-Host "  Output   : $outputDir"

Write-Host ""
Write-Host "Prepare completed successfully."
Write-Host "============================================================"
'''
        .replace('__WORK_ROOT__', workRoot)
    )
}
