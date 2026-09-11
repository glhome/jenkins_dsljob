[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$WorkRoot,
 [Parameter(Mandatory=$true)][string]$WindowsBuild,
 [string]$Architecture="x64",
 [string]$UpdateManifestUrl="",
 [string]$UpdateManifestFile=""
)
$ErrorActionPreference="Stop"
$out=Join-Path $WorkRoot "download\update-selection.json"
New-Item -ItemType Directory -Force -Path (Split-Path $out)|Out-Null
if($UpdateManifestFile){if(!(Test-Path $UpdateManifestFile)){throw "Update manifest file not found: $UpdateManifestFile"};Copy-Item $UpdateManifestFile $out -Force}
elseif($UpdateManifestUrl){Invoke-WebRequest -Uri $UpdateManifestUrl -OutFile $out -UseBasicParsing}
else{throw "Provide UpdateManifestUrl or UpdateManifestFile."}
$m=Get-Content $out -Raw|ConvertFrom-Json
$u=@($m.updates|Where-Object{$_.type -in @("SSU","LCU") -and $_.kb -and $_.sourceUrl})
if(!$u){throw "No applicable SSU/LCU entries found."}
$u|ConvertTo-Json -Depth 10|Set-Content $out -Encoding UTF8
Write-Host "Selected updates:"; $u|%{Write-Host "  $($_.type) $($_.kb)"}
