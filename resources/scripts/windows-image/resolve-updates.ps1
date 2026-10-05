
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [Parameter(Mandatory = $false)]
    [Alias('Profile')]
    [ValidateSet('windows11-24h2', 'windows10-21h2')]
    [string]$WindowsProfile = 'windows11-24h2',

    [Parameter(Mandatory = $false)]
    [ValidateSet('x64', 'amd64', 'arm64')]
    [string]$Architecture = 'x64',

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryBaseUrl,

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryRepo = 'snapshot-generic-local',

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryUser,

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryPassword,

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryToken,

    [Parameter(Mandatory = $false)]
    [string]$JfPath = 'jf.exe',

    [Parameter(Mandatory = $false)]
    [switch]$ForceMicrosoftDownload,

    [Parameter(Mandatory = $false)]
    [switch]$ResolveOnly
)


Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Normalization
# -----------------------------------------------------------------------------

if ($Architecture -eq 'amd64') {
    $Architecture = 'x64'
}

$WorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)

$DownloadRoot = Join-Path $WorkRoot 'download'
$UpdatesRoot  = Join-Path $DownloadRoot 'updates'

New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
New-Item -ItemType Directory -Force -Path $DownloadRoot | Out-Null
New-Item -ItemType Directory -Force -Path $UpdatesRoot | Out-Null

Write-Host ''
Write-Host '============================================================'
Write-Host ' Windows Image Update Resolver'
Write-Host '============================================================'
Write-Host "WorkRoot:            $WorkRoot"
Write-Host "Profile:             $WindowsProfile"
Write-Host "Architecture:        $Architecture"
Write-Host "Artifactory Repo:    $ArtifactoryRepo"
Write-Host "Force MS Download:   $ForceMicrosoftDownload"
Write-Host "Resolve Only:        $ResolveOnly"
Write-Host '============================================================'
Write-Host ''

# -----------------------------------------------------------------------------
# Load profiles
# -----------------------------------------------------------------------------

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$profilesPath = Join-Path $scriptRoot 'profiles.ps1'

if (-not (Test-Path -LiteralPath $profilesPath)) {
    throw "profiles.ps1 was not found at '$profilesPath'."
}

. $profilesPath

if (-not (Get-Command Get-WindowsImageProfile -ErrorAction SilentlyContinue)) {
    throw "Get-WindowsImageProfile was not found after loading '$profilesPath'."
}

$imageProfile = Get-WindowsImageProfile -Name $WindowsProfile

if ($null -eq $imageProfile) {
    throw "Windows image profile '$WindowsProfile' was not found."
}

Write-Host "Loaded image profile: $WindowsProfile"

# -----------------------------------------------------------------------------
# Generic profile property helper
# -----------------------------------------------------------------------------

function Get-ProfileProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ProfileObject,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [object]$DefaultValue = $null
    )

    $property = $ProfileObject.PSObject.Properties[$Name]

    if ($null -eq $property) {
        return $DefaultValue
    }

    if ($null -eq $property.Value) {
        return $DefaultValue
    }

    return $property.Value
}

$Product = [string](Get-ProfileProperty -ProfileObject $imageProfile -Name 'Product')
$Release = [string](Get-ProfileProperty -ProfileObject $imageProfile -Name 'Release')

if ([string]::IsNullOrWhiteSpace($Product)) {
    throw "Profile '$Profile' does not define Product."
}

if ([string]::IsNullOrWhiteSpace($Release)) {
    throw "Profile '$WindowsProfile' does not define Release."
}

$CatalogQuery = [string](Get-ProfileProperty `
    -ProfileObject $imageProfile `
    -Name 'CatalogQuery')

$CatalogProductPattern = [string](Get-ProfileProperty `
    -ProfileObject $imageProfile `
    -Name 'CatalogProductPattern' `
    -DefaultValue 'Windows 11')

$CatalogClassificationPattern = [string](Get-ProfileProperty `
    -ProfileObject $imageProfile `
    -Name 'CatalogClassificationPattern' `
    -DefaultValue '')

$CatalogArchitecturePattern = [string](Get-ProfileProperty `
    -ProfileObject $imageProfile `
    -Name 'CatalogArchitecturePattern' `
    -DefaultValue '')

$CatalogBuildPattern = [string](Get-ProfileProperty `
    -ProfileObject $imageProfile `
    -Name 'CatalogBuildPattern' `
    -DefaultValue '')

$CatalogSecurityUpdatesRequired = [bool](Get-ProfileProperty `
    -ProfileObject $imageProfile `
    -Name 'CatalogSecurityUpdatesRequired' `
    -DefaultValue $false)

$ProfileBuild = [string](Get-ProfileProperty `
    -ProfileObject $imageProfile `
    -Name 'Build' `
    -DefaultValue '')

$ArtifactRoot = [string](Get-ProfileProperty `
    -ProfileObject $imageProfile `
    -Name 'ArtifactRoot' `
    -DefaultValue "$Product/$Release")

$BaseIsoArtifact = [string](Get-ProfileProperty `
    -ProfileObject $imageProfile `
    -Name 'BaseIsoArtifact' `
    -DefaultValue '')

$BaseIsoSha256 = [string](Get-ProfileProperty `
    -ProfileObject $imageProfile `
    -Name 'BaseIsoSha256' `
    -DefaultValue '')

$IsoPrefix = [string](Get-ProfileProperty `
    -ProfileObject $imageProfile `
    -Name 'IsoPrefix' `
    -DefaultValue "$Product-$Release")

# -----------------------------------------------------------------------------
# Artifactory configuration
# -----------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($ArtifactoryBaseUrl)) {
    throw 'ArtifactoryBaseUrl is required.'
}

$ArtifactoryRoot = $ArtifactoryBaseUrl.TrimEnd('/')

if ($ArtifactoryRoot -notmatch '/artifactory$') {
    $ArtifactoryRoot = "$ArtifactoryRoot/artifactory"
}

Write-Host "Artifactory URL:     $ArtifactoryRoot"

# -----------------------------------------------------------------------------
# JFrog authentication helpers
# -----------------------------------------------------------------------------

function Get-JFrogAuthArguments {
    $args = @()

    if (-not [string]::IsNullOrWhiteSpace($ArtifactoryUser)) {
        $args += '--user'
        $args += $ArtifactoryUser
    }

    if (-not [string]::IsNullOrWhiteSpace($ArtifactoryPassword)) {
        $args += '--password'
        $args += $ArtifactoryPassword
    }

    if (-not [string]::IsNullOrWhiteSpace($ArtifactoryToken)) {
        $args += '--access-token'
        $args += $ArtifactoryToken
    }

    return $args
}

function Get-JFrogSafeAuthArguments {
    $args = @()

    if (-not [string]::IsNullOrWhiteSpace($ArtifactoryUser)) {
        $args += '--user'
        $args += '***'
    }

    if (-not [string]::IsNullOrWhiteSpace($ArtifactoryPassword)) {
        $args += '--password'
        $args += '***'
    }

    if (-not [string]::IsNullOrWhiteSpace($ArtifactoryToken)) {
        $args += '--access-token'
        $args += '***'
    }

    return $args
}

function Invoke-JFrog {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $authArgs = @(Get-JFrogAuthArguments)

    $fullArgs = @()

    $fullArgs += $Arguments

    if ($fullArgs -notcontains '--url') {
        $fullArgs += '--url'
        $fullArgs += $ArtifactoryRoot
    }

    $fullArgs += $authArgs

    $safeArgs = @()

    foreach ($arg in $fullArgs) {
        if (
            $arg -eq $ArtifactoryPassword -or
            $arg -eq $ArtifactoryToken
        ) {
            $safeArgs += '***'
        }
        else {
            $safeArgs += $arg
        }
    }

    Write-Host "JFrog: $JfPath $($safeArgs -join ' ')"

    & $JfPath @fullArgs

    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "JFrog command failed with exit code $exitCode."
    }
}

function ConvertTo-JFrogArtifactPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    return "$ArtifactoryRepo/$($RelativePath.TrimStart('/'))"
}

function Get-ArtifactoryUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    return "$ArtifactoryRoot/$($RelativePath.TrimStart('/'))"
}

# -----------------------------------------------------------------------------
# Artifactory existence check
#
# IMPORTANT:
# Do not pipe jf output through 2>&1 here.
# JFrog writes informational messages to stderr, which PowerShell can surface
# as NativeCommandError even when the command succeeds.
#
# The configured jf server is used here intentionally because:
#
#   jf.exe rt search <repo/path> --count
#
# has already been validated on the Jenkins node.
# -----------------------------------------------------------------------------

