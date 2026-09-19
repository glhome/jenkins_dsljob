[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [Parameter(Mandatory = $true)]
    [string]$BaseIsoArtifact,

    [Parameter(Mandatory = $false)]
    [string]$BaseIsoSha256 = '',

    [Parameter(Mandatory = $true)]
    [string]$WindowsBuild,

    [Parameter(Mandatory = $true)]
    [string]$Architecture,

    [Parameter(Mandatory = $false)]
    [string]$UpdateManifestUrl = '',

    [Parameter(Mandatory = $false)]
    [string]$UpdateManifestFile = '',

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryRepo,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryUser,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryPassword,

    [Parameter(Mandatory = $true)]
    [string]$ResolverScriptPath
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Helper Functions
# ============================================================

function Normalize-PathString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path)
}

function Get-ArtifactoryHeaders {

    if ([string]::IsNullOrWhiteSpace($ArtifactoryUser)) {
        throw "Artifactory username is empty."
    }

    if ([string]::IsNullOrWhiteSpace($ArtifactoryPassword)) {
        throw "Artifactory password/token is empty."
    }

    $credentialBytes =
        [System.Text.Encoding]::ASCII.GetBytes(
            "${ArtifactoryUser}:${ArtifactoryPassword}"
        )

    $encodedCredential =
        [Convert]::ToBase64String($credentialBytes)

    return @{
        Authorization = "Basic $encodedCredential"
    }
}

function Get-ArtifactoryUrl {

    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$ArtifactPath
    )

    $base =
        $BaseUrl.TrimEnd('/')

    $repo =
        $Repository.Trim('/')

    $artifact =
        $ArtifactPath.TrimStart('/')

    return "$base/artifactory/$repo/$artifact"
}

function Get-ArtifactoryArtifact {

    param(
        [Parameter(Mandatory = $true)]
        [string]$ArtifactPath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $false)]
        [string]$ExpectedSha256 = ''
    )

    $url = Get-ArtifactoryUrl `
        -BaseUrl $ArtifactoryBaseUrl `
        -Repository $ArtifactoryRepo `
        -ArtifactPath $ArtifactPath

    $headers = Get-ArtifactoryHeaders

    $destinationDirectory =
        Split-Path `
            -Parent `
            -Path $DestinationPath

    if (-not (Test-Path -LiteralPath $destinationDirectory)) {

        New-Item `
            -ItemType Directory `
            -Path $destinationDirectory `
            -Force |
            Out-Null
    }

    Write-Host ""
    Write-Host "Artifactory artifact:"
    Write-Host "  $ArtifactPath"

    Write-Host "Destination:"
    Write-Host "  $DestinationPath"

    Write-Host "URL:"
    Write-Host "  $url"

    if (Test-Path -LiteralPath $DestinationPath) {

        Write-Host ""
        Write-Host "Destination already exists."

        $existingHash =
            (Get-FileHash `
                -LiteralPath $DestinationPath `
                -Algorithm SHA256).Hash.ToLowerInvariant()

        if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {

            $expected =
                $ExpectedSha256.Trim().ToLowerInvariant()

            if ($existingHash -eq $expected) {

                Write-Host ""
                Write-Host "Existing file matches expected SHA256."
                Write-Host "Using existing artifact."

                return
            }

            Write-Warning `
                "Existing file SHA256 does not match expected checksum."

            Write-Host "Expected:"
            Write-Host "  $expected"

            Write-Host "Actual:"
            Write-Host "  $existingHash"

            Remove-Item `
                -LiteralPath $DestinationPath `
                -Force
        }
        else {

            throw @"
Existing artifact found but no expected SHA256 was supplied.

Artifact:
  $ArtifactPath

File:
  $DestinationPath

For reproducible image builds, supply BASE_ISO_SHA256.
"@
        }
    }

    Write-Host ""
    Write-Host "Downloading from Artifactory..."

    Invoke-WebRequest `
        -Uri $url `
        -Headers $headers `
        -OutFile $DestinationPath `
        -UseBasicParsing

    if (-not (Test-Path -LiteralPath $DestinationPath)) {

        throw "Artifactory download completed but destination file was not created: $DestinationPath"
    }

    $actualHash =
        (Get-FileHash `
            -LiteralPath $DestinationPath `
            -Algorithm SHA256).Hash.ToLowerInvariant()

    Write-Host ""
    Write-Host "Downloaded SHA256:"
    Write-Host "  $actualHash"

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {

        $expected =
            $ExpectedSha256.Trim().ToLowerInvariant()

        if ($actualHash -ne $expected) {

            Remove-Item `
                -LiteralPath $DestinationPath `
                -Force `
                -ErrorAction SilentlyContinue

            throw @"
SHA256 validation failed.

Artifact:
  $ArtifactPath

Expected:
  $expected

Actual:
  $actualHash
"@
        }

        Write-Host "SHA256 validation successful."
    }
}

