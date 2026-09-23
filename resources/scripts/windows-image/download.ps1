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
$ErrorActionPreference = 'Stop'

if ($Architecture -match '(?i)^(amd64|x64)$') { $Architecture = 'x64' }
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
$DownloadDir = Join-Path $WorkRoot 'download'
$UpdatesDir = Join-Path $DownloadDir 'updates'
$BaseIsoPath = Join-Path $DownloadDir 'base.iso'
$ResolvedPath = Join-Path $DownloadDir 'resolved-updates.json'
$CacheMarker = Join-Path $DownloadDir 'patched-cache-hit.json'
New-Item -ItemType Directory -Force -Path $DownloadDir, $UpdatesDir | Out-Null

if ([string]::IsNullOrWhiteSpace($ArtifactoryBaseUrl)) { throw 'ArtifactoryBaseUrl is required.' }
if ([string]::IsNullOrWhiteSpace($ArtifactoryRepo)) { throw 'ArtifactoryRepo is required.' }
$ArtifactoryBaseUrl = $ArtifactoryBaseUrl.TrimEnd('/')
$ArtifactoryUrlRoot = if ($ArtifactoryBaseUrl.EndsWith('/artifactory')) { $ArtifactoryBaseUrl } else { "$ArtifactoryBaseUrl/artifactory" }

$pair = '{0}:{1}' -f $ArtifactoryUser, $ArtifactoryPassword
$headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair)) }

function Get-ArtifactUrl([string]$Path) {
    return "$ArtifactoryUrlRoot/$ArtifactoryRepo/$($Path.TrimStart('/'))"
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ArtifactText([string]$Path) {
    $uri = Get-ArtifactUrl $Path
    try {
        return (Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 60).Content
    }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }
}

function Test-ArtifactExists([string]$Path) {
    $uri = Get-ArtifactUrl $Path
    try {
        Invoke-WebRequest -Uri $uri -Headers $headers -Method Head -UseBasicParsing -TimeoutSec 60 | Out-Null
        return $true
    }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $false }
        throw
    }
}

