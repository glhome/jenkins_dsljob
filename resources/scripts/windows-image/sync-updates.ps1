[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$WorkRoot,
 [Parameter(Mandatory=$true)][string]$WindowsBuild,
 [Parameter(Mandatory=$true)][string]$Architecture,
 [Parameter(Mandatory=$true)][string]$ArtifactoryRepo,
 [Parameter(Mandatory=$true)][string]$ArtifactoryBaseUrl
)
$ErrorActionPreference="Stop"
$sel=Join-Path $WorkRoot "download\update-selection.json"
$dst=Join-Path $WorkRoot "download\updates"
New-Item -ItemType Directory -Force -Path $dst|Out-Null
if(!(Test-Path $sel)){throw "Update selection not found: $sel"}
if(!(Get-Command jf.exe -ErrorAction SilentlyContinue)){throw "jf.exe not found on Jenkins agent."}
$m=Get-Content $sel -Raw|ConvertFrom-Json
$r=@()
foreach($u in @($m.updates)){
 $kb=[string]$u.kb;$type=[string]$u.type
 $fn=if($u.fileName){[string]$u.fileName}else{Split-Path ([string]$u.sourceUrl) -Leaf}
 if([string]::IsNullOrWhiteSpace($fn)){$fn="$kb.msu"}
 $rel="$WindowsBuild/$Architecture/$type/$kb/$fn"
 $repo="$ArtifactoryRepo/$rel";$local=Join-Path $dst $fn
 $j=&jf.exe rt search $repo --count 2>$null
 $hit=$false
 if($LASTEXITCODE -eq 0 -and $j){try{$hit=@($j|ConvertFrom-Json).Count -gt 0}catch{$hit=$false}}
 if($hit){
   Write-Host "CACHE HIT: $kb"
   &jf.exe rt dl $repo $local --flat=true --fail-no-op=true
   if($LASTEXITCODE-ne0){throw "Artifactory download failed: $kb"}
 }else{
   Write-Host "CACHE MISS: $kb"
   Invoke-WebRequest -Uri ([string]$u.sourceUrl) -OutFile $local -UseBasicParsing
   $h=(Get-FileHash $local -Algorithm SHA256).Hash.ToLowerInvariant()
   if($u.sha256 -and $h -ne ([string]$u.sha256).Trim().ToLowerInvariant()){throw "SHA256 mismatch: $kb"}
   &jf.exe rt u $local $repo --flat=true --fail-no-op=true
   if($LASTEXITCODE-ne0){throw "Failed to publish immutable update: $kb"}
 }
 $h=(Get-FileHash $local -Algorithm SHA256).Hash.ToLowerInvariant()
 if($u.sha256 -and $h -ne ([string]$u.sha256).Trim().ToLowerInvariant()){throw "SHA256 mismatch after cache retrieval: $kb"}
 $r+=[pscustomobject][ordered]@{kb=$kb;type=$type;windowsBuild=$WindowsBuild;architecture=$Architecture;fileName=$fn;sha256=$h;artifactoryPath=$rel;artifactoryUrl="$ArtifactoryBaseUrl/$ArtifactoryRepo/$rel";sourceUrl=[string]$u.sourceUrl}
}
$r|ConvertTo-Json -Depth 10|Set-Content (Join-Path $WorkRoot "download\resolved-updates.json") -Encoding UTF8
