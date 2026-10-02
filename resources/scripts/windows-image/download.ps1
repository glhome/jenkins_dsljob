[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [Parameter(Mandatory = $true)]
    [string]$BaseIsoArtifact,

    [string]$BaseIsoSha256 = '',

    [string]$Profile = 'windows11-24h2',

    [ValidateSet('x64', 'amd64', 'arm64')]
    [string]$Architecture = 'x64',

    [string]$ArtifactoryBaseUrl = '',

    [string]$ArtifactoryRepo = 'snapshot-generic-local',

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryUser,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryPassword,

    [Parameter(Mandatory = $true)]
    [string]$ResolverScriptPath,

    [Parameter(Mandatory = $true)]
    [string]$ProfileScriptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# Normalize architecture
# ============================================================

if ($Architecture -match '^(?i)(amd64|x64)$') {
    $Architecture = 'x64'
}

# ============================================================
# Load Windows image profile
# ============================================================

if (-not (Test-Path -LiteralPath $ProfileScriptPath -PathType Leaf)) {
    throw "Windows image profiles file does not exist: $ProfileScriptPath"
}

. $ProfileScriptPath

$profileInfo = Get-WindowsImageProfile -Name $Profile

# ============================================================
# Paths
# ============================================================

$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)

$DownloadDir  = Join-Path $WorkRoot 'download'
$UpdatesDir   = Join-Path $DownloadDir 'updates'
$BaseIsoPath  = Join-Path $DownloadDir 'base.iso'
$ResolvedPath = Join-Path $DownloadDir 'resolved-updates.json'
$CacheMarker  = Join-Path $DownloadDir 'patched-cache-hit.json'

New-Item `
    -ItemType Directory `
    -Force `
    -Path $DownloadDir, $UpdatesDir |
    Out-Null

# ============================================================
# Validate inputs
# ============================================================

if (-not (Test-Path -LiteralPath $ResolverScriptPath -PathType Leaf)) {
    throw "Resolver script does not exist: $ResolverScriptPath"
}

if ([string]::IsNullOrWhiteSpace($ArtifactoryBaseUrl)) {
    throw 'ArtifactoryBaseUrl is required.'
}

# ============================================================
# Artifactory URL
# ============================================================

$ArtifactoryBaseUrl = $ArtifactoryBaseUrl.TrimEnd('/')

if ($ArtifactoryBaseUrl.EndsWith('/artifactory')) {
    $ArtifactoryUrlRoot = $ArtifactoryBaseUrl
}
else {
    $ArtifactoryUrlRoot = "$ArtifactoryBaseUrl/artifactory"
}

# ============================================================
# Authentication
# ============================================================

$pair = '{0}:{1}' -f $ArtifactoryUser, $ArtifactoryPassword

$headers = @{
    Authorization =
        'Basic ' +
        [Convert]::ToBase64String(
            [Text.Encoding]::ASCII.GetBytes($pair)
        )
}

# ============================================================
# Helper: Artifactory URL
# ============================================================

function Get-ArtifactUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return "$ArtifactoryUrlRoot/$ArtifactoryRepo/$($Path.TrimStart('/'))"
}

# ============================================================
# Helper: SHA256
# ============================================================

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (
        Get-FileHash `
            -LiteralPath $Path `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()
}

# ============================================================
# Helper: Get text artifact from Artifactory
#
# Handles UTF-8 BOM safely.
# ============================================================

function Get-ArtifactText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $uri = Get-ArtifactUrl $Path

    try {
        $response = Invoke-WebRequest `
            -Uri $uri `
            -Headers $headers `
            -Method Get `
            -UseBasicParsing `
            -TimeoutSec 60 `
            -ErrorAction Stop

        $stream = $response.RawContentStream

        if ($stream.CanSeek) {
            $stream.Position = 0
        }

        $utf8 = New-Object `
            System.Text.UTF8Encoding($false, $true)

        $reader = New-Object `
            System.IO.StreamReader(
                $stream,
                $utf8,
                $true
            )

        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    catch {
        if (
            $_.Exception.Response -and
            [int]$_.Exception.Response.StatusCode -eq 404
        ) {
            return $null
        }

        throw
    }
}

# ============================================================
# Helper: Test artifact exists
# ============================================================

function Test-ArtifactExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $uri = Get-ArtifactUrl $Path

    try {
        Invoke-WebRequest `
            -Uri $uri `
            -Headers $headers `
            -Method Head `
            -UseBasicParsing `
            -TimeoutSec 60 `
            -ErrorAction Stop |
            Out-Null

        return $true
    }
    catch {
        if (
            $_.Exception.Response -and
            [int]$_.Exception.Response.StatusCode -eq 404
        ) {
            return $false
        }

        throw
    }
}

# ============================================================
# Helper: Download artifact from Artifactory
# ============================================================

 function Download-Artifact {
     param(
         [Parameter(Mandatory = $true)]
         [string]$Path,

         [Parameter(Mandatory = $true)]
         [string]$Destination,

         [string]$ExpectedSha256 = ''
     )

-    $spec = "$ArtifactoryRepo/$Path"
+    $uri = Get-ArtifactUrl $Path

     $dir = Split-Path -Parent $Destination

     New-Item `
         -ItemType Directory `
         -Force `
         -Path $dir |
         Out-Null

     Write-Host ''
     Write-Host "Downloading Artifactory artifact:"
