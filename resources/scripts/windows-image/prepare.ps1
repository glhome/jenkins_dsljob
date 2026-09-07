[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkRoot)
$ErrorActionPreference = "Stop"
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "This script must run as Administrator." }
if (-not (Get-Command dism.exe -ErrorAction SilentlyContinue)) { throw "DISM was not found." }
@($WorkRoot,"$WorkRoot\download","$WorkRoot\source","$WorkRoot\mount","$WorkRoot\output","$WorkRoot\logs") | ForEach-Object { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
Write-Host "Windows image workspace prepared: $WorkRoot"