# ============================================================
# Normalize Inputs
# ============================================================

$WorkRoot =
    Normalize-PathString -Path $WorkRoot

$DownloadDir =
    Join-Path $WorkRoot 'download'

$UpdatesDir =
    Join-Path $DownloadDir 'updates'

$BaseIsoPath =
    Join-Path $DownloadDir 'base.iso'

$ResolvedManifestPath =
    Join-Path $DownloadDir 'resolved-updates.json'

# ============================================================
# Validate Credentials
# ============================================================

if ([string]::IsNullOrWhiteSpace($ArtifactoryUser)) {
    throw "Artifactory username is required."
}

if ([string]::IsNullOrWhiteSpace($ArtifactoryPassword)) {
    throw "Artifactory password/API token is required."
}

# ============================================================
# Create Directories
# ============================================================

New-Item `
    -ItemType Directory `
    -Path $DownloadDir `
    -Force |
    Out-Null

New-Item `
    -ItemType Directory `
    -Path $UpdatesDir `
    -Force |
    Out-Null

# ============================================================
# Display Configuration
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Windows Image Download"
Write-Host "============================================================"
Write-Host ""
Write-Host "WorkRoot:"
Write-Host "  $WorkRoot"
Write-Host ""
Write-Host "Base ISO Artifact:"
Write-Host "  $BaseIsoArtifact"
Write-Host ""
Write-Host "Base ISO Destination:"
Write-Host "  $BaseIsoPath"
Write-Host ""
Write-Host "Windows Build:"
Write-Host "  $WindowsBuild"
Write-Host ""
Write-Host "Architecture:"
Write-Host "  $Architecture"
Write-Host ""
Write-Host "Artifactory:"
Write-Host "  $ArtifactoryBaseUrl"
Write-Host ""
Write-Host "Repository:"
Write-Host "  $ArtifactoryRepo"
Write-Host ""
Write-Host "============================================================"

# ============================================================
# Download Base ISO
# ============================================================

Write-Host ""
Write-Host "Downloading / validating base ISO..."

