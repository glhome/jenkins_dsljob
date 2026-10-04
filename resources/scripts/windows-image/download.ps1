
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

$DownloadDir = Join-Path $WorkRoot 'download'
$UpdatesDir = Join-Path $DownloadDir 'updates'
$BaseIsoPath = Join-Path $DownloadDir 'base.iso'
$ResolvedPath = Join-Path $DownloadDir 'resolved-updates.json'
$CacheMarker = Join-Path $DownloadDir 'patched-cache-hit.json'

New-Item -ItemType Directory -Force -Path $DownloadDir, $UpdatesDir | Out-Null

# ============================================================
# Validate inputs
# ============================================================

if (-not (Test-Path -LiteralPath $ResolverScriptPath -PathType Leaf)) {
    throw "Resolver script does not exist: $ResolverScriptPath"
}

if ([string]::IsNullOrWhiteSpace($ArtifactoryBaseUrl)) {
    throw "ArtifactoryBaseUrl is required."
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

    $headers['Authorization'] = 'Basic ' + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes($pair)
    )
}

# ============================================================
# Validate JFrog configuration
# ============================================================

function Assert-JFrogAvailable {
    if (-not (Get-Command $JfPath -ErrorAction SilentlyContinue)) {
        throw "ArtifactTransferMethod is 'JFrog', but jf.exe was not found. JfPath='$JfPath'"
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

    throw "JFrog authentication requires ArtifactoryToken or ArtifactoryUser/ArtifactoryPassword."
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
# Sanitize JFrog arguments for logging
# ============================================================

function Protect-JFrogArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $safe = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $arg = [string]$Arguments[$i]

        if ($arg -eq '--password' -or $arg -eq '--access-token') {
            $safe.Add($arg)

            if (($i + 1) -lt $Arguments.Count) {
                $safe.Add('****')
                $i++
            }

            continue
        }

        if ($arg -like '--password=*') {
            $safe.Add('--password=****')
            continue
        }

        if ($arg -like '--access-token=*') {
            $safe.Add('--access-token=****')
            continue
        }

        $safe.Add($arg)
    }

    return @($safe)
}

# ============================================================
# Execute JFrog CLI
#
# URL and authentication are added here.
# Callers must NOT add authentication arguments.
# ============================================================