-    Write-Host "  $spec"
+    Write-Host "  $uri"
     Write-Host "Destination:"
     Write-Host "  $Destination"

-    & jf rt download `
-        --server-id=local-artifactory `
-        --flat=true `
-        $spec `
-        $dir\ `
-        2>&1 |
-        ForEach-Object {
-            Write-Host $_
+    try {
+        Invoke-WebRequest `
+            -Uri $uri `
+            -Headers $headers `
+            -Method Get `
+            -UseBasicParsing `
+            -OutFile $Destination `
+            -TimeoutSec 1800 `
+            -ErrorAction Stop
+    }
+    catch {
+        throw (
+            "Artifactory download failed: $uri`n" +
+            $_.Exception.Message
+        )
     }

-    $exitCode = $LASTEXITCODE
-
-    if ($exitCode -ne 0) {
-        throw `
-            "JFrog download failed with exit code ${exitCode}: $spec"
-    }
-
-    $source = Join-Path `
-        $dir `
-        ([IO.Path]::GetFileName($Path))
-
-    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
-        throw "Downloaded artifact not found: $source"
+    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
+        throw "Downloaded artifact not found: $Destination"
     }

-    if ($source -ne $Destination) {
-        Move-Item `
-            -LiteralPath $source `
-            -Destination $Destination `
-            -Force
-    }
-
     if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
-
         $actual = Get-Sha256 $Destination

         if (
             $actual -ne
             $ExpectedSha256.ToLowerInvariant()
         ) {
-            throw `
-                "SHA256 mismatch for $Path. " +
-                "Expected $ExpectedSha256, actual $actual"
+            Remove-Item `
+                -LiteralPath $Destination `
+                -Force `
+                -ErrorAction SilentlyContinue
+
+            throw (
+                "SHA256 mismatch for $Path. " +
+                "Expected $ExpectedSha256, actual $actual"
+            )
         }
+
+        Write-Host "SHA256 verified: $actual"
     }
 }
# ============================================================
# Resolve LCU
#
# IMPORTANT:
# resolve-updates.ps1 loads profiles.ps1 itself.
#
# DO NOT pass:
#   -ProfileScriptPath
# ============================================================

Write-Host ''
Write-Host '============================================================'
Write-Host ' Resolve LCU and Check Patched Image Cache'
Write-Host '============================================================'
Write-Host "Profile      : $($profileInfo.Name)"
Write-Host "Windows      : $($profileInfo.WindowsVersion)"
Write-Host "Windows Build: $($profileInfo.Build)"
Write-Host "Architecture : $Architecture"
Write-Host ''

# ============================================================
# Remove stale cache marker
# ============================================================

if (Test-Path -LiteralPath $CacheMarker) {
    Remove-Item `
        -LiteralPath $CacheMarker `
        -Force
}

# ============================================================
# Resolve-only
#
# No MSU download.
# ============================================================

& $ResolverScriptPath `
    -WorkRoot $WorkRoot `
    -Profile $Profile `
    -Architecture $Architecture `
    -ArtifactoryBaseUrl $ArtifactoryBaseUrl `
    -ArtifactoryRepo $ArtifactoryRepo `
    -ArtifactoryUser $ArtifactoryUser `
    -ArtifactoryPassword $ArtifactoryPassword `
    -ResolveOnly

$resolveExit = $LASTEXITCODE

if ($resolveExit -ne 0) {
    throw `
        "Update resolver failed with exit code ${resolveExit}"
}

if (-not (Test-Path -LiteralPath $ResolvedPath -PathType Leaf)) {
    throw `
        "Resolved update manifest was not created: $ResolvedPath"
}

