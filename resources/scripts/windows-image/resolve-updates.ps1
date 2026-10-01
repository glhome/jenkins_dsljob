[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [ValidateSet('windows11-24h2', 'windows10-21h2')]
    [string]$Profile = 'windows11-24h2',

    [ValidateSet('x64', 'amd64', 'arm64')]
    [string]$Architecture = 'x64',

    [string]$ArtifactoryBaseUrl = '',

    [string]$ArtifactoryRepo = 'snapshot-generic-local',

    [string]$ArtifactoryUser = '',

    [string]$ArtifactoryPassword = '',

    [string]$ArtifactoryToken = '',

    [switch]$ForceMicrosoftDownload,

    [switch]$ResolveOnly
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
# Load Windows image profiles
# ============================================================

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$profilesPath = Join-Path $scriptDirectory 'profiles.ps1'

if (-not (Test-Path -LiteralPath $profilesPath)) {
    throw "Windows image profiles file not found: $profilesPath"
}

. $profilesPath

$profileInfo = Get-WindowsImageProfile -Name $Profile

Write-Host ''
Write-Host '============================================================'
Write-Host ' Resolve Windows LCU'
Write-Host '============================================================'
Write-Host "Profile      : $($profileInfo.Name)"
Write-Host "Windows      : $($profileInfo.WindowsVersion)"
Write-Host "Windows Build: $($profileInfo.Build)"
Write-Host "Architecture : $Architecture"
Write-Host ''

# ============================================================
# Paths
# ============================================================

$downloadDirectory = Join-Path $WorkRoot 'download'
$updateDirectory   = Join-Path $downloadDirectory 'updates'
$resolvedManifest  = Join-Path $downloadDirectory 'resolved-updates.json'

New-Item `
    -ItemType Directory `
    -Force `
    -Path $downloadDirectory, $updateDirectory |
    Out-Null

# ============================================================
# Artifactory URL
# ============================================================

if ([string]::IsNullOrWhiteSpace($ArtifactoryBaseUrl)) {
    throw 'ArtifactoryBaseUrl is required.'
}

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

    $headers = @{
        Authorization = "Bearer $ArtifactoryToken"
    }
}
elseif (
    -not [string]::IsNullOrWhiteSpace($ArtifactoryUser) -and
    -not [string]::IsNullOrWhiteSpace($ArtifactoryPassword)
) {

    $pair = "$ArtifactoryUser`:$ArtifactoryPassword"

    $encodedPair = [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes($pair)
    )

    $headers = @{
        Authorization = "Basic $encodedPair"
    }
}

# ============================================================
# Helper: Artifactory URL
# ============================================================

function Get-ArtifactoryUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return "$ArtifactoryUrlRoot/$ArtifactoryRepo/$($Path.TrimStart('/'))"
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
# Helper: Check Artifactory artifact
# ============================================================

function Find-ArtifactoryArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $url = Get-ArtifactoryUrl $Path

    try {

        if ($headers.Count -gt 0) {
            Invoke-WebRequest `
                -Uri $url `
                -Headers $headers `
                -Method Head `
                -UseBasicParsing `
                -TimeoutSec 60 |
                Out-Null
        }
        else {
            Invoke-WebRequest `
                -Uri $url `
                -Method Head `
                -UseBasicParsing `
                -TimeoutSec 60 |
                Out-Null
        }

        return $url
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

# ============================================================
# Helper: Download
# ============================================================

function Download-File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [hashtable]$RequestHeaders = $null
    )

    Write-Host "Downloading:"
    Write-Host "  $Url"
    Write-Host "To:"
    Write-Host "  $Destination"

    if ($RequestHeaders -and $RequestHeaders.Count -gt 0) {

        Invoke-WebRequest `
            -Uri $Url `
            -Headers $RequestHeaders `
            -OutFile $Destination `
            -UseBasicParsing `
            -TimeoutSec 3600
    }
    else {

        Invoke-WebRequest `
            -Uri $Url `
            -OutFile $Destination `
            -UseBasicParsing `
            -TimeoutSec 3600
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        throw "Download failed: $Url"
    }
}

