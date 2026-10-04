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

    [string]$ArtifactoryToken = '',

    [ValidateSet('InvokeWebRequest', 'JFrog')]
    [string]$ArtifactTransferMethod = 'InvokeWebRequest',

    [string]$JfPath = 'jf.exe',

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
# Authentication headers
# ============================================================

$headers = @{}

if (-not [string]::IsNullOrWhiteSpace($ArtifactoryToken)) {
    $headers['Authorization'] = "Bearer $ArtifactoryToken"
}
else {
    $pair = '{0}:{1}' -f $ArtifactoryUser, $ArtifactoryPassword

    $headers['Authorization'] =
        'Basic ' +
        [Convert]::ToBase64String(
            [Text.Encoding]::ASCII.GetBytes($pair)
        )
}

# ============================================================
# Validate JFrog configuration
# ============================================================

function Assert-JFrogAvailable {
    if (-not (Get-Command $JfPath -ErrorAction SilentlyContinue)) {
        throw (
            "ArtifactTransferMethod is 'JFrog', but jf.exe was not found. " +
            "JfPath='$JfPath'"
        )
    }

    Write-Host "JFrog CLI: $JfPath"
}

# ============================================================
# JFrog authentication arguments
# ============================================================

function Get-JFrogAuthArguments {
    if (-not [string]::IsNullOrWhiteSpace($ArtifactoryToken)) {
        return @(
            '--access-token'
            $ArtifactoryToken
        )
    }

    if (
        -not [string]::IsNullOrWhiteSpace($ArtifactoryUser) -and
        -not [string]::IsNullOrWhiteSpace($ArtifactoryPassword)
    ) {
        return @(
            '--user'
            $ArtifactoryUser
            '--password'
            $ArtifactoryPassword
        )
    }

    throw (
        'JFrog authentication requires ArtifactoryToken or ' +
        'ArtifactoryUser/ArtifactoryPassword.'
    )
}

# ============================================================
# Artifactory URL
# ============================================================

function Get-ArtifactUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return "$ArtifactoryUrlRoot/$ArtifactoryRepo/$($Path.TrimStart('/'))"
}

# ============================================================
# Convert repository path to JFrog CLI path
# ============================================================

function ConvertTo-JFrogArtifactPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return "$ArtifactoryRepo/$($Path.TrimStart('/'))"
}

# ============================================================
# Execute JFrog CLI
# ============================================================

function Invoke-JFrog {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Assert-JFrogAvailable

    Write-Host ''
    Write-Host 'Executing JFrog CLI:'
    Write-Host "  $JfPath $($Arguments -join ' ')"

    & $JfPath @Arguments

    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw (
            "jf.exe failed with exit code $exitCode. " +
            "Arguments: $($Arguments -join ' ')"
        )
    }

    return $exitCode
}

# ============================================================
# SHA256 helper
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
# Get text artifact
# ============================================================

function Get-ArtifactText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    switch ($ArtifactTransferMethod) {

        'InvokeWebRequest' {

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

        'JFrog' {

            $tempDir = Join-Path $DownloadDir '.jfrog-text'

            New-Item `
                -ItemType Directory `
                -Force `
                -Path $tempDir |
                Out-Null

            $downloadedFile = Join-Path `
                $tempDir `
                (Split-Path $Path -Leaf)

            try {

                $jfArtifact =
                    ConvertTo-JFrogArtifactPath $Path

                $authArgs =
                    Get-JFrogAuthArguments

                $jfArgs = @(
                    'rt'
                    'dl'
                    $jfArtifact
                    $tempDir
                    '--flat=true'
                    '--fail-no-op=true'
                )

                $jfArgs += $authArgs

                Invoke-JFrog `
                    -Arguments $jfArgs |
                    Out-Null

                if (
                    -not (
                        Test-Path `
                            -LiteralPath $downloadedFile `
                            -PathType Leaf
                    )
                ) {
                    return $null
                }

                $bytes =
                    [IO.File]::ReadAllBytes(
                        $downloadedFile
                    )

                $offset = 0

                # UTF-8 BOM = EF BB BF
                if (
                    $bytes.Length -ge 3 -and
                    $bytes[0] -eq 0xEF -and
                    $bytes[1] -eq 0xBB -and
                    $bytes[2] -eq 0xBF
                ) {
                    $offset = 3
                }

                $utf8 =
                    New-Object `
                        System.Text.UTF8Encoding(
                            $false,
                            $true
                        )

                return $utf8.GetString(
                    $bytes,
                    $offset,
                    $bytes.Length - $offset
                )
            }
            catch {
                if (
                    $_.Exception.Message -match
                    '(?i)404|not found|no artifacts|no files'
                ) {
                    return $null
                }

                throw
            }
            finally {
                if (Test-Path -LiteralPath $downloadedFile) {
                    Remove-Item `
                        -LiteralPath $downloadedFile `
                        -Force `
                        -ErrorAction SilentlyContinue
                }
            }
        }

        default {
            throw "Unsupported ArtifactTransferMethod: $ArtifactTransferMethod"
        }
    }
}

