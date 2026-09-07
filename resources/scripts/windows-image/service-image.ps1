[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkRoot,[int]$ImageIndex=1)
$ErrorActionPreference="Stop"
$sourceRoot=Join-Path $WorkRoot "source"
$mountRoot=Join-Path $WorkRoot "mount\install"
$downloadRoot=Join-Path $WorkRoot "download"
$installWim=Join-Path $sourceRoot "sources\install.wim"
$ssu=Join-Path $downloadRoot "ssu.msu"
$lcu=Join-Path $downloadRoot "lcu.msu"
New-Item -ItemType Directory -Path $mountRoot -Force | Out-Null
if (-not (Test-Path $installWim)) { throw "install.wim not found." }
& dism.exe /Mount-Wim /WimFile:$installWim /Index:$ImageIndex /MountDir:$mountRoot
if ($LASTEXITCODE -ne 0) { throw "DISM failed to mount install.wim." }
$mounted=$true
try {
 if (Test-Path $ssu) { & dism.exe /Image:$mountRoot /Add-Package /PackagePath:$ssu; if ($LASTEXITCODE -ne 0) { throw "Failed applying SSU." } }
 if (Test-Path $lcu) { & dism.exe /Image:$mountRoot /Add-Package /PackagePath:$lcu; if ($LASTEXITCODE -ne 0) { throw "Failed applying LCU." } }
 & dism.exe /Image:$mountRoot /Cleanup-Image /StartComponentCleanup
 if ($LASTEXITCODE -ne 0) { throw "Component cleanup failed." }
 & dism.exe /Unmount-Wim /MountDir:$mountRoot /Commit
 if ($LASTEXITCODE -ne 0) { throw "Failed to commit WIM." }
 $mounted=$false
} catch {
 if ($mounted) { & dism.exe /Unmount-Wim /MountDir:$mountRoot /Discard | Out-Null }
 throw
}
