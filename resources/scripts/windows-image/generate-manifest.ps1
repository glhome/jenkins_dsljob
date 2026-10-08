[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkRoot,
    [string]$OutputName='Windows-Custom',
    [int]$ImageIndex=1,
    [string]$Architecture='x64',
    [string]$WindowsVersion='',
    [string]$WindowsBuild=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$download=Join-Path $WorkRoot 'download'; $source=Join-Path $WorkRoot 'source'; $output=Join-Path $WorkRoot 'output'; $iso=Join-Path $output "$OutputName.iso"; $resolvedPath=Join-Path $download 'resolved-updates.json'
function Hash($p){if(Test-Path -LiteralPath $p -PathType Leaf){return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()};return $null}
$resolved=$null;if(Test-Path -LiteralPath $resolvedPath -PathType Leaf){$resolved=Get-Content -LiteralPath $resolvedPath -Raw|ConvertFrom-Json}
if($resolved){if(!$WindowsVersion){$WindowsVersion=[string]$resolved.windowsVersion};if(!$WindowsBuild){$WindowsBuild=[string]$resolved.windowsBuild}}
$lcu=$null;if($resolved){$lcu=[ordered]@{kb=$resolved.kb;build=$resolved.build;releaseDate=$resolved.releaseDate;updateId=$resolved.updateId;fileName=$resolved.fileName;sha256=$resolved.sha256;artifactoryUrl=$resolved.artifactoryUrl;artifactoryPath=$resolved.artifactoryPath;source=$resolved.source}}
$m=[ordered]@{schemaVersion='1.0';image=[ordered]@{outputName=$OutputName;imageIndex=$ImageIndex;architecture=$Architecture;windowsVersion=$WindowsVersion;windowsBuild=$WindowsBuild};source=[ordered]@{baseIsoSha256=(Hash (Join-Path $download 'base.iso'))};updates=[ordered]@{lcu=$lcu;ssuIncluded=if($resolved){[bool]$resolved.ssuIncluded}else{$null}};servicedImage=[ordered]@{installWimSha256=(Hash (Join-Path $source 'sources\install.wim'))};output=[ordered]@{isoFileName=[IO.Path]::GetFileName($iso);isoSha256=(Hash $iso)};build=[ordered]@{timestampUtc=(Get-Date).ToUniversalTime().ToString('o')}}
$json=$m|ConvertTo-Json -Depth 20
[IO.File]::WriteAllText((Join-Path $output 'manifest.json'),$json,(New-Object System.Text.UTF8Encoding($false)))
