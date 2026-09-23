[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkRoot,
    [Parameter(Mandatory=$true)][string]$BaseIsoArtifact,
    [string]$BaseIsoSha256 = '',
    [string]$WindowsBuild = '26100',
    [ValidateSet('x64','amd64','arm64')][string]$Architecture = 'x64',
    [string]$ArtifactoryBaseUrl = '',
    [string]$ArtifactoryRepo = 'snapshot-generic-local',
    [Parameter(Mandatory=$true)][string]$ArtifactoryUser,
    [Parameter(Mandatory=$true)][string]$ArtifactoryPassword,
    [Parameter(Mandatory=$true)][string]$ResolverScriptPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ($Architecture -match '^(?i)(amd64|x64)$') {$Architecture='x64'}
$WorkRoot=[IO.Path]::GetFullPath($WorkRoot)
$DownloadDir=Join-Path $WorkRoot 'download'
$UpdatesDir=Join-Path $DownloadDir 'updates'
$BaseIsoPath=Join-Path $DownloadDir 'base.iso'
$ResolvedPath=Join-Path $DownloadDir 'resolved-updates.json'
$CacheMarker=Join-Path $DownloadDir 'patched-cache-hit.json'
New-Item -ItemType Directory -Force -Path $DownloadDir,$UpdatesDir | Out-Null
$ArtifactoryBaseUrl=$ArtifactoryBaseUrl.TrimEnd('/')
$ArtifactoryUrlRoot=if ($ArtifactoryBaseUrl.EndsWith('/artifactory')) {$ArtifactoryBaseUrl} else {"$ArtifactoryBaseUrl/artifactory"}
if ([string]::IsNullOrWhiteSpace($ArtifactoryBaseUrl)) {throw 'ArtifactoryBaseUrl is required.'}
if ([string]::IsNullOrWhiteSpace($ArtifactoryRepo)) {throw 'ArtifactoryRepo is required.'}

$pair='{0}:{1}' -f $ArtifactoryUser,$ArtifactoryPassword
$headers=@{Authorization='Basic '+[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))}
function Get-ArtifactUrl([string]$Path) { return "$ArtifactoryUrlRoot/$ArtifactoryRepo/$($Path.TrimStart('/'))" }
function Get-Sha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-ArtifactText([string]$Path) {
    $uri=Get-ArtifactUrl $Path
    try { return (Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 60).Content }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
}
function Download-Artifact([string]$Path,[string]$Destination,[string]$ExpectedSha256='') {
    $spec="$ArtifactoryRepo/$Path"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    & jf rt download --server-id=local-artifactory --flat=true "$spec" "$(Split-Path -Parent $Destination)\"
    if ($LASTEXITCODE -ne 0) { throw "JFrog download failed with exit code ${LASTEXITCODE}: $spec" }
    $source=Join-Path (Split-Path -Parent $Destination) ([IO.Path]::GetFileName($Path))
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Downloaded artifact not found: $source" }
    if ($source -ne $Destination) { Move-Item -LiteralPath $source -Destination $Destination -Force }
    if ($ExpectedSha256) {
        $actual=Get-Sha256 $Destination
        if ($actual -ne $ExpectedSha256.ToLowerInvariant()) { throw "SHA256 mismatch for $Path. Expected $ExpectedSha256, actual $actual" }
    }
}

Write-Host '============================================================'
Write-Host ' Resolve LCU and Check Patched Image Cache'
Write-Host '============================================================'
Write-Host "Windows Build: $WindowsBuild"
Write-Host "Architecture : $Architecture"

if (Test-Path -LiteralPath $CacheMarker) { Remove-Item -LiteralPath $CacheMarker -Force }
if (-not (Test-Path -LiteralPath $ResolverScriptPath -PathType Leaf)) { throw "Resolver script does not exist: $ResolverScriptPath" }