function Test-ArtifactoryFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $artifact = ConvertTo-JFrogArtifactPath -RelativePath $RelativePath

    Write-Host "Checking Artifactory artifact:"
    Write-Host "  $artifact"

    $tempRoot = Join-Path $env:TEMP ("jf-search-" + [guid]::NewGuid().ToString('N'))

    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

    $stdoutFile = Join-Path $tempRoot 'stdout.txt'
    $stderrFile = Join-Path $tempRoot 'stderr.txt'

    try {
        $arguments = @(
            'rt'
            'search'
            $artifact
            '--count'
        )

        $process = Start-Process `
            -FilePath $JfPath `
            -ArgumentList $arguments `
            -Wait `
            -PassThru `
            -NoNewWindow `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile

        $stdout = ''
        $stderr = ''

        if (Test-Path -LiteralPath $stdoutFile) {
            $rawStdout = Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue

            if ($null -ne $rawStdout) {
                $stdout = [string]$rawStdout
            }
        }

        if (Test-Path -LiteralPath $stderrFile) {
            $rawStderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue

            if ($null -ne $rawStderr) {
                $stderr = [string]$rawStderr
            }
        }

        Write-Host "JFrog search exit code: $($process.ExitCode)"

        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Host $stderr.Trim()
        }

        if ($process.ExitCode -ne 0) {
            return $false
        }

        $count = 0

        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $countMatch = [regex]::Match(
                $stdout,
                '(?m)^\s*(\d+)\s*$'
            )

            if ($countMatch.Success) {
                $count = [int]$countMatch.Groups[1].Value
            }
        }

        Write-Host "JFrog artifact count: $count"

        return ($count -gt 0)
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# -----------------------------------------------------------------------------
# SHA256
# -----------------------------------------------------------------------------

function Get-FileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Cannot calculate SHA256. File not found: $Path"
    }

    return (
        Get-FileHash `
            -LiteralPath $Path `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()
}

# -----------------------------------------------------------------------------
# Download from Artifactory
# -----------------------------------------------------------------------------

function Download-ArtifactoryFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [string]$ExpectedSha256 = ''
    )

    $artifact = ConvertTo-JFrogArtifactPath -RelativePath $RelativePath

    Write-Host ''
    Write-Host 'Downloading from Artifactory:'
    Write-Host "  $artifact"
    Write-Host "  Destination: $Destination"

    $destinationDirectory = Split-Path -Parent $Destination

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $destinationDirectory | Out-Null

    $temporaryDestination = "$Destination.download"

    if (Test-Path -LiteralPath $temporaryDestination) {
        Remove-Item `
            -LiteralPath $temporaryDestination `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Invoke-JFrog @(
        'rt'
        'download'
        $artifact
        $temporaryDestination
        '--flat=true'
        '--threads=4'
    )

    if (-not (Test-Path -LiteralPath $temporaryDestination -PathType Leaf)) {
        throw "JFrog reported success but downloaded file does not exist: $temporaryDestination"
    }

    $fileInfo = Get-Item -LiteralPath $temporaryDestination

    if ($fileInfo.Length -le 0) {
        throw "Downloaded Artifactory file is empty: $temporaryDestination"
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $actualSha256 = Get-FileSha256 -Path $temporaryDestination

        if ($actualSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
            Remove-Item `
                -LiteralPath $temporaryDestination `
                -Force `
                -ErrorAction SilentlyContinue

            throw @"
SHA256 mismatch for Artifactory artifact.

Artifact:  $RelativePath
Expected:  $ExpectedSha256
Actual:    $actualSha256
"@
        }
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item `
            -LiteralPath $Destination `
            -Force
    }

    Move-Item `
        -LiteralPath $temporaryDestination `
        -Destination $Destination `
        -Force

    return $Destination
}

# -----------------------------------------------------------------------------
# Publish to Artifactory
# -----------------------------------------------------------------------------

function Publish-ArtifactoryFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalPath,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
        throw "Cannot publish missing file: $LocalPath"
    }

    $artifact = ConvertTo-JFrogArtifactPath -RelativePath $RelativePath

    Write-Host ''
    Write-Host 'Publishing to Artifactory:'
    Write-Host "  $artifact"

    Invoke-JFrog @(
        'rt'
        'upload'
        $LocalPath
        $artifact
    )
}

# -----------------------------------------------------------------------------
# Microsoft Catalog download
# -----------------------------------------------------------------------------

function Download-Url {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $destinationDirectory = Split-Path -Parent $Destination

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $destinationDirectory | Out-Null

    $temporaryDestination = "$Destination.download"

    if (Test-Path -LiteralPath $temporaryDestination) {
        Remove-Item `
            -LiteralPath $temporaryDestination `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Host 'Downloading from Microsoft:'
    Write-Host "  $Url"
    Write-Host "  $Destination"

    Invoke-WebRequest `
        -Uri $Url `
        -OutFile $temporaryDestination `
        -UseBasicParsing `
        -TimeoutSec 300

    if (-not (Test-Path -LiteralPath $temporaryDestination -PathType Leaf)) {
        throw "Microsoft download completed without creating '$temporaryDestination'."
    }

    $fileInfo = Get-Item -LiteralPath $temporaryDestination

    if ($fileInfo.Length -le 0) {
        throw "Microsoft download produced an empty file: $temporaryDestination"
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item `
            -LiteralPath $Destination `
            -Force
    }

    Move-Item `
        -LiteralPath $temporaryDestination `
        -Destination $Destination `
        -Force

    return $Destination
}

# -----------------------------------------------------------------------------
# Microsoft Update Catalog search
# -----------------------------------------------------------------------------

function Get-CatalogHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $encodedQuery = [System.Uri]::EscapeDataString($Query)

    $url = "https://www.catalog.update.microsoft.com/Search.aspx?q=$encodedQuery"

    Write-Host ''
    Write-Host "Catalog query: $Query"
    Write-Host ''

    $response = Invoke-WebRequest `
        -Uri $url `
        -UseBasicParsing `
        -TimeoutSec 120

    if ($null -eq $response -or [string]::IsNullOrWhiteSpace($response.Content)) {
        throw "Microsoft Update Catalog returned an empty response for '$Query'."
    }

    return $response.Content
}

# -----------------------------------------------------------------------------
# Extract UpdateID from a Catalog row
#
# The important rule here is:
#
#   ONE ROW -> ONE UpdateID
#
# We do NOT collect every GUID from the <tr>.
#
# Collecting every GUID was the reason KB5129195 could become associated with
# KB5043080's filename.
# -----------------------------------------------------------------------------

function Get-CatalogRowUpdateId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RowHtml
    )

    # Primary form used by the Catalog details link.
    $guidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

    $match = [regex]::Match(
        $RowHtml,
        "(?is)goToDetails\s*\(\s*['""]\s*\{?($guidPattern)\}?\s*['""]\s*\)"
    )

    if ($match.Success) {
        return $match.Groups[1].Value
    }

    # Fallback: Catalog markup can contain the update ID in an input.
    $match = [regex]::Match(
        $RowHtml,
        "(?is)<input[^>]+(?:id|value)\s*=\s*['""]\s*\{?($guidPattern)\}?\s*['""]"
    )

    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return ''
}

# -----------------------------------------------------------------------------
# Catalog row parser
# -----------------------------------------------------------------------------