Get-ArtifactoryArtifact `
    -ArtifactPath $BaseIsoArtifact `
    -DestinationPath $BaseIsoPath `
    -ExpectedSha256 $BaseIsoSha256

# ============================================================
# Validate Base ISO
# ============================================================

if (-not (Test-Path -LiteralPath $BaseIsoPath)) {

    throw "Base ISO does not exist after download: $BaseIsoPath"
}

$baseIsoInfo =
    Get-Item -LiteralPath $BaseIsoPath

Write-Host ""
Write-Host "Base ISO:"
Write-Host "  $($baseIsoInfo.FullName)"

Write-Host "Size:"
Write-Host "  $([Math]::Round($baseIsoInfo.Length / 1GB, 2)) GB"

$actualBaseIsoSha256 =
    (Get-FileHash `
        -LiteralPath $BaseIsoPath `
        -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Host "SHA256:"
Write-Host "  $actualBaseIsoSha256"

if (-not [string]::IsNullOrWhiteSpace($BaseIsoSha256)) {

    $expectedBaseIsoSha256 =
        $BaseIsoSha256.Trim().ToLowerInvariant()

    if ($actualBaseIsoSha256 -ne $expectedBaseIsoSha256) {

        throw @"
Base ISO SHA256 validation failed.

Expected:
  $expectedBaseIsoSha256

Actual:
  $actualBaseIsoSha256

Artifact:
  $BaseIsoArtifact
"@
    }

    Write-Host ""
    Write-Host "Base ISO SHA256 validation successful."
}
else {

    Write-Warning @"
BASE_ISO_SHA256 was not supplied.

The base ISO was downloaded successfully, but this build is not fully
reproducible because the immutable base checksum was not explicitly pinned.

Recommended:
  Set BASE_ISO_SHA256 in the Jenkins job.
"@
}

# ============================================================
# Resolve Windows Update
# ============================================================

if (-not (Test-Path -LiteralPath $ResolverScriptPath)) {

    throw "Update resolver script not found: $ResolverScriptPath"
}

Write-Host ""
Write-Host "============================================================"
Write-Host " Resolving Windows Updates"
Write-Host "============================================================"
Write-Host ""

if (-not [string]::IsNullOrWhiteSpace($UpdateManifestUrl)) {

    Write-Host "Update manifest URL:"
    Write-Host "  $UpdateManifestUrl"
}

if (-not [string]::IsNullOrWhiteSpace($UpdateManifestFile)) {

    Write-Host "Update manifest file:"
    Write-Host "  $UpdateManifestFile"
}

Write-Host ""
Write-Host "Running update resolver..."

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

    throw "Windows update resolver failed with exit code $LASTEXITCODE."
}

# ============================================================
# Validate Resolved Manifest
# ============================================================

if (-not (Test-Path -LiteralPath $ResolvedManifestPath)) {

    throw @"
Windows update resolver completed but did not create:

$ResolvedManifestPath
"@
}

Write-Host ""
Write-Host "Resolved update manifest:"
Write-Host "  $ResolvedManifestPath"

$manifestText =
    Get-Content `
        -LiteralPath $ResolvedManifestPath `
        -Raw

if ([string]::IsNullOrWhiteSpace($manifestText)) {

    throw "Resolved update manifest is empty."
}

$manifest =
    $manifestText | ConvertFrom-Json

# ============================================================
# Validate Update Manifest Structure
# ============================================================

if ($manifest.PSObject.Properties['updates']) {

    $updates = @($manifest.updates)

}
elseif ($manifest.PSObject.Properties['kb']) {

    $updates = @($manifest)

}
else {

    throw @"
Invalid update manifest.

Expected either:

{
    "kb": "KBxxxxxxx",
    ...
}

or:

{
    "updates": [
        {
            "kb": "KBxxxxxxx",
            ...
        }
    ]
}
"@
}

if ($updates.Count -eq 0) {

    throw "Resolved update manifest contains no updates."
}

Write-Host ""
Write-Host "Resolved updates:"
Write-Host ""

foreach ($update in $updates) {

    Write-Host "KB:"
    Write-Host "  $($update.kb)"

    Write-Host "Build:"
    Write-Host "  $($update.build)"

    Write-Host "Filename:"
    Write-Host "  $($update.fileName)"

    Write-Host "SHA256:"
    Write-Host "  $($update.sha256)"

    Write-Host ""
}

# ============================================================
# Download Resolved Update Packages
# ============================================================

foreach ($update in $updates) {

    if ([string]::IsNullOrWhiteSpace($update.kb)) {

        throw "Resolved update does not contain a KB number."
    }

    if ([string]::IsNullOrWhiteSpace($update.fileName)) {

        throw "Resolved update $($update.kb) does not contain a filename."
    }

    if ([string]::IsNullOrWhiteSpace($update.artifactPath)) {

        throw "Resolved update $($update.kb) does not contain an Artifactory artifactPath."
    }

    $packagePath =
        Join-Path `
            $UpdatesDir `
            $update.fileName

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " Windows Update: $($update.kb)"
    Write-Host "============================================================"

    Get-ArtifactoryArtifact `
        -ArtifactPath $update.artifactPath `
        -DestinationPath $packagePath `
        -ExpectedSha256 $update.sha256

    # --------------------------------------------------------
    # Validate package
    # --------------------------------------------------------

    if (-not (Test-Path -LiteralPath $packagePath)) {

        throw "Update package was not downloaded: $packagePath"
    }

    $actualPackageSha256 =
        (Get-FileHash `
            -LiteralPath $packagePath `
            -Algorithm SHA256).Hash.ToLowerInvariant()

    $expectedPackageSha256 =
        $update.sha256.Trim().ToLowerInvariant()

    Write-Host ""
    Write-Host "Package:"
    Write-Host "  $packagePath"

    Write-Host "SHA256:"
    Write-Host "  $actualPackageSha256"

    if ($actualPackageSha256 -ne $expectedPackageSha256) {

        throw @"
Windows update SHA256 validation failed.

KB:
  $($update.kb)

Expected:
  $expectedPackageSha256

Actual:
  $actualPackageSha256

File:
  $packagePath
"@
    }

    Write-Host "Update package validation successful."
}

# ============================================================
# Final Output
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Download Stage Complete"
Write-Host "============================================================"
Write-Host ""
Write-Host "Base ISO:"
Write-Host "  $BaseIsoPath"
Write-Host ""
Write-Host "Resolved Manifest:"
Write-Host "  $ResolvedManifestPath"
Write-Host ""
Write-Host "Updates:"
Write-Host "  $UpdatesDir"
Write-Host ""
Write-Host "============================================================"