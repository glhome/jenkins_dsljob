[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [Parameter(Mandatory = $true)]
    [string]$BaseIsoArtifact,

    [Parameter(Mandatory = $false)]
    [string]$BaseIsoSha256 = '',

    [Parameter(Mandatory = $false)]
    [string]$WindowsBuild = '26100',

    [Parameter(Mandatory = $false)]
    [ValidateSet('x64', 'amd64', 'arm64')]
    [string]$Architecture = 'x64',

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryBaseUrl = '',

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryRepo = 'snapshot-generic-local',

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryUser,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryPassword,

    [Parameter(Mandatory = $true)]
    [string]$ResolverScriptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# Normalize architecture
# ============================================================

if ($Architecture -match '^(?i)(amd64|x64)$') {
    $Architecture = 'x64'
}
elseif ($Architecture -match '^(?i)arm64$') {
    $Architecture = 'arm64'
}
else {
    throw "Unsupported architecture: $Architecture"
}

# ============================================================
# Normalize paths
# ============================================================

$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)

$DownloadDir = Join-Path $WorkRoot 'download'
$UpdatesDir = Join-Path $DownloadDir 'updates'

$BaseIsoPath = Join-Path $DownloadDir 'base.iso'
$ResolvedManifestPath = Join-Path $DownloadDir 'resolved-updates.json'

New-Item `
    -ItemType Directory `
    -Force `
    -Path $DownloadDir, $UpdatesDir |
    Out-Null

# ============================================================
# Normalize Artifactory URL
#
# Accept either:
#
#   http://server:8082
#
# or:
#
#   http://server:8082/artifactory
#
# Internally always use:
#
#   http://server:8082/artifactory
# ============================================================

$ArtifactoryBaseUrl = $ArtifactoryBaseUrl.TrimEnd('/')

if ($ArtifactoryBaseUrl.EndsWith('/artifactory')) {
    $ArtifactoryUrlRoot = $ArtifactoryBaseUrl
}
else {
    $ArtifactoryUrlRoot = "$ArtifactoryBaseUrl/artifactory"
}

Write-Host ''
Write-Host '============================================================'
Write-Host ' Windows Image Download'
Write-Host '============================================================'
Write-Host "WorkRoot           : $WorkRoot"
Write-Host "Base ISO Artifact  : $BaseIsoArtifact"
Write-Host "Artifactory URL    : $ArtifactoryUrlRoot"
Write-Host "Artifactory Repo   : $ArtifactoryRepo"
Write-Host "Windows Build      : $WindowsBuild"
Write-Host "Architecture       : $Architecture"
Write-Host ''

# ============================================================
# Validate Artifactory credentials
# ============================================================

if ([string]::IsNullOrWhiteSpace($ArtifactoryBaseUrl)) {
    throw 'ArtifactoryBaseUrl is required.'
}

if ([string]::IsNullOrWhiteSpace($ArtifactoryRepo)) {
    throw 'ArtifactoryRepo is required.'
}

if ([string]::IsNullOrWhiteSpace($ArtifactoryUser)) {
    throw 'Artifactory username is empty.'
}

if ([string]::IsNullOrWhiteSpace($ArtifactoryPassword)) {
    throw 'Artifactory password is empty.'
}

# ============================================================
# Authentication
# ============================================================

$credentialPair = '{0}:{1}' -f `
    $ArtifactoryUser, `
    $ArtifactoryPassword

$credentialBytes =
    [System.Text.Encoding]::ASCII.GetBytes($credentialPair)

$encodedCredentials =
    [System.Convert]::ToBase64String($credentialBytes)

$headers = @{
    Authorization = "Basic $encodedCredentials"
}

# ============================================================
# Artifactory URL helper
# ============================================================

function Get-ArtifactoryUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArtifactPath
    )

    $cleanPath = $ArtifactPath.TrimStart('/')

    return (
        "$ArtifactoryUrlRoot/" +
        "$ArtifactoryRepo/" +
        $cleanPath
    )
}

# ============================================================
# SHA256
# ============================================================

function Get-FileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File does not exist: $Path"
    }

    return (
        Get-FileHash `
            -LiteralPath $Path `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()
}

# ============================================================
# Artifactory connection test
# ============================================================

function Test-ArtifactoryConnection {

    $pingUri =
        "$ArtifactoryUrlRoot/api/system/ping"

    Write-Host ''
    Write-Host 'Testing Artifactory connection...'
    Write-Host "  $pingUri"

    try {

        $response = Invoke-WebRequest `
            -Uri $pingUri `
            -Headers $headers `
            -Method Get `
            -UseBasicParsing `
            -TimeoutSec 60

        Write-Host "  HTTP Status: $($response.StatusCode)"

        if ($response.StatusCode -ne 200) {
            throw `
                "Artifactory ping returned HTTP $($response.StatusCode)."
        }

        Write-Host '  Artifactory connection: PASS'
    }
    catch {

        Write-Host ''
        Write-Host 'Artifactory connection test failed.'
        Write-Host "URL: $pingUri"

        if ($_.Exception.Response) {
            try {
                Write-Host `
                    "HTTP Status: $([int]$_.Exception.Response.StatusCode)"
            }
            catch {
            }
        }

        throw
    }
}

