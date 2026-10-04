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

# ------------------------------------------------------------
# Normalize architecture
# ------------------------------------------------------------

if ($Architecture -match '^(?i)(amd64|x64)$') {
    $Architecture = 'x64'
}

# ------------------------------------------------------------
# Load Windows image profile
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ProfileScriptPath -PathType Leaf)) {
    throw "Windows image profiles file does not exist: $ProfileScriptPath"
}

. $ProfileScriptPath

$profileInfo = Get-WindowsImageProfile -Name $Profile

# ------------------------------------------------------------
# Normalize paths
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# Validate inputs
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ResolverScriptPath -PathType Leaf)) {
    throw "Resolver script does not exist: $ResolverScriptPath"
}

if ([string]::IsNullOrWhiteSpace($ArtifactoryBaseUrl)) {
    throw "ArtifactoryBaseUrl is required."
}

$ArtifactoryBaseUrl = $ArtifactoryBaseUrl.TrimEnd('/')

if ($ArtifactoryBaseUrl.EndsWith('/artifactory')) {
    $ArtifactoryUrlRoot = $ArtifactoryBaseUrl
}
else {
    $ArtifactoryUrlRoot = "$ArtifactoryBaseUrl/artifactory"
}

# ------------------------------------------------------------
# Artifactory authentication
# ------------------------------------------------------------

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
# Helper functions
# ============================================================

function Assert-JFrogAvailable {
    if (-not (Get-Command $JfPath -ErrorAction SilentlyContinue)) {
        throw `
            "ArtifactTransferMethod is 'JFrog', but jf.exe was not found. " +
            "JfPath='$JfPath'"
    }

    Write-Host "JFrog CLI: $JfPath"
}

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

    throw `
        "JFrog authentication requires ArtifactoryToken or " +
        "ArtifactoryUser/ArtifactoryPassword."
}

function Get-ArtifactUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return "$ArtifactoryUrlRoot/$ArtifactoryRepo/$($Path.TrimStart('/'))"
}

function ConvertTo-JFrogArtifactPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return "$ArtifactoryRepo/$($Path.TrimStart('/'))"
}