function Get-CatalogRows {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Html,

        [Parameter(Mandatory = $true)]
        [ValidateSet('LCU', 'SSU')]
        [string]$ExpectedType
    )

    # Use a normal PowerShell array instead of
    # System.Collections.Generic.List[object].
    #
    # Windows PowerShell 5.1 can produce:
    #   "Argument types do not match"
    #
    # when generic .NET collections are combined with
    # PowerShell pipeline/object conversion.
    $rows = @()

    if ([string]::IsNullOrWhiteSpace($Html)) {
        return @()
    }

    # -------------------------------------------------------------------------
    # Extract Catalog table rows
    # -------------------------------------------------------------------------

    $trMatches = [regex]::Matches(
        [string]$Html,
        '(?is)<tr\b[^>]*>.*?</tr>'
    )

    foreach ($trMatch in $trMatches) {

        $rowHtml = [string]$trMatch.Value

        if ([string]::IsNullOrWhiteSpace($rowHtml)) {
            continue
        }

        # ---------------------------------------------------------------------
        # Convert HTML row to searchable text
        # ---------------------------------------------------------------------

        $rowText = $rowHtml

        # Remove script/style blocks first so their GUIDs, URLs, etc.
        # do not accidentally become part of the row metadata.
        $rowText = [regex]::Replace(
            $rowText,
            '(?is)<script\b[^>]*>.*?</script>',
            ' '
        )

        $rowText = [regex]::Replace(
            $rowText,
            '(?is)<style\b[^>]*>.*?</style>',
            ' '
        )

        # Replace HTML tags with spaces.
        $rowText = [regex]::Replace(
            $rowText,
            '(?is)<[^>]+>',
            ' '
        )

        # Decode HTML entities.
        try {
            $rowText = [System.Net.WebUtility]::HtmlDecode($rowText)
        }
        catch {
            # Keep the undecoded text if WebUtility is unavailable/fails.
        }

        # Normalize whitespace.
        $rowText = [regex]::Replace(
            [string]$rowText,
            '\s+',
            ' '
        ).Trim()

        if ([string]::IsNullOrWhiteSpace($rowText)) {
            continue
        }

        # ---------------------------------------------------------------------
        # Product
        # ---------------------------------------------------------------------

        if (
            -not [string]::IsNullOrWhiteSpace($CatalogProductPattern) -and
            $rowText -notmatch $CatalogProductPattern
        ) {
            continue
        }

        # ---------------------------------------------------------------------
        # Classification
        # ---------------------------------------------------------------------

        if (
            -not [string]::IsNullOrWhiteSpace($CatalogClassificationPattern) -and
            $rowText -notmatch $CatalogClassificationPattern
        ) {
            continue
        }

        # ---------------------------------------------------------------------
        # Security Updates
        # ---------------------------------------------------------------------

        if (
            $CatalogSecurityUpdatesRequired -and
            $rowText -notmatch '(?i)Security Updates'
        ) {
            continue
        }

        # ---------------------------------------------------------------------
        # Architecture
        # ---------------------------------------------------------------------

        if (
            -not [string]::IsNullOrWhiteSpace($CatalogArchitecturePattern) -and
            $rowText -notmatch $CatalogArchitecturePattern
        ) {
            continue
        }

        # ---------------------------------------------------------------------
        # KB
        # ---------------------------------------------------------------------

        $kbMatch = [regex]::Match(
            $rowText,
            '(?i)\b(KB\d{6,8})\b'
        )

        if (-not $kbMatch.Success) {
            continue
        }

        $kb = $kbMatch.Groups[1].Value.ToUpperInvariant()

        # ---------------------------------------------------------------------
        # Build
        #
        # Windows 11:
        #   26100.9457
        #
        # Windows 10:
        #   Some Catalog rows do not expose a usable build number.
        # ---------------------------------------------------------------------

        $build = ''

        $buildMatch = [regex]::Match(
            $rowText,
            '\b(\d{5}\.\d+)\b'
        )

        if ($buildMatch.Success) {
            $build = $buildMatch.Groups[1].Value
        }

        if (
            -not [string]::IsNullOrWhiteSpace($CatalogBuildPattern) -and
            $rowText -notmatch $CatalogBuildPattern
        ) {
            continue
        }

        # ---------------------------------------------------------------------
        # Date
        # ---------------------------------------------------------------------

        $date = $null

        $dateMatch = [regex]::Match(
            $rowText,
            '\b(\d{1,2}/\d{1,2}/\d{4})\b'
        )

        if ($dateMatch.Success) {
            try {
                $date = [datetime]::Parse(
                    $dateMatch.Groups[1].Value,
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
            }
            catch {
                $date = $null
            }
        }

        # ---------------------------------------------------------------------
        # UpdateID
        #
        # IMPORTANT:
        #
        # A Catalog <tr> can contain multiple GUIDs in its HTML because the
        # row contains links/buttons such as "Download" and "Details".
        #
        # Get-CatalogRowUpdateId is responsible for selecting ONE authoritative
        # UpdateID for this row.
        #
        # Do NOT enumerate every GUID here.
        # Do NOT call DownloadDialog for every GUID.
        # ---------------------------------------------------------------------

        $updateId = Get-CatalogRowUpdateId `
            -RowHtml $rowHtml

        if ([string]::IsNullOrWhiteSpace($updateId)) {
            continue
        }

        # Normalize the GUID representation.
        $updateId = $updateId.Trim().Trim('{}').ToLowerInvariant()

        # Validate that the selected value actually looks like a GUID.
        $guidValue = [guid]::Empty

        if (
            -not [guid]::TryParse(
                $updateId,
                [ref]$guidValue
            )
        ) {
            continue
        }

        $updateId = $guidValue.ToString()

        # ---------------------------------------------------------------------
        # Store candidate
        # ---------------------------------------------------------------------

        $candidate = [pscustomobject]@{
            Type     = $ExpectedType
            KB       = $kb
            Build    = $build
            Date     = $date
            UpdateId = $updateId
            Title    = $rowText
            RowHtml  = $rowHtml
        }

        # Normal PowerShell array append.
        $rows += $candidate
    }

    # -------------------------------------------------------------------------
    # Return a predictable array.
    # -------------------------------------------------------------------------

    return @($rows)
}


# -----------------------------------------------------------------------------
# Catalog DownloadDialog
#
# Returns ALL actual downloadable files associated with ONE UpdateID.
#
# This is intentionally different from the old implementation:
#
#   Old:
#       extract every GUID from row
#       call DownloadDialog for every GUID
#       take first .msu
#
#   New:
#       extract ONE UpdateID from selected row
#       call DownloadDialog ONCE
#       collect every returned MSU
#
# This is required for checkpoint/target LCUs.
# -----------------------------------------------------------------------------

function Get-CatalogDownloadUrls {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UpdateId
    )

    Write-Host ''
    Write-Host "Getting Catalog download information for UpdateID:"
    Write-Host "  $UpdateId"

    $item = @{
        size     = 0
        updateID = $UpdateId
        uidInfo  = $UpdateId
    } | ConvertTo-Json -Compress

    $body = @{
        updateIDs = "[$item]"
    }

    $response = Invoke-WebRequest `
        -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' `
        -Method Post `
        -Body $body `
        -ContentType 'application/x-www-form-urlencoded' `
        -UseBasicParsing `
        -TimeoutSec 120

    if (
        $null -eq $response -or
        [string]::IsNullOrWhiteSpace($response.Content)
    ) {
        throw "DownloadDialog returned an empty response for UpdateID $UpdateId."
    }

    $content = [string]$response.Content

    $content = $content.Replace(
        '&amp;',
        '&'
    )

    $urls = New-Object System.Collections.Generic.List[string]

    # Preferred parser:
    # downloadInformation[n].files[n].url = 'https://...'
    $matches = [regex]::Matches(
        $content,
        "downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*['""]([^'""]+)['""]",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    foreach ($match in $matches) {
        $url = [System.Net.WebUtility]::HtmlDecode(
            $match.Groups[1].Value
        )

        if (
            $url -match '(?i)\.(msu|cab)(?:\?|$)' -and
            $urls -notcontains $url
        ) {
            $urls.Add($url)
        }
    }

    # Fallback parser for Catalog markup variations.
    if ($urls.Count -eq 0) {
        $genericMatches = [regex]::Matches(
            $content,
            'https?://[^""''\s<>]+',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        foreach ($match in $genericMatches) {
            $url = [System.Net.WebUtility]::HtmlDecode(
                $match.Value
            )

            if (
                $url -match '(?i)\.(msu|cab)(?:\?|$)' -and
                $urls -notcontains $url
            ) {
                $urls.Add($url)
            }
        }
    }

    if ($urls.Count -eq 0) {
        throw "No MSU/CAB download URLs were returned for UpdateID $UpdateId."
    }

    Write-Host "Catalog returned $($urls.Count) downloadable package(s)."

    foreach ($url in $urls) {
        Write-Host "  $url"
    }

    return @($urls)
}

# -----------------------------------------------------------------------------
# Extract filename from Catalog URL
# -----------------------------------------------------------------------------

function Get-UrlFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    try {
        $uri = [System.Uri]$Url

        $fileName = [System.IO.Path]::GetFileName(
            $uri.AbsolutePath
        )

        if (-not [string]::IsNullOrWhiteSpace($fileName)) {
            return $fileName
        }
    }
    catch {
        # Fall through to string parsing.
    }

    $cleanUrl = $Url.Split('?')[0]

    return [System.IO.Path]::GetFileName(
        $cleanUrl
    )
}

# -----------------------------------------------------------------------------
# Extract KB number from package filename
# -----------------------------------------------------------------------------

function Get-KbFromFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $match = [regex]::Match(
        $FileName,
        '(?i)\bkb(\d{6,8})\b'
    )

    if (-not $match.Success) {
        return ''
    }

    return "KB$($match.Groups[1].Value)"
}

# -----------------------------------------------------------------------------
# Select a target MSU from a Catalog package set
# -----------------------------------------------------------------------------

function Select-TargetMsu {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [Parameter(Mandatory = $true)]
        [string]$TargetKb
    )

    $target = @(
        $Packages | Where-Object {
            $_.FileName -match "(?i)\b$([regex]::Escape($TargetKb))\b"
        }
    )

    if ($target.Count -eq 1) {
        return $target[0]
    }

    if ($target.Count -gt 1) {
        # Prefer an exact KB filename match.
        $exact = @(
            $target | Where-Object {
                (Get-KbFromFileName -FileName $_.FileName) -eq $TargetKb
            }
        )

        if ($exact.Count -eq 1) {
            return $exact[0]
        }

        throw @"
Multiple target packages were returned for $TargetKb.

Target KB: $TargetKb

Packages:
$(
    ($target | ForEach-Object {
        "  $($_.FileName)"
    }) -join "`r`n"
)
"@
    }

    throw @"
The Microsoft Catalog DownloadDialog response did not contain the target MSU.

Target KB: $TargetKb

Returned packages:
$(
    ($Packages | ForEach-Object {
        "  $($_.FileName)"
    }) -join "`r`n"
)
"@
}

# -----------------------------------------------------------------------------
# Resolve a Catalog package set
#
# Windows 11 24H2:
#   The selected Catalog row identifies the target LCU.
#   DownloadDialog can return:
#
#       target MSU
#       checkpoint MSU(s)
#
# All MSUs are retained.
# -----------------------------------------------------------------------------


