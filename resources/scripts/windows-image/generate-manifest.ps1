[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$WorkRoot,[string]$OutputName="Windows-Custom",[int]$ImageIndex=1,
 [string]$BaseIsoUrl="",[string]$SsuUrl="",[string]$LcuUrl="",[string]$BuildNumber="",[string]$BuildId=""
)
$ErrorActionPreference="Stop"
$download=Join-Path $WorkRoot "download"
$source=Join-Path $WorkRoot "source"
$output=Join-Path $WorkRoot "output"
$iso=Join-Path $output "$OutputName.iso"
function Hash($p) { if (Test-Path $p) { return (Get-FileHash $p -Algorithm SHA256).Hash.ToLowerInvariant() }; return $null }
$m=[ordered]@{
 schemaVersion="1.0"
 image=[ordered]@{outputName=$OutputName;imageIndex=$ImageIndex;architecture="x64"}
 source=[ordered]@{baseIsoUrl=$BaseIsoUrl;baseIsoSha256=(Hash (Join-Path $download "base.iso"))}
 updates=[ordered]@{
   ssu=[ordered]@{url=$SsuUrl;sha256=(Hash (Join-Path $download "ssu.msu"))}
   lcu=[ordered]@{url=$LcuUrl;sha256=(Hash (Join-Path $download "lcu.msu"))}
 }
 servicedImage=[ordered]@{installWimSha256=(Hash (Join-Path $source "sources\install.wim"))}
 output=[ordered]@{isoFileName=[IO.Path]::GetFileName($iso);isoSha256=(Hash $iso)}
 build=[ordered]@{buildNumber=$BuildNumber;buildId=$BuildId;timestampUtc=(Get-Date).ToUniversalTime().ToString("o")}
}
$m | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $output "manifest.json") -Encoding UTF8
