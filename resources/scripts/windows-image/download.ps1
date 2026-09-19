[CmdletBinding()]
param(

    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [Parameter(Mandatory = $true)]
    [string]$BaseIsoArtifact,

    [Parameter(Mandatory = $false)]
    [string]$BaseIsoSha256,

    [Parameter(Mandatory = $true)]
    [string]$WindowsBuild,

    [Parameter(Mandatory = $true)]
    [string]$Architecture,

    [Parameter(Mandatory = $false)]
    [string]$UpdateManifestUrl,

    [Parameter(Mandatory = $false)]
    [string]$UpdateManifestFile,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryRepo,

    [Parameter(Mandatory = $true)]
    [string]$ResolverScriptPath
)

$ErrorActionPreference = 'Stop'


$WorkRoot =
    [System.IO.Path]::GetFullPath($WorkRoot)


$DownloadDir =
    Join-Path $WorkRoot 'download'

$UpdatesDir =
    Join-Path $DownloadDir 'updates'

$BaseIso =
    Join-Path $DownloadDir 'base.iso'


Write-Host ""
Write-Host "============================================================"
Write-Host " Download Windows Image Artifacts"
Write-Host "============================================================"

Write-Host "WorkRoot:"
Write-Host "  $WorkRoot"

Write-Host ""
Write-Host "Artifactory Repository:"
Write-Host "  $ArtifactoryRepo"

Write-Host ""
Write-Host "Base ISO Artifact:"
Write-Host "  $BaseIsoArtifact"

Write-Host ""
Write-Host "Base ISO Destination:"
Write-Host "  $BaseIso"

Write-Host ""
Write-Host "Resolver:"
Write-Host "  $ResolverScriptPath"

Write-Host "============================================================"


New-Item `
    -ItemType Directory `
    -Force `
    -Path $DownloadDir |
    Out-Null


New-Item `
    -ItemType Directory `
    -Force `
    -Path $UpdatesDir |
    Out-Null


function Get-ArtifactoryUrl {

    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$ArtifactPath
    )


    $encodedPath =
        ($ArtifactPath -split '/') |
        ForEach-Object {
            [System.Uri]::EscapeDataString($_)
        }


    $encodedPath =
        $encodedPath -join '/'


    return "$($BaseUrl.TrimEnd('/'))/$Repository/$encodedPath"
}


function Get-ArtifactoryArtifact {

    param(

        [Parameter(Mandatory = $true)]
        [string]$ArtifactoryBaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$ArtifactPath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $false)]
        [string]$ExpectedSha256
    )


    $url =
        Get-ArtifactoryUrl `
            -BaseUrl $ArtifactoryBaseUrl `
            -Repository $Repository `
            -ArtifactPath $ArtifactPath


    Write-Host ""
    Write-Host "Artifactory URL:"
    Write-Host "  $url"


    if (Test-Path -LiteralPath $DestinationPath) {

        Write-Host ""
        Write-Host "Destination already exists."

        if ($ExpectedSha256) {

            $existingHash =
                (Get-FileHash `
                    -LiteralPath $DestinationPath `
                    -Algorithm SHA256).Hash.ToLowerInvariant()


            if ($existingHash -eq
                $ExpectedSha256.Trim().ToLowerInvariant()) {

                Write-Host "Existing file SHA256 matches."
                Write-Host "Skipping download."

                return
            }


            Write-Warning `
                "Existing file SHA256 does not match. Redownloading."


            Remove-Item `
                -LiteralPath $DestinationPath `
                -Force
        }
        else {

            Write-Host "No expected SHA256 supplied."
            Write-Host "Redownloading artifact."

            Remove-Item `
                -LiteralPath $DestinationPath `
                -Force
        }
    }


    Write-Host ""
    Write-Host "Downloading from Artifactory..."


    Invoke-WebRequest `
        -Uri $url `
        -OutFile $DestinationPath `
        -UseBasicParsing `
        -ErrorAction Stop


    if (-not (Test-Path -LiteralPath $DestinationPath)) {

        throw "Artifact download failed: $url"
    }


    $file =
        Get-Item -LiteralPath $DestinationPath


    if ($file.Length -eq 0) {

        throw "Downloaded artifact is empty: $DestinationPath"
    }


    Write-Host ""
    Write-Host "Downloaded:"
    Write-Host "  $DestinationPath"

    Write-Host "Size:"
    Write-Host "  $($file.Length) bytes"


    if ($ExpectedSha256) {

        $actualHash =
            (Get-FileHash `
                -LiteralPath $DestinationPath `
                -Algorithm SHA256).Hash.ToLowerInvariant()


        $expectedHash =
            $ExpectedSha256.Trim().ToLowerInvariant()


        Write-Host ""
        Write-Host "SHA256:"
        Write-Host "  Expected: $expectedHash"
        Write-Host "  Actual:   $actualHash"


        if ($actualHash -ne $expectedHash) {

            Remove-Item `
                -LiteralPath $DestinationPath `
                -Force `
                -ErrorAction SilentlyContinue


            throw @"
SHA256 mismatch.

Artifact:
  $ArtifactPath

Expected:
  $expectedHash

Actual:
  $actualHash
"@
        }


        Write-Host "SHA256 verification passed."
    }
}


# ============================================================
# Download Base ISO
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Download Base ISO"
Write-Host "============================================================"


Get-ArtifactoryArtifact `
    -ArtifactoryBaseUrl $ArtifactoryBaseUrl `
    -Repository $ArtifactoryRepo `
    -ArtifactPath $BaseIsoArtifact `
    -DestinationPath $BaseIso `
    -ExpectedSha256 $BaseIsoSha256


if (-not (Test-Path -LiteralPath $BaseIso)) {

    throw "Base ISO was not downloaded: $BaseIso"
}


$isoFile =
    Get-Item -LiteralPath $BaseIso


$actualIsoSha256 =
    (Get-FileHash `
        -LiteralPath $BaseIso `
        -Algorithm SHA256).Hash.ToLowerInvariant()


Write-Host ""
Write-Host "Base ISO:"
Write-Host "  $BaseIso"

Write-Host ""
Write-Host "Size:"
Write-Host "  $($isoFile.Length) bytes"

Write-Host ""
Write-Host "SHA256:"
Write-Host "  $actualIsoSha256"


if ($BaseIsoSha256) {

    if ($actualIsoSha256 -ne
        $BaseIsoSha256.Trim().ToLowerInvariant()) {

        throw @"
Base ISO SHA256 mismatch.

Expected:
  $($BaseIsoSha256.Trim().ToLowerInvariant())

Actual:
  $actualIsoSha256
"@
    }


    Write-Host "Base ISO SHA256 verification passed."
}


# ============================================================
# Resolve Updates
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Resolve Windows Updates"
Write-Host "============================================================"


if (-not (Test-Path -LiteralPath $ResolverScriptPath)) {

    throw @"
Update resolver script was not found.

Expected:
  $ResolverScriptPath
"@
}


& $ResolverScriptPath `
    -WorkRoot $WorkRoot `
    -WindowsBuild $WindowsBuild `
    -Architecture $Architecture `
    -ArtifactoryBaseUrl $ArtifactoryBaseUrl `
    -ArtifactoryRepo $ArtifactoryRepo


if ($LASTEXITCODE -ne 0) {

    throw "Update resolver failed."
}


Write-Host ""
Write-Host "============================================================"
Write-Host " Download Stage Complete"
Write-Host "============================================================"