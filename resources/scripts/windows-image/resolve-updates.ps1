[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$WorkRoot,
 [string]$Profile='windows11-24h2',
 [string]$WindowsBuild='',
 [Parameter(Mandatory=$false)][string]$ProfileScriptPath='',
 [ValidateSet('x64','amd64','arm64')][string]$Architecture='x64',
 [string]$ArtifactoryBaseUrl='',
 [string]$ArtifactoryRepo='snapshot-generic-local',
 [string]$ArtifactoryUser='',
 [string]$ArtifactoryPassword='',
 [string]$ArtifactoryToken='',
 [switch]$ForceMicrosoftDownload,
 [switch]$ResolveOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

if ($Architecture -match '^(?i)(amd64|x64)$') {$Architecture='x64'}
. $(if ($ProfileScriptPath) { $ProfileScriptPath } else { Join-Path $PSScriptRoot 'profiles.ps1' })
$profileInfo=Get-WindowsImageProfile -Name $Profile
if ($WindowsBuild -and $WindowsBuild -ne $profileInfo.Build) { throw "WindowsBuild '$WindowsBuild' does not match profile '$Profile' build '$($profileInfo.Build)'." }
$WindowsBuild=$profileInfo.Build
if ($profileInfo.Name -eq 'windows10-21h2' -and $Architecture -eq 'arm64') { throw 'windows10-21h2 profile currently supports x64 only.' }

$downloadDir=Join-Path $WorkRoot 'download'; $updateDir=Join-Path $downloadDir 'updates'; $manifest=Join-Path $downloadDir 'resolved-updates.json'
New-Item -ItemType Directory -Force -Path $downloadDir,$updateDir | Out-Null
$ArtifactoryBaseUrl=$ArtifactoryBaseUrl.TrimEnd('/')
if (-not $ArtifactoryBaseUrl) {throw 'ArtifactoryBaseUrl is required.'}
if (-not $ArtifactoryBaseUrl.EndsWith('/artifactory')) {$ArtifactoryUrlRoot="$ArtifactoryBaseUrl/artifactory"} else {$ArtifactoryUrlRoot=$ArtifactoryBaseUrl}
$pair="$ArtifactoryUser`:$ArtifactoryPassword"; $headers=@{Authorization='Basic '+[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))}
function AUrl([string]$p){"$ArtifactoryUrlRoot/$ArtifactoryRepo/$($p.TrimStart('/'))"}
function Sha([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function Find([string]$p){try{(Invoke-WebRequest -Uri (AUrl $p) -Headers $headers -Method Head -UseBasicParsing -TimeoutSec 60)|Out-Null;AUrl $p}catch{if($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404){$null}else{throw}}}
function Download([string]$url,[string]$dest,[hashtable]$RequestHeaders=$null){if($RequestHeaders){Invoke-WebRequest -Uri $url -Headers $RequestHeaders -OutFile $dest -UseBasicParsing -TimeoutSec 3600}else{Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 3600};if(!(Test-Path $dest)){throw "Download failed: $url"}}
function Catalog([string]$q){(Invoke-WebRequest -Uri ('https://www.catalog.update.microsoft.com/Search.aspx?q='+[uri]::EscapeDataString($q)) -UseBasicParsing -TimeoutSec 120).Content}
function DownloadUrls([string]$id){$obj=@{size=0;updateID=$id;uidInfo=$id}|ConvertTo-Json -Compress;$body=@{updateIDs="[$obj]"};$c=(Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 120).Content.Replace('&amp;','&');[regex]::Matches($c,'https?://[^"''\s<>]+')|ForEach-Object{$u=$_.Value.TrimEnd("'",'"',')',';');if($u -match '(?i)(download\.windowsupdate\.com|windowsupdate\.com|delivery\.mp\.microsoft\.com)'){$u}}|Select-Object -Unique}
function Candidates([string]$html){$out=@();foreach($r in [regex]::Matches($html,'<tr[^>]*>(.*?)</tr>',[Text.RegularExpressions.RegexOptions]::Singleline)){$row=$r.Groups[1].Value;$p=[Net.WebUtility]::HtmlDecode(($row -replace '<[^>]+>',' ')) -replace '\s+',' ';if($p -notmatch [regex]::Escape($profileInfo.WindowsVersion) -or $p -notmatch '(?i)Cumulative Update' -or $p -notmatch '(?i)Security Updates|LTSB Updates' -or $p -match '(?i)Preview|\.NET|Dynamic Update|Server'){continue};if($Architecture -eq 'x64' -and ($p -notmatch '(?i)x64-based Systems' -or $p -match '(?i)ARM64')){continue};$k=[regex]::Match($p,'(?i)\(KB(\d+)\)');if(!$k.Success){continue};$b=[regex]::Match($p,"\($([regex]::Escape($profileInfo.Build))\.\d+\)");if(!$b.Success){$b=[regex]::Match($p,"\($([regex]::Escape($profileInfo.Build))\.\d+)")};$fullb=[regex]::Match($p,"($([regex]::Escape($profileInfo.Build)))\.\d+");$d=[regex]::Match($p,'(\d{1,2}/\d{1,2}/\d{4})');$ids=[regex]::Matches($row,'(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')|ForEach-Object Value|Select-Object -Unique;$out+=[pscustomobject]@{KB="KB$($k.Groups[1].Value)";Build=if($fullb.Success){$fullb.Value}else{''};Date=if($d.Success){[datetime]::Parse($d.Groups[1].Value)}else{[datetime]::MinValue};Title=$p;UpdateIds=@($ids)}};@($out)}
function TestMsuName([string]$name,[string]$kb){$n=$kb -replace '^KB','';$name -match "(?i)kb$([regex]::Escape($n))(?:[^0-9]|$)" -and $name -match '(?i)\.msu$' -and (($Architecture -eq 'x64' -and $name -match '(?i)(x64|amd64)') -or ($Architecture -eq 'arm64' -and $name -match '(?i)arm64'))}

Write-Host "Resolving $($profileInfo.WindowsVersion) $Architecture LCU..."
$c=Candidates (Catalog $profileInfo.CatalogQuery);if(!$c){throw "No matching $($profileInfo.WindowsVersion) $Architecture cumulative update found for build $WindowsBuild."}
$selected=$c | Group-Object KB | ForEach-Object { $_.Group | Sort-Object -Property Date -Descending | Select-Object -First 1 } | Sort-Object -Property @{Expression={ try { [version]$_.Build } catch { [version]'0.0' } }; Descending=$true}, Date -Descending | Select-Object -First 1
$ids=@($selected.UpdateIds);if(!$ids){$ids=@([regex]::Matches((Catalog $selected.KB),'(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')|ForEach-Object Value|Select-Object -Unique)};if(!$ids){throw "Unable to resolve UpdateID for $($selected.KB)."}
$chosen=$null;foreach($id in $ids){foreach($url in @(DownloadUrls $id)){try{$fn=[IO.Path]::GetFileName(([uri]$url).AbsolutePath);if(TestMsuName $fn $selected.KB){$chosen=[pscustomobject]@{UpdateId=$id;Url=$url;FileName=$fn};break}}catch{} };if($chosen){break}}
if(!$chosen){throw "Unable to resolve a valid MSU for $($selected.KB)."}
$relative="$($profileInfo.ArtifactRoot)/$Architecture/LCU/$($selected.KB)/$($chosen.FileName)";$local=Join-Path $updateDir $chosen.FileName
$artifact=AUrl $relative

if ($ResolveOnly) {
    [ordered]@{schemaVersion='1.0';type='LCU';profile=$profileInfo.Name;product=$profileInfo.Product;windowsVersion=$profileInfo.WindowsVersion;release=$profileInfo.Release;windowsBuild=$WindowsBuild;architecture=$Architecture;isoPrefix=$profileInfo.IsoPrefix;kb=$selected.KB;build=$selected.Build;updateId=$chosen.UpdateId;releaseDate=$selected.Date.ToString('yyyy-MM-dd');fileName=$chosen.FileName;sha256='';microsoftUrl=$chosen.Url;artifactoryUrl=$artifact;artifactoryRepo=$ArtifactoryRepo;artifactoryPath=$relative;artifactRoot=$profileInfo.ArtifactRoot;source='ResolveOnly';ssuIncluded=$true;resolvedAtUtc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $manifest -Encoding UTF8
    Write-Host "Resolved $($selected.KB) / $($selected.Build) (resolve-only; MSU download skipped)"
    exit 0
}

$artifact=Find $relative
if($artifact -and !$ForceMicrosoftDownload){Download $artifact $local $headers;$source='Artifactory'}else{Download $chosen.Url $local;$source='Microsoft';if(!(Test-Path $local)){throw 'Microsoft download failed.'};if(-not (Find $relative)){& jf rt upload --server-id=local-artifactory --flat=true --detailed-summary $local "$ArtifactoryRepo/$relative" 2>&1;if($LASTEXITCODE -ne 0){throw "JFrog upload failed with exit code ${LASTEXITCODE}"}};$artifact=AUrl $relative}
$sha=Sha $local
[ordered]@{schemaVersion='1.0';type='LCU';profile=$profileInfo.Name;product=$profileInfo.Product;windowsVersion=$profileInfo.WindowsVersion;release=$profileInfo.Release;windowsBuild=$WindowsBuild;architecture=$Architecture;isoPrefix=$profileInfo.IsoPrefix;kb=$selected.KB;build=$selected.Build;updateId=$chosen.UpdateId;releaseDate=$selected.Date.ToString('yyyy-MM-dd');fileName=$chosen.FileName;sha256=$sha;microsoftUrl=$chosen.Url;artifactoryUrl=$artifact;artifactoryRepo=$ArtifactoryRepo;artifactoryPath=$relative;artifactRoot=$profileInfo.ArtifactRoot;source=$source;ssuIncluded=$true;resolvedAtUtc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $manifest -Encoding UTF8
Write-Host "Resolved $($selected.KB) / $($selected.Build) / $sha"
exit 0