# ============================================================
# Read resolved update
# ============================================================

$resolvedJson =
    Get-Content `
        -LiteralPath $ResolvedPath `
        -Raw

$resolvedJson =
    $resolvedJson.TrimStart([char]0xFEFF)

$resolved =
    $resolvedJson |
    ConvertFrom-Json

if (
    -not $resolved.kb -or
    -not $resolved.updateId -or
    -not $resolved.fileName
) {
    throw `
        'Resolved update manifest is missing KB, build, UpdateID, or fileName.'
}

# ============================================================
# Resolve artifact information
# ============================================================

$kb =
    $resolved.kb.ToString().ToUpperInvariant()

$lcuBuild =
    $resolved.build.ToString()

$normalizedArch =
    $Architecture.ToLowerInvariant()

if ($normalizedArch -eq 'amd64') {
    $normalizedArch = 'x64'
}

$resolvedWindowsBuild =
    [string]$resolved.windowsBuild

if ([string]::IsNullOrWhiteSpace($resolvedWindowsBuild)) {
    $resolvedWindowsBuild =
        [string]$profileInfo.Build
}

$artifactRoot =
    [string]$resolved.artifactRoot

if ([string]::IsNullOrWhiteSpace($artifactRoot)) {
    $artifactRoot =
        [string]$profileInfo.ArtifactRoot
}

$isoPrefix =
    [string]$resolved.isoPrefix

if ([string]::IsNullOrWhiteSpace($isoPrefix)) {
    $isoPrefix =
        [string]$profileInfo.IsoPrefix
}

if ([string]::IsNullOrWhiteSpace($artifactRoot)) {
    throw `
        'Resolved update manifest is missing artifactRoot.'
}