function Resolve-CatalogPackageSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [Parameter(Mandatory = $true)]
        [ValidateSet('LCU', 'SSU')]
        [string]$ExpectedType,

        [string]$ExpectedKb = '',

        [string]$ExpectedBuild = ''
    )

    # -------------------------------------------------------------------------
    # Query Microsoft Update Catalog
    # -------------------------------------------------------------------------

    $html = Get-CatalogHtml `
        -Query $Query

    # -------------------------------------------------------------------------
    # Find matching Catalog rows.
    #
    # Get-CatalogRows returns exactly one authoritative UpdateID per row.
    # -------------------------------------------------------------------------

    $rows = @(
        Get-CatalogRows `
            -Html $html `
            -ExpectedType $ExpectedType
    )

    if ($rows.Count -eq 0) {
        throw @"
No matching Catalog rows were found.

Query:       $Query
Type:        $ExpectedType
Expected KB: $ExpectedKb
Build:       $ExpectedBuild
"@
    }

    # -------------------------------------------------------------------------
    # Prefer the requested KB when one was supplied.
    # -------------------------------------------------------------------------

    if (-not [string]::IsNullOrWhiteSpace($ExpectedKb)) {

        $kbRows = @(
            $rows |
                Where-Object {
                    $_.KB -eq $ExpectedKb
                }
        )

        if ($kbRows.Count -gt 0) {
            $rows = $kbRows
        }
    }

    # -------------------------------------------------------------------------
    # Prefer the requested build when one was supplied.
    # -------------------------------------------------------------------------

    if (-not [string]::IsNullOrWhiteSpace($ExpectedBuild)) {

        $buildRows = @(
            $rows |
                Where-Object {
                    $_.Build -eq $ExpectedBuild
                }
        )

        if ($buildRows.Count -gt 0) {
            $rows = $buildRows
        }
    }

    # -------------------------------------------------------------------------
    # Select the newest Catalog row.
    #
    # Date is the primary ordering field.
    # Build is used as a secondary ordering field when available.
    # -------------------------------------------------------------------------

    $selectedRow = $rows |
        Sort-Object `
            -Property `
                @{ Expression = {
                    if ($null -eq $_.Date) {
                        [datetime]::MinValue
                    }
                    else {
                        $_.Date
                    }
                }; Descending = $true },
                @{ Expression = {
                    if ([string]::IsNullOrWhiteSpace($_.Build)) {
                        [version]'0.0'
                    }
                    else {
                        try {
                            [version]$_.Build
                        }
                        catch {
                            [version]'0.0'
                        }
                    }
                }; Descending = $true } |
        Select-Object -First 1

    if ($null -eq $selectedRow) {
        throw @"
Unable to select a Windows Catalog row.

Query:       $Query
Type:        $ExpectedType
Expected KB: $ExpectedKb
Build:       $ExpectedBuild
"@
    }

    Write-Host ''
    Write-Host 'Selected Microsoft Update Catalog row:'
    Write-Host "  Type:      $($selectedRow.Type)"
    Write-Host "  KB:        $($selectedRow.KB)"
    Write-Host "  Build:     $($selectedRow.Build)"
    Write-Host "  Date:      $($selectedRow.Date)"
    Write-Host "  UpdateID:  $($selectedRow.UpdateId)"
    Write-Host ''

    # -------------------------------------------------------------------------
    # The selected row MUST contain exactly one authoritative UpdateID.
    # -------------------------------------------------------------------------

    $updateId = [string]$selectedRow.UpdateId

    if ([string]::IsNullOrWhiteSpace($updateId)) {
        throw 'Selected Catalog row does not contain an UpdateID.'
    }

    # -------------------------------------------------------------------------
    # Query DownloadDialog ONCE.
    #
    # IMPORTANT:
    #
    # Windows 11 24H2 cumulative updates can use the checkpoint model.
    #
    # One UpdateID can therefore return:
    #
    #   KB5043080  -> checkpoint MSU
    #   KB5129195  -> target LCU MSU
    #
    # We must retain ALL returned MSUs.
    # -------------------------------------------------------------------------

    $urls = @(
        Get-CatalogDownloadUrls `
            -UpdateId $updateId
    )

    if ($urls.Count -eq 0) {
        throw "Catalog returned no downloadable files for UpdateID $updateId."
    }

    # -------------------------------------------------------------------------
    # Use a normal PowerShell array.
    #
    # Do NOT use:
    #
    #   System.Collections.Generic.List[object]
    #
    # because Windows PowerShell 5.1 can produce:
    #
    #   Argument types do not match
    # -------------------------------------------------------------------------

    $packages = @()

    foreach ($url in $urls) {

        if ([string]::IsNullOrWhiteSpace([string]$url)) {
            continue
        }

        $fileName = Get-UrlFileName `
            -Url ([string]$url)

        if ([string]::IsNullOrWhiteSpace($fileName)) {
            continue
        }

        # Only MSU packages belong in the Windows update package set.
        if ($fileName -notmatch '(?i)\.msu$') {
            continue
        }

        # ---------------------------------------------------------------------
        # Determine KB from the actual filename.
        #
        # This is important because the DownloadDialog response can contain
        # both checkpoint and target packages.
        # ---------------------------------------------------------------------

        $packageKb = Get-KbFromFileName `
            -FileName $fileName

        if ([string]::IsNullOrWhiteSpace($packageKb)) {
            Write-Host "Skipping MSU with no recognizable KB: $fileName"
            continue
        }

        $packageKb = $packageKb.ToUpperInvariant()

        # ---------------------------------------------------------------------
        # Determine package role.
        #
        # The selected Catalog row identifies the target KB.
        # Every other MSU returned by the same UpdateID is treated as a
        # checkpoint/prerequisite package.
        # ---------------------------------------------------------------------

        $packageType = 'checkpoint'

        if (
            -not [string]::IsNullOrWhiteSpace($selectedRow.KB) -and
            $packageKb -eq $selectedRow.KB
        ) {
            $packageType = 'target'
        }

        $package = [pscustomobject]@{
            Type     = $packageType
            KB       = $packageKb
            FileName = $fileName
            Url      = [string]$url
            UpdateId = $updateId
            Build    = $selectedRow.Build
            Date     = $selectedRow.Date
            Title    = $selectedRow.Title
        }

        # Normal PowerShell array append.
        $packages += $package
    }

    # -------------------------------------------------------------------------
    # Validate package discovery.
    # -------------------------------------------------------------------------

    if ($packages.Count -eq 0) {
        throw "Catalog returned no MSU packages for UpdateID $updateId."
    }

    # -------------------------------------------------------------------------
    # Remove duplicate filenames.
    #
    # Keep the first occurrence of each actual MSU filename.
    # -------------------------------------------------------------------------

    $uniquePackages = @(
        $packages |
            Group-Object -Property FileName |
            ForEach-Object {
                $_.Group |
                    Select-Object -First 1
            }
    )

    if ($uniquePackages.Count -eq 0) {
        throw "Catalog package list became empty after duplicate removal."
    }

    # -------------------------------------------------------------------------
    # For LCU, identify the target package.
    # -------------------------------------------------------------------------

    $targetPackage = $null

    if ($ExpectedType -eq 'LCU') {

        $targetKbForSelection = [string]$selectedRow.KB

        if ([string]::IsNullOrWhiteSpace($targetKbForSelection)) {
            throw 'Selected LCU Catalog row does not contain a target KB.'
        }

        $targetPackage = Select-TargetMsu `
            -Packages $uniquePackages `
            -TargetKb $targetKbForSelection

        if ($null -eq $targetPackage) {
            throw @"
The Catalog returned MSU packages, but the target LCU was not found.

Target KB: $targetKbForSelection
UpdateID:  $updateId

Returned packages:
$(
    ($uniquePackages |
        ForEach-Object {
            "  $($_.KB)  $($_.FileName)"
        }) -join [Environment]::NewLine
)
"@
        }
    }

    # -------------------------------------------------------------------------
    # Display final package set.
    # -------------------------------------------------------------------------

    Write-Host ''
    Write-Host "Resolved ${ExpectedType} package set:"
    Write-Host "  Target KB: $($selectedRow.KB)"
    Write-Host "  Build:     $($selectedRow.Build)"
    Write-Host "  Packages:  $($uniquePackages.Count)"
    Write-Host ''

    foreach ($package in $uniquePackages) {

        Write-Host "  [$($package.Type)]"
        Write-Host "    KB:       $($package.KB)"
        Write-Host "    File:     $($package.FileName)"
        Write-Host "    UpdateID: $($package.UpdateId)"
        Write-Host "    URL:      $($package.Url)"
    }

    # -------------------------------------------------------------------------
    # Return resolved package set.
    #
    # For LCU:
    #
    #   KB       = target KB
    #   Build    = target build
    #   Target   = target MSU
    #   Packages = checkpoint(s) + target MSU
    #
    # Keeping Target/Packages separate preserves compatibility with the
    # existing resolver while allowing the Windows 11 checkpoint model.
    # -------------------------------------------------------------------------

    return [pscustomobject]@{
        Type     = $ExpectedType
        KB       = $selectedRow.KB
        Build    = $selectedRow.Build
        Date     = $selectedRow.Date
        Title    = $selectedRow.Title
        UpdateId = $selectedRow.UpdateId
        Target   = $targetPackage
        Packages = @($uniquePackages)
    }
}