# ============================================================
# Test artifact exists
# ============================================================

function Test-ArtifactExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    switch ($ArtifactTransferMethod) {

        'InvokeWebRequest' {

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

        'JFrog' {

            Assert-JFrogAvailable

            $jfArtifact =
                ConvertTo-JFrogArtifactPath $Path

            $authArgs =
                Get-JFrogAuthArguments

            $jfArgs = @(
                'rt'
                's'
                $jfArtifact
                '--count'
            )

            $jfArgs += $authArgs

            Write-Host ''
            Write-Host 'Checking JFrog artifact:'
            Write-Host "  $jfArtifact"

            $output = & $JfPath @jfArgs 2>&1
            $exitCode = $LASTEXITCODE

            $text =
                ($output | Out-String).Trim()

            if ($exitCode -ne 0) {

                if (
                    $text -match '(?i)no artifacts' -or
                    $text -match '(?i)not found' -or
                    $text -match '(?i)0 artifacts' -or
                    $text -match '(?i)no files'
                ) {
                    return $false
                }

                throw (
                    "jf.exe artifact search failed with exit code " +
                    "$exitCode.`n$text"
                )
            }

            $count = 0

            if (
                [int]::TryParse(
                    $text,
                    [ref]$count
                )
            ) {
                return ($count -gt 0)
            }

            # Some JFrog CLI versions can emit surrounding text.
            # Extract the first standalone integer.
            $match = [regex]::Match(
                $text,
                '(?m)^\s*(\d+)\s*$'
            )

            if ($match.Success) {
                return (
                    [int]$match.Groups[1].Value -gt 0
                )
            }

            return $false
        }

        default {
            throw "Unsupported ArtifactTransferMethod: $ArtifactTransferMethod"
        }
    }
}

# ============================================================
# Download artifact
# ============================================================

