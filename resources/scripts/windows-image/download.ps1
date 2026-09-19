[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [Parameter(Mandatory = $true)]
    [string]$BaseIsoArtifact,

    [string]$BaseIsoSha256 = '',

    [string]$WindowsBuild = '26100',

    [string]$Architecture = 'x64',

    [string]$UpdateManifestUrl = '',

    [string]$UpdateManifestFile = '',

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryBaseUrl = '', 

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryRepo = 'snapshot-generic-local',

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryUser,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryPassword,

    [Parameter(Mandatory = $true)]
    [string]$ResolverScriptPath
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# Normalize paths
# ------------------------------------------------------------

$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)

$DownloadDir = Join-Path $WorkRoot 'download'
$UpdatesDir = Join-Path $DownloadDir 'updates'

$BaseIsoPath = Join-Path $DownloadDir 'base.iso'
$ResolvedManifestPath = Join-Path $DownloadDir 'resolved-updates.json'

New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
New-Item -ItemType Directory -Force -Path $UpdatesDir | Out-Null

Write-Host ''
Write-Host '============================================================'
Write-Host ' Windows Image Download'
Write-Host '============================================================'
Write-Host "WorkRoot           : $WorkRoot"
Write-Host "Base ISO Artifact  : $BaseIsoArtifact"
Write-Host "Artifactory URL    : $ArtifactoryBaseUrl"
Write-Host "Artifactory Repo   : $ArtifactoryRepo"
Write-Host "Artifactory User   : $ArtifactoryUser"
Write-Host "Password supplied  : $([bool]$ArtifactoryPassword)"
Write-Host "Windows Build      : $WindowsBuild"
Write-Host "Architecture       : $Architecture"
Write-Host ''

# ------------------------------------------------------------
# Normalize Artifactory URL
#
# Expected:
#   http://localhost:8082
#
# The script adds:
#   /artifactory/<repo>/<artifact>
#
# ------------------------------------------------------------

$ArtifactoryBaseUrl = $ArtifactoryBaseUrl.TrimEnd('/')

if ($ArtifactoryBaseUrl.EndsWith('/artifactory')) {
    $ArtifactoryBaseUrl =
        $ArtifactoryBaseUrl.Substring(
            0,
            $ArtifactoryBaseUrl.Length - '/artifactory'.Length
        ).TrimEnd('/')
}

Write-Host "Normalized Artifactory URL: $ArtifactoryBaseUrl"

# ------------------------------------------------------------
# Create Basic Authentication header
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($ArtifactoryUser)) {
    throw 'Artifactory username is empty.'
}

if ([string]::IsNullOrWhiteSpace($ArtifactoryPassword)) {
    throw 'Artifactory password is empty.'
}

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

Write-Host "Authentication header created: $($headers.ContainsKey('Authorization'))"

# ------------------------------------------------------------
# Build Artifactory REST URL
# ------------------------------------------------------------

function Get-ArtifactoryUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArtifactPath
    )

    $cleanPath = $ArtifactPath.TrimStart('/')

    return (
        "$ArtifactoryBaseUrl/artifactory/" +
        "$ArtifactoryRepo/" +
        $cleanPath
    )
}

# ------------------------------------------------------------
# Calculate SHA256
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# Download Artifactory artifact
# ------------------------------------------------------------

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
    Write-Host 'DEBUG Artifactory request'
    Write-Host "  URI              = [$uri]"
    Write-Host "  User             = [$ArtifactoryUser]"
    Write-Host "  User length      = $($ArtifactoryUser.Length)"
    Write-Host "  Password supplied= $([bool]$ArtifactoryPassword)"
    Write-Host "  Header present   = $($headers.ContainsKey('Authorization'))"
    Write-Host "  ComputerName     = $env:COMPUTERNAME"
    Write-Host "  UserName         = $env:USERNAME"
    Write-Host "  Identity         = $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

    # --------------------------------------------------------
    # Reuse existing local file when checksum matches
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

            Write-Warning 'Existing file SHA256 does not match expected value.'
            Write-Host '  Removing existing file.'

            Remove-Item `
                -LiteralPath $DestinationPath `
                -Force
        }
        else {
            Write-Warning `
                'Existing file found but no expected SHA256 was supplied.'

            Write-Host '  Removing existing file before download.'

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

        Write-Host '  Sending GET request...'

        $response = Invoke-WebRequest `
            -Uri $uri `
            -Headers $headers `
            -Method Get `
            -OutFile $DestinationPath `
            -UseBasicParsing `
            -Verbose

        Write-Host "  HTTP Status: $($response.StatusCode)"
    }
    catch {

        Write-Host ''
        Write-Host 'Artifactory request failed.'

        if ($_.Exception.Response) {
            try {
                Write-Host `
                    "HTTP Status: $([int]$_.Exception.Response.StatusCode)"
            }
            catch {
                Write-Host 'HTTP Status: unavailable'
            }
        }

        Write-Host "URL: $uri"

        throw
    }

    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
        throw "Artifactory download completed but file was not created: $DestinationPath"
    }

    $fileInfo =
        Get-Item -LiteralPath $DestinationPath

    Write-Host "  Downloaded size: $($fileInfo.Length) bytes"

    # --------------------------------------------------------
    # Validate SHA256
    # --------------------------------------------------------

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