# -----------------------------------------------------------------------------
# Resolve one package into Artifactory/cache
#
# The KB is derived from the actual package when possible.
# This prevents checkpoint KB5043080 from being stored beneath KB5129195.
# -----------------------------------------------------------------------------
function Resolve-PackageFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Package,

        [Parameter(Mandatory = $true)]
        [string]$UpdatesDir,

        [Parameter(Mandatory = $true)]
        [string]$ArtifactRoot,

        [Parameter(Mandatory = $true)]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [string]$ArtifactoryBaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$ArtifactoryRepo,

        [Parameter(Mandatory = $false)]
        [string]$PackageType = 'LCU',

        [string]$ArtifactoryUser,

        [string]$ArtifactoryPassword,

        [string]$ArtifactoryToken,

        [string]$JfPath = 'jf.exe',

        [switch]$ForceMicrosoftDownload
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # -------------------------------------------------------------------------
    # Validate package
    # -------------------------------------------------------------------------

    if ($null -eq $Package) {
        throw 'Package information is required.'
    }

    if (
        -not $Package.PSObject.Properties.Name -contains 'FileName' -or
        [string]::IsNullOrWhiteSpace([string]$Package.FileName)
    ) {
        throw 'Package FileName is missing.'
    }

    if (
        -not $Package.PSObject.Properties.Name -contains 'KB' -or
        [string]::IsNullOrWhiteSpace([string]$Package.KB)
    ) {
        throw "Package KB is missing for '$($Package.FileName)'."
    }

    $fileName = [string]$Package.FileName
    $packageKb = ([string]$Package.KB).Trim().ToUpperInvariant()

    if ([string]::IsNullOrWhiteSpace($PackageType)) {
        $PackageType = 'LCU'
    }

    # -------------------------------------------------------------------------
    # Validate/update URL
    # -------------------------------------------------------------------------

    $downloadUrl = ''

    if (
        $Package.PSObject.Properties.Name -contains 'Url' -and
        -not [string]::IsNullOrWhiteSpace([string]$Package.Url)
    ) {
        $downloadUrl = [string]$Package.Url
    }

    # -------------------------------------------------------------------------
    # Workspace layout
    #
    # IMPORTANT:
    #
    # Local Jenkins workspace is ALWAYS FLAT:
    #
    #   download\
    #       resolved-updates.json
    #       updates\
    #           windows11.0-kb5043080-....msu
    #           windows11.0-kb5129195-....msu
    #
    # Do NOT create:
    #
    #   updates\LCU\KB5043080\...
    #
    # -------------------------------------------------------------------------

    if (-not (Test-Path -LiteralPath $UpdatesDir -PathType Container)) {
        New-Item `
            -ItemType Directory `
            -Path $UpdatesDir `
            -Force | Out-Null
    }

    $localPath = Join-Path $UpdatesDir $fileName

    # -------------------------------------------------------------------------
    # Artifactory layout
    #
    # Artifactory remains hierarchical by package KB:
    #
    #   Windows11/24H2/x64/LCU/KB5043080/file.msu
    #   Windows11/24H2/x64/LCU/KB5129195/file.msu
    #
    # This is deliberately independent from the local workspace layout.
    # -------------------------------------------------------------------------

    $artifactPath = (
        "$ArtifactRoot/" +
        "$Architecture/" +
        "$PackageType/" +
        "$packageKb/" +
        "$fileName"
    )

    $artifactPath = $artifactPath.Replace('\', '/')

    $artifact = (
        "$ArtifactoryRepo/" +
        "$artifactPath"
    ).Replace('\', '/')

    # -------------------------------------------------------------------------
    # Expected SHA256
    # -------------------------------------------------------------------------

    $expectedSha256 = ''

    if (
        $Package.PSObject.Properties.Name -contains 'Sha256' -and
        -not [string]::IsNullOrWhiteSpace([string]$Package.Sha256)
    ) {
        $expectedSha256 =
            ([string]$Package.Sha256).Trim().ToLowerInvariant()
    }

    # -------------------------------------------------------------------------
    # Local cache
    # -------------------------------------------------------------------------

    if (Test-Path -LiteralPath $localPath -PathType Leaf) {

        $actualSha256 = (
            Get-FileHash `
                -LiteralPath $localPath `
                -Algorithm SHA256
        ).Hash.ToLowerInvariant()

        if (
            [string]::IsNullOrWhiteSpace($expectedSha256) -or
            $actualSha256 -eq $expectedSha256
        ) {

            Write-Host ''
            Write-Host 'Local update cache hit:'
            Write-Host "  KB:      $packageKb"
            Write-Host "  File:    $fileName"
            Write-Host "  Path:    $localPath"
            Write-Host "  SHA256:  $actualSha256"

            return [pscustomobject]@{
                KB           = $packageKb
                Type         = $PackageType
                FileName     = $fileName
                Url          = $downloadUrl
                ArtifactPath = $artifactPath
                LocalPath    = $localPath
                Sha256       = $actualSha256
                Source       = 'local-cache'
            }
        }

        Write-Warning (
            "Local package '$fileName' exists but SHA256 does not match. " +
            "Expected '$expectedSha256', actual '$actualSha256'. " +
            "The file will be replaced."
        )

        Remove-Item `
            -LiteralPath $localPath `
            -Force
    }

    # -------------------------------------------------------------------------
    # Artifactory
    # -------------------------------------------------------------------------

    if (-not $ForceMicrosoftDownload) {

        $temporaryPath = "$localPath.download"

        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item `
                -LiteralPath $temporaryPath `
                -Force `
                -ErrorAction SilentlyContinue
        }

        $jfArgs = @(
            'rt'
            'download'
            $artifact
            $temporaryPath
            '--flat=true'
            '--threads=4'
            "--url=$ArtifactoryBaseUrl"
        )

        if (-not [string]::IsNullOrWhiteSpace($ArtifactoryToken)) {

            $jfArgs += "--access-token=$ArtifactoryToken"
        }
        elseif (
            -not [string]::IsNullOrWhiteSpace($ArtifactoryUser) -and
            -not [string]::IsNullOrWhiteSpace($ArtifactoryPassword)
        ) {

            $jfArgs += '--user'
            $jfArgs += $ArtifactoryUser

            $jfArgs += '--password'
            $jfArgs += $ArtifactoryPassword
        }
        else {
            Write-Warning `
                'No Artifactory token or username/password was supplied.'
        }

        # ---------------------------------------------------------------------
        # Safe command logging
        # ---------------------------------------------------------------------

        $safeJfArgs = @()

        foreach ($arg in $jfArgs) {

            if (
                $arg -eq "--access-token=$ArtifactoryToken" -or
                $arg -eq $ArtifactoryPassword
            ) {
                $safeJfArgs += '***'
            }
            else {
                $safeJfArgs += $arg
            }
        }

        Write-Host ''
        Write-Host 'Downloading from Artifactory:'
        Write-Host "  Artifact:    $artifact"
        Write-Host "  Destination: $localPath"
        Write-Host "  JFrog:       $JfPath $($safeJfArgs -join ' ')"

        & $JfPath @jfArgs

        $jfExitCode = $LASTEXITCODE

        if (
            $jfExitCode -eq 0 -and
            (Test-Path -LiteralPath $temporaryPath -PathType Leaf)
        ) {

            $temporaryInfo = Get-Item -LiteralPath $temporaryPath

            if ($temporaryInfo.Length -le 0) {

                Remove-Item `
                    -LiteralPath $temporaryPath `
                    -Force `
                    -ErrorAction SilentlyContinue

                throw "JFrog downloaded an empty file for '$fileName'."
            }

            Move-Item `
                -LiteralPath $temporaryPath `
                -Destination $localPath `
                -Force

            $actualSha256 = (
                Get-FileHash `
                    -LiteralPath $localPath `
                    -Algorithm SHA256
            ).Hash.ToLowerInvariant()

            if (
                -not [string]::IsNullOrWhiteSpace($expectedSha256) -and
                $actualSha256 -ne $expectedSha256
            ) {

                Remove-Item `
                    -LiteralPath $localPath `
                    -Force `
                    -ErrorAction SilentlyContinue

                throw (
                    "SHA256 mismatch for '$fileName'. " +
                    "Expected '$expectedSha256', actual '$actualSha256'."
                )
            }

            Write-Host ''
            Write-Host 'Artifactory download successful:'
            Write-Host "  KB:       $packageKb"
            Write-Host "  File:     $fileName"
            Write-Host "  Local:    $localPath"
            Write-Host "  Artifact: $artifactPath"
            Write-Host "  SHA256:   $actualSha256"

            return [pscustomobject]@{
                KB           = $packageKb
                Type         = $PackageType
                FileName     = $fileName
                Url          = $downloadUrl
                ArtifactPath = $artifactPath
                LocalPath    = $localPath
                Sha256       = $actualSha256
                Source       = 'artifactory'
            }
        }

        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item `
                -LiteralPath $temporaryPath `
                -Force `
                -ErrorAction SilentlyContinue
        }

        Write-Warning (
            "Package '$fileName' was not successfully downloaded from " +
            "Artifactory. JFrog exit code: $jfExitCode"
        )
    }

    # -------------------------------------------------------------------------
    # Microsoft Catalog fallback
    # -------------------------------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($downloadUrl)) {

        throw (
            "Unable to obtain package '$fileName' ($packageKb). " +
            "No usable Artifactory artifact or Microsoft Catalog URL was " +
            "available."
        )
    }

    $temporaryPath = "$localPath.download"

    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
        Remove-Item `
            -LiteralPath $temporaryPath `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Host 'Downloading package from Microsoft Catalog:'
    Write-Host "  KB:          $packageKb"
    Write-Host "  File:        $fileName"
    Write-Host "  Destination: $localPath"
    Write-Host "  URL:         $downloadUrl"

    try {

        Invoke-WebRequest `
            -Uri $downloadUrl `
            -OutFile $temporaryPath `
            -UseBasicParsing `
            -TimeoutSec 300

        if (-not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
            throw "Microsoft download did not create '$temporaryPath'."
        }

        $temporaryInfo = Get-Item -LiteralPath $temporaryPath

        if ($temporaryInfo.Length -le 0) {
            throw "Microsoft download produced an empty file: $temporaryPath"
        }

        Move-Item `
            -LiteralPath $temporaryPath `
            -Destination $localPath `
            -Force
    }
    catch {

        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item `
                -LiteralPath $temporaryPath `
                -Force `
                -ErrorAction SilentlyContinue
        }

        throw (
            "Failed to download package '$fileName' from Microsoft Catalog. " +
            $_.Exception.Message
        )
    }

    $actualSha256 = (
        Get-FileHash `
            -LiteralPath $localPath `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    if (
        -not [string]::IsNullOrWhiteSpace($expectedSha256) -and
        $actualSha256 -ne $expectedSha256
    ) {

        Remove-Item `
            -LiteralPath $localPath `
            -Force `
            -ErrorAction SilentlyContinue

        throw (
            "SHA256 mismatch for Microsoft package '$fileName'. " +
            "Expected '$expectedSha256', actual '$actualSha256'."
        )
    }

    Write-Host ''
    Write-Host 'Microsoft Catalog download successful:'
    Write-Host "  KB:       $packageKb"
    Write-Host "  File:     $fileName"
    Write-Host "  Local:    $localPath"
    Write-Host "  SHA256:   $actualSha256"

    return [pscustomobject]@{
        KB           = $packageKb
        Type         = $PackageType
        FileName     = $fileName
        Url          = $downloadUrl
        ArtifactPath = $artifactPath
        LocalPath    = $localPath
        Sha256       = $actualSha256
        Source       = 'microsoft'
    }
}