# ============================================================
# Helper: Microsoft Update Catalog
# ============================================================

function Get-CatalogHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $url =
        'https://www.catalog.update.microsoft.com/Search.aspx?q=' +
        [uri]::EscapeDataString($Query)

    Write-Host "Catalog query:"
    Write-Host "  $Query"

    return (
        Invoke-WebRequest `
            -Uri $url `
            -UseBasicParsing `
            -TimeoutSec 120
    ).Content
}

# ============================================================
# Helper: Get Microsoft Update download URLs
# ============================================================

function Get-DownloadUrls {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UpdateId
    )

    $obj = @{
        size     = 0
        updateID = $UpdateId
        uidInfo  = $UpdateId
    } | ConvertTo-Json -Compress

    $body = @{
        updateIDs = "[$obj]"
    }

    $content = (
        Invoke-WebRequest `
            -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' `
            -Method Post `
            -Body $body `
            -ContentType 'application/x-www-form-urlencoded' `
            -UseBasicParsing `
            -TimeoutSec 120
    ).Content

    $content = $content.Replace('&amp;', '&')

    $urls = [regex]::Matches(
        $content,
        'https?://[^"''\s<>]+'
    ) |
    ForEach-Object {
        $url = $_.Value.TrimEnd(
            "'",
            '"',
            ')',
            ';'
        )

        if (
            $url -match '(?i)download\.windowsupdate\.com' -or
            $url -match '(?i)windowsupdate\.com' -or
            $url -match '(?i)delivery\.mp\.microsoft\.com'
        ) {
            $url
        }
    } |
    Select-Object -Unique

    return @($urls)
}

# ============================================================
# Microsoft Update Catalog candidate parser
#
# IMPORTANT:
# This intentionally follows the original working parser.
# ============================================================

function Get-CatalogCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Html
    )

    $rows = [regex]::Matches(
        $Html,
        '(?is)<tr[^>]*>(.*?)</tr>'
    )

    $candidates = @()

    foreach ($row in $rows) {
        $r = $row.Groups[1].Value

        # ------------------------------------------------------------
        # Product / release filtering
        # ------------------------------------------------------------
        if ($r -notmatch $profileInfo.CatalogProductPattern) {
            continue
        }

        # ------------------------------------------------------------
        # Architecture filtering
        # ------------------------------------------------------------
        if ($Architecture -eq 'x64') {
            if ($r -notmatch '(?i)x64-based Systems') {
                continue
            }
        }
        elseif ($Architecture -eq 'arm64') {
            if ($r -notmatch '(?i)ARM64-based Systems') {
                continue
            }
        }

        # ------------------------------------------------------------
        # Build filtering
        #
        # Windows 11 24H2:
        #   Catalog title contains "(26100.x)"
        #
        # Windows 10 21H2:
        #   Catalog title normally does NOT contain "(19044.x)"
        #
        # Therefore the profile controls whether Catalog build
        # matching is required.
        # ------------------------------------------------------------
        if ($profileInfo.CatalogBuildRequired) {

            $b = [regex]::Match(
                $r,
                "\(($($profileInfo.BuildRegex))\)"
            )

            if (-not $b.Success) {
                continue
            }

            $build = $b.Groups[1].Value
        }
        else {
            # Windows 10 LTSC 2021:
            # Build is not reliably present in the Catalog title.
            # Leave it empty here and obtain/validate it later
            # from the update metadata/MSU.
            $build = ''
        }

        # ------------------------------------------------------------
        # Extract KB
        # ------------------------------------------------------------
        $kbMatch = [regex]::Match(
            $r,
            '(?i)\bKB(\d{7})\b'
        )

        if (-not $kbMatch.Success) {
            continue
        }

        $kb = "KB$($kbMatch.Groups[1].Value)"

        # ------------------------------------------------------------
        # Extract date
        # ------------------------------------------------------------
        $dateMatch = [regex]::Match(
            $r,
            '(?i)(\d{4}-\d{2})'
        )

        if (-not $dateMatch.Success) {
            continue
        }

        try {
            $date = [datetime]::ParseExact(
                $dateMatch.Groups[1].Value,
                'yyyy-MM',
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        }
        catch {
            continue
        }

        # ------------------------------------------------------------
        # Extract Catalog links
        # ------------------------------------------------------------
        $links = [regex]::Matches(
            $r,
            '(?is)<a[^>]+href=["'']([^"'']+)["''][^>]*>(.*?)</a>'
        )

        foreach ($link in $links) {
            $url = $link.Groups[1].Value
            $linkText = [System.Net.WebUtility]::HtmlDecode(
                $link.Groups[2].Value
            )

            # Catalog links normally point to the update detail page.
            if ($url -notmatch '(?i)catalog\.update\.microsoft\.com') {
                continue
            }

            $candidates += [pscustomobject]@{
                KB       = $kb
                Build    = $build
                Date     = $date
                Title    = ([System.Net.WebUtility]::HtmlDecode(
                                ($r -replace '<[^>]+>', ' ')
                            ) -replace '\s+', ' ').Trim()
                UpdateUrl = $url
                LinkText  = $linkText
            }
        }
    }

    # ------------------------------------------------------------
    # Remove duplicate KBs / links and return newest first.
    # ------------------------------------------------------------
    $candidates |
        Sort-Object Date -Descending |
        Group-Object KB |
        ForEach-Object {
            $_.Group | Select-Object -First 1
        }
}