function Protect-JFrogArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $safe = @()

    for ($i = 0; $i -lt $Arguments.Count; $i++) {

        $arg = [string]$Arguments[$i]

        if (
            $arg -eq '--password' -or
            $arg -eq '--access-token'
        ) {
            $safe += $arg

            if (($i + 1) -lt $Arguments.Count) {
                $safe += '****'
                $i++
            }

            continue
        }

        if ($arg -like '--password=*') {
            $safe += '--password=****'
            continue
        }

        if ($arg -like '--access-token=*') {
            $safe += '--access-token=****'
            continue
        }

        $safe += $arg
    }

    return @($safe)
}

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

    $jfArgs = @(
        $Arguments
    ) + $urlArgs + $authArgs

    $safeArgs = Protect-JFrogArguments -Arguments $jfArgs

    Write-Host ""
    Write-Host "Executing JFrog CLI:"
    Write-Host "  $JfPath $($safeArgs -join ' ')"

    & $JfPath @jfArgs

    # LASTEXITCODE is valid here because jf.exe is a native executable.
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw `
            "jf.exe failed with exit code $exitCode. " +
            "Arguments: $($safeArgs -join ' ')"
    }

    return $exitCode
}

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

                $utf8 = New-Object System.Text.UTF8Encoding(
                    $false,
                    $true
                )

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
                Write-Host `
                    "JFrog artifact does not exist: $Path"

                return $null
            }

            $tempDir = Join-Path `
                $DownloadDir `
                '.jfrog-text'

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

                $jfArtifact =
                    ConvertTo-JFrogArtifactPath -Path $Path

                $jfArgs = @(
                    'rt'
                    'dl'
                    $jfArtifact
                    $tempDir
                    '--flat=true'
                )

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
                    throw `
                        "JFrog download succeeded but artifact was not found: " +
                        "$downloadedFile"
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

                $utf8 = New-Object System.Text.UTF8Encoding(
                    $false,
                    $true
                )

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
            throw `
                "Unsupported ArtifactTransferMethod: " +
                "$ArtifactTransferMethod"
        }
    }
}

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

            $jfArtifact =
                ConvertTo-JFrogArtifactPath -Path $Path

            $fullArgs = @(
                'rt'
                's'
                $jfArtifact
                '--count'
                '--url'
                $ArtifactoryUrlRoot
            ) + (Get-JFrogAuthArguments)

            $safeArgs =
                Protect-JFrogArguments -Arguments $fullArgs

            Write-Host ""
            Write-Host "Checking JFrog artifact:"
            Write-Host "  $($safeArgs -join ' ')"

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

            $argumentString = @(
                $fullArgs |
                    ForEach-Object {

                        $value = [string]$_

                        if ($value -match '[\s"]') {
                            '"' +
                            $value.Replace('"', '\"') +
                            '"'
                        }
                        else {
                            $value
                        }
                    }
            ) -join ' '

            $cmdLine =
                "`"$JfPath`" $argumentString " +
                "1>`"$stdoutFile`" " +
                "2>`"$stderrFile`""

            cmd.exe /d /s /c $cmdLine

            # LASTEXITCODE is valid here because cmd.exe is native.
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

            if ($exitCode -ne 0) {

                $combined = "$stdout`n$stderr"

                if (
                    $combined -match '(?i)no artifacts' -or
                    $combined -match '(?i)no files' -or
                    $combined -match '(?i)not found' -or
                    $combined -match '(?i)0 artifacts'
                ) {
                    Write-Host `
                        "JFrog artifact does not exist: $Path"

                    return $false
                }

                throw @"
jf.exe artifact search failed with exit code $exitCode.

$combined
"@
            }

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
                    Write-Host `
                        "JFrog artifact exists: $Path"

                    return $true
                }

                Write-Host `
                    "JFrog artifact does not exist: $Path"

                return $false
            }

            $match = [regex]::Match(
                $countText,
                '(?m)^\s*(\d+)\s*$'
            )

            if ($match.Success) {

                $count = [int]$match.Groups[1].Value

                if ($count -gt 0) {
                    Write-Host `
                        "JFrog artifact exists: $Path"

                    return $true
                }

                Write-Host `
                    "JFrog artifact does not exist: $Path"

                return $false
            }

            Write-Host `
                "JFrog returned no usable artifact count."

            Write-Host "JFrog stdout:"
            Write-Host $countText

            if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                Write-Host "JFrog stderr:"
                Write-Host $stderr.Trim()
            }

            return $false
        }

        default {
            throw `
                "Unsupported ArtifactTransferMethod: " +
                "$ArtifactTransferMethod"
        }
    }
}

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

                    throw `
                        "Artifactory download failed: $uri`n" +
                        "$($_.Exception.Message)"
                }
            }

            'JFrog' {

                Assert-JFrogAvailable

                $jfArtifact =
                    ConvertTo-JFrogArtifactPath -Path $Path

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
                    throw `
                        "JFrog reported successful download, but the " +
                        "downloaded file was not found: $temporary"
                }
            }

            default {
                throw `
                    "Unsupported ArtifactTransferMethod: " +
                    "$ArtifactTransferMethod"
            }
        }

        if (
            -not (
                Test-Path `
                    -LiteralPath $temporary `
                    -PathType Leaf
            )
        ) {
            throw `
                "Artifact transfer completed but temporary file was " +
                "not created: $temporary"
        }

        $temporaryInfo =
            Get-Item -LiteralPath $temporary

        if ($temporaryInfo.Length -le 0) {
            throw `
                "Artifact transfer produced an empty file: $temporary"
        }

        Write-Host ""
        Write-Host `
            "Downloaded file size: $($temporaryInfo.Length) bytes"

        if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {

            Write-Host "Calculating SHA256..."

            $actual =
                Get-Sha256 -Path $temporary

            $expected =
                $ExpectedSha256.ToLowerInvariant()

            if ($actual -ne $expected) {

                Remove-Item `
                    -LiteralPath $temporary `
                    -Force `
                    -ErrorAction SilentlyContinue

                throw `
                    "SHA256 mismatch for $Path. " +
                    "Expected $expected, actual $actual"
            }

            Write-Host `
                "SHA256 verified: $actual"
        }

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
# Start
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
# Resolve LCU and check patched-image cache
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
    Remove-Item `
        -LiteralPath $CacheMarker `
        -Force
}