# -----------------------------------------------------------------------------
# Resolve Win11 checkpoint/target package set
# -----------------------------------------------------------------------------


function Resolve-Windows11Lcu {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    # -------------------------------------------------------------------------
    # Resolve the Windows Update Catalog package set.
    #
    # For Windows 11 24H2 checkpoint-based LCUs, this can return:
    #
    #   KB5043080 -> checkpoint
    #   KB5129195 -> target
    #
    # Resolve-CatalogPackageSet has already selected the authoritative
    # Catalog UpdateID and downloaded the DownloadDialog metadata exactly once.
    # -------------------------------------------------------------------------

    $resolved = Resolve-CatalogPackageSet `
        -Query $Query `
        -ExpectedType LCU

    if ($null -eq $resolved) {
        throw 'Windows 11 LCU Catalog resolution returned no result.'
    }

    $targetKb = [string]$resolved.KB
    $targetBuild = [string]$resolved.Build

    if ([string]::IsNullOrWhiteSpace($targetKb)) {
        throw 'Windows 11 LCU Catalog result did not contain a target KB.'
    }

    Write-Host ''
    Write-Host 'Windows 11 24H2 LCU package set:'
    Write-Host "  Target KB:    $targetKb"
    Write-Host "  Target Build: $targetBuild"
    Write-Host "  Package count: $(@($resolved.Packages).Count)"
    Write-Host ''

    # -------------------------------------------------------------------------
    # IMPORTANT:
    #
    # Use a normal PowerShell array.
    #
    # Do NOT use:
    #
    #   New-Object System.Collections.Generic.List[object]
    #
    # The latter has been causing:
    #
    #   Argument types do not match
    #
    # under Windows PowerShell 5.1.
    # -------------------------------------------------------------------------

    $resolvedPackages = @()

    foreach ($package in @($resolved.Packages)) {

        if ($null -eq $package) {
            continue
        }

        $packageKb = [string]$package.KB
        $fileName = [string]$package.FileName
        $url = [string]$package.Url

        if ([string]::IsNullOrWhiteSpace($packageKb)) {
            throw @"
Unable to determine KB from Windows 11 LCU filename.

File:   $fileName
Target: $targetKb
"@
        }

        if ([string]::IsNullOrWhiteSpace($fileName)) {
            throw @"
Windows 11 LCU package has no filename.

KB:     $packageKb
Target: $targetKb
"@
        }

        if ([string]::IsNullOrWhiteSpace($url)) {
            throw @"
Windows 11 LCU package has no download URL.

KB:     $packageKb
File:   $fileName
Target: $targetKb
"@
        }

        # ---------------------------------------------------------------------
        # Resolve the actual package into Artifactory/cache.
        #
        # The KB is derived from the actual MSU filename rather than inherited
        # from the target Catalog row. This is what keeps checkpoint packages
        # in their own Artifactory location.
        # ---------------------------------------------------------------------

        $resolvedPackage = Resolve-PackageFile `
            -PackageType 'LCU' `
            -KB $packageKb `
            -FileName $fileName `
            -Url $url

        # ---------------------------------------------------------------------
        # Preserve checkpoint/target classification from Catalog resolution.
        # ---------------------------------------------------------------------

        $packageType = [string]$package.Type

        if ([string]::IsNullOrWhiteSpace($packageType)) {
            if ($packageKb -eq $targetKb) {
                $packageType = 'target'
            }
            else {
                $packageType = 'checkpoint'
            }
        }

        $resolvedPackageObject = [pscustomobject]@{
            Type         = $packageType
            KB           = $packageKb
            FileName     = $resolvedPackage.FileName
            Url          = $resolvedPackage.Url
            ArtifactPath = $resolvedPackage.ArtifactPath
            LocalPath    = $resolvedPackage.LocalPath
            Sha256       = $resolvedPackage.Sha256
            Source       = $resolvedPackage.Source
            UpdateId     = $package.UpdateId
        }

        # Normal PowerShell array append.
        $resolvedPackages += $resolvedPackageObject
    }

    # -------------------------------------------------------------------------
    # Validate package resolution.
    # -------------------------------------------------------------------------

    if ($resolvedPackages.Count -eq 0) {
        throw @"
Windows 11 LCU package set resolved from Catalog, but no packages were
successfully resolved into the local cache.

Target KB:    $targetKb
Target Build: $targetBuild
"@
    }

    # -------------------------------------------------------------------------
    # Find the target package.
    # -------------------------------------------------------------------------

    $target = @(
        $resolvedPackages |
            Where-Object {
                $_.KB -eq $targetKb
            }
    )

    if ($target.Count -ne 1) {
        throw @"
Windows 11 target LCU package was not resolved uniquely.

Target KB: $targetKb

Resolved packages:
$(
    ($resolvedPackages |
        ForEach-Object {
            "  [$($_.Type)] $($_.KB) - $($_.FileName)"
        }) -join "`r`n"
)
"@
    }

    $targetPackage = $target[0]

    # -------------------------------------------------------------------------
    # Verify target package classification.
    # -------------------------------------------------------------------------

    if ($targetPackage.Type -ne 'target') {
        Write-Host ''
        Write-Host 'WARNING: Target package was not classified as target by the'
        Write-Host 'Catalog resolver. Correcting classification based on target KB.'
        Write-Host ''

        $targetPackage = [pscustomobject]@{
            Type         = 'target'
            KB           = $targetPackage.KB
            FileName     = $targetPackage.FileName
            Url          = $targetPackage.Url
            ArtifactPath = $targetPackage.ArtifactPath
            LocalPath    = $targetPackage.LocalPath
            Sha256       = $targetPackage.Sha256
            Source       = $targetPackage.Source
            UpdateId     = $targetPackage.UpdateId
        }

        $resolvedPackages = @(
            $resolvedPackages |
                ForEach-Object {
                    if ($_.KB -eq $targetKb) {
                        $targetPackage
                    }
                    else {
                        $_
                    }
                }
        )
    }

    # -------------------------------------------------------------------------
    # Optional SSU inspection.
    #
    # Windows 11 cumulative MSUs can contain an SSU payload. Preserve the
    # filename when it can be identified. This information can be used later
    # by the image-servicing pipeline.
    # -------------------------------------------------------------------------

    $ssuFileName = ''
    $sevenZip = $null

    $sevenZipCandidates = @(
        '7z.exe',
        '7zz.exe',
        'C:\Program Files\7-Zip\7z.exe'
    )

    foreach ($candidate in $sevenZipCandidates) {

        if (
            $candidate -match '^[^\\]+$' -and
            (Get-Command $candidate -ErrorAction SilentlyContinue)
        ) {
            $sevenZip = $candidate
            break
        }

        if (
            Test-Path `
                -LiteralPath $candidate `
                -PathType Leaf
        ) {
            $sevenZip = $candidate
            break
        }
    }

    # -------------------------------------------------------------------------
    # Only inspect the local MSU when ResolveOnly is false.
    # -------------------------------------------------------------------------

    if (
        -not $ResolveOnly -and
        -not [string]::IsNullOrWhiteSpace($sevenZip) -and
        (Test-Path `
            -LiteralPath $targetPackage.LocalPath `
            -PathType Leaf)
    ) {
        try {

            $sevenZipOutput = & $sevenZip `
                'l' `
                '-ba' `
                '-slt' `
                $targetPackage.LocalPath 2>&1

            $sevenZipText = (
                $sevenZipOutput -join "`r`n"
            )

            $ssuMatch = [regex]::Match(
                $sevenZipText,
                '(?im)(SSU-[^\\\r\n]+\.cab)'
            )

            if ($ssuMatch.Success) {
                $ssuFileName = $ssuMatch.Groups[1].Value
            }
        }
        catch {
            Write-Host `
                "WARNING: Unable to inspect target MSU for SSU payload: $($_.Exception.Message)"
        }
    }

    # -------------------------------------------------------------------------
    # Display final result.
    # -------------------------------------------------------------------------

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' Windows 11 LCU Resolution Complete'
    Write-Host '============================================================'
    Write-Host "Target KB:       $targetKb"
    Write-Host "Target Build:    $targetBuild"
    Write-Host "UpdateID:        $($resolved.UpdateId)"
    Write-Host "Package count:   $($resolvedPackages.Count)"

    if (-not [string]::IsNullOrWhiteSpace($ssuFileName)) {
        Write-Host "Embedded SSU:    $ssuFileName"
    }
    else {
        Write-Host 'Embedded SSU:    Not detected'
    }

    Write-Host ''

    foreach ($package in $resolvedPackages) {

        Write-Host "  [$($package.Type)]"
        Write-Host "    KB:       $($package.KB)"
        Write-Host "    File:     $($package.FileName)"
        Write-Host "    Artifact: $($package.ArtifactPath)"
        Write-Host "    Source:   $($package.Source)"
    }

    Write-Host '============================================================'
    Write-Host ''

    # -------------------------------------------------------------------------
    # Return resolved Windows 11 LCU.
    #
    # Msu is retained for compatibility with the existing consumer.
    # Packages contains the complete checkpoint + target package set.
    # -------------------------------------------------------------------------

    return [pscustomobject]@{
        Type        = 'LCU'
        KB          = $targetKb
        Build       = $targetBuild
        Date        = $resolved.Date
        Title       = $resolved.Title
        UpdateId    = $resolved.UpdateId

        # Existing compatibility field.
        Msu         = $targetPackage

        # Complete checkpoint + target package set.
        Packages    = @($resolvedPackages)

        # Optional embedded SSU information.
        SsuFileName = $ssuFileName
    }
}


# -----------------------------------------------------------------------------
# Windows 10 package resolver
# -----------------------------------------------------------------------------

function Resolve-Windows10Package {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [Parameter(Mandatory = $true)]
        [ValidateSet('SSU', 'LCU')]
        [string]$PackageType,

        [string]$ExpectedKb = ''
    )

    $resolved = Resolve-CatalogPackageSet `
        -Query $Query `
        -ExpectedType $PackageType `
        -ExpectedKb $ExpectedKb

    $targetKb = $resolved.KB

    if (
        -not [string]::IsNullOrWhiteSpace($ExpectedKb) -and
        $targetKb -ne $ExpectedKb
    ) {
        throw @"
Catalog returned the wrong KB.

Expected: $ExpectedKb
Returned: $targetKb
UpdateID: $($resolved.UpdateId)
"@
    }

    # For Win10, retain the first MSU returned for the selected row.
    $package = @(
        $resolved.Packages |
            Where-Object {
                $_.FileName -match '(?i)\.msu$'
            }
    )

    if ($package.Count -eq 0) {
        throw "No MSU was returned for Windows 10 $PackageType $targetKb."
    }

    if ($package.Count -gt 1) {
        $matching = @(
            $package | Where-Object {
                $_.KB -eq $targetKb
            }
        )

        if ($matching.Count -eq 1) {
            $package = $matching
        }
        else {
            throw @"
Multiple MSUs were returned for Windows 10 $PackageType.

KB: $targetKb

Packages:
$(
    ($package | ForEach-Object {
        "  $($_.FileName)"
    }) -join "`r`n"
)
"@
        }
    }

    $selected = $package[0]

    $resolvedFile = Resolve-PackageFile `
        -PackageType $PackageType `
        -KB $targetKb `
        -FileName $selected.FileName `
        -Url $selected.Url

    return [pscustomobject]@{
        Type         = $PackageType
        KB           = $targetKb
        Build        = $resolved.Build
        Date         = $resolved.Date
        Title        = $resolved.Title
        UpdateId     = $resolved.UpdateId
        FileName     = $resolvedFile.FileName
        Url          = $resolvedFile.Url
        ArtifactPath = $resolvedFile.ArtifactPath
        LocalPath    = $resolvedFile.LocalPath
        Sha256       = $resolvedFile.Sha256
        Source       = $resolvedFile.Source
    }
}

# -----------------------------------------------------------------------------
# JSON output
# -----------------------------------------------------------------------------

function Write-ResolvedUpdatesJson {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest
    )

    $outputPath = Join-Path `
        $DownloadRoot `
        'resolved-updates.json'

    $json = $Manifest |
        ConvertTo-Json `
            -Depth 20

    # UTF-8 without BOM.
    $utf8NoBom = New-Object `
        System.Text.UTF8Encoding(
            $false
        )

    [System.IO.File]::WriteAllText(
        $outputPath,
        $json,
        $utf8NoBom
    )

    Write-Host ''
    Write-Host 'Resolved update manifest:'
    Write-Host "  $outputPath"

    return $outputPath
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

$resolvedLcu = $null
$resolvedSsu = $null

# -----------------------------------------------------------------------------
# Windows 11 24H2
# -----------------------------------------------------------------------------

if ($WindowsProfile -eq 'windows11-24h2') {

    if ([string]::IsNullOrWhiteSpace($CatalogQuery)) {
        $CatalogQuery = 'Windows 11 24H2 cumulative update x64'
    }

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' Resolving Windows 11 24H2 LCU'
    Write-Host '============================================================'

    $resolvedLcu = Resolve-Windows11Lcu `
        -Query $CatalogQuery

    if ($null -eq $resolvedLcu.Msu) {
        throw 'Windows 11 LCU target package was not resolved.'
    }

    if ([string]::IsNullOrWhiteSpace($resolvedLcu.Msu.KB)) {
        throw 'Windows 11 LCU target package has no KB.'
    }

    if ([string]::IsNullOrWhiteSpace($resolvedLcu.Msu.FileName)) {
        throw 'Windows 11 LCU target package has no filename.'
    }

    # -------------------------------------------------------------------------
    # Important target-package validation.
    #
    # This catches the exact class of problem that previously occurred:
    #
    #   KB5129195
    #   UpdateID = 6523...
    #   FileName = KB5043080
    #
    # The checkpoint is allowed elsewhere in Packages, but Msu MUST be target.
    # -------------------------------------------------------------------------

    $expectedTargetKb = $resolvedLcu.KB

    if ($resolvedLcu.Msu.KB -ne $expectedTargetKb) {
        throw @"
Windows 11 target LCU mismatch.

Expected target KB: $expectedTargetKb
Resolved target KB: $($resolvedLcu.Msu.KB)
FileName:            $($resolvedLcu.Msu.FileName)
UpdateID:            $($resolvedLcu.UpdateId)
"@
    }

    Write-Host ''
    Write-Host 'Windows 11 LCU target resolved successfully:'
    Write-Host "  KB:       $($resolvedLcu.KB)"
    Write-Host "  Build:    $($resolvedLcu.Build)"
    Write-Host "  UpdateID: $($resolvedLcu.UpdateId)"
    Write-Host "  Target:   $($resolvedLcu.Msu.FileName)"
    Write-Host ''

    Write-Host 'Windows 11 LCU package set:'

    foreach ($package in $resolvedLcu.Packages) {
        Write-Host "  [$($package.Type)] $($package.KB) $($package.FileName)"
    }

    # -------------------------------------------------------------------------
    # Manifest
    #
    # Msu remains the target package for existing consumers.
    #
    # Packages contains target + checkpoint package(s).
    # -------------------------------------------------------------------------

    $manifest = [ordered]@{
        schemaVersion = '1.4'

        profile       = $Profile
        product       = $Product
        release       = $Release
        architecture = $Architecture

        build         = $resolvedLcu.Build

        lcu           = [ordered]@{
            kb         = $resolvedLcu.KB
            build      = $resolvedLcu.Build
            date       = $resolvedLcu.Date
            title      = $resolvedLcu.Title
            updateId   = $resolvedLcu.UpdateId

            # Compatibility target package.
            msu        = [ordered]@{
                kb           = $resolvedLcu.Msu.KB
                fileName     = $resolvedLcu.Msu.FileName
                url          = $resolvedLcu.Msu.Url
                artifactPath = $resolvedLcu.Msu.ArtifactPath
                localPath    = $resolvedLcu.Msu.LocalPath
                sha256       = $resolvedLcu.Msu.Sha256
                source       = $resolvedLcu.Msu.Source
            }

            # Complete checkpoint/target package set.
            packages   = @(
                $resolvedLcu.Packages | ForEach-Object {
                    [ordered]@{
                        type         = $_.Type
                        kb           = $_.KB
                        fileName     = $_.FileName
                        url          = $_.Url
                        artifactPath = $_.ArtifactPath
                        localPath    = $_.LocalPath
                        sha256       = $_.Sha256
                        source       = $_.Source
                        updateId     = $_.UpdateId
                    }
                }
            )

            ssuFileName = $resolvedLcu.SsuFileName
        }

        baseIso      = [ordered]@{
            artifact = $BaseIsoArtifact
            sha256   = $BaseIsoSha256
        }

        artifactRoot = $ArtifactRoot
    }

    Write-ResolvedUpdatesJson -Manifest $manifest | Out-Null
}

# -----------------------------------------------------------------------------
# Windows 10 21H2
# -----------------------------------------------------------------------------

elseif ($WindowsProfile -eq 'windows10-21h2') {

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' Resolving Windows 10 21H2 updates'
    Write-Host '============================================================'

    # -------------------------------------------------------------------------
    # Profile can provide separate queries.
    # -------------------------------------------------------------------------

    $ssuQuery = [string](Get-ProfileProperty `
        -ProfileObject $imageProfile `
        -Name 'CatalogSsuQuery' `
        -DefaultValue '')

    $lcuQuery = [string](Get-ProfileProperty `
        -ProfileObject $imageProfile `
        -Name 'CatalogLcuQuery' `
        -DefaultValue '')

    $ssuKb = [string](Get-ProfileProperty `
        -ProfileObject $imageProfile `
        -Name 'SsuKb' `
        -DefaultValue '')

    $lcuKb = [string](Get-ProfileProperty `
        -ProfileObject $imageProfile `
        -Name 'LcuKb' `
        -DefaultValue '')

    if ([string]::IsNullOrWhiteSpace($ssuQuery)) {
        $ssuQuery = 'Windows 10 version 21H2 servicing stack update x64'
    }

    if ([string]::IsNullOrWhiteSpace($lcuQuery)) {
        $lcuQuery = 'Windows 10 version 21H2 cumulative update x64'
    }

    Write-Host ''
    Write-Host 'Resolving SSU...'

    $resolvedSsu = Resolve-Windows10Package `
        -Query $ssuQuery `
        -PackageType SSU `
        -ExpectedKb $ssuKb

    Write-Host ''
    Write-Host 'Resolving LCU...'

    $resolvedLcu = Resolve-Windows10Package `
        -Query $lcuQuery `
        -PackageType LCU `
        -ExpectedKb $lcuKb

    # -------------------------------------------------------------------------
    # Extract authoritative build from LCU CAB/MUM if possible.
    #
    # Catalog build may be empty on Windows 10 rows.
    # -------------------------------------------------------------------------

    $authoritativeBuild = $resolvedLcu.Build

    if (
        -not $ResolveOnly -and
        -not [string]::IsNullOrWhiteSpace($resolvedLcu.LocalPath) -and
        (Test-Path -LiteralPath $resolvedLcu.LocalPath -PathType Leaf)
    ) {

        $sevenZip = $null

        foreach ($candidate in @(
            '7z.exe',
            '7zz.exe',
            'C:\Program Files\7-Zip\7z.exe'
        )) {
            if (
                $candidate -match '^[^\\]+$' -and
                (Get-Command $candidate -ErrorAction SilentlyContinue)
            ) {
                $sevenZip = $candidate
                break
            }

            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $sevenZip = $candidate
                break
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($sevenZip)) {

            $tempExtract = Join-Path `
                $DownloadRoot `
                'win10-lcu-inspect'

            if (Test-Path -LiteralPath $tempExtract) {
                Remove-Item `
                    -LiteralPath $tempExtract `
                    -Recurse `
                    -Force
            }

            New-Item `
                -ItemType Directory `
                -Force `
                -Path $tempExtract | Out-Null

            try {

                & $sevenZip `
                    'x' `
                    $resolvedLcu.LocalPath `
                    "-o$tempExtract" `
                    '-y' `
                    '*.cab' `
                    '*.mum' | Out-Null

                $cabFiles = @(
                    Get-ChildItem `
                        -LiteralPath $tempExtract `
                        -Recurse `
                        -File `
                        -Filter '*.cab'
                )

                foreach ($cab in $cabFiles) {

                    $cabName = $cab.Name

                    $buildMatch = [regex]::Match(
                        $cabName,
                        '(?i)(\d{5}\.\d+|\d{5}\.\d+\.\d+)'
                    )

                    if ($buildMatch.Success) {
                        $authoritativeBuild = $buildMatch.Groups[1].Value
                        break
                    }
                }
            }
            catch {
                Write-Host "WARNING: Unable to inspect Windows 10 LCU for build: $($_.Exception.Message)"
            }
            finally {
                if (Test-Path -LiteralPath $tempExtract) {
                    Remove-Item `
                        -LiteralPath $tempExtract `
                        -Recurse `
                        -Force `
                        -ErrorAction SilentlyContinue
                }
            }
        }
    }

    $manifest = [ordered]@{
        schemaVersion = '1.4'

        profile       = $WindowsProfile
        product       = $Product
        release       = $Release
        architecture = $Architecture

        build         = $authoritativeBuild

        ssu           = [ordered]@{
            kb           = $resolvedSsu.KB
            fileName     = $resolvedSsu.FileName
            url          = $resolvedSsu.Url
            artifactPath = $resolvedSsu.ArtifactPath
            localPath    = $resolvedSsu.LocalPath
            sha256       = $resolvedSsu.Sha256
            source       = $resolvedSsu.Source
            updateId     = $resolvedSsu.UpdateId
            date         = $resolvedSsu.Date
            title        = $resolvedSsu.Title
        }

        lcu           = [ordered]@{
            kb           = $resolvedLcu.KB
            fileName     = $resolvedLcu.FileName
            url           = $resolvedLcu.Url
            artifactPath = $resolvedLcu.ArtifactPath
            localPath    = $resolvedLcu.LocalPath
            sha256       = $resolvedLcu.Sha256
            source       = $resolvedLcu.Source
            updateId     = $resolvedLcu.UpdateId
            date         = $resolvedLcu.Date
            title        = $resolvedLcu.Title
            build        = $authoritativeBuild
        }

        baseIso       = [ordered]@{
            artifact = $BaseIsoArtifact
            sha256   = $BaseIsoSha256
        }

        artifactRoot  = $ArtifactRoot
    }

    Write-ResolvedUpdatesJson -Manifest $manifest | Out-Null
}

else {
    throw "Unsupported Windows image profile '$Profile'."
}

# -----------------------------------------------------------------------------
# Final summary
# -----------------------------------------------------------------------------

Write-Host ''
Write-Host '============================================================'
Write-Host ' Resolution complete'
Write-Host '============================================================'

if ($null -ne $resolvedLcu) {
    Write-Host "LCU KB:        $($resolvedLcu.KB)"

    if (-not [string]::IsNullOrWhiteSpace($resolvedLcu.Build)) {
        Write-Host "LCU Build:     $($resolvedLcu.Build)"
    }

    Write-Host "LCU UpdateID:  $($resolvedLcu.UpdateId)"

    if ($null -ne $resolvedLcu.Packages) {
        Write-Host "LCU Packages:  $(@($resolvedLcu.Packages).Count)"

        foreach ($package in $resolvedLcu.Packages) {
            Write-Host "  [$($package.Type)] $($package.KB) $($package.FileName)"
        }
    }
    else {
        Write-Host "LCU File:      $($resolvedLcu.FileName)"
    }
}

if ($null -ne $resolvedSsu) {
    Write-Host "SSU KB:        $($resolvedSsu.KB)"
    Write-Host "SSU File:      $($resolvedSsu.FileName)"
}

Write-Host ''
Write-Host "Output:        $(Join-Path $DownloadRoot 'resolved-updates.json')"
Write-Host '============================================================'
