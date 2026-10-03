```powershell
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
# Authentication
#
# Invoke-WebRequest:
#   Prefer Bearer token when supplied.
#   Otherwise use Basic authentication.
#
# JFrog:
#   Prefer access token when supplied.
#   Otherwise use user/password.
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
# Helper: Convert Artifactory URL to JFrog repository path
#
# Example:
#
#   https://server/artifactory/snapshot-generic-local/
#       Windows11/24H2/x64/base/foo.iso
#
# becomes:
#
#   snapshot-generic-local/Windows11/24H2/x64/base/foo.iso
# ============================================================

function ConvertTo-JFrogArtifactPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (
        "$ArtifactoryRepo/$($Path.TrimStart('/'))"
    )
}

# ============================================================
# Helper: Run jf.exe
# ============================================================

function Invoke-JFrog {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Assert-JFrogAvailable

    Write-Host ''
    Write-Host "Executing JFrog CLI:"
    Write-Host "  $JfPath $($Arguments -join ' ')"

    #
    # Do not redirect stdout into a PowerShell object here.
    # jf.exe's normal output should remain visible in Jenkins.
    #
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
#
# JFrog implementation downloads the text artifact to a temporary
# file and then reads it as UTF-8.
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

            $tempFile = Join-Path `
                $tempDir `
                ([guid]::NewGuid().ToString() + '.txt')

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

                $downloadedFile =
                    Join-Path `
                        $tempDir `
                        (Split-Path $Path -Leaf)

                if (-not (Test-Path -LiteralPath $downloadedFile -PathType Leaf)) {
                    return $null
                }

                $bytes =
                    [IO.File]::ReadAllBytes(
                        $downloadedFile
                    )

                #
                # UTF-8 BOM = EF BB BF.
                #
                $offset = 0

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
                #
                # jf.exe uses non-zero status for an unsuccessful lookup.
                # For a text artifact lookup, treat a missing artifact as
                # not found rather than hiding genuine transfer errors.
                #
                if ($_.Exception.Message -match '(?i)404|not found|no artifacts') {
                    return $null
                }

                throw
            }
            finally {
                if (Test-Path -LiteralPath $tempFile) {
                    Remove-Item `
                        -LiteralPath $tempFile `
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
# Helper: Test artifact exists
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

            #
            # Search for the exact artifact.
            #
            # Do not use "jf rt dl" as an existence test because that would
            # actually download the artifact.
            #
            $jfArgs = @(
                'rt'
                's'
                $jfArtifact
                '--count'
            )

            $jfArgs += $authArgs

            Write-Host ''
            Write-Host "Checking JFrog artifact:"
            Write-Host "  $jfArtifact"

            #
            # Capture output here because we need to inspect the result.
            #
            $output = & $JfPath @jfArgs 2>&1

            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) {

                $text =
                    ($output | Out-String).Trim()

                #
                # A search failure is different from an artifact miss.
                # Return false only for a clean no-result condition.
                #
                if (
                    $text -match '(?i)no artifacts' -or
                    $text -match '(?i)not found' -or
                    $text -match '(?i)0 artifacts'
                ) {
                    return $false
                }

                throw (
                    "jf.exe artifact search failed with exit code " +
                    "$exitCode.`n$text"
                )
            }

            $text =
                ($output | Out-String).Trim()

            #
            # jf rt search --count normally returns a count.
            #
            $count = 0

            if ([int]::TryParse($text, [ref]$count)) {
                return ($count -gt 0)
            }

            #
            # Some jf versions can return JSON/object-style output despite
            # --count. Fall back to looking for a positive integer.
            #
            $match =
                [regex]::Match(
                    $text,
                    '(?m)^\s*(\d+)\s*$'
                )

            if ($match.Success) {
                return (
                    [int]$match.Groups[1].Value -gt 0
                )
```