# ------------------------------------------------------------
# First resolver pass: ResolveOnly
#
# IMPORTANT:
# This is a PowerShell script, so LASTEXITCODE must NOT be used.
# ------------------------------------------------------------

try {

    & $ResolverScriptPath `
        -WorkRoot $WorkRoot `
        -WindowsProfile $Profile `
        -Architecture $Architecture `
        -ArtifactoryBaseUrl $ArtifactoryBaseUrl `
        -ArtifactoryRepo $ArtifactoryRepo `
        -ArtifactoryUser $ArtifactoryUser `
        -ArtifactoryPassword $ArtifactoryPassword `
        -ArtifactoryToken $ArtifactoryToken `
        -ResolveOnly

    if (-not $?) {
        throw `
            "Windows update resolver reported failure."
    }

    $resolveExit = 0
}
catch {

    $resolveExit = 1

    Write-Error `
        "Windows update resolver failed: $($_.Exception.Message)"
}

if ($resolveExit -ne 0) {
    throw "Windows update resolution failed."
}

# ------------------------------------------------------------
# Load resolved-updates.json
# ------------------------------------------------------------

if (
    -not (
        Test-Path `
            -LiteralPath $ResolvedPath `
            -PathType Leaf
    )
) {
    throw `
        "Resolved update manifest was not created: $ResolvedPath"
}

$resolvedJson =
    Get-Content `
        -LiteralPath $ResolvedPath `
        -Raw

$resolvedJson =
    $resolvedJson.TrimStart([char]0xFEFF)

$resolved =
    $resolvedJson | ConvertFrom-Json

if ($null -eq $resolved) {
    throw `
        "Resolved update manifest is empty: $ResolvedPath"
}

# ============================================================
# Validate resolved schema
# ============================================================

if ($null -eq $resolved.lcu) {
    throw `
        "Resolved update manifest does not contain an 'lcu' section: " +
        "$ResolvedPath"
}

$lcu = $resolved.lcu

if (
    $lcu.PSObject.Properties.Name -notcontains 'kb' -or
    [string]::IsNullOrWhiteSpace([string]$lcu.kb)
) {
    throw `
        "Resolved LCU manifest is missing lcu.kb."
}

if (
    $lcu.PSObject.Properties.Name -notcontains 'build' -or
    [string]::IsNullOrWhiteSpace([string]$lcu.build)
) {
    throw `
        "Resolved LCU manifest is missing lcu.build."
}

if (
    $lcu.PSObject.Properties.Name -notcontains 'updateId' -or
    [string]::IsNullOrWhiteSpace([string]$lcu.updateId)
) {
    throw `
        "Resolved LCU manifest is missing lcu.updateId."
}

if (
    $lcu.PSObject.Properties.Name -notcontains 'msu' -or
    $null -eq $lcu.msu
) {
    throw `
        "Resolved LCU manifest is missing lcu.msu."
}

if (
    $lcu.msu.PSObject.Properties.Name -notcontains 'fileName' -or
    [string]::IsNullOrWhiteSpace([string]$lcu.msu.fileName)
) {
    throw `
        "Resolved LCU manifest is missing lcu.msu.fileName."
}

# ------------------------------------------------------------
# Resolve Windows build
#
# The profile is authoritative.
#
# If resolver output contains windowsBuild, accept it.
# Otherwise use profileInfo.Build.
# ------------------------------------------------------------

$resolvedWindowsBuild =
    [string]$profileInfo.Build

if (
    $resolved.PSObject.Properties.Name -contains 'windowsBuild' -and
    -not [string]::IsNullOrWhiteSpace(
        [string]$resolved.windowsBuild
    )
) {
    $resolvedWindowsBuild =
        [string]$resolved.windowsBuild
}

if ([string]::IsNullOrWhiteSpace($resolvedWindowsBuild)) {
    throw `
        "Unable to determine Windows build from profile."
}

# ------------------------------------------------------------
# Extract target LCU
# ------------------------------------------------------------

$kb =
    [string]$lcu.kb

$kb =
    $kb.ToUpperInvariant()