# ============================================================
# Validate MSU filename
# ============================================================

function Test-MsuName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$KB
    )

    $number = $KB -replace '^KB', ''

    $kbMatch =
        $Name -match
        "(?i)kb$([regex]::Escape($number))(?:[^0-9]|$)"

    $msuMatch =
        $Name -match '(?i)\.msu$'

    if ($Architecture -eq 'x64') {

        $architectureMatch =
            $Name -match '(?i)(x64|amd64)'
    }
    elseif ($Architecture -eq 'arm64') {

        $architectureMatch =
            $Name -match '(?i)arm64'
    }
    else {

        $architectureMatch = $false
    }

    return (
        $kbMatch -and
        $msuMatch -and
        $architectureMatch
    )
}

# ============================================================
# Resolve latest LCU
# ============================================================

Write-Host "Resolving $($profileInfo.WindowsVersion) $Architecture LCU..."

$catalogHtml = Get-CatalogHtml $profileInfo.CatalogQuery

$candidates = Get-CatalogCandidates $catalogHtml

if (-not $candidates) {
    throw `
        "No matching $($profileInfo.WindowsVersion) $Architecture " +
        "cumulative update found for build $($profileInfo.Build)."
}

Write-Host ''
Write-Host "Catalog candidates found: $($candidates.Count)"

# ============================================================
# Select newest build/date
# ============================================================

$selected =
    $candidates |
    Group-Object KB |
    ForEach-Object {

        $_.Group |
            Sort-Object -Property Date -Descending |
            Select-Object -First 1
    } |
    Sort-Object `
        -Property @{
            Expression = {
                try {
                    [version]$_.Build
                }
                catch {
                    [version]'0.0'
                }
            }
            Descending = $true
        }, Date -Descending |
    Select-Object -First 1

if (-not $selected) {
    throw 'Unable to select an LCU from Microsoft Update Catalog.'
}

Write-Host ''
Write-Host 'Selected Catalog update:'
Write-Host "  KB       : $($selected.KB)"
Write-Host "  Build    : $($selected.Build)"
Write-Host "  Date     : $($selected.Date.ToString('yyyy-MM-dd'))"
Write-Host "  Title    : $($selected.Title)"

# ============================================================
# Resolve UpdateID
# ============================================================

$updateIds = @($selected.UpdateIds)

if (-not $updateIds) {

    $updateIds =
        [regex]::Matches(
            $catalogHtml,
            '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        ) |
        ForEach-Object Value |
        Select-Object -Unique
}

if (-not $updateIds) {
    throw "Unable to resolve UpdateID for $($selected.KB)."
}

# ============================================================
# Resolve MSU download URL
# ============================================================

$chosen = $null

foreach ($id in $updateIds) {

    foreach ($url in @(Get-DownloadUrls $id)) {

        try {

            $fileName =
                [IO.Path]::GetFileName(
                    ([uri]$url).AbsolutePath
                )

            if (
                Test-MsuName `
                    -Name $fileName `
                    -KB $selected.KB
            ) {

                $chosen = [pscustomobject]@{
                    UpdateId = $id
                    Url      = $url
                    FileName = $fileName
                }

                break
            }
        }
        catch {
            # Try the next URL.
        }
    }

    if ($chosen) {
        break
    }
}

if (-not $chosen) {
    throw "Unable to resolve a valid MSU for $($selected.KB)."
}

# ============================================================
# Artifactory path
# ============================================================

$relativePath =
    "$($profileInfo.ArtifactRoot)/$Architecture/LCU/" +
    "$($selected.KB)/$($chosen.FileName)"

$localPath =
    Join-Path `
        $updateDirectory `
        $chosen.FileName

$artifactoryUrl =
    Get-ArtifactoryUrl $relativePath

# ============================================================
# Resolve-only
#
# IMPORTANT:
# No MSU download.
# No Artifactory MSU download.
# ============================================================

if ($ResolveOnly) {

    $resolvedObject = [ordered]@{
        schemaVersion   = '1.0'
        type            = 'LCU'

        profile         = $profileInfo.Name
        product         = $profileInfo.Product
        windowsVersion  = $profileInfo.WindowsVersion
        release         = $profileInfo.Release
        windowsBuild    = $profileInfo.Build

        artifactRoot    = $profileInfo.ArtifactRoot
        isoPrefix       = $profileInfo.IsoPrefix

        kb              = $selected.KB
        build           = $selected.Build
        releaseDate     = $selected.Date.ToString('yyyy-MM-dd')

        architecture    = $Architecture

        updateId        = $chosen.UpdateId
        fileName        = $chosen.FileName

        sha256          = ''

        microsoftUrl    = $chosen.Url

        artifactoryUrl  = $artifactoryUrl
        artifactoryRepo = $ArtifactoryRepo
        artifactoryPath = $relativePath

        source          = 'ResolveOnly'

        # Windows 11 24H2 current LCUs include the SSU.
        ssuIncluded     = $true

        resolvedAtUtc   =
            [datetime]::UtcNow.ToString('o')
    }

    $json =
        $resolvedObject |
        ConvertTo-Json -Depth 10

    [System.IO.File]::WriteAllText(
        $resolvedManifest,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Host ''
    Write-Host "Resolved $($selected.KB) / $($selected.Build) " +
               '(resolve-only; MSU download skipped)'

    Write-Host "UpdateID: $($chosen.UpdateId)"
    Write-Host "MSU    : $($chosen.FileName)"
    Write-Host "Manifest: $resolvedManifest"

    exit 0
}

# ============================================================
# Download/cache MSU
# ============================================================

$existingArtifact =
    Find-ArtifactoryArtifact $relativePath

if (
    $existingArtifact -and
    -not $ForceMicrosoftDownload
) {

    Write-Host ''
    Write-Host 'MSU found in Artifactory.'
    Write-Host "  $existingArtifact"

    Download-File `
        -Url $existingArtifact `
        -Destination $localPath `
        -RequestHeaders $headers

    $source = 'Artifactory'
}
else {

    Write-Host ''
    Write-Host 'Downloading MSU from Microsoft Update Catalog...'

    Download-File `
        -Url $chosen.Url `
        -Destination $localPath

    $source = 'Microsoft'

    if (-not (Test-Path -LiteralPath $localPath)) {
        throw 'Microsoft download failed.'
    }

    # --------------------------------------------------------
    # Cache the MSU in Artifactory if it is not already there.
    # --------------------------------------------------------

    $existingAfterDownload =
        Find-ArtifactoryArtifact $relativePath

    if (-not $existingAfterDownload) {

        Write-Host ''
        Write-Host 'Uploading MSU to Artifactory...'

        & jf rt upload `
            --server-id=local-artifactory `
            --flat=true `
            --detailed-summary `
            $localPath `
            "$ArtifactoryRepo/$relativePath"

        $uploadExitCode = $LASTEXITCODE

        if ($uploadExitCode -ne 0) {
            throw `
                "JFrog upload failed with exit code ${uploadExitCode}"
        }
    }

    $existingArtifact =
        Find-ArtifactoryArtifact $relativePath

    if (-not $existingArtifact) {
        throw `
            "MSU upload completed but artifact cannot be found: " +
            "$relativePath"
    }

    $artifactoryUrl = $existingArtifact
}

# ============================================================
# Calculate SHA256
# ============================================================

if (-not (Test-Path -LiteralPath $localPath)) {
    throw "Resolved MSU was not found: $localPath"
}

$sha256 = Get-Sha256 $localPath

# ============================================================
# Write resolved-updates.json
# ============================================================

$resolvedObject = [ordered]@{
    schemaVersion   = '1.0'
    type            = 'LCU'

    profile         = $profileInfo.Name
    product         = $profileInfo.Product
    windowsVersion  = $profileInfo.WindowsVersion
    release         = $profileInfo.Release
    windowsBuild    = $profileInfo.Build

    artifactRoot    = $profileInfo.ArtifactRoot
    isoPrefix       = $profileInfo.IsoPrefix

    kb              = $selected.KB
    build           = $selected.Build
    releaseDate     = $selected.Date.ToString('yyyy-MM-dd')

    architecture    = $Architecture

    updateId        = $chosen.UpdateId
    fileName        = $chosen.FileName

    sha256          = $sha256

    microsoftUrl    = $chosen.Url

    artifactoryUrl  = $artifactoryUrl
    artifactoryRepo = $ArtifactoryRepo
    artifactoryPath = $relativePath

    source          = $source

    # Current Windows 11 24H2 LCUs contain the SSU.
    ssuIncluded     = $true

    resolvedAtUtc   =
        [datetime]::UtcNow.ToString('o')
}

$json =
    $resolvedObject |
    ConvertTo-Json -Depth 10

# UTF-8 WITHOUT BOM.
[System.IO.File]::WriteAllText(
    $resolvedManifest,
    $json,
    [System.Text.UTF8Encoding]::new($false)
)

# ============================================================
# Final output
# ============================================================

Write-Host ''
Write-Host '============================================================'
Write-Host ' LCU Resolved Successfully'
Write-Host '============================================================'
Write-Host "Profile       : $($profileInfo.Name)"
Write-Host "Windows       : $($profileInfo.WindowsVersion)"
Write-Host "Windows Build : $($profileInfo.Build)"
Write-Host "Architecture  : $Architecture"
Write-Host "KB            : $($selected.KB)"
Write-Host "LCU Build     : $($selected.Build)"
Write-Host "Release Date  : $($selected.Date.ToString('yyyy-MM-dd'))"
Write-Host "UpdateID      : $($chosen.UpdateId)"
Write-Host "MSU           : $($chosen.FileName)"
Write-Host "SHA256        : $sha256"
Write-Host "Source        : $source"
Write-Host "SSU Included  : True"
Write-Host "Artifactory   : $relativePath"
Write-Host "Local MSU     : $localPath"
Write-Host "Manifest      : $resolvedManifest"
Write-Host '============================================================'
Write-Host ''

exit 0