function Download-Artifact([string]$Path,[string]$Destination,[string]$ExpectedSha256='') {
    $spec = "$ArtifactoryRepo/$Path"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    & jf rt download --server-id=local-artifactory --flat=true "$spec" "$(Split-Path -Parent $Destination)\"
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "JFrog download failed with exit code ${exitCode}: $spec" }
    $source = Join-Path (Split-Path -Parent $Destination) ([IO.Path]::GetFileName($Path))
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Downloaded artifact not found: $source" }
    if ($source -ne $Destination) { Move-Item -LiteralPath $source -Destination $Destination -Force }
    if ($ExpectedSha256) {
        $actual = Get-Sha256 $Destination
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

# Resolve update identity only. This must not download the base ISO or MSU.
& $ResolverScriptPath -WorkRoot $WorkRoot -WindowsBuild $WindowsBuild -Architecture $Architecture -ArtifactoryBaseUrl $ArtifactoryBaseUrl -ArtifactoryRepo $ArtifactoryRepo -ArtifactoryUser $ArtifactoryUser -ArtifactoryPassword $ArtifactoryPassword -ResolveOnly
$resolveExit = $LASTEXITCODE
if ($resolveExit -ne 0) { throw "Update resolver failed with exit code ${resolveExit}" }
if (-not (Test-Path -LiteralPath $ResolvedPath -PathType Leaf)) { throw "Resolved update manifest was not created: $ResolvedPath" }

$resolved = Get-Content -LiteralPath $ResolvedPath -Raw | ConvertFrom-Json
if (-not $resolved.kb -or -not $resolved.build -or -not $resolved.updateId -or -not $resolved.fileName) {
    throw 'Resolved update manifest is missing KB, build, UpdateID, or fileName.'
}

$kb = $resolved.kb.ToString().ToUpperInvariant()
$lcuBuild = $resolved.build.ToString()
$normalizedArch = if ($Architecture -eq 'amd64') { 'x64' } else { $Architecture.ToLowerInvariant() }
$patchedBase = "Windows11/24H2/$normalizedArch/patched/$lcuBuild"
$manifestArtifact = "$patchedBase/manifest.json"
$isoName = "Windows11-24H2-$normalizedArch-$lcuBuild-$kb.iso"
$isoArtifact = "$patchedBase/$isoName"

Write-Host "Resolved LCU: $kb / $lcuBuild"
Write-Host "UpdateID    : $($resolved.updateId)"
Write-Host "MSU         : $($resolved.fileName)"
Write-Host "Patched manifest: $(Get-ArtifactUrl $manifestArtifact)"

# Exact cache validation. BASE_ISO_SHA256 is required because the pipeline must
# be able to decide on a cache hit before downloading the base ISO.
$cacheHit = $false
if ([string]::IsNullOrWhiteSpace($BaseIsoSha256)) {
    Write-Warning 'BASE_ISO_SHA256 is empty; exact patched-image cache validation is disabled.'
}
else {
    $remoteManifest = Get-ArtifactText $manifestArtifact
    if ($remoteManifest) {
        try {
            $m = $remoteManifest | ConvertFrom-Json
            $remoteBase = ([string]$m.source.baseIsoSha256).ToLowerInvariant()
            $remoteImageBuild = [string]$m.image.windowsBuild
            $remoteArch = [string]$m.image.architecture
            $remoteLcu = $m.updates.lcu
            $remoteKb = ([string]$remoteLcu.kb).ToUpperInvariant()
            $remoteBuild = [string]$remoteLcu.build
            $remoteUpdateId = [string]$remoteLcu.updateId
            $remoteFileName = [string]$remoteLcu.fileName
            $wantedBase = $BaseIsoSha256.ToLowerInvariant()
            $wantedUpdateId = [string]$resolved.updateId
            $wantedFileName = [string]$resolved.fileName

            $same =
                ($remoteBase -eq $wantedBase) -and
                ($remoteImageBuild -eq [string]$WindowsBuild) -and
                ($remoteArch -ieq $normalizedArch) -and
                ($remoteKb -eq $kb) -and
                ($remoteBuild -eq $lcuBuild) -and
                ($remoteUpdateId -eq $wantedUpdateId) -and
                ($remoteFileName -eq $wantedFileName)

            if ($same -and (Test-ArtifactExists $isoArtifact)) {
                $cacheHit = $true
                [ordered]@{
                    cacheHit = $true
                    manifestArtifactPath = $manifestArtifact
                    isoArtifactPath = $isoArtifact
                    kb = $kb
                    build = $lcuBuild
                    updateId = $wantedUpdateId
                } | ConvertTo-Json | Set-Content -LiteralPath $CacheMarker -Encoding UTF8
                Write-Host 'PATCHED IMAGE CACHE HIT'
                Write-Host 'Base ISO download skipped.'
                Write-Host 'MSU download skipped.'
                exit 0
            }
            Write-Host 'Patched image manifest exists, but inputs do not match or ISO is missing. Cache miss.'
        }
        catch {
            Write-Warning "Could not parse remote patched manifest: $($_.Exception.Message)"
        }
    }
    else {
        Write-Host 'Patched image manifest not found. Cache miss.'
    }
}

# Cache miss: download the base ISO first, then resolve/download the actual MSU.
Write-Host '============================================================'
Write-Host ' Download Base ISO and MSU (cache miss)'
Write-Host '============================================================'
Download-Artifact -Path $BaseIsoArtifact -Destination $BaseIsoPath -ExpectedSha256 $BaseIsoSha256
if (-not (Test-Path -LiteralPath $BaseIsoPath -PathType Leaf)) { throw "Base ISO was not downloaded: $BaseIsoPath" }

if ($BaseIsoSha256) {
    $actualBase = Get-Sha256 $BaseIsoPath
    if ($actualBase -ne $BaseIsoSha256.ToLowerInvariant()) { throw "Base ISO SHA256 mismatch. Expected $BaseIsoSha256, actual $actualBase" }
}

# Resolve again without -ResolveOnly. The resolver will obtain the MSU from the
# immutable update cache or Microsoft, validate it, and populate download\updates.
& $ResolverScriptPath -WorkRoot $WorkRoot -WindowsBuild $WindowsBuild -Architecture $Architecture -ArtifactoryBaseUrl $ArtifactoryBaseUrl -ArtifactoryRepo $ArtifactoryRepo -ArtifactoryUser $ArtifactoryUser -ArtifactoryPassword $ArtifactoryPassword
$resolveExit = $LASTEXITCODE
if ($resolveExit -ne 0) { throw "Update download/resolution failed with exit code ${resolveExit}" }

$resolved = Get-Content -LiteralPath $ResolvedPath -Raw | ConvertFrom-Json
if (-not $resolved.kb -or -not $resolved.build -or -not $resolved.sha256) { throw 'Resolved update manifest is missing KB, build, or SHA256.' }

$package = Join-Path $UpdatesDir $resolved.fileName
if (-not (Test-Path -LiteralPath $package -PathType Leaf)) { throw "Resolved update package is missing: $package" }
$actual = Get-Sha256 $package
if ($actual -ne $resolved.sha256.ToLowerInvariant()) {
    throw "MSU SHA256 mismatch for $($resolved.fileName). Expected $($resolved.sha256), actual $actual"
}

Write-Host 'Download stage: SUCCESS'
exit 0