function Download-Artifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [string]$ExpectedSha256 = ''
    )

    $uri = Get-ArtifactUrl $Path

    $dir = Split-Path -Parent $Destination

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $dir |
        Out-Null

    Write-Host ''
    Write-Host 'Downloading Artifactory artifact:'
    Write-Host "  Transfer method:"
    Write-Host "    $ArtifactTransferMethod"
    Write-Host "  Artifact:"
    Write-Host "    $uri"
    Write-Host "  Destination:"
    Write-Host "    $Destination"

    # Always transfer into a temporary file first.
    $temporary = "$Destination.download"

    if (Test-Path -LiteralPath $temporary) {
        Remove-Item `
            -LiteralPath $temporary `
            -Force `
            -ErrorAction SilentlyContinue
    }

    try {

        switch ($ArtifactTransferMethod) {

            'InvokeWebRequest' {

                try {
                    Invoke-WebRequest `
                        -Uri $uri `
                        -Headers $headers `
                        -Method Get `
                        -UseBasicParsing `
                        -OutFile $temporary `
                        -TimeoutSec 1800 `
                        -ErrorAction Stop
                }
                catch {
                    throw (
                        "Artifactory download failed: $uri`n" +
                        $_.Exception.Message
                    )
                }
            }

            'JFrog' {

                Assert-JFrogAvailable

                $jfArtifact =
                    ConvertTo-JFrogArtifactPath $Path

                $authArgs =
                    Get-JFrogAuthArguments

                $tempDir =
                    Split-Path -Parent $temporary

                $jfArgs = @(
                    'rt'
                    'dl'
                    $jfArtifact
                    $tempDir
                    '--flat=true'
                    '--fail-no-op=true'
                    '--threads=4'
                )

                $jfArgs += $authArgs

                Invoke-JFrog `
                    -Arguments $jfArgs |
                    Out-Null

                # JFrog writes the original artifact filename.
                $jfDownloaded =
                    Join-Path `
                        $tempDir `
                        (Split-Path $Path -Leaf)

                if (
                    -not (
                        Test-Path `
                            -LiteralPath $jfDownloaded `
                            -PathType Leaf
                    )
                ) {
                    throw (
                        "JFrog reported successful download, but the " +
                        "downloaded file was not found: $jfDownloaded"
                    )
                }

                Move-Item `
                    -LiteralPath $jfDownloaded `
                    -Destination $temporary `
                    -Force
            }

            default {
                throw (
                    "Unsupported ArtifactTransferMethod: " +
                    $ArtifactTransferMethod
                )
            }
        }

        if (
            -not (
                Test-Path `
                    -LiteralPath $temporary `
                    -PathType Leaf
            )
        ) {
            throw (
                "Artifact transfer completed but temporary file was not " +
                "created: $temporary"
            )
        }

        $temporaryInfo =
            Get-Item -LiteralPath $temporary

        if ($temporaryInfo.Length -le 0) {
            throw (
                "Artifact transfer produced an empty file: $temporary"
            )
        }

        # Validate SHA256 before replacing the destination.
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {

            $actual =
                Get-Sha256 $temporary

            if (
                $actual -ne
                $ExpectedSha256.ToLowerInvariant()
            ) {

                Remove-Item `
                    -LiteralPath $temporary `
                    -Force `
                    -ErrorAction SilentlyContinue

                throw (
                    "SHA256 mismatch for $Path. " +
                    "Expected $ExpectedSha256, actual $actual"
                )
            }

            Write-Host "SHA256 verified: $actual"
        }

        if (Test-Path -LiteralPath $Destination) {
            Remove-Item `
                -LiteralPath $Destination `
                -Force
        }

        Move-Item `
            -LiteralPath $temporary `
            -Destination $Destination `
            -Force

        Write-Host ''
        Write-Host 'Artifact download: SUCCESS'
        Write-Host "  $Destination"
    }
    catch {

        if (Test-Path -LiteralPath $temporary) {
            Remove-Item `
                -LiteralPath $temporary `
                -Force `
                -ErrorAction SilentlyContinue
        }

        throw
    }
}

# ============================================================
# Display configuration
# ============================================================

Write-Host ''
Write-Host '============================================================'
Write-Host ' Windows Image Download'
Write-Host '============================================================'
Write-Host "Profile                  : $($profileInfo.Name)"
Write-Host "Windows                  : $($profileInfo.WindowsVersion)"
Write-Host "Windows Build            : $($profileInfo.Build)"
Write-Host "Architecture             : $Architecture"
Write-Host "Artifact transfer method : $ArtifactTransferMethod"
Write-Host "Artifactory URL          : $ArtifactoryUrlRoot"
Write-Host "Artifactory repo         : $ArtifactoryRepo"
Write-Host "Work root                : $WorkRoot"
Write-Host ''

if ($ArtifactTransferMethod -eq 'JFrog') {
    Assert-JFrogAvailable
}

# ============================================================
# Resolve LCU - resolve only
#
# The resolver owns update metadata resolution.
# This script owns artifact transfer and patched-image caching.
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

if (Test-Path -LiteralPath $CacheMarker) {
    Remove-Item `
        -LiteralPath $CacheMarker `
        -Force
}

# Resolve metadata only.
& $ResolverScriptPath `
    -WorkRoot $WorkRoot `
    -Profile $Profile `
    -Architecture $Architecture `
    -ArtifactoryBaseUrl $ArtifactoryBaseUrl `
    -ArtifactoryRepo $ArtifactoryRepo `
    -ArtifactoryUser $ArtifactoryUser `
    -ArtifactoryPassword $ArtifactoryPassword `
    -ArtifactoryToken $ArtifactoryToken `
    -ResolveOnly

$resolveExit = $LASTEXITCODE

if ($resolveExit -ne 0) {
    throw "Update resolver failed with exit code $resolveExit"
}

if (-not (Test-Path -LiteralPath $ResolvedPath -PathType Leaf)) {
    throw "Resolved update manifest was not created: $ResolvedPath"
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
    -not $resolved.build -or
    -not $resolved.updateId -or
    -not $resolved.fileName
) {
    throw (
        'Resolved update manifest is missing KB, build, ' +
        'UpdateID, or fileName.'
    )
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
    throw 'Resolved update manifest is missing artifactRoot.'
}

if ([string]::IsNullOrWhiteSpace($isoPrefix)) {
    throw 'Resolved update manifest is missing isoPrefix.'
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

if ([string]::IsNullOrWhiteSpace($BaseIsoSha256)) {

    Write-Warning `
        'BASE_ISO_SHA256 is empty; exact patched-image cache validation is disabled.'
}
else {

    $remoteManifest =
        Get-ArtifactText $manifestArtifact

    if ($remoteManifest) {

        try {

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

                $markerObject = [ordered]@{
                    cacheHit             = $true
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
                Write-Host '============================================================'
                Write-Host ' PATCHED IMAGE CACHE HIT'
                Write-Host '============================================================'
                Write-Host 'Base ISO download skipped.'
                Write-Host 'MSU download skipped.'
                Write-Host "Cached ISO: $isoArtifact"
                Write-Host ''

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
    throw "Base ISO was not downloaded: $BaseIsoPath"
}

Write-Host ''
Write-Host 'Base ISO download: SUCCESS'
Write-Host "Base ISO: $BaseIsoPath"

# ============================================================
# Resolve and download/cache MSU
# ============================================================

& $ResolverScriptPath `
    -WorkRoot $WorkRoot `
    -Profile $Profile `
    -Architecture $Architecture `
    -ArtifactoryBaseUrl $ArtifactoryBaseUrl `
    -ArtifactoryRepo $ArtifactoryRepo `
    -ArtifactoryUser $ArtifactoryUser `
    -ArtifactoryPassword $ArtifactoryPassword `
    -ArtifactoryToken $ArtifactoryToken

$resolveExit = $LASTEXITCODE

if ($resolveExit -ne 0) {
    throw (
        "Update download/resolution failed with exit code $resolveExit"
    )
}

if (-not (Test-Path -LiteralPath $ResolvedPath -PathType Leaf)) {
    throw (
        "Resolved update manifest was not created: $ResolvedPath"
    )
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
    throw (
        'Resolved update manifest is missing KB, build, or SHA256.'
    )
}

# ============================================================
# MSU path
# ============================================================

$package =
    Join-Path `
        $UpdatesDir `
        $resolved.fileName

if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
    throw "Resolved update package is missing: $package"
}

# ============================================================
# Validate MSU SHA256
# ============================================================

$actual =
    Get-Sha256 $package

$expected =
    $resolved.sha256.ToString().ToLowerInvariant()

if ($actual -ne $expected) {
    throw (
        "MSU SHA256 mismatch for $($resolved.fileName). " +
        "Expected $expected, actual $actual"
    )
}

# ============================================================
# Success
# ============================================================

Write-Host ''
Write-Host '============================================================'
Write-Host ' Download Stage Complete'
Write-Host '============================================================'
Write-Host "Profile                  : $($profileInfo.Name)"
Write-Host "Windows                  : $($profileInfo.WindowsVersion)"
Write-Host "Windows Build            : $($profileInfo.Build)"
Write-Host "Architecture             : $Architecture"
Write-Host "Artifact transfer method : $ArtifactTransferMethod"
Write-Host "KB                       : $($resolved.kb)"
Write-Host "LCU Build                : $($resolved.build)"
Write-Host "MSU                      : $($resolved.fileName)"
Write-Host "MSU SHA256               : $actual"
Write-Host "MSU Source               : $($resolved.source)"
Write-Host "MSU Path                 : $package"
Write-Host 'Download stage: SUCCESS'
Write-Host '============================================================'
Write-Host ''

exit 0

