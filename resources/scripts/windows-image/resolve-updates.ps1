[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$WorkRoot,
 [string]$WindowsBuild='26100',
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
$downloadDir=Join-Path $WorkRoot 'download'; $updateDir=Join-Path $downloadDir 'updates'; $manifest=Join-Path $downloadDir 'resolved-updates.json'
New-Item -ItemType Directory -Force -Path $downloadDir,$updateDir | Out-Null
$ArtifactoryBaseUrl=$ArtifactoryBaseUrl.TrimEnd('/'); if (-not $ArtifactoryBaseUrl.EndsWith('/artifactory')) {$ArtifactoryUrlRoot="$ArtifactoryBaseUrl/artifactory"} else {$ArtifactoryUrlRoot=$ArtifactoryBaseUrl}
if (!$ArtifactoryBaseUrl) {throw 'ArtifactoryBaseUrl is required.'}
$pair="$ArtifactoryUser`:$ArtifactoryPassword"; $headers=@{Authorization='Basic '+[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))}
function AUrl([string]$p){"$ArtifactoryUrlRoot/$ArtifactoryRepo/$($p.TrimStart('/'))"}
function Sha([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function Find([string]$p){try{(Invoke-WebRequest -Uri (AUrl $p) -Headers $headers -Method Head -UseBasicParsing -TimeoutSec 60)|Out-Null;AUrl $p}catch{if($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404){$null}else{throw}}}
function Download([string]$url,[string]$dest){Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 3600;if(!(Test-Path $dest)){throw "Download failed: $url"}}
function Catalog([string]$q){(Invoke-WebRequest -Uri ('https://www.catalog.update.microsoft.com/Search.aspx?q='+[uri]::EscapeDataString($q)) -UseBasicParsing -TimeoutSec 120).Content}
function DownloadUrls([string]$id){$obj=@{size=0;updateID=$id;uidInfo=$id}|ConvertTo-Json -Compress;$body=@{updateIDs="[$obj]"};$c=(Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 120).Content.Replace('&amp;','&');[regex]::Matches($c,'https?://[^"''\s<>]+')|ForEach-Object{$u=$_.Value.TrimEnd("'",'"',')',';');if($u -match '(?i)(download\.windowsupdate\.com|windowsupdate\.com|delivery\.mp\.microsoft\.com)'){$u}}|Select-Object -Unique}
function Candidates([string]$html){$out=@();foreach($r in [regex]::Matches($html,'<tr[^>]*>(.*?)</tr>',[Text.RegularExpressions.RegexOptions]::Singleline)){$row=$r.Groups[1].Value;$p=[Net.WebUtility]::HtmlDecode(($row -replace '<[^>]+>',' ')) -replace '\s+',' ';if($p -notmatch '(?i)Windows 11' -or $p -notmatch '(?i)version 24H2' -or $p -notmatch '(?i)Cumulative Update' -or $p -notmatch '(?i)Security Updates' -or $p -match '(?i)Preview|\.NET|Dynamic Update|Server'){continue};if($Architecture -eq 'x64' -and ($p -notmatch '(?i)x64-based Systems' -or $p -match '(?i)ARM64')){continue};$k=[regex]::Match($p,'(?i)\(KB(\d+)\)');if(!$k.Success){continue};$b=[regex]::Match($p,'\((26100\.\d+)\)');$d=[regex]::Match($p,'(\d{1,2}/\d{1,2}/\d{4})');$ids=[regex]::Matches($row,'(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')|ForEach-Object Value|Select-Object -Unique;$out+=[pscustomobject]@{KB="KB$($k.Groups[1].Value)";Build=if($b.Success){$b.Groups[1].Value}else{''};Date=if($d.Success){[datetime]::Parse($d.Groups[1].Value)}else{[datetime]::MinValue};Title=$p;UpdateIds=@($ids)}};@($out)}
function TestMsuName([string]$name,[string]$kb){$n=$kb -replace '^KB','';$name -match "(?i)kb$([regex]::Escape($n))(?:[^0-9]|$)" -and $name -match '(?i)\.msu$' -and (($Architecture -eq 'x64' -and $name -match '(?i)(x64|amd64)') -or ($Architecture -eq 'arm64' -and $name -match '(?i)arm64'))}

Write-Host "Resolving latest Windows 11 24H2 $Architecture LCU..."
$c=Candidates (Catalog "Windows 11 24H2 cumulative update $Architecture");if(!$c){throw 'No matching Windows 11 24H2 cumulative update found.'}
$selected=$c | Group-Object KB | ForEach-Object { $_.Group | Sort-Object -Property Date -Descending | Select-Object -First 1 } | Sort-Object -Property @{Expression={ try { [version]$_.Build } catch { [version]'0.0' } }; Descending=$true}, Date -Descending | Select-Object -First 1
$ids=@($selected.UpdateIds);if(!$ids){$ids=@([regex]::Matches((Catalog $selected.KB),'(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')|ForEach-Object Value|Select-Object -Unique)};if(!$ids){throw "Unable to resolve UpdateID for $($selected.KB)."}
$chosen=$null;foreach($id in $ids){foreach($url in @(DownloadUrls $id)){try{$fn=[IO.Path]::GetFileName(([uri]$url).AbsolutePath);if(TestMsuName $fn $selected.KB){$chosen=[pscustomobject]@{UpdateId=$id;Url=$url;FileName=$fn};break}}catch{} };if($chosen){break}}
if(!$chosen){throw "Unable to resolve a valid MSU for $($selected.KB)."}
$relative="Windows11/24H2/$Architecture/LCU/$($selected.KB)/$($chosen.FileName)";$local=Join-Path $updateDir $chosen.FileName
$artifact=Find $relative
if($artifact -and !$ForceMicrosoftDownload){Download $artifact $local;$source='Artifactory'}else{Download $chosen.Url $local;$source='Microsoft';if(!(Test-Path $local)){throw 'Microsoft download failed.'};$target=AUrl $relative;if(-not (Find $relative)){& jf rt upload --server-id=local-artifactory --flat=true --detailed-summary $local "$ArtifactoryRepo/$relative";if($LASTEXITCODE -ne 0){throw "JFrog upload failed with exit code $LASTEXITCODE"}};$artifact=AUrl $relative}
if ($ResolveOnly) {
    [ordered]@{schemaVersion='1.0';type='LCU';kb=$selected.KB;build=$selected.Build;windowsVersion='Windows 11 24H2';windowsBuild=$WindowsBuild;architecture=$Architecture;updateId=$chosen.UpdateId;releaseDate=$selected.Date.ToString('yyyy-MM-dd');fileName=$chosen.FileName;sha256='';microsoftUrl=$chosen.Url;artifactoryUrl=$artifact;artifactoryRepo=$ArtifactoryRepo;artifactoryPath=$relative;source='ResolveOnly';ssuIncluded=$true;resolvedAtUtc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $manifest -Encoding UTF8
    Write-Host "Resolved $($selected.KB) / $($selected.Build) (resolve-only; MSU download skipped)"
    exit 0
}
$sha=Sha $local
[ordered]@{schemaVersion='1.0';type='LCU';kb=$selected.KB;build=$selected.Build;windowsVersion='Windows 11 24H2';windowsBuild=$WindowsBuild;architecture=$Architecture;updateId=$chosen.UpdateId;releaseDate=$selected.Date.ToString('yyyy-MM-dd');fileName=$chosen.FileName;sha256=$sha;microsoftUrl=$chosen.Url;artifactoryUrl=$artifact;artifactoryRepo=$ArtifactoryRepo;artifactoryPath=$relative;source=$source;ssuIncluded=$true;resolvedAtUtc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $manifest -Encoding UTF8
Write-Host "Resolved $($selected.KB) / $($selected.Build) / $sha"
exit 0