# ============================================================
# Download Artifactory artifact
# ============================================================

function Get-ArtifactoryArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArtifactPath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [string]$ExpectedSha256 = ''
    )

    $uri = Get-ArtifactoryUrl -ArtifactPath $ArtifactPath

    Write-Host ''
    Write-Host 'Artifactory request'
    Write-Host "  URI         : $uri"
    Write-Host "  Destination : $DestinationPath"

    # --------------------------------------------------------
    # Reuse existing file when checksum matches
    # --------------------------------------------------------

    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {

        if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {

            Write-Host '  Existing file found. Checking SHA256...'

            $existingHash =
                Get-FileSha256 -Path $DestinationPath

            if ($existingHash -eq $ExpectedSha256.ToLowerInvariant()) {

                Write-Host '  Existing file SHA256 matches.'
                Write-Host '  Download skipped.'

                return
            }

            Write-Warning `
                'Existing file SHA256 does not match expected value.'

            Remove-Item `
                -LiteralPath $DestinationPath `
                -Force
        }
        else {

            Write-Warning `
                'Existing file found but no expected SHA256 was supplied.'

            Remove-Item `
                -LiteralPath $DestinationPath `
                -Force
        }
    }

    $parentDirectory =
        Split-Path `
            -Parent `
            $DestinationPath

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $parentDirectory |
        Out-Null

    try {

        Write-Host '  Downloading from Artifactory using JFrog CLI...'
        Write-Host "  URL: $uri"
        Write-Host "  Destination: $DestinationPath"

        $downloadStart = Get-Date

        $destinationDirectory = Split-Path -Parent $DestinationPath

        New-Item `
            -ItemType Directory `
            -Force `
            -Path $destinationDirectory | Out-Null

        $artifactSpec = "$ArtifactoryRepo/$ArtifactPath"
        Write-Host "  Artifact: $artifactSpec"

        & jf rt download `
            --server-id=local-artifactory `
            --flat=true `
            --threads=8 `
            $artifactSpec `
            "$destinationDirectory\"

        if ($LASTEXITCODE -ne 0) {
            throw "JFrog CLI download failed with exit code $LASTEXITCODE"
        }

        if (-not (Test-Path -LiteralPath $DestinationPath)) {
            throw "JFrog CLI completed successfully but file was not found: $DestinationPath"
        }

        $downloadedFile = Get-Item -LiteralPath $DestinationPath

        if ($downloadedFile.Length -eq 0) {
            throw "Downloaded file is 0 bytes: $DestinationPath"
        }

        $downloadElapsed = (Get-Date) - $downloadStart

        Write-Host "  Download completed."
        Write-Host "  Size: $($downloadedFile.Length) bytes"
        Write-Host "  Download time: $($downloadElapsed.ToString())"
    }
    catch {

        Write-Host ''
        Write-Host 'Artifactory request failed.'
        Write-Host "URL: $uri"

        if (Test-Path -LiteralPath $DestinationPath) {
            try {
                $partialFile = Get-Item -LiteralPath $DestinationPath
                Write-Host "Partial file size: $($partialFile.Length) bytes"
            }
            catch {
            }
        }

        throw
    }

    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
        throw `
            "Artifactory download completed but file was not created: $DestinationPath"
    }

    $fileInfo =
        Get-Item -LiteralPath $DestinationPath

    Write-Host "  Downloaded size: $($fileInfo.Length) bytes"

    if ($fileInfo.Length -le 0) {
        throw "Downloaded file is empty: $DestinationPath"
    }

    $actualSha256 =
        Get-FileSha256 -Path $DestinationPath

    Write-Host "  SHA256: $actualSha256"

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {

        if ($actualSha256 -ne $ExpectedSha256.ToLowerInvariant()) {

            throw @"
SHA256 mismatch for Artifactory artifact.

Artifact : $ArtifactPath
Expected : $ExpectedSha256
Actual   : $actualSha256
File     : $DestinationPath
"@
        }

        Write-Host '  SHA256 verification: PASS'
    }

    Write-Host '  Download: PASS'
}

# ============================================================
# Test Artifactory
# ============================================================

Test-ArtifactoryConnection

# ============================================================
# Download base ISO
#
# Expected artifact example:
#
# Windows11/24H2/x64/base/
# en-us_windows_11_iot_enterprise_version_24h2_x64_dvd_3a99b72b.iso
# ============================================================

Write-Host ''
Write-Host '============================================================'
Write-Host ' Download Base ISO'
Write-Host '============================================================'

Get-ArtifactoryArtifact `
    -ArtifactPath $BaseIsoArtifact `
    -DestinationPath $BaseIsoPath `
    -ExpectedSha256 $BaseIsoSha256

