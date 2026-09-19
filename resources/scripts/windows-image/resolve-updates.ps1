[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [Parameter(Mandatory = $true)]
    [string]$WindowsBuild,

    [Parameter(Mandatory = $true)]
    [string]$Architecture,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryRepo,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryUser,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactoryPassword,

    [Parameter(Mandatory = $false)]
    [string]$UpdateManifestUrl = '',

    [Parameter(Mandatory = $false)]
    [string]$UpdateManifestFile = ''
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Configuration
# ============================================================

$WindowsVersion = '24H2'

# ============================================================
# Paths
# ============================================================

$WorkRoot =
    [System.IO.Path]::GetFullPath($WorkRoot)

$DownloadDir =
    Join-Path $WorkRoot 'download'

$UpdatesDir =
    Join-Path $DownloadDir 'updates'

$ResolvedManifestPath =
    Join-Path $DownloadDir 'resolved-updates.json'

$TempDir =
    Join-Path $DownloadDir 'resolver-temp'

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

New-Item `
    -ItemType Directory `
    -Path $TempDir `
    -Force |
    Out-Null

# ============================================================
# Helper Functions
# ============================================================

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
        [string]$ArtifactPath
    )

    $base =
        $ArtifactoryBaseUrl.TrimEnd('/')

    $repo =
        $ArtifactoryRepo.Trim('/')

    $artifact =
        $ArtifactPath.TrimStart('/')

    return "$base/artifactory/$repo/$artifact"
}

function Test-ArtifactoryArtifact {

    param(
        [Parameter(Mandatory = $true)]
        [string]$ArtifactPath
    )

    $url =
        Get-ArtifactoryUrl -ArtifactPath $ArtifactPath

    $headers =
        Get-ArtifactoryHeaders

    try {

        $response =
            Invoke-WebRequest `
                -Uri $url `
                -Headers $headers `
                -Method Head `
                -UseBasicParsing `
                -ErrorAction Stop

        return ($response.StatusCode -ge 200 -and
                $response.StatusCode -lt 300)
    }
    catch {

        if ($_.Exception.Response) {

            $statusCode =
                [int]$_.Exception.Response.StatusCode

            if ($statusCode -eq 404) {
                return $false
            }

            if ($statusCode -eq 401) {
                throw "Artifactory authentication failed while checking artifact: $ArtifactPath"
            }

            if ($statusCode -eq 403) {
                throw "Artifactory authorization failed while checking artifact: $ArtifactPath"
            }
        }

        return $false
    }
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

    $url =
        Get-ArtifactoryUrl -ArtifactPath $ArtifactPath

    $headers =
        Get-ArtifactoryHeaders

    $destinationDirectory =
        Split-Path `
            -Parent `
            -Path $DestinationPath

    New-Item `
        -ItemType Directory `
        -Path $destinationDirectory `
        -Force |
        Out-Null

    Write-Host ""
    Write-Host "Downloading cached artifact:"
    Write-Host "  $ArtifactPath"

    Invoke-WebRequest `
        -Uri $url `
        -Headers $headers `
        -OutFile $DestinationPath `
        -UseBasicParsing `
        -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $DestinationPath)) {

        throw "Artifactory download failed: $DestinationPath"
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {

        $actual =
            (Get-FileHash `
                -LiteralPath $DestinationPath `
                -Algorithm SHA256).Hash.ToLowerInvariant()

        $expected =
            $ExpectedSha256.Trim().ToLowerInvariant()

        if ($actual -ne $expected) {

            Remove-Item `
                -LiteralPath $DestinationPath `
                -Force `
                -ErrorAction SilentlyContinue

            throw @"
Artifactory artifact checksum validation failed.

Artifact:
  $ArtifactPath

Expected:
  $expected

Actual:
  $actual
"@
        }
    }

    return $DestinationPath
}

function Publish-ArtifactoryArtifact {

    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$ArtifactPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {

        throw "Cannot publish missing file: $SourcePath"
    }

    $url =
        Get-ArtifactoryUrl -ArtifactPath $ArtifactPath

    $headers =
        Get-ArtifactoryHeaders

    Write-Host ""
    Write-Host "Publishing artifact to Artifactory:"
    Write-Host "  $ArtifactPath"

    Invoke-WebRequest `
        -Uri $url `
        -Headers $headers `
        -Method Put `
        -InFile $SourcePath `
        -ContentType 'application/octet-stream' `
        -UseBasicParsing `
        -ErrorAction Stop

    Write-Host "Artifactory upload successful."
}

function Search-MicrosoftCatalog {

    param(
        [Parameter(Mandatory = $true)]
        [string]$SearchText
    )

    $encodedSearch =
        [System.Uri]::EscapeDataString($SearchText)

    $url =
        "https://www.catalog.update.microsoft.com/Search.aspx?q=$encodedSearch"

    Write-Host ""
    Write-Host "Microsoft Update Catalog search:"
    Write-Host "  $SearchText"

    try {

        $response =
            Invoke-WebRequest `
                -Uri $url `
                -UseBasicParsing `
                -ErrorAction Stop

        return $response
    }
    catch {

        throw "Microsoft Update Catalog search failed: $SearchText. $($_.Exception.Message)"
    }
}

function Get-KbNumbers {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $matches =
        [regex]::Matches(
            $Text,
            '(?i)KB\d{7}'
        )

    $results = @()

    foreach ($match in $matches) {

        $results +=
            $match.Value.ToUpperInvariant()
    }

    return $results |
        Sort-Object -Unique
}

function Get-CatalogCandidates {

    param(
        [Parameter(Mandatory = $true)]
        $Response
    )

    $results = @()

    $rows =
        $Response.ParsedHtml.getElementsByTagName('tr')

    foreach ($row in $rows) {

        $text =
            $row.innerText

        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        if ($text -notmatch '(?i)Windows 11') {
            continue
        }

        if ($text -notmatch '(?i)24H2') {
            continue
        }

        if ($text -notmatch '(?i)Cumulative Update') {
            continue
        }

        if ($text -match '(?i)Preview') {
            continue
        }

        if ($text -match '(?i)ARM64') {
            continue
        }

        if ($text -match '(?i)Dynamic Update') {
            continue
        }

        if ($text -notmatch '(?i)x64') {
            continue
        }

        $kbNumbers =
            @(Get-KbNumbers -Text $text)

        if ($kbNumbers.Count -eq 0) {
            continue
        }

        $updateId = ''

        foreach ($element in $row.getElementsByTagName('input')) {

            $name =
                $element.name

            $value =
                $element.value

            if ($name -match '(?i)uidInfo') {

                if (-not [string]::IsNullOrWhiteSpace($value)) {

                    $updateId =
                        $value
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($updateId)) {

            foreach ($element in $row.getElementsByTagName('a')) {

                $onclick =
                    $element.getAttribute('onclick')

                if ($onclick -match '(?i)([0-9a-f]{8}-[0-9a-f-]{27,})') {

                    $updateId =
                        $Matches[1]

                    break
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($updateId)) {
            continue
        }

        $date = $null

        $dateMatch =
            [regex]::Match(
                $text,
                '\b\d{1,2}/\d{1,2}/\d{4}\b'
            )

        if ($dateMatch.Success) {

            try {

                $date =
                    [datetime]::Parse(
                        $dateMatch.Value,
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )
            }
            catch {
                $date = $null
            }
        }

        $build = ''

        $buildMatch =
            [regex]::Match(
                $text,
                '\b26\d{3}\.\d{3,5}\b'
            )

        if ($buildMatch.Success) {

            $build =
                $buildMatch.Value
        }

        $results += [PSCustomObject]@{
            KB       = $kbNumbers[0]
            UpdateId = $updateId
            Date     = $date
            Build    = $build
            Text     = $text
        }
    }

    return $results
}

function Get-CatalogDownloadDialog {

    param(
        [Parameter(Mandatory = $true)]
        [string]$UpdateId
    )

    $url =
        'https://www.catalog.update.microsoft.com/DownloadDialog.aspx'

    $body =
        "updateIDs=[%7B%22size%22%3A%22%22%2C%22updateID%22%3A%22$UpdateId%22%7D]"

    try {

        return Invoke-WebRequest `
            -Uri $url `
            -Method Post `
            -Body $body `
            -ContentType 'application/x-www-form-urlencoded' `
            -UseBasicParsing `
            -ErrorAction Stop
    }
    catch {

        throw "Failed to retrieve Microsoft Update Catalog download dialog for $UpdateId. $($_.Exception.Message)"
    }
}

function Get-MsuDownloadUrl {

    param(
        [Parameter(Mandatory = $true)]
        $Response
    )

    $content =
        $Response.Content

    $patterns = @(
        'https?://[^"\s<>]+\.msu',
        'https?://[^"\s<>]+'
    )

    foreach ($pattern in $patterns) {

        $matches =
            [regex]::Matches(
                $content,
                $pattern,
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

        foreach ($match in $matches) {

            $candidate =
                $match.Value

            $candidate =
                [System.Net.WebUtility]::HtmlDecode($candidate)

            $candidate =
                $candidate.Replace('\u0026', '&')

            if ($candidate -match '(?i)\.msu(?:\?|$)') {

                return $candidate
            }
        }
    }

    throw "No MSU download URL found in Microsoft Update Catalog response."
}

function Get-MsuFileName {

    param(
        [Parameter(Mandatory = $true)]
        [string]$DownloadUrl
    )

    try {

        $uri =
            [System.Uri]$DownloadUrl

        $fileName =
            [System.IO.Path]::GetFileName(
                $uri.AbsolutePath
            )

        if (-not [string]::IsNullOrWhiteSpace($fileName)) {

            return $fileName
        }
    }
    catch {
    }

    $decoded =
        [System.Net.WebUtility]::UrlDecode($DownloadUrl)

    $match =
        [regex]::Match(
            $decoded,
            '(?i)([^/\\?&]+\.msu)'
        )

    if ($match.Success) {

        return $match.Groups[1].Value
    }

    throw "Unable to determine MSU filename from URL."
}

function Convert-CatalogDate {

    param(
        [Parameter(Mandatory = $false)]
        $Date
    )

    if ($null -eq $Date) {
        return ''
    }

    return $Date.ToUniversalTime().ToString(
        'yyyy-MM-dd'
    )
}

# ============================================================
# Validate
# ============================================================

if ($Architecture -notmatch '^(?i)x64$') {

    throw "This resolver currently supports x64 only. Architecture: $Architecture"
}

if ([string]::IsNullOrWhiteSpace($ArtifactoryUser)) {

    throw "Artifactory username is required."
}

if ([string]::IsNullOrWhiteSpace($ArtifactoryPassword)) {

    throw "Artifactory password/API token is required."
}

# ============================================================
# Display Configuration
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Windows Update Resolver"
Write-Host "============================================================"
Write-Host ""
Write-Host "Windows Version:"
Write-Host "  $WindowsVersion"
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
# Optional Existing Manifest
# ============================================================

if (-not [string]::IsNullOrWhiteSpace($UpdateManifestFile)) {

    if (-not (Test-Path -LiteralPath $UpdateManifestFile)) {

        throw "Specified update manifest file does not exist: $UpdateManifestFile"
    }

    Write-Host ""
    Write-Host "Using supplied update manifest file:"
    Write-Host "  $UpdateManifestFile"

    Copy-Item `
        -LiteralPath $UpdateManifestFile `
        -Destination $ResolvedManifestPath `
        -Force

    return
}

if (-not [string]::IsNullOrWhiteSpace($UpdateManifestUrl)) {

    Write-Host ""
    Write-Host "Downloading supplied update manifest:"
    Write-Host "  $UpdateManifestUrl"

    Invoke-WebRequest `
        -Uri $UpdateManifestUrl `
        -OutFile $ResolvedManifestPath `
        -UseBasicParsing `
        -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $ResolvedManifestPath)) {

        throw "Failed to create update manifest: $ResolvedManifestPath"
    }

    return
}

# ============================================================
# Search Microsoft Update Catalog
# ============================================================

$searchQueries = @(
    "Windows 11 Version 24H2 x64 Cumulative Update",
    "Windows 11 24H2 x64 Cumulative Update"
)

$candidates = @()

foreach ($query in $searchQueries) {

    try {

        $response =
            Search-MicrosoftCatalog -SearchText $query

        $found =
            @(Get-CatalogCandidates -Response $response)

        $candidates += $found
    }
    catch {

        Write-Warning $_.Exception.Message
    }
}

if ($candidates.Count -eq 0) {

    throw @"
No applicable Windows 11 24H2 x64 cumulative updates were found
in Microsoft Update Catalog.

Windows build:
  $WindowsBuild
"@
}

# ============================================================
# Deduplicate
# ============================================================

$candidates =
    $candidates |
    Group-Object -Property UpdateId |
    ForEach-Object {
        $_.Group |
            Sort-Object Date -Descending |
            Select-Object -First 1
    }

# ============================================================
# Rank Candidates
#
# Prefer updates whose reported build begins with the requested
# Windows build number.
# ============================================================

$matchingBuildCandidates =
    @(
        $candidates |
        Where-Object {
            $_.Build -and
            $_.Build.StartsWith(
                "$WindowsBuild.",
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
    )

if ($matchingBuildCandidates.Count -gt 0) {

    $selectedCandidate =
        $matchingBuildCandidates |
        Sort-Object Date -Descending |
        Select-Object -First 1
}
else {

    Write-Warning @"
No catalog candidate exposed a build beginning with $WindowsBuild.

Selecting the newest matching 24H2 x64 cumulative update by catalog date.
"@

    $selectedCandidate =
        $candidates |
        Sort-Object Date -Descending |
        Select-Object -First 1
}

if ($null -eq $selectedCandidate) {

    throw "Unable to select a Windows cumulative update."
}

# ============================================================
# Display Candidate
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Selected Windows Update"
Write-Host "============================================================"
Write-Host ""
Write-Host "KB:"
Write-Host "  $($selectedCandidate.KB)"
Write-Host ""
Write-Host "Build:"
Write-Host "  $($selectedCandidate.Build)"
Write-Host ""
Write-Host "Date:"
Write-Host "  $($selectedCandidate.Date)"
Write-Host ""
Write-Host "Update ID:"
Write-Host "  $($selectedCandidate.UpdateId)"
Write-Host ""
Write-Host "============================================================"

# ============================================================
# Retrieve Microsoft Download URL
# ============================================================

$dialogResponse =
    Get-CatalogDownloadDialog `
        -UpdateId $selectedCandidate.UpdateId

$msuDownloadUrl =
    Get-MsuDownloadUrl `
        -Response $dialogResponse

$msuFileName =
    Get-MsuFileName `
        -DownloadUrl $msuDownloadUrl

Write-Host ""
Write-Host "Microsoft download URL:"
Write-Host "  $msuDownloadUrl"

Write-Host ""
Write-Host "MSU filename:"
Write-Host "  $msuFileName"

# ============================================================
# Validate Filename
# ============================================================

if ($msuFileName -notmatch '(?i)^windows11\.0-') {

    throw @"
Unexpected Windows update filename.

Filename:
  $msuFileName
"@
}

$filenameKbMatch =
    [regex]::Match(
        $msuFileName,
        '(?i)KB\d{7}'
    )

if (-not $filenameKbMatch.Success) {

    throw @"
Unable to identify KB number from MSU filename.

Filename:
  $msuFileName
"@
}

$filenameKb =
    $filenameKbMatch.Value.ToUpperInvariant()

$catalogKb =
    $selectedCandidate.KB.ToUpperInvariant()

if ($filenameKb -ne $catalogKb) {

    throw @"
KB mismatch detected.

Microsoft Update Catalog:
  $catalogKb

Downloaded filename:
  $filenameKb

Filename:
  $msuFileName

The update will NOT be downloaded.
"@
}

# ============================================================
# Determine Artifactory Path
# ============================================================

$artifactPath =
    "Windows11/24H2/$Architecture/LCU/$catalogKb/$msuFileName"

$localPackagePath =
    Join-Path `
        $UpdatesDir `
        $msuFileName

Write-Host ""
Write-Host "Artifactory artifact path:"
Write-Host "  $artifactPath"

Write-Host ""
Write-Host "Local package path:"
Write-Host "  $localPackagePath"

# ============================================================
# Check Artifactory Cache
# ============================================================

$artifactExists =
    Test-ArtifactoryArtifact `
        -ArtifactPath $artifactPath

$sourceType = ''

if ($artifactExists) {

    Write-Host ""
    Write-Host "Update already exists in Artifactory."
    Write-Host "Using immutable cached artifact."

    Get-ArtifactoryArtifact `
        -ArtifactPath $artifactPath `
        -DestinationPath $localPackagePath

    $sourceType =
        'Artifactory cache'
}
else {

    Write-Host ""
    Write-Host "Update is not present in Artifactory."
    Write-Host "Downloading from Microsoft Update Catalog..."

    Invoke-WebRequest `
        -Uri $msuDownloadUrl `
        -OutFile $localPackagePath `
        -UseBasicParsing `
        -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $localPackagePath)) {

        throw "Microsoft update download failed: $localPackagePath"
    }

    Write-Host ""
    Write-Host "Microsoft download completed."

    # --------------------------------------------------------
    # Publish immutable MSU to Artifactory
    # --------------------------------------------------------

    Publish-ArtifactoryArtifact `
        -SourcePath $localPackagePath `
        -ArtifactPath $artifactPath

    $sourceType =
        'Microsoft Update Catalog -> Artifactory'
}

# ============================================================
# Calculate SHA256
# ============================================================

if (-not (Test-Path -LiteralPath $localPackagePath)) {

    throw "Resolved update package does not exist: $localPackagePath"
}

$fileInfo =
    Get-Item `
        -LiteralPath $localPackagePath

$sha256 =
    (Get-FileHash `
        -LiteralPath $localPackagePath `
        -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Host ""
Write-Host "Resolved update:"
Write-Host "  KB:       $catalogKb"
Write-Host "  Build:    $($selectedCandidate.Build)"
Write-Host "  Date:     $(Convert-CatalogDate $selectedCandidate.Date)"
Write-Host "  Filename: $msuFileName"
Write-Host "  Size:     $($fileInfo.Length)"
Write-Host "  SHA256:   $sha256"

# ============================================================
# Determine SSU Inclusion
# ============================================================

$ssuIncluded = $true

# Modern Windows 11 cumulative updates commonly include the
# servicing stack update. We record this in the manifest rather
# than attempting to separately inject an SSU unless a future
# product requirement explicitly calls for one.

# ============================================================
# Build Manifest
# ============================================================

$manifest = [ordered]@{
    type            = 'LCU'
    kb              = $catalogKb
    build           = $selectedCandidate.Build
    date            = Convert-CatalogDate $selectedCandidate.Date
    architecture    = $Architecture
    windowsBuild    = $WindowsBuild
    updateId        = $selectedCandidate.UpdateId
    fileName        = $msuFileName
    downloadUrl     = $msuDownloadUrl
    artifactPath    = $artifactPath
    sha256          = $sha256
    size            = $fileInfo.Length
    ssuIncluded     = $ssuIncluded
    source          = 'Microsoft Update Catalog'
    cacheSource     = $sourceType
    resolvedAtUtc   = [DateTime]::UtcNow.ToString(
        'o'
    )
}

$manifestJson =
    $manifest |
    ConvertTo-Json `
        -Depth 10

Set-Content `
    -LiteralPath $ResolvedManifestPath `
    -Value $manifestJson `
    -Encoding UTF8

# ============================================================
# Validate Manifest
# ============================================================

if (-not (Test-Path -LiteralPath $ResolvedManifestPath)) {

    throw "Failed to create resolved update manifest."
}

$manifestCheck =
    Get-Content `
        -LiteralPath $ResolvedManifestPath `
        -Raw |
        ConvertFrom-Json

if ($manifestCheck.kb -ne $catalogKb) {

    throw "Manifest KB validation failed."
}

if ($manifestCheck.fileName -ne $msuFileName) {

    throw "Manifest filename validation failed."
}

if ($manifestCheck.sha256 -ne $sha256) {

    throw "Manifest SHA256 validation failed."
}

# ============================================================
# Final Output
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Windows Update Resolution Complete"
Write-Host "============================================================"
Write-Host ""
Write-Host "Selected KB:"
Write-Host "  $catalogKb"
Write-Host ""
Write-Host "Build:"
Write-Host "  $($selectedCandidate.Build)"
Write-Host ""
Write-Host "Package:"
Write-Host "  $localPackagePath"
Write-Host ""
Write-Host "Artifactory:"
Write-Host "  $artifactPath"
Write-Host ""
Write-Host "SHA256:"
Write-Host "  $sha256"
Write-Host ""
Write-Host "Manifest:"
Write-Host "  $ResolvedManifestPath"
Write-Host ""
Write-Host "Source:"
Write-Host "  $sourceType"
Write-Host ""
Write-Host "============================================================"