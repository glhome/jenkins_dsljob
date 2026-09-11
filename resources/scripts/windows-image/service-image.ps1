[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkRoot,[int]$ImageIndex=1)
$ErrorActionPreference="Stop"
$src=Join-Path $WorkRoot "source";$mnt=Join-Path $WorkRoot "mount\install"
$pkgs=Join-Path $WorkRoot "download\updates";$resolved=Join-Path $WorkRoot "download\resolved-updates.json"
$wim=Join-Path $src "sources\install.wim"
New-Item -ItemType Directory -Force -Path $mnt|Out-Null
if(!(Test-Path $wim)){throw "install.wim not found."};if(!(Test-Path $resolved)){throw "Resolved updates not found."}
&dism.exe /Mount-Wim /WimFile:$wim /Index:$ImageIndex /MountDir:$mnt
if($LASTEXITCODE-ne0){throw "DISM mount failed."}
$mounted=$true
try{
 $u=@(Get-Content $resolved -Raw|ConvertFrom-Json)
 foreach($type in @("SSU","LCU")){
  foreach($x in @($u|? type -eq $type)){
   $p=Join-Path $pkgs $x.fileName
   if(!(Test-Path $p)){throw "Package not found: $p"}
   Write-Host "Applying $($x.type) $($x.kb)"
   &dism.exe /Image:$mnt /Add-Package /PackagePath:$p
   if($LASTEXITCODE-ne0){throw "Failed applying $($x.kb)"}
  }
 }
 &dism.exe /Image:$mnt /Cleanup-Image /StartComponentCleanup
 if($LASTEXITCODE-ne0){throw "Component cleanup failed."}
 &dism.exe /Unmount-Wim /MountDir:$mnt /Commit
 if($LASTEXITCODE-ne0){throw "WIM commit failed."}
 $mounted=$false
}catch{if($mounted){&dism.exe /Unmount-Wim /MountDir:$mnt /Discard|Out-Null};throw}