# Resolve the LCU first. The resolver also populates download\updates from the immutable LCU cache.
& $ResolverScriptPath -WorkRoot $WorkRoot -WindowsBuild $WindowsBuild -Architecture $Architecture -ArtifactoryBaseUrl $ArtifactoryBaseUrl -ArtifactoryRepo $ArtifactoryRepo -ArtifactoryUser $ArtifactoryUser -ArtifactoryPassword $ArtifactoryPassword
if ($LASTEXITCODE -ne 0) { throw "Update resolver failed with exit code $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath $ResolvedPath -PathType Leaf)) { throw "Resolved update manifest was not created: $ResolvedPath" }
$resolved=Get-Content -LiteralPath $ResolvedPath -Raw | ConvertFrom-Json
if (-not $resolved.kb -or -not $resolved.build -or -not $resolved.sha256) { throw 'Resolved update manifest is missing KB, build, or SHA256.' }

$kb=$resolved.kb.ToString().ToUpperInvariant()
$lcuBuild=$resolved.build.ToString()
$normalizedArch=if ($Architecture -eq 'amd64') {'x64'} else {$Architecture.ToLowerInvariant()}
$patchedBase="Windows11/24H2/$normalizedArch/patched/$lcuBuild"
$manifestArtifact="$patchedBase/manifest.json"
$isoName="Windows11-24H2-$normalizedArch-$lcuBuild-$kb.iso"
$isoArtifact="$patchedBase/$isoName"

Write-Host "Resolved LCU: $kb / $lcuBuild"
Write-Host "Patched manifest: $(Get-ArtifactUrl $manifestArtifact)"

# A cache hit is valid only when the manifest represents the exact requested inputs.
if ([string]::IsNullOrWhiteSpace($BaseIsoSha256)) {
    Write-Warning 'BASE_ISO_SHA256 is empty; exact patched-image cache validation is disabled.'
} else {
    $remoteManifest=Get-ArtifactText $manifestArtifact
    if ($remoteManifest) {
        try {
            $m=$remoteManifest | ConvertFrom-Json
            $remoteBase=([string]$m.source.baseIsoSha256).ToLowerInvariant()
            $remoteLcu=$m.updates.lcu
            $remoteKb=([string]$remoteLcu.kb).ToUpperInvariant()
            $remoteBuild=[string]$remoteLcu.build
            $remoteSha=([string]$remoteLcu.sha256).ToLowerInvariant()
            $remoteUpdateId=[string]$remoteLcu.updateId
            $wantedSha=$BaseIsoSha256.ToLowerInvariant()
            $wantedUpdateId=[string]$resolved.updateId
            $same = ($remoteBase -eq $wantedSha) -and ($remoteKb -eq $kb) -and ($remoteBuild -eq $lcuBuild) -and ($remoteSha -eq $resolved.sha256.ToLowerInvariant())
            if ($wantedUpdateId -and $remoteUpdateId) { $same = $same -and ($remoteUpdateId -eq $wantedUpdateId) }
            if ($same) {
                [ordered]@{cacheHit=$true;manifestArtifactPath=$manifestArtifact;isoArtifactPath=$isoArtifact;kb=$kb;build=$lcuBuild} | ConvertTo-Json | Set-Content -LiteralPath $CacheMarker -Encoding UTF8
                Write-Host 'PATCHED IMAGE CACHE HIT'
                Write-Host 'Base ISO download skipped.'
                Write-Host 'MSU download skipped.'
                exit 0
            }
            Write-Host 'Patched image manifest exists, but inputs do not match. Cache miss.'
        } catch { Write-Warning "Could not parse remote patched manifest: $($_.Exception.Message)" }
    } else { Write-Host 'Patched image manifest not found. Cache miss.' }
}

# Cache miss: now download the base ISO. The resolver already cached/downloaded the MSU.
Write-Host '============================================================'
Write-Host ' Download Base ISO (cache miss)'
Write-Host '============================================================'
Download-Artifact -Path $BaseIsoArtifact -Destination $BaseIsoPath -ExpectedSha256 $BaseIsoSha256
if (-not (Test-Path -LiteralPath $BaseIsoPath -PathType Leaf)) { throw "Base ISO was not downloaded: $BaseIsoPath" }
if ($BaseIsoSha256) {
    $actualBase=Get-Sha256 $BaseIsoPath
    if ($actualBase -ne $BaseIsoSha256.ToLowerInvariant()) { throw "Base ISO SHA256 mismatch. Expected $BaseIsoSha256, actual $actualBase" }
}

$updates=@($resolved)
foreach ($update in $updates) {
    $package=Join-Path $UpdatesDir $update.fileName
    if (-not (Test-Path -LiteralPath $package -PathType Leaf)) { throw "Resolved update package is missing: $package" }
    $actual=Get-Sha256 $package
    if ($actual -ne $update.sha256.ToLowerInvariant()) { throw "MSU SHA256 mismatch for $($update.fileName). Expected $($update.sha256), actual $actual" }
}
Write-Host 'Download stage: SUCCESS'
exit 0