if ([string]::IsNullOrWhiteSpace($isoPrefix)) {
    throw `
        'Resolved update manifest is missing isoPrefix.'
}

# ============================================================
# Patched image artifact paths
# ============================================================

$patchedBase =
    "$artifactRoot/$normalizedArch/patched/$lcuBuild"

$manifestArtifact =
    "$patchedBase/manifest.json"

$isoName =
    "$isoPrefix-$normalizedArch-$lcuBuild-$kb.iso"

$isoArtifact =
    "$patchedBase/$isoName"

$manifestUrl =
    Get-ArtifactUrl $manifestArtifact

Write-Host "Resolved LCU: $kb / $lcuBuild"
Write-Host "UpdateID    : $($resolved.updateId)"
Write-Host "MSU         : $($resolved.fileName)"
Write-Host "Patched manifest: $manifestUrl"

# ============================================================
# Patched image cache validation
# ============================================================

$cacheHit = $false

if ([string]::IsNullOrWhiteSpace($BaseIsoSha256)) {

    Write-Warning `
        'BASE_ISO_SHA256 is empty; exact patched-image cache validation is disabled.'
}
else {

    $remoteManifest =
        Get-ArtifactText $manifestArtifact

    if ($remoteManifest) {

        try {

            # Remove UTF-8 BOM if present.
            $remoteManifest =
                $remoteManifest.TrimStart([char]0xFEFF)

            $m =
                $remoteManifest |
                ConvertFrom-Json

            $remoteBase =
                ([string]$m.source.baseIsoSha256).ToLowerInvariant()

            $remoteImageBuild =
                [string]$m.image.windowsBuild

            $remoteArch =
                [string]$m.image.architecture

            $remoteLcu =
                $m.updates.lcu

            $remoteKb =
                ([string]$remoteLcu.kb).ToUpperInvariant()

            $remoteBuild =
                [string]$remoteLcu.build

            $remoteUpdateId =
                [string]$remoteLcu.updateId

            $remoteFileName =
                [string]$remoteLcu.fileName

            $same =
                ($remoteBase -eq $BaseIsoSha256.ToLowerInvariant()) -and
                ($remoteImageBuild -eq $resolvedWindowsBuild) -and
                ($remoteArch -ieq $normalizedArch) -and
                ($remoteKb -eq $kb) -and
                ($remoteBuild -eq $lcuBuild) -and
                ($remoteUpdateId -eq [string]$resolved.updateId) -and
                ($remoteFileName -eq [string]$resolved.fileName)

            if (
                $same -and
                (Test-ArtifactExists $isoArtifact)
            ) {

                $cacheHit = $true

                $markerObject = [ordered]@{
                    cacheHit            = $true
                    manifestArtifactPath = $manifestArtifact
                    isoArtifactPath      = $isoArtifact
                    kb                   = $kb
                    build                = $lcuBuild
                    updateId             = [string]$resolved.updateId
                    isoFileName          = $isoName
                }

                $markerJson =
                    $markerObject |
                    ConvertTo-Json -Depth 10

                [System.IO.File]::WriteAllText(
                    $CacheMarker,
                    $markerJson,
                    [System.Text.UTF8Encoding]::new($false)
                )

                Write-Host ''
                Write-Host 'PATCHED IMAGE CACHE HIT'
                Write-Host 'Base ISO download skipped.'
                Write-Host 'MSU download skipped.'
                Write-Host "Cached ISO: $isoArtifact"

                exit 0
            }

            Write-Host ''
            Write-Host `
                'Patched image manifest exists, but inputs do not match or ISO is missing. Cache miss.'
        }
        catch {

            Write-Warning `
                "Could not parse remote patched manifest: $($_.Exception.Message)"
        }
    }
    else {

        Write-Host `
            'Patched image manifest not found. Cache miss.'
    }
}

# ============================================================
# Cache miss
# ============================================================

Write-Host ''
Write-Host '============================================================'
Write-Host ' Download Base ISO and MSU (cache miss)'
Write-Host '============================================================'

# ============================================================
# Download base ISO
# ============================================================

Download-Artifact `
    -Path $BaseIsoArtifact `
    -Destination $BaseIsoPath `
    -ExpectedSha256 $BaseIsoSha256

if (-not (Test-Path -LiteralPath $BaseIsoPath -PathType Leaf)) {
    throw `
        "Base ISO was not downloaded: $BaseIsoPath"
}

Write-Host ''
Write-Host 'Base ISO download: SUCCESS'
Write-Host "Base ISO: $BaseIsoPath"

# ============================================================
# Resolve and download/cache MSU
#
# IMPORTANT:
# No ProfileScriptPath parameter here.
# ============================================================

& $ResolverScriptPath `
    -WorkRoot $WorkRoot `
    -Profile $Profile `
    -Architecture $Architecture `
    -ArtifactoryBaseUrl $ArtifactoryBaseUrl `
    -ArtifactoryRepo $ArtifactoryRepo `
    -ArtifactoryUser $ArtifactoryUser `
    -ArtifactoryPassword $ArtifactoryPassword

$resolveExit = $LASTEXITCODE

if ($resolveExit -ne 0) {
    throw `
        "Update download/resolution failed with exit code ${resolveExit}"
}

if (-not (Test-Path -LiteralPath $ResolvedPath -PathType Leaf)) {
    throw `
        "Resolved update manifest was not created: $ResolvedPath"
}

# ============================================================
# Read resolved update again
# ============================================================

$resolvedJson =
    Get-Content `
        -LiteralPath $ResolvedPath `
        -Raw

$resolvedJson =
    $resolvedJson.TrimStart([char]0xFEFF)

$resolved =
    $resolvedJson |
    ConvertFrom-Json

if (
    -not $resolved.kb -or
    -not $resolved.build -or
    -not $resolved.sha256
) {
    throw `
        'Resolved update manifest is missing KB, build, or SHA256.'
}

# ============================================================
# MSU path
# ============================================================

$package =
    Join-Path `
        $UpdatesDir `
        $resolved.fileName

if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
    throw `
        "Resolved update package is missing: $package"
}

# ============================================================
# Validate MSU SHA256
# ============================================================

$actual =
    Get-Sha256 $package

$expected =
    $resolved.sha256.ToString().ToLowerInvariant()

if ($actual -ne $expected) {
    throw `
        "MSU SHA256 mismatch for $($resolved.fileName). " +
        "Expected $expected, actual $actual"
}

# ============================================================
# Success
# ============================================================

Write-Host ''
Write-Host '============================================================'
Write-Host ' Download Stage Complete'
Write-Host '============================================================'
Write-Host "Profile       : $($profileInfo.Name)"
Write-Host "Windows       : $($profileInfo.WindowsVersion)"
Write-Host "Windows Build : $($profileInfo.Build)"
Write-Host "Architecture  : $Architecture"
Write-Host "KB            : $($resolved.kb)"
Write-Host "LCU Build     : $($resolved.build)"
Write-Host "MSU           : $($resolved.fileName)"
Write-Host "MSU SHA256    : $actual"
Write-Host "MSU Source    : $($resolved.source)"
Write-Host "MSU Path      : $package"
Write-Host 'Download stage: SUCCESS'
Write-Host '============================================================'
Write-Host ''

exit 0