$lcuBuild =
    [string]$lcu.build

$updateId =
    [string]$lcu.updateId

$lcuFileName =
    [string]$lcu.msu.fileName

# ------------------------------------------------------------
# Normalize architecture
# ------------------------------------------------------------

$normalizedArch =
    $Architecture.ToLowerInvariant()

if ($normalizedArch -eq 'amd64') {
    $normalizedArch = 'x64'
}

# ------------------------------------------------------------
# Artifact root
# ------------------------------------------------------------

$artifactRoot =
    [string]$profileInfo.ArtifactRoot

if (
    $resolved.PSObject.Properties.Name -contains 'artifactRoot' -and
    -not [string]::IsNullOrWhiteSpace(
        [string]$resolved.artifactRoot
    )
) {
    $artifactRoot =
        [string]$resolved.artifactRoot
}

if ([string]::IsNullOrWhiteSpace($artifactRoot)) {
    throw `
        "Unable to determine artifactRoot."
}

# ------------------------------------------------------------
# ISO prefix
# ------------------------------------------------------------

$isoPrefix =
    [string]$profileInfo.IsoPrefix

if (
    $resolved.PSObject.Properties.Name -contains 'isoPrefix' -and
    -not [string]::IsNullOrWhiteSpace(
        [string]$resolved.isoPrefix
    )
) {
    $isoPrefix =
        [string]$resolved.isoPrefix
}

if ([string]::IsNullOrWhiteSpace($isoPrefix)) {
    throw `
        "Unable to determine isoPrefix."
}

# ============================================================
# LCU package set
# ============================================================

if (
    $lcu.PSObject.Properties.Name -notcontains 'packages' -or
    $null -eq $lcu.packages
) {
    throw `
        "Resolved LCU manifest does not contain lcu.packages."
}

$lcuPackages =
    @($lcu.packages)

if ($lcuPackages.Count -eq 0) {
    throw `
        "Resolved LCU manifest contains no lcu.packages."
}

Write-Host ""
Write-Host "Resolved LCU:"
Write-Host "  KB       : $kb"
Write-Host "  Build    : $lcuBuild"
Write-Host "  UpdateID : $updateId"
Write-Host "  Target   : $lcuFileName"
Write-Host "  Packages : $($lcuPackages.Count)"