# ------------------------------------------------------------
# Validate Artifactory connection
# ------------------------------------------------------------

function Test-ArtifactoryConnection {

    $pingUri =
        "$ArtifactoryBaseUrl/artifactory/api/system/ping"

    Write-Host ''
    Write-Host 'Testing Artifactory connection...'
    Write-Host "  $pingUri"

    try {

        $response = Invoke-WebRequest `
            -Uri $pingUri `
            -Headers $headers `
            -Method Get `
            -UseBasicParsing

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

# ------------------------------------------------------------
# Test Artifactory
# ------------------------------------------------------------

Test-ArtifactoryConnection

# ------------------------------------------------------------
# Download base ISO
# ------------------------------------------------------------

Write-Host ''
Write-Host '============================================================'
Write-Host ' Download Base ISO'
Write-Host '============================================================'

Get-ArtifactoryArtifact `
    -ArtifactPath $BaseIsoArtifact `
    -DestinationPath $BaseIsoPath `
    -ExpectedSha256 $BaseIsoSha256

# ------------------------------------------------------------
# Validate base ISO
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $BaseIsoPath -PathType Leaf)) {
    throw "Base ISO was not downloaded: $BaseIsoPath"
}

$baseIsoInfo =
    Get-Item -LiteralPath $BaseIsoPath

Write-Host ''
Write-Host "Base ISO:"
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
        $actualBaseIsoSha256 `
        -ne $BaseIsoSha256.ToLowerInvariant()
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

# ------------------------------------------------------------
# Resolve Windows update
# ------------------------------------------------------------

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
    -ArtifactoryPassword $ArtifactoryPassword `
    -UpdateManifestUrl $UpdateManifestUrl `
    -UpdateManifestFile $UpdateManifestFile

if ($LASTEXITCODE -ne 0) {
    throw `
        "Windows update resolver failed with exit code $LASTEXITCODE."
}

# ------------------------------------------------------------
# Validate resolved manifest
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ResolvedManifestPath -PathType Leaf)) {
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

# The resolver currently writes either:
#
# 1. A single update object:
#       { "kb": "KB..." }
#
# or
#
# 2. A wrapper:
#       { "updates": [ ... ] }
#

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
    throw `
        'Resolved update manifest contains no updates.'
}

Write-Host ''
Write-Host "Resolved update count: $($updates.Count)"

# ------------------------------------------------------------
# Validate every resolved package
# ------------------------------------------------------------

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

    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        throw @"
Resolved update package is missing.

KB   : $($update.kb)
File : $packagePath
"@
    }

    $actualHash =
        Get-FileSha256 -Path $packagePath

    if (
        $actualHash `
        -ne $update.sha256.ToLowerInvariant()
    ) {
        throw @"
Resolved update SHA256 mismatch.

KB       : $($update.kb)
File     : $packagePath
Expected : $($update.sha256)
Actual   : $actualHash
"@
    }

    # Verify that the filename corresponds to the resolved KB.
    if (
        $update.fileName.ToLowerInvariant() `
        -notmatch $update.kb.ToLowerInvariant()
    ) {
        throw @"
Resolved update filename does not contain the expected KB.

KB       : $($update.kb)
Filename : $($update.fileName)
"@
    }

    Write-Host "  SHA256 verification: PASS"
}

# ------------------------------------------------------------
# Final summary
# ------------------------------------------------------------

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