[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$WorkRoot,
 [Parameter(Mandatory=$true)][string]$BaseIsoUrl,
 [string]$BaseIsoSha256,[string]$SsuUrl,[string]$SsuSha256,[string]$LcuUrl,[string]$LcuSha256
)
$ErrorActionPreference="Stop"
$downloadRoot=Join-Path $WorkRoot "download"
New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
function Download-AndVerify {
 param([string]$Url,[string]$Destination,[string]$ExpectedSha256,[string]$Name)
 if ([string]::IsNullOrWhiteSpace($Url)) { return }
 Write-Host "Downloading $Name..."
 Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
 if (-not (Test-Path $Destination)) { throw "Download failed: $Destination" }
 if ($ExpectedSha256) {
   $actual=(Get-FileHash $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
   if ($actual -ne $ExpectedSha256.Trim().ToLowerInvariant()) { throw "$Name SHA256 mismatch." }
   Write-Host "$Name SHA256 verified: $actual"
 } else { Write-Warning "No SHA256 supplied for $Name." }
}
Download-AndVerify $BaseIsoUrl (Join-Path $downloadRoot "base.iso") $BaseIsoSha256 "Base ISO"
Download-AndVerify $SsuUrl (Join-Path $downloadRoot "ssu.msu") $SsuSha256 "SSU"
Download-AndVerify $LcuUrl (Join-Path $downloadRoot "lcu.msu") $LcuSha256 "LCU"