if (-not (Test-Path -LiteralPath $BaseIsoPath -PathType Leaf)) {
    throw "Base ISO was not downloaded: $BaseIsoPath"
}

$baseIsoInfo =
    Get-Item -LiteralPath $BaseIsoPath

Write-Host ''
Write-Host 'Base ISO:'
Write-Host "  Path : $BaseIsoPath"
Write-Host "  Size : $($baseIsoInfo.Length) bytes"

if ([string]::IsNullOrWhiteSpace($BaseIsoSha256)) {

    Write-Warning `
        'BASE_ISO_SHA256 is empty. Base ISO integrity was not verified against an expected hash.'
}
else {

    $actualBaseIsoSha256 =
        Get-FileSha256 -Path $BaseIsoPath

    Write-Host "  SHA256: $actualBaseIsoSha256"

    if (
        $actualBaseIsoSha256 -ne
        $BaseIsoSha256.ToLowerInvariant()
    ) {

        throw @"
Base ISO SHA256 mismatch.

Expected: $BaseIsoSha256
Actual  : $actualBaseIsoSha256
File    : $BaseIsoPath
"@
    }

    Write-Host '  SHA256 verification: PASS'
}

# ============================================================
# Resolve Windows update
#
# IMPORTANT:
# The resolver creates:
#
#   download\resolved-updates.json
#
# There is intentionally NO UpdateManifestUrl or
# UpdateManifestFile parameter here.
# ============================================================

Write-Host ''
Write-Host '============================================================'
Write-Host ' Resolve Windows Update'
Write-Host '============================================================'

if (-not (Test-Path -LiteralPath $ResolverScriptPath -PathType Leaf)) {
    throw "Resolver script does not exist: $ResolverScriptPath"
}

Write-Host "Resolver script: $ResolverScriptPath"

& $ResolverScriptPath `
    -WorkRoot $WorkRoot `
    -WindowsBuild $WindowsBuild `
    -Architecture $Architecture `
    -ArtifactoryBaseUrl $ArtifactoryBaseUrl `
    -ArtifactoryRepo $ArtifactoryRepo `
    -ArtifactoryUser $ArtifactoryUser `
    -ArtifactoryPassword $ArtifactoryPassword

if ($LASTEXITCODE -ne 0) {
    throw `
        "Windows update resolver failed with exit code $LASTEXITCODE."
}

# ============================================================
# Validate resolved manifest
# ============================================================

if (-not (
    Test-Path `
        -LiteralPath $ResolvedManifestPath `
        -PathType Leaf
)) {
    throw `
        "Resolved update manifest was not created: $ResolvedManifestPath"
}

$manifestJson =
    Get-Content `
        -LiteralPath $ResolvedManifestPath `
        -Raw

if ([string]::IsNullOrWhiteSpace($manifestJson)) {
    throw `
        "Resolved update manifest is empty: $ResolvedManifestPath"
}

$manifest =
    $manifestJson | ConvertFrom-Json

# The resolver currently creates one update object:
#
# {
#     schemaVersion: "1.0",
#     type: "LCU",
#     kb: "...",
#     ...
# }
#
# Support an updates[] wrapper as well.

if ($manifest.PSObject.Properties.Name -contains 'updates') {
    $updates = @($manifest.updates)
}
elseif ($manifest.PSObject.Properties.Name -contains 'kb') {
    $updates = @($manifest)
}
else {
    throw `
        'Resolved update manifest does not contain an "updates" array or "kb" property.'
}

if ($updates.Count -eq 0) {
    throw 'Resolved update manifest contains no updates.'
}

Write-Host ''
Write-Host "Resolved update count: $($updates.Count)"

# ============================================================
# Validate every resolved package
# ============================================================

foreach ($update in $updates) {

    if ([string]::IsNullOrWhiteSpace($update.kb)) {
        throw 'Resolved update is missing KB number.'
    }

    if ([string]::IsNullOrWhiteSpace($update.fileName)) {
        throw `
            "Resolved update $($update.kb) is missing fileName."
    }

    if ([string]::IsNullOrWhiteSpace($update.sha256)) {
        throw `
            "Resolved update $($update.kb) is missing sha256."
    }

    $packagePath =
        Join-Path `
            $UpdatesDir `
            $update.fileName

    Write-Host ''
    Write-Host 'Resolved update:'
    Write-Host "  KB       : $($update.kb)"
    Write-Host "  Build    : $($update.build)"
    Write-Host "  File     : $($update.fileName)"
    Write-Host "  SHA256   : $($update.sha256)"
    Write-Host "  Path     : $packagePath"

    if (-not (
        Test-Path `
            -LiteralPath $packagePath `
            -PathType Leaf
    )) {

        throw @"
Resolved update package is missing.

KB   : $($update.kb)
File : $packagePath
"@
    }

    $actualHash =
        Get-FileSha256 -Path $packagePath

    if (
        $actualHash -ne
        $update.sha256.ToLowerInvariant()
    ) {

        throw @"
Resolved update SHA256 mismatch.

KB       : $($update.kb)
File     : $packagePath
Expected : $($update.sha256)
Actual   : $actualHash
"@
    }

   $updateFileName = [System.IO.Path]::GetFileName($update.fileName)
    $expectedKb = $update.kb.ToString()

    if ($updateFileName -notmatch "(?i)$([regex]::Escape($expectedKb))") {
        throw "Resolved update filename '$updateFileName' does not contain expected KB '$expectedKb'."
    }
    Write-Host '  SHA256 verification: PASS'
}

# ============================================================
# Final summary
# ============================================================

Write-Host ''
Write-Host '============================================================'
Write-Host ' Download Stage Complete'
Write-Host '============================================================'
Write-Host "Base ISO : $BaseIsoPath"
Write-Host "Manifest : $ResolvedManifestPath"
Write-Host "Updates  : $UpdatesDir"
Write-Host ''

foreach ($update in $updates) {
    Write-Host `
        "  $($update.kb) | $($update.build) | $($update.fileName)"
}

Write-Host ''
Write-Host 'Download stage: SUCCESS'

exit 0