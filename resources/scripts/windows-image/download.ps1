[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkRoot,[Parameter(Mandatory=$true)][string]$BaseIsoUrl,[string]$BaseIsoSha256)
$ErrorActionPreference="Stop"
$d=Join-Path $WorkRoot "download";New-Item -ItemType Directory -Force -Path $d|Out-Null
$p=Join-Path $d "en-us_windows_11_iot_enterprise_version_24h2_x64_dvd_3a99b72b.iso"
Invoke-WebRequest -Uri $BaseIsoUrl -OutFile $p -UseBasicParsing
if(!(Test-Path $p)){throw "Base ISO download failed."}
$h=(Get-FileHash $p -Algorithm SHA256).Hash.ToLowerInvariant()
if($BaseIsoSha256 -and $h-ne$BaseIsoSha256.Trim().ToLowerInvariant()){throw "Base ISO SHA256 mismatch."}
Write-Host "Base ISO SHA256: $h"