foreach ($p in $lcuPackages) {

    $packageType =
        if (
            $p.PSObject.Properties.Name -contains 'type'
        ) {
            [string]$p.type
        }
        else {
            'unknown'
        }

    $packageKb =
        if (
            $p.PSObject.Properties.Name -contains 'kb'
        ) {
            [string]$p.kb
        }
        else {
            ''
        }

    $packageFileName =
        if (
            $p.PSObject.Properties.Name -contains 'fileName'
        ) {
            [string]$p.fileName
        }
        else {
            ''
        }

    Write-Host `
        "    [$packageType] $packageKb $packageFileName"
}

# ============================================================
# Construct patched-image artifact paths
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
    Get-ArtifactUrl -Path $manifestArtifact

Write-Host ""
Write-Host "Resolved LCU: $kb / $lcuBuild"
Write-Host "UpdateID    : $updateId"
Write-Host "MSU         : $lcuFileName"
Write-Host "Patched manifest: $manifestUrl"

# ============================================================
# Patched image cache check
# ============================================================

if ([string]::IsNullOrWhiteSpace($BaseIsoSha256)) {

    Write-Warning `
        "BASE_ISO_SHA256 is empty; exact patched-image cache " +
        "validation is disabled."
}
else {

    $remoteManifest =
        Get-ArtifactText -Path $manifestArtifact

    if ($remoteManifest) {

        try {

            $remoteManifest =
                $remoteManifest.TrimStart([char]0xFEFF)

            $m =
                $remoteManifest | ConvertFrom-Json

            # ------------------------------------------------
            # Base ISO SHA
            # ------------------------------------------------

            $remoteBase = ''

            if (
                $m.PSObject.Properties.Name -contains 'source' -and
                $null -ne $m.source -and
                $m.source.PSObject.Properties.Name -contains 'baseIsoSha256'
            ) {
                $remoteBase =
                    [string]$m.source.baseIsoSha256
            }

            $remoteBase =
                $remoteBase.ToLowerInvariant()

            # ------------------------------------------------
            # Image build
            #
            # Profile build is the fallback.
            # ------------------------------------------------

            $remoteImageBuild =
                [string]$profileInfo.Build

            if (
                $m.PSObject.Properties.Name -contains 'image' -and
                $null -ne $m.image -and
                $m.image.PSObject.Properties.Name -contains 'windowsBuild' -and
                -not [string]::IsNullOrWhiteSpace(
                    [string]$m.image.windowsBuild
                )
            ) {
                $remoteImageBuild =
                    [string]$m.image.windowsBuild
            }

            # ------------------------------------------------
            # Image architecture
            # ------------------------------------------------

            $remoteArch =
                $normalizedArch

            if (
                $m.PSObject.Properties.Name -contains 'image' -and
                $null -ne $m.image -and
                $m.image.PSObject.Properties.Name -contains 'architecture' -and
                -not [string]::IsNullOrWhiteSpace(
                    [string]$m.image.architecture
                )
            ) {
                $remoteArch =
                    [string]$m.image.architecture
            }

            # ------------------------------------------------
            # LCU
            # ------------------------------------------------

            if (
                $m.PSObject.Properties.Name -notcontains 'updates' -or
                $null -eq $m.updates
            ) {
                throw `
                    "Patched image manifest does not contain updates."
            }

            if (
                $m.updates.PSObject.Properties.Name -notcontains 'lcu' -or
                $null -eq $m.updates.lcu
            ) {
                throw `
                    "Patched image manifest does not contain updates.lcu."
            }

            $remoteLcu =
                $m.updates.lcu

            $remoteKb = ''

            if (
                $remoteLcu.PSObject.Properties.Name -contains 'kb'
            ) {
                $remoteKb =
                    [string]$remoteLcu.kb
            }

            $remoteKb =
                $remoteKb.ToUpperInvariant()

            $remoteBuild = ''

            if (
                $remoteLcu.PSObject.Properties.Name -contains 'build'
            ) {
                $remoteBuild =
                    [string]$remoteLcu.build
            }

            $remoteUpdateId = ''

            if (
                $remoteLcu.PSObject.Properties.Name -contains 'updateId'
            ) {
                $remoteUpdateId =
                    [string]$remoteLcu.updateId
            }

            # ------------------------------------------------
            # Target MSU
            # ------------------------------------------------

            if (
                $remoteLcu.PSObject.Properties.Name -notcontains 'msu' -or
                $null -eq $remoteLcu.msu
            ) {
                throw `
                    "Patched image manifest does not contain " +
                    "updates.lcu.msu."
            }

            $remoteFileName = ''

            if (
                $remoteLcu.msu.PSObject.Properties.Name -contains 'fileName'
            ) {
                $remoteFileName =
                    [string]$remoteLcu.msu.fileName
            }

            # ------------------------------------------------
            # Compare cache inputs
            # ------------------------------------------------

            $same =
                ($remoteBase -eq $BaseIsoSha256.ToLowerInvariant()) -and
                ($remoteImageBuild -eq $resolvedWindowsBuild) -and
                ($remoteArch -ieq $normalizedArch) -and
                ($remoteKb -eq $kb) -and
                ($remoteBuild -eq $lcuBuild) -and
                ($remoteUpdateId -eq $updateId) -and
                ($remoteFileName -eq $lcuFileName)

            if (
                $same -and
                (Test-ArtifactExists -Path $isoArtifact)
            ) {

                $markerObject = [ordered]@{
                    cacheHit             = $true
                    manifestArtifactPath = $manifestArtifact
                    isoArtifactPath      = $isoArtifact
                    kb                   = $kb
                    build                = $lcuBuild
                    updateId             = $updateId
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
            Write-Host `
                "Patched image manifest exists, but inputs do not match " +
                "or ISO is missing. Cache miss."
        }
        catch {

            Write-Warning `
                "Could not parse remote patched manifest: " +
                "$($_.Exception.Message)"
        }
    }
    else {

        Write-Host `
            "Patched image manifest not found. Cache miss."
    }
}

# ============================================================
# Cache miss
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Download Base ISO and MSU (cache miss)"
Write-Host "============================================================"

# ------------------------------------------------------------
# Base ISO
# ------------------------------------------------------------

Download-Artifact `
    -Path $BaseIsoArtifact `
    -Destination $BaseIsoPath `
    -ExpectedSha256 $BaseIsoSha256

if (
    -not (
        Test-Path `
            -LiteralPath $BaseIsoPath `
            -PathType Leaf
    )
) {
    throw `
        "Base ISO was not downloaded: $BaseIsoPath"
}

Write-Host ""
Write-Host "Base ISO download: SUCCESS"
Write-Host "Base ISO: $BaseIsoPath"

# ------------------------------------------------------------
# Second resolver pass
#
# Full resolver downloads/resolves all required packages.
#
# IMPORTANT:
# This is a PowerShell script. Do not use LASTEXITCODE.
# ------------------------------------------------------------

try {

    & $ResolverScriptPath `
        -WorkRoot $WorkRoot `
        -WindowsProfile $Profile `
        -Architecture $Architecture `
        -ArtifactoryBaseUrl $ArtifactoryBaseUrl `
        -ArtifactoryRepo $ArtifactoryRepo `
        -ArtifactoryUser $ArtifactoryUser `
        -ArtifactoryPassword $ArtifactoryPassword `
        -ArtifactoryToken $ArtifactoryToken

    if (-not $?) {
        throw `
            "Windows update resolver reported failure."
    }

    $resolveExit = 0
}
catch {

    $resolveExit = 1

    Write-Error `
        "Windows update download/resolution failed: " +
        "$($_.Exception.Message)"
}

if ($resolveExit -ne 0) {
    throw `
        "Windows update download/resolution failed."
}

# ============================================================
# Reload resolved-updates.json
# ============================================================

if (
    -not (
        Test-Path `
            -LiteralPath $ResolvedPath `
            -PathType Leaf
    )
) {
    throw `
        "Resolved update manifest was not created: $ResolvedPath"
}

$resolvedJson =
    Get-Content `
        -LiteralPath $ResolvedPath `
        -Raw

$resolvedJson =
    $resolvedJson.TrimStart([char]0xFEFF)

$resolved =
    $resolvedJson | ConvertFrom-Json

if ($null -eq $resolved) {
    throw `
        "Resolved update manifest is empty: $ResolvedPath"
}

if (
    $resolved.PSObject.Properties.Name -notcontains 'lcu' -or
    $null -eq $resolved.lcu
) {
    throw `
        "Resolved update manifest does not contain lcu."
}

$lcu =
    $resolved.lcu

if (
    $lcu.PSObject.Properties.Name -notcontains 'msu' -or
    $null -eq $lcu.msu
) {
    throw `
        "Resolved update manifest does not contain lcu.msu."
}

if (
    $lcu.msu.PSObject.Properties.Name -notcontains 'fileName' -or
    [string]::IsNullOrWhiteSpace(
        [string]$lcu.msu.fileName
    )
) {
    throw `
        "Resolved update manifest is missing lcu.msu.fileName."
}

if (
    $lcu.PSObject.Properties.Name -notcontains 'packages' -or
    $null -eq $lcu.packages
) {
    throw `
        "Resolved update manifest does not contain lcu.packages."
}

$lcuPackages =
    @($lcu.packages)

if ($lcuPackages.Count -eq 0) {
    throw `
        "Resolved update manifest contains no lcu.packages."
}

# ============================================================
# Validate every LCU package
#
# This must include:
#
#   checkpoint KB5043080
#   target     KB5129195
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Validate Resolved LCU Packages"
Write-Host "============================================================"
Write-Host "Package count: $($lcuPackages.Count)"
Write-Host ""

foreach ($packageInfo in $lcuPackages) {

    if (
        $packageInfo.PSObject.Properties.Name -notcontains 'fileName'
    ) {
        throw `
            "Resolved LCU package is missing fileName."
    }

    $packageFileName =
        [string]$packageInfo.fileName

    if ([string]::IsNullOrWhiteSpace($packageFileName)) {
        throw `
            "Resolved LCU package has an empty fileName."
    }

    $packagePath =
        Join-Path $UpdatesDir $packageFileName

    if (
        -not (
            Test-Path `
                -LiteralPath $packagePath `
                -PathType Leaf
        )
    ) {
        throw `
            "Resolved LCU package is missing: $packagePath"
    }

    $packageType = 'unknown'

    if (
        $packageInfo.PSObject.Properties.Name -contains 'type'
    ) {
        $packageType =
            [string]$packageInfo.type
    }

    $packageKb = ''

    if (
        $packageInfo.PSObject.Properties.Name -contains 'kb'
    ) {
        $packageKb =
            [string]$packageInfo.kb
    }

    Write-Host "LCU package found:"
    Write-Host "  Type : $packageType"
    Write-Host "  KB   : $packageKb"
    Write-Host "  File : $packageFileName"
    Write-Host "  Path : $packagePath"

    $expectedSha = ''

    if (
        $packageInfo.PSObject.Properties.Name -contains 'sha256'
    ) {
        $expectedSha =
            [string]$packageInfo.sha256
    }

    if (-not [string]::IsNullOrWhiteSpace($expectedSha)) {

        $actualSha =
            Get-Sha256 -Path $packagePath

        $expectedSha =
            $expectedSha.ToLowerInvariant()

        if ($actualSha -ne $expectedSha) {

            throw @"
SHA256 mismatch for $packageFileName.
Expected: $expectedSha
Actual:   $actualSha
"@
        }

        Write-Host "  SHA256: $actualSha"
    }
    else {
        Write-Host `
            "  SHA256: not supplied by resolver"
    }

    Write-Host ""
}

# ============================================================
# Validate target MSU
# ============================================================

$targetPackage =
    $lcu.msu

if ($null -eq $targetPackage) {
    throw `
        "Resolved LCU target package (lcu.msu) is missing."
}

$targetFileName =
    [string]$targetPackage.fileName

if ([string]::IsNullOrWhiteSpace($targetFileName)) {
    throw `
        "Resolved LCU target package is missing fileName."
}

$targetPackagePath =
    Join-Path $UpdatesDir $targetFileName

if (
    -not (
        Test-Path `
            -LiteralPath $targetPackagePath `
            -PathType Leaf
    )
) {
    throw `
        "Target LCU package is missing: $targetPackagePath"
}

$package =
    $targetPackagePath

$actual =
    Get-Sha256 -Path $package

$expected = ''

if (
    $targetPackage.PSObject.Properties.Name -contains 'sha256'
) {
    $expected =
        [string]$targetPackage.sha256
}

if (-not [string]::IsNullOrWhiteSpace($expected)) {

    $expected =
        $expected.ToLowerInvariant()

    if ($actual -ne $expected) {

        throw @"
Target LCU SHA256 mismatch for $targetFileName.
Expected: $expected
Actual:   $actual
"@
    }

    Write-Host `
        "Target LCU SHA256 verified: $actual"
}
else {
    Write-Host `
        "Target LCU SHA256: $actual"
}

# ============================================================
# Final result
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
Write-Host "KB                       : $($lcu.kb)"
Write-Host "LCU Build                : $($lcu.build)"
Write-Host "UpdateID                 : $($lcu.updateId)"
Write-Host "LCU package count        : $($lcuPackages.Count)"
Write-Host "Target MSU               : $targetFileName"
Write-Host "Target MSU SHA256        : $actual"
Write-Host "Target MSU Path          : $package"
Write-Host ""
Write-Host "Resolved LCU packages:"

foreach ($p in $lcuPackages) {

    $type = 'unknown'

    if (
        $p.PSObject.Properties.Name -contains 'type'
    ) {
        $type = [string]$p.type
    }

    $packageKb = ''

    if (
        $p.PSObject.Properties.Name -contains 'kb'
    ) {
        $packageKb = [string]$p.kb
    }

    $fileName = ''

    if (
        $p.PSObject.Properties.Name -contains 'fileName'
    ) {
        $fileName = [string]$p.fileName
    }

    Write-Host `
        "  [$type] $packageKb $fileName"
}

Write-Host ""
Write-Host "Download stage: SUCCESS"
Write-Host "============================================================"
Write-Host ""

exit 0
