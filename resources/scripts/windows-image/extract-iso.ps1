[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkRoot,[int]$ImageIndex=1)
$ErrorActionPreference="Stop"
$isoPath=Join-Path $WorkRoot "download\base.iso"
$sourceRoot=Join-Path $WorkRoot "source"
$mountRoot=Join-Path $WorkRoot "mount"
$installWim=Join-Path $sourceRoot "sources\install.wim"
$installEsd=Join-Path $sourceRoot "sources\install.esd"
if (-not (Test-Path $isoPath)) { throw "Base ISO not found: $isoPath" }
if (Test-Path $sourceRoot) { Remove-Item $sourceRoot -Recurse -Force }
New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null
Mount-DiskImage -ImagePath $isoPath -StorageType ISO -PassThru | Out-Null
try {
 $volume=Get-DiskImage -ImagePath $isoPath | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
 if (-not $volume) { throw "Unable to find mounted ISO drive." }
 $drive="$($volume.DriveLetter):"
 $p=Start-Process robocopy.exe -ArgumentList @("$drive\","$sourceRoot","/E","/COPY:DAT","/DCOPY:DAT","/R:2","/W:2") -Wait -PassThru -NoNewWindow
 if ($p.ExitCode -gt 7) { throw "Robocopy failed with exit code $($p.ExitCode)." }
} finally { Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue }
if (Test-Path $installEsd) { throw "The ISO contains install.esd. This pipeline currently expects install.wim." }
if (-not (Test-Path $installWim)) { throw "install.wim was not found." }
New-Item -ItemType Directory -Path $mountRoot -Force | Out-Null
& dism.exe /Get-WimInfo /WimFile:$installWim | Tee-Object -FilePath (Join-Path $mountRoot "image-info.txt")
if ($LASTEXITCODE -ne 0) { throw "DISM /Get-WimInfo failed." }
New-Item -ItemType Directory -Path (Join-Path $mountRoot "install") -Force | Out-Null