function Invoke-JFrog {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Assert-JFrogAvailable

    $urlArgs = @(
        '--url'
        $ArtifactoryUrlRoot
    )

    $authArgs = Get-JFrogAuthArguments

    $jfArgs = @($Arguments) + $urlArgs + $authArgs

    $safeArgs = Protect-JFrogArguments -Arguments $jfArgs

    Write-Host ""
    Write-Host "Executing JFrog CLI:"
    Write-Host "  $JfPath $($safeArgs -join ' ')"

    & $JfPath @jfArgs

    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "jf.exe failed with exit code $exitCode. Arguments: $($safeArgs -join ' ')"
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
        Get-FileHash -LiteralPath $Path -Algorithm SHA256
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

            $uri = Get-ArtifactUrl -Path $Path

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

                $utf8 = New-Object System.Text.UTF8Encoding($false, $true)

                $reader = New-Object System.IO.StreamReader(
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

            if (-not (Test-ArtifactExists -Path $Path)) {
                Write-Host "JFrog artifact does not exist: $Path"
                return $null
            }

            $tempDir = Join-Path $DownloadDir '.jfrog-text'

            if (Test-Path -LiteralPath $tempDir) {
                Remove-Item `
                    -LiteralPath $tempDir `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }

            New-Item `
                -ItemType Directory `
                -Force `
                -Path $tempDir |
                Out-Null

            $fileName = Split-Path $Path -Leaf
            $downloadedFile = Join-Path $tempDir $fileName

            try {

                $jfArtifact = ConvertTo-JFrogArtifactPath -Path $Path

                $jfArgs = @(
                    'rt'
                    'dl'
                    $jfArtifact
                    $tempDir
                    '--flat=true'
                )

                Invoke-JFrog -Arguments $jfArgs | Out-Null

                if (-not (Test-Path -LiteralPath $downloadedFile -PathType Leaf)) {
                    throw "JFrog download succeeded but artifact was not found: $downloadedFile"
                }

                $bytes = [IO.File]::ReadAllBytes($downloadedFile)

                $offset = 0

                if (
                    $bytes.Length -ge 3 -and
                    $bytes[0] -eq 0xEF -and
                    $bytes[1] -eq 0xBB -and
                    $bytes[2] -eq 0xBF
                ) {
                    $offset = 3
                }

                $utf8 = New-Object System.Text.UTF8Encoding($false, $true)

                return $utf8.GetString(
                    $bytes,
                    $offset,
                    $bytes.Length - $offset
                )
            }
            finally {

                if (Test-Path -LiteralPath $tempDir) {
                    Remove-Item `
                        -LiteralPath $tempDir `
                        -Recurse `
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

            $uri = Get-ArtifactUrl -Path $Path

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

            $jfArtifact = ConvertTo-JFrogArtifactPath -Path $Path

            $fullArgs = @(
                'rt'
                's'
                $jfArtifact
                '--count'
                '--url'
                $ArtifactoryUrlRoot
            ) + (Get-JFrogAuthArguments)

            $safeArgs = Protect-JFrogArguments `
                -Arguments $fullArgs

            Write-Host ""
            Write-Host "Checking JFrog artifact:"
            Write-Host "  $($safeArgs -join ' ')"

            #
            # IMPORTANT:
            #
            # Do not use:
            #
            #   2>&1
            #
            # JFrog writes informational messages such as
            # "Searching artifacts..." to stderr.
            #
            # Capture stdout and stderr independently.
            #

            $stdoutFile = Join-Path `
                $DownloadDir `
                '.jfrog-search.stdout'

            $stderrFile = Join-Path `
                $DownloadDir `
                '.jfrog-search.stderr'

            Remove-Item `
                -LiteralPath $stdoutFile `
                -Force `
                -ErrorAction SilentlyContinue

            Remove-Item `
                -LiteralPath $stderrFile `
                -Force `
                -ErrorAction SilentlyContinue

            #
            # Execute jf.exe through cmd.exe so that stderr does
            # not become a PowerShell NativeCommandError.
            #
            $argumentString = @(
                $fullArgs | ForEach-Object {
                    $value = [string]$_

                    if (
                        $value -match '[\s"]'
                    ) {
                        '"' + $value.Replace('"', '\"') + '"'
                    }
                    else {
                        $value
                    }
                }
            ) -join ' '

            $cmdLine = "`"$JfPath`" $argumentString 1>`"$stdoutFile`" 2>`"$stderrFile`""

            cmd.exe /d /s /c $cmdLine

            $exitCode = $LASTEXITCODE

            $stdout = ''

            if (Test-Path -LiteralPath $stdoutFile) {
                $stdout = Get-Content `
                    -LiteralPath $stdoutFile `
                    -Raw `
                    -ErrorAction SilentlyContinue
            }

            $stderr = ''

            if (Test-Path -LiteralPath $stderrFile) {
                $stderr = Get-Content `
                    -LiteralPath $stderrFile `
                    -Raw `
                    -ErrorAction SilentlyContinue
            }

            Remove-Item `
                -LiteralPath $stdoutFile `
                -Force `
                -ErrorAction SilentlyContinue

            Remove-Item `
                -LiteralPath $stderrFile `
                -Force `
                -ErrorAction SilentlyContinue

            #
            # Exit code 2 can mean "no files affected" for some
            # JFrog operations. Treat that as a cache miss.
            #
            if ($exitCode -ne 0) {

                $combined = "$stdout`n$stderr"

                if (
                    $combined -match '(?i)no artifacts' -or
                    $combined -match '(?i)no files' -or
                    $combined -match '(?i)not found' -or
                    $combined -match '(?i)0 artifacts'
                ) {
                    Write-Host "JFrog artifact does not exist: $Path"
                    return $false
                }

                throw "jf.exe artifact search failed with exit code $exitCode.`n$combined"
            }

            #
            # jf rt s --count normally returns a numeric value.
            #
            $countText = $stdout.Trim()

            $count = 0

            if (
                [int]::TryParse(
                    $countText,
                    [Globalization.NumberStyles]::Integer,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$count
                )
            ) {
                if ($count -gt 0) {
                    Write-Host "JFrog artifact exists: $Path"
                    return $true
                }

                Write-Host "JFrog artifact does not exist: $Path"
                return $false
            }

            #
            # Some JFrog CLI versions may put the count in a
            # slightly different output format.
            #
            $match = [regex]::Match(
                $countText,
                '(?m)^\s*(\d+)\s*$'
            )

            if ($match.Success) {

                $count = [int]$match.Groups[1].Value

                if ($count -gt 0) {
                    Write-Host "JFrog artifact exists: $Path"
                    return $true
                }

                Write-Host "JFrog artifact does not exist: $Path"
                return $false
            }

            #
            # If there was no numeric output, don't assume the
            # artifact exists. Treat it as a cache miss.
            #
            Write-Host "JFrog returned no usable artifact count."
            Write-Host "JFrog stdout:"
            Write-Host $countText

            if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                Write-Host "JFrog stderr:"
                Write-Host $stderr.Trim()
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

    $uri = Get-ArtifactUrl -Path $Path

    $dir = Split-Path -Parent $Destination

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $dir |
        Out-Null

    Write-Host ""
    Write-Host "Downloading Artifactory artifact:"
    Write-Host "  Transfer method:"
    Write-Host "    $ArtifactTransferMethod"
    Write-Host "  Artifact:"
    Write-Host "    $uri"
    Write-Host "  Destination:"
    Write-Host "    $Destination"

    #
    # Always download to a temporary FILE.
    #
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

                    throw "Artifactory download failed: $uri`n$($_.Exception.Message)"
                }
            }

            'JFrog' {

                Assert-JFrogAvailable

                $jfArtifact = ConvertTo-JFrogArtifactPath -Path $Path

                #
                # IMPORTANT:
                #
                # Pass the exact temporary FILE as the JFrog target.
                #
                # Do not pass:
                #
                #   $dir
                #
                # because jf.exe may attempt directory cleanup.
                #
                $jfArgs = @(
                    'rt'
                    'dl'
                    $jfArtifact
                    $temporary
                    '--flat=true'
                    '--threads=4'
                )

                Invoke-JFrog `
                    -Arguments $jfArgs |
                    Out-Null

                if (
                    -not (
                        Test-Path `
                            -LiteralPath $temporary `
                            -PathType Leaf
                    )
                ) {
                    throw "JFrog reported successful download, but the downloaded file was not found: $temporary"
                }
            }

            default {
                throw "Unsupported ArtifactTransferMethod: $ArtifactTransferMethod"
            }
        }

        #
        # Validate downloaded file.
        #
        if (
            -not (
                Test-Path `
                    -LiteralPath $temporary `
                    -PathType Leaf
            )
        ) {
            throw "Artifact transfer completed but temporary file was not created: $temporary"
        }

        $temporaryInfo = Get-Item -LiteralPath $temporary

        if ($temporaryInfo.Length -le 0) {
            throw "Artifact transfer produced an empty file: $temporary"
        }

        Write-Host ""
        Write-Host "Downloaded file size: $($temporaryInfo.Length) bytes"

        #
        # SHA256 verification.
        #
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {

            Write-Host "Calculating SHA256..."

            $actual = Get-Sha256 -Path $temporary

            $expected = $ExpectedSha256.ToLowerInvariant()

            if ($actual -ne $expected) {

                Remove-Item `
                    -LiteralPath $temporary `
                    -Force `
                    -ErrorAction SilentlyContinue

                throw "SHA256 mismatch for $Path. Expected $expected, actual $actual"
            }

            Write-Host "SHA256 verified: $actual"
        }

        #
        # Replace destination atomically-ish.
        #
        if (Test-Path -LiteralPath $Destination) {

            Remove-Item `
                -LiteralPath $Destination `
                -Force `
                -ErrorAction Stop
        }

        Move-Item `
            -LiteralPath $temporary `
            -Destination $Destination `
            -Force `
            -ErrorAction Stop

        Write-Host ""
        Write-Host "Artifact download: SUCCESS"
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

Write-Host ""
Write-Host "============================================================"
Write-Host " Windows Image Download"
Write-Host "============================================================"
Write-Host "Profile                  : $($profileInfo.Name)"
Write-Host "Windows                  : $($profileInfo.WindowsVersion)"
Write-Host "Windows Build            : $($profileInfo.Build)"
Write-Host "Architecture             : $Architecture"
Write-Host "Artifact transfer method : $ArtifactTransferMethod"
Write-Host "Artifactory URL          : $ArtifactoryUrlRoot"
Write-Host "Artifactory repo         : $ArtifactoryRepo"
Write-Host "Work root                : $WorkRoot"
Write-Host ""

if ($ArtifactTransferMethod -eq 'JFrog') {
    Assert-JFrogAvailable
}

# ============================================================
# Resolve LCU - resolve only
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Resolve LCU and Check Patched Image Cache"
Write-Host "============================================================"
Write-Host "Profile      : $($profileInfo.Name)"
Write-Host "Windows      : $($profileInfo.WindowsVersion)"
Write-Host "Windows Build: $($profileInfo.Build)"
Write-Host "Architecture : $Architecture"
Write-Host ""

if (Test-Path -LiteralPath $CacheMarker) {
    Remove-Item -LiteralPath $CacheMarker -Force
}

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

$resolvedJson = Get-Content -LiteralPath $ResolvedPath -Raw

$resolvedJson = $resolvedJson.TrimStart([char]0xFEFF)

$resolved = $resolvedJson | ConvertFrom-Json

if (
    -not $resolved.kb -or
    -not $resolved.build -or
    -not $resolved.updateId -or
    -not $resolved.fileName
) {
    throw "Resolved update manifest is missing KB, build, UpdateID, or fileName."
}

# ============================================================
# Resolve artifact information
# ============================================================

$kb = $resolved.kb.ToString().ToUpperInvariant()

$lcuBuild = $resolved.build.ToString()

$normalizedArch = $Architecture.ToLowerInvariant()

if ($normalizedArch -eq 'amd64') {
    $normalizedArch = 'x64'
}

$resolvedWindowsBuild = [string]$resolved.windowsBuild

if ([string]::IsNullOrWhiteSpace($resolvedWindowsBuild)) {
    $resolvedWindowsBuild = [string]$profileInfo.Build
}

$artifactRoot = [string]$resolved.artifactRoot

if ([string]::IsNullOrWhiteSpace($artifactRoot)) {
    $artifactRoot = [string]$profileInfo.ArtifactRoot
}

$isoPrefix = [string]$resolved.isoPrefix

if ([string]::IsNullOrWhiteSpace($isoPrefix)) {
    $isoPrefix = [string]$profileInfo.IsoPrefix
}

if ([string]::IsNullOrWhiteSpace($artifactRoot)) {
    throw "Resolved update manifest is missing artifactRoot."
}

if ([string]::IsNullOrWhiteSpace($isoPrefix)) {
    throw "Resolved update manifest is missing isoPrefix."
}

# ============================================================
# Patched image artifact paths
# ============================================================

$patchedBase = "$artifactRoot/$normalizedArch/patched/$lcuBuild"

$manifestArtifact = "$patchedBase/manifest.json"

$isoName = "$isoPrefix-$normalizedArch-$lcuBuild-$kb.iso"

$isoArtifact = "$patchedBase/$isoName"

$manifestUrl = Get-ArtifactUrl -Path $manifestArtifact

Write-Host "Resolved LCU: $kb / $lcuBuild"
Write-Host "UpdateID    : $($resolved.updateId)"
Write-Host "MSU         : $($resolved.fileName)"
Write-Host "Patched manifest: $manifestUrl"

# ============================================================
# Patched image cache validation
# ============================================================

if ([string]::IsNullOrWhiteSpace($BaseIsoSha256)) {

    Write-Warning "BASE_ISO_SHA256 is empty; exact patched-image cache validation is disabled."
}
else {

    $remoteManifest = Get-ArtifactText -Path $manifestArtifact

    if ($remoteManifest) {

        try {

            $remoteManifest = $remoteManifest.TrimStart([char]0xFEFF)

            $m = $remoteManifest | ConvertFrom-Json

            $remoteBase = (
                [string]$m.source.baseIsoSha256
            ).ToLowerInvariant()

            $remoteImageBuild = [string]$m.image.windowsBuild

            $remoteArch = [string]$m.image.architecture

            $remoteLcu = $m.updates.lcu

            $remoteKb = (
                [string]$remoteLcu.kb
            ).ToUpperInvariant()

            $remoteBuild = [string]$remoteLcu.build

            $remoteUpdateId = [string]$remoteLcu.updateId

            $remoteFileName = [string]$remoteLcu.fileName

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
                (Test-ArtifactExists -Path $isoArtifact)
            ) {

                $markerObject = [ordered]@{
                    cacheHit = $true
                    manifestArtifactPath = $manifestArtifact
                    isoArtifactPath = $isoArtifact
                    kb = $kb
                    build = $lcuBuild
                    updateId = [string]$resolved.updateId
                    isoFileName = $isoName
                }

                $markerJson = $markerObject | ConvertTo-Json -Depth 10

                [System.IO.File]::WriteAllText(
                    $CacheMarker,
                    $markerJson,
                    [System.Text.UTF8Encoding]::new($false)
                )

                Write-Host ""
                Write-Host "============================================================"
                Write-Host " PATCHED IMAGE CACHE HIT"
                Write-Host "============================================================"
                Write-Host "Base ISO download skipped."
                Write-Host "MSU download skipped."
                Write-Host "Cached ISO: $isoArtifact"
                Write-Host ""

                exit 0
            }

            Write-Host ""
            Write-Host "Patched image manifest exists, but inputs do not match or ISO is missing. Cache miss."
        }
        catch {
            Write-Warning "Could not parse remote patched manifest: $($_.Exception.Message)"
        }
    }
    else {
        Write-Host "Patched image manifest not found. Cache miss."
    }
}

# ============================================================
# Cache miss
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Download Base ISO and MSU (cache miss)"
Write-Host "============================================================"

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

Write-Host ""
Write-Host "Base ISO download: SUCCESS"
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
    throw "Update download/resolution failed with exit code $resolveExit"
}

if (-not (Test-Path -LiteralPath $ResolvedPath -PathType Leaf)) {
    throw "Resolved update manifest was not created: $ResolvedPath"
}

# ============================================================
# Read resolved update again
# ============================================================

$resolvedJson = Get-Content -LiteralPath $ResolvedPath -Raw

$resolvedJson = $resolvedJson.TrimStart([char]0xFEFF)

$resolved = $resolvedJson | ConvertFrom-Json

if (
    -not $resolved.kb -or
    -not $resolved.build -or
    -not $resolved.sha256
) {
    throw "Resolved update manifest is missing KB, build, or SHA256."
}

# ============================================================
# MSU path
# ============================================================

$package = Join-Path $UpdatesDir $resolved.fileName

if (-not (Test-Path -LiteralPath $package -PathType Leaf)) {
    throw "Resolved update package is missing: $package"
}

# ============================================================
# Validate MSU SHA256
# ============================================================

$actual = Get-Sha256 -Path $package

$expected = $resolved.sha256.ToString().ToLowerInvariant()

if ($actual -ne $expected) {
    throw "MSU SHA256 mismatch for $($resolved.fileName). Expected $expected, actual $actual"
}

# ============================================================
# Success
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Download Stage Complete"
Write-Host "============================================================"
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
Write-Host "Download stage: SUCCESS"
Write-Host "============================================================"
Write-Host ""

exit 0
