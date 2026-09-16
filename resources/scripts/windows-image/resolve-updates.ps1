[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [int]$WindowsBuild = 26100,

    [string]$Architecture = "x64",

    [string]$ArtifactoryBaseUrl = "",

    [string]$ArtifactoryRepo = "windows-updates",

    [string]$ArtifactoryUser = "",

    [string]$ArtifactoryPassword = ""
)

$ErrorActionPreference = "Stop"

# ============================================================
# Configuration
# ============================================================

$DownloadDir = Join-Path $WorkRoot "download"
$UpdatesDir  = Join-Path $DownloadDir "updates"
$ResolvedFile = Join-Path $DownloadDir "resolved-updates.json"

New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
New-Item -ItemType Directory -Force -Path $UpdatesDir  | Out-Null

# ============================================================
# Normalize architecture
# ============================================================

$Architecture = $Architecture.ToLowerInvariant().Trim()

switch ($Architecture) {

    "x64" {
        $CatalogArchitecture = "x64"
    }

    "amd64" {
        $Architecture = "x64"
        $CatalogArchitecture = "x64"
    }

    "arm64" {
        $CatalogArchitecture = "arm64"
    }

    default {
        throw "Unsupported architecture: $Architecture"
    }
}

# ============================================================
# Helper: SHA-256
# ============================================================

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File not found for SHA-256 calculation: $Path"
    }

    return (
        Get-FileHash `
            -LiteralPath $Path `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()
}

# ============================================================
# Helper: Microsoft Update Catalog search URL
# ============================================================

function Get-CatalogSearchUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $encoded = [System.Uri]::EscapeDataString($Query)

    return "https://www.catalog.update.microsoft.com/Search.aspx?q=$encoded"
}

# ============================================================
# Helper: Microsoft Update Catalog page
# ============================================================

function Get-CatalogPage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $url = Get-CatalogSearchUrl -Query $Query

    Write-Host ""
    Write-Host "Microsoft Update Catalog:"
    Write-Host "  $url"

    try {

        $response = Invoke-WebRequest `
            -Uri $url `
            -UseBasicParsing `
            -MaximumRedirection 10

        if (!$response.Content) {
            throw "Catalog returned empty content."
        }

        return $response.Content
    }
    catch {

        throw @"
Unable to retrieve Microsoft Update Catalog.

Query:
  $Query

URL:
  $url

Error:
  $($_.Exception.Message)
"@
    }
}

# ============================================================
# Helper: extract filename from URL
# ============================================================

function Get-FileNameFromUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    try {

        $uri = [System.Uri]$Url

        $name = [System.IO.Path]::GetFileName(
            $uri.AbsolutePath
        )

        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "URL does not contain a filename."
        }

        return [System.Uri]::UnescapeDataString($name)
    }
    catch {

        # Fallback for URLs that don't parse cleanly
        $clean = $Url.Split("?")[0]
        $name = [System.IO.Path]::GetFileName($clean)

        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "Could not determine filename from URL: $Url"
        }

        return $name
    }
}

# ============================================================
# Helper: verify MSU filename belongs to selected KB
# ============================================================

function Test-MsuFileNameMatchesKb {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string]$Kb
    )

    $kbNumber = $Kb -replace '(?i)^KB', ''

    if ([string]::IsNullOrWhiteSpace($kbNumber)) {
        return $false
    }

    # Microsoft MSU filenames normally contain:
    #
    # Windows11.0-KB1234567-x64.msu
    #
    # We intentionally require the KB number to appear
    # as KB<number> in the filename.
    $pattern = "(?i)KB$([regex]::Escape($kbNumber))(?:[^0-9]|$)"

    return ($FileName -match $pattern)
}

# ============================================================
# Helper: retrieve Catalog DownloadDialog URLs
# ============================================================

function Get-CatalogDownloadUrls {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UpdateId
    )

    $dialogUrl = "https://www.catalog.update.microsoft.com/DownloadDialog.aspx"

    $body = @{
        updateIDs = "[{`"size`":0,`"updateID`":`"$UpdateId`"}]"
    }

    Write-Host "  DownloadDialog:"
    Write-Host "    $dialogUrl"

    try {

        $response = Invoke-WebRequest `
            -Uri $dialogUrl `
            -Method Post `
            -Body $body `
            -ContentType "application/x-www-form-urlencoded" `
            -UseBasicParsing

        $html = $response.Content

        if ([string]::IsNullOrWhiteSpace($html)) {
            throw "DownloadDialog returned empty content."
        }

        $urls = New-Object System.Collections.Generic.List[string]

        # ----------------------------------------------------
        # Extract https/http URLs
        # ----------------------------------------------------

        $urlMatches = [regex]::Matches(
            $html,
            '(?i)https?://[^"''<>\s]+'
        )

        foreach ($match in $urlMatches) {

            $url = $match.Value

            # HTML entities
            $url = $url `
                -replace '&amp;', '&' `
                -replace '\\/', '/'

            # Remove trailing punctuation
            $url = $url.TrimEnd(
                '"',
                "'",
                '>',
                ')',
                ';'
            )

            if ($url -match '(?i)\.msu(?:\?|$)') {

                if (!$urls.Contains($url)) {
                    $urls.Add($url)
                }
            }
        }

        # ----------------------------------------------------
        # Sometimes URLs are HTML encoded
        # ----------------------------------------------------

        $decodedHtml = [System.Net.WebUtility]::HtmlDecode($html)

        $decodedMatches = [regex]::Matches(
            $decodedHtml,
            '(?i)https?://[^"''<>\s]+'
        )

        foreach ($match in $decodedMatches) {

            $url = $match.Value

            $url = $url.TrimEnd(
                '"',
                "'",
                '>',
                ')',
                ';'
            )

            if ($url -match '(?i)\.msu(?:\?|$)') {

                if (!$urls.Contains($url)) {
                    $urls.Add($url)
                }
            }
        }

        # ----------------------------------------------------
        # DownloadDialog can contain links escaped with \/
        # ----------------------------------------------------

        $slashDecoded = $html -replace '\\/', '/'

        $slashMatches = [regex]::Matches(
            $slashDecoded,
            '(?i)https?://[^"''<>\s]+'
        )

        foreach ($match in $slashMatches) {

            $url = $match.Value

            $url = $url.TrimEnd(
                '"',
                "'",
                '>',
                ')',
                ';'
            )

            if ($url -match '(?i)\.msu(?:\?|$)') {

                if (!$urls.Contains($url)) {
                    $urls.Add($url)
                }
            }
        }

        return @($urls)
    }
    catch {

        throw "DownloadDialog request failed for UpdateID $UpdateId : $($_.Exception.Message)"
    }
}

# ============================================================
# Helper: Artifactory URL
# ============================================================

function Get-ArtifactoryUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($ArtifactoryBaseUrl)) {
        return $null
    }

    $base = $ArtifactoryBaseUrl.TrimEnd("/")

    $repo = $ArtifactoryRepo.Trim("/")

    $relative = $RelativePath.TrimStart("/")

    return "$base/$repo/$relative"
}

# ============================================================
# Helper: Artifactory headers
# ============================================================

function Get-ArtifactoryHeaders {

    $headers = @{}

    if (
        ![string]::IsNullOrWhiteSpace($ArtifactoryUser) -and
        ![string]::IsNullOrWhiteSpace($ArtifactoryPassword)
    ) {

        $pair = "$ArtifactoryUser`:$ArtifactoryPassword"

        $encoded = [Convert]::ToBase64String(
            [Text.Encoding]::ASCII.GetBytes($pair)
        )

        $headers["Authorization"] = "Basic $encoded"
    }

    return $headers
}

# ============================================================
# Helper: test Artifactory artifact
# ============================================================

function Test-ArtifactoryArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $url = Get-ArtifactoryUrl -RelativePath $RelativePath

    if ([string]::IsNullOrWhiteSpace($url)) {
        return $false
    }

    Write-Host ""
    Write-Host "Checking Artifactory:"
    Write-Host "  $url"

    try {

        $headers = Get-ArtifactoryHeaders

        $response = Invoke-WebRequest `
            -Uri $url `
            -Method Head `
            -Headers $headers `
            -UseBasicParsing

        return ($response.StatusCode -ge 200 -and
                $response.StatusCode -lt 300)
    }
    catch {

        return $false
    }
}

# ============================================================
# Helper: download from Artifactory
# ============================================================

function Get-ArtifactoryArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $url = Get-ArtifactoryUrl -RelativePath $RelativePath

    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "ArtifactoryBaseUrl is empty."
    }

    Write-Host ""
    Write-Host "Downloading from Artifactory:"
    Write-Host "  $url"

    $headers = Get-ArtifactoryHeaders

    Invoke-WebRequest `
        -Uri $url `
        -Headers $headers `
        -OutFile $Destination `
        -UseBasicParsing

    if (!(Test-Path -LiteralPath $Destination)) {
        throw "Artifactory download did not create: $Destination"
    }
}

# ============================================================
# Helper: upload to Artifactory
# ============================================================

function Publish-ArtifactoryArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $url = Get-ArtifactoryUrl -RelativePath $RelativePath

    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "ArtifactoryBaseUrl is empty."
    }

    if (!(Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Cannot upload missing file: $Source"
    }

    Write-Host ""
    Write-Host "Uploading to Artifactory:"
    Write-Host "  $url"

    $headers = Get-ArtifactoryHeaders

    try {

        Invoke-WebRequest `
            -Uri $url `
            -Method Put `
            -Headers $headers `
            -InFile $Source `
            -ContentType "application/octet-stream" `
            -UseBasicParsing
    }
    catch {

        throw "Artifactory upload failed: $($_.Exception.Message)"
    }
}

# ============================================================
# Resolve latest Windows 11 24H2 LCU
# ============================================================

$query = "Windows 11 24H2 cumulative update $CatalogArchitecture"

Write-Host ""
Write-Host "============================================================"
Write-Host " Microsoft Update Catalog Search"
Write-Host "============================================================"
Write-Host "Query:"
Write-Host "  $query"
Write-Host ""

$html = Get-CatalogPage -Query $query

# ============================================================
# Parse Catalog rows
# ============================================================

$rows = [regex]::Matches(
    $html,
    '<tr[^>]*>(.*?)</tr>',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)

$candidates = @()

foreach ($rowMatch in $rows) {

    $row = $rowMatch.Groups[1].Value

    $plain = [System.Net.WebUtility]::HtmlDecode(
        ($row -replace '<[^>]+>', ' ')
    )

    $plain = $plain -replace '\s+', ' '
    $plain = $plain.Trim()

    if ($plain -notmatch '(?i)Windows 11') {
        continue
    }

    if ($plain -notmatch '(?i)version 24H2') {
        continue
    }

    if ($plain -notmatch '(?i)Cumulative Update') {
        continue
    }

    if ($plain -notmatch '(?i)Security Updates') {
        continue
    }

    # --------------------------------------------------------
    # Architecture
    # --------------------------------------------------------

    if ($Architecture -eq "x64") {

        if ($plain -notmatch '(?i)x64-based Systems') {
            continue
        }

        if ($plain -match '(?i)ARM64') {
            continue
        }
    }
    elseif ($Architecture -eq "arm64") {

        if ($plain -notmatch '(?i)ARM64-based Systems') {
            continue
        }
    }

    # --------------------------------------------------------
    # Exclusions
    # --------------------------------------------------------

    if ($plain -match '(?i)Preview') {
        continue
    }

    if ($plain -match '(?i)\.NET') {
        continue
    }

    if ($plain -match '(?i)Dynamic Update') {
        continue
    }

    if ($plain -match '(?i)Server') {
        continue
    }

    # --------------------------------------------------------
    # KB
    # --------------------------------------------------------

    $kbMatch = [regex]::Match(
        $plain,
        '(?i)\(KB(\d+)\)'
    )

    if (!$kbMatch.Success) {
        continue
    }

    $kb = "KB$($kbMatch.Groups[1].Value)"

    # --------------------------------------------------------
    # Build
    # --------------------------------------------------------

    $build = ""

    $buildMatch = [regex]::Match(
        $plain,
        '\((26100\.\d+)\)'
    )

    if ($buildMatch.Success) {
        $build = $buildMatch.Groups[1].Value
    }

    # --------------------------------------------------------
    # Date
    # --------------------------------------------------------

    $date = [datetime]::MinValue

    $dateMatch = [regex]::Match(
        $plain,
        '(\d{1,2}/\d{1,2}/\d{4})'
    )

    if ($dateMatch.Success) {

        try {

            $date = [datetime]::Parse(
                $dateMatch.Groups[1].Value
            )
        }
        catch {

            $date = [datetime]::MinValue
        }
    }

    $candidates += [pscustomobject]@{
        KB    = $kb
        Build = $build
        Date  = $date
        Title = $plain
        Row   = $row
    }
}

# ============================================================
# Remove duplicate KBs
# ============================================================

$candidates = @(
    $candidates |
        Group-Object KB |
        ForEach-Object {
            $_.Group |
                Sort-Object Date -Descending |
                Select-Object -First 1
        }
)

if ($candidates.Count -eq 0) {

    throw @"
Could not find a Windows 11 24H2 $Architecture LCU
in Microsoft Update Catalog.

Search:
  $query
"@
}

# ============================================================
# Display candidates
# ============================================================

Write-Host ""
Write-Host "Catalog candidates:"
Write-Host ""

foreach ($candidate in $candidates) {

    Write-Host (
        "  {0} | {1} | {2}" -f
        $candidate.KB,
        $candidate.Build,
        $candidate.Date.ToString("yyyy-MM-dd")
    )
}

# ============================================================
# Select newest candidate
# ============================================================

$selected = $candidates |
    Sort-Object `
        @{ Expression = { $_.Date }; Descending = $true }, `
        @{ Expression = {
            if ($_.Build) {
                try {
                    [version]$_.Build
                }
                catch {
                    [version]"0.0"
                }
            }
            else {
                [version]"0.0"
            }
        }; Descending = $true } |
    Select-Object -First 1

if (!$selected) {
    throw "Unable to select an LCU candidate."
}

Write-Host ""
Write-Host "============================================================"
Write-Host " Selected LCU"
Write-Host "============================================================"
Write-Host "KB       : $($selected.KB)"
Write-Host "Build    : $($selected.Build)"
Write-Host "Date     : $($selected.Date.ToString('yyyy-MM-dd'))"
Write-Host "Title    : $($selected.Title)"
Write-Host "============================================================"
Write-Host ""

# ============================================================
# Resolve UpdateID using KB-specific Catalog page
# ============================================================

$kbQuery = $selected.KB

Write-Host "Resolving UpdateID for:"
Write-Host "  $kbQuery"

$kbHtml = Get-CatalogPage -Query $kbQuery

# Save raw Catalog HTML for diagnostics
$catalogDebugFile = Join-Path `
    $DownloadDir `
    "catalog-$($selected.KB).html"

$kbHtml |
    Set-Content `
        -LiteralPath $catalogDebugFile `
        -Encoding UTF8

Write-Host ""
Write-Host "Catalog HTML saved to:"
Write-Host "  $catalogDebugFile"

# ============================================================
# Find matching KB rows
# ============================================================

$kbRows = [regex]::Matches(
    $kbHtml,
    '<tr[^>]*>(.*?)</tr>',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)

$matchingRows = @()

foreach ($kbRowMatch in $kbRows) {

    $kbRow = $kbRowMatch.Groups[1].Value

    $kbPlain = [System.Net.WebUtility]::HtmlDecode(
        ($kbRow -replace '<[^>]+>', ' ')
    )

    $kbPlain = $kbPlain -replace '\s+', ' '
    $kbPlain = $kbPlain.Trim()

    if ($kbPlain -notmatch [regex]::Escape($selected.KB)) {
        continue
    }

    if ($kbPlain -notmatch '(?i)Windows 11') {
        continue
    }

    if ($kbPlain -notmatch '(?i)version 24H2') {
        continue
    }

    if ($kbPlain -notmatch '(?i)Cumulative Update') {
        continue
    }

    if ($kbPlain -match '(?i)Preview') {
        continue
    }

    if ($kbPlain -match '(?i)\.NET') {
        continue
    }

    if ($kbPlain -match '(?i)Dynamic Update') {
        continue
    }

    if ($kbPlain -match '(?i)Server') {
        continue
    }

    if ($Architecture -eq "x64") {

        if ($kbPlain -notmatch '(?i)x64-based Systems') {
            continue
        }

        if ($kbPlain -match '(?i)ARM64') {
            continue
        }
    }
    elseif ($Architecture -eq "arm64") {

        if ($kbPlain -notmatch '(?i)ARM64-based Systems') {
            continue
        }
    }

    $matchingRows += [pscustomobject]@{
        Row   = $kbRow
        Plain = $kbPlain
    }
}

Write-Host ""
Write-Host "Matching KB rows: $($matchingRows.Count)"

if ($matchingRows.Count -eq 0) {

    throw @"
Could not find a matching Microsoft Catalog row.

KB:
  $($selected.KB)

Architecture:
  $Architecture

Catalog:
  $(Get-CatalogSearchUrl -Query $kbQuery)

Debug HTML:
  $catalogDebugFile
"@
}

# ============================================================
# Extract UpdateID GUIDs
# ============================================================

$updateIds = @()

foreach ($match in $matchingRows) {

    $row = $match.Row

    $guidMatches = [regex]::Matches(
        $row,
        '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
    )

    foreach ($guidMatch in $guidMatches) {

        $guid = $guidMatch.Groups[1].Value

        if ($updateIds -notcontains $guid) {
            $updateIds += $guid
        }
    }
}

# ============================================================
# Fallback: search complete KB page
# ============================================================

if ($updateIds.Count -eq 0) {

    Write-Host ""
    Write-Host "No UpdateID found directly in matching row."
    Write-Host "Searching complete KB page for GUIDs..."

    $allGuidMatches = [regex]::Matches(
        $kbHtml,
        '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
    )

    foreach ($guidMatch in $allGuidMatches) {

        $guid = $guidMatch.Groups[1].Value

        if ($updateIds -notcontains $guid) {
            $updateIds += $guid
        }
    }
}

Write-Host ""
Write-Host "UpdateIDs found: $($updateIds.Count)"

foreach ($updateId in $updateIds) {
    Write-Host "  $updateId"
}

if ($updateIds.Count -eq 0) {

    throw @"
Could not resolve UpdateID for $($selected.KB).

Microsoft Catalog returned the KB, but no UpdateID GUID
could be extracted.

Debug HTML:
  $catalogDebugFile
"@
}

# ============================================================
# IMPORTANT:
# Initialize these BEFORE the loop.
# ============================================================

[string]$selectedUpdateId = $null
[string]$downloadUrl = $null
[string]$fileName = $null

# ============================================================
# Test each UpdateID
# ============================================================

foreach ($updateId in $updateIds) {

    if ([string]::IsNullOrWhiteSpace($updateId)) {
        continue
    }

    Write-Host ""
    Write-Host "Testing UpdateID:"
    Write-Host "  $updateId"

    try {

        $urls = @(Get-CatalogDownloadUrls -UpdateId $updateId)

        if ($urls.Count -eq 0) {

            Write-Host "  No download URLs returned."
            continue
        }

        foreach ($url in $urls) {

            if ([string]::IsNullOrWhiteSpace($url)) {
                continue
            }

            try {

                $candidateFileName = Get-FileNameFromUrl `
                    -Url $url

                Write-Host ""
                Write-Host "  Candidate:"
                Write-Host "    $candidateFileName"

                # ------------------------------------------------
                # Must be MSU
                # ------------------------------------------------

                if ($candidateFileName -notmatch '(?i)\.msu$') {

                    Write-Host "    Rejected: not an MSU."
                    continue
                }

                # ------------------------------------------------
                # Must match selected KB
                # ------------------------------------------------

                if (-not (
                    Test-MsuFileNameMatchesKb `
                        -FileName $candidateFileName `
                        -Kb $selected.KB
                )) {

                    Write-Host `
                        "    Rejected: KB does not match $($selected.KB)."

                    continue
                }

                # ------------------------------------------------
                # Architecture validation
                # ------------------------------------------------

                if ($Architecture -eq "x64") {

                    if ($candidateFileName -notmatch '(?i)(x64|amd64)') {

                        Write-Host `
                            "    Rejected: architecture is not x64."

                        continue
                    }

                    if ($candidateFileName -match '(?i)arm64') {

                        Write-Host `
                            "    Rejected: ARM64 package."

                        continue
                    }
                }

                if ($Architecture -eq "arm64") {

                    if ($candidateFileName -notmatch '(?i)arm64') {

                        Write-Host `
                            "    Rejected: architecture is not ARM64."

                        continue
                    }
                }

                # ------------------------------------------------
                # VALID PACKAGE
                # ------------------------------------------------

                $selectedUpdateId = [string]$updateId
                $downloadUrl = [string]$url
                $fileName = [string]$candidateFileName

                Write-Host ""
                Write-Host "    ACCEPTED"
                Write-Host "    UpdateID : $selectedUpdateId"
                Write-Host "    File     : $fileName"
                Write-Host "    URL      : $downloadUrl"

                break
            }
            catch {

                Write-Host ""
                Write-Host "    Rejected:"
                Write-Host "      $($_.Exception.Message)"
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($selectedUpdateId)) {
            break
        }
    }
    catch {

        Write-Host ""
        Write-Host "  UpdateID failed:"
        Write-Host "    $($_.Exception.Message)"
    }
}

# ============================================================
# Verify resolution
# ============================================================

if ([string]::IsNullOrWhiteSpace($selectedUpdateId)) {

    throw @"
Could not find a Microsoft Update Catalog UpdateID whose
download matches the selected update.

Selected KB:
  $($selected.KB)

Architecture:
  $Architecture

Debug HTML:
  $catalogDebugFile
"@
}

if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
    throw "UpdateID was resolved but download URL is empty."
}

if ([string]::IsNullOrWhiteSpace($fileName)) {
    throw "UpdateID was resolved but package filename is empty."
}

# ============================================================
# Store resolved properties
# ============================================================

$selected |
    Add-Member `
        -MemberType NoteProperty `
        -Name UpdateId `
        -Value $selectedUpdateId `
        -Force

$selected |
    Add-Member `
        -MemberType NoteProperty `
        -Name DownloadUrl `
        -Value $downloadUrl `
        -Force

$selected |
    Add-Member `
        -MemberType NoteProperty `
        -Name FileName `
        -Value $fileName `
        -Force

# ============================================================
# Immutable Artifactory path
# ============================================================

$artifactRelativePath =
    "Windows11/24H2/$Architecture/LCU/$($selected.KB)/$fileName"

$localUpdatePath = Join-Path `
    $UpdatesDir `
    $fileName

Write-Host ""
Write-Host "============================================================"
Write-Host " Artifact"
Write-Host "============================================================"
Write-Host "Relative path:"
Write-Host "  $artifactRelativePath"
Write-Host ""
Write-Host "Local path:"
Write-Host "  $localUpdatePath"
Write-Host "============================================================"
Write-Host ""

# ============================================================
# Obtain package
# ============================================================

$artifactExists = $false

if (![string]::IsNullOrWhiteSpace($ArtifactoryBaseUrl)) {

    $artifactExists = Test-ArtifactoryArtifact `
        -RelativePath $artifactRelativePath
}

if ($artifactExists) {

    Write-Host ""
    Write-Host "Artifact already exists in Artifactory."
    Write-Host "Using immutable cached package."

    Get-ArtifactoryArtifact `
        -RelativePath $artifactRelativePath `
        -Destination $localUpdatePath
}
else {

    Write-Host ""
    Write-Host "Package is not present in Artifactory."
    Write-Host "Downloading from Microsoft Update Catalog."

    Write-Host ""
    Write-Host "Downloading:"
    Write-Host "  $downloadUrl"

    Invoke-WebRequest `
        -Uri $downloadUrl `
        -OutFile $localUpdatePath `
        -UseBasicParsing

    if (!(Test-Path -LiteralPath $localUpdatePath)) {
        throw "Microsoft download failed: $localUpdatePath"
    }

    # --------------------------------------------------------
    # Verify downloaded filename again
    # --------------------------------------------------------

    $actualName = Split-Path `
        -Leaf `
        $localUpdatePath

    if (-not (
        Test-MsuFileNameMatchesKb `
            -FileName $actualName `
            -Kb $selected.KB
    )) {

        Remove-Item `
            -LiteralPath $localUpdatePath `
            -Force `
            -ErrorAction SilentlyContinue

        throw @"
Downloaded package does not match selected KB.

Selected:
  $($selected.KB)

Downloaded:
  $actualName

The package was deleted.
"@
    }

    # --------------------------------------------------------
    # Upload immutable artifact
    # --------------------------------------------------------

    if (![string]::IsNullOrWhiteSpace($ArtifactoryBaseUrl)) {

        Write-Host ""
        Write-Host "Publishing package to immutable Artifactory repository."

        Publish-ArtifactoryArtifact `
            -RelativePath $artifactRelativePath `
            -Source $localUpdatePath

        Write-Host "Published:"
        Write-Host "  $artifactRelativePath"
    }
}

# ============================================================
# Verify local package
# ============================================================

if (!(Test-Path -LiteralPath $localUpdatePath -PathType Leaf)) {

    throw "Resolved update package does not exist: $localUpdatePath"
}

$fileInfo = Get-Item -LiteralPath $localUpdatePath

if ($fileInfo.Length -le 0) {
    throw "Resolved update package is empty: $localUpdatePath"
}

$sha256 = Get-Sha256 `
    -Path $localUpdatePath

Write-Host ""
Write-Host "Package verification:"
Write-Host "  File   : $fileName"
Write-Host "  Size   : $($fileInfo.Length)"
Write-Host "  SHA256 : $sha256"

# ============================================================
# Determine SSU inclusion
# ============================================================

# Modern Windows 11 24H2 LCUs generally contain the servicing
# stack update. Do not require a separate SSU unless a future
# resolver explicitly identifies one.

$ssuIncluded = $true

# ============================================================
# Build resolved update manifest
# ============================================================

$resolvedUpdate = [ordered]@{
    type              = "LCU"
    kb                = $selected.KB
    build             = $selected.Build
    date              = $selected.Date.ToString("yyyy-MM-dd")
    architecture      = $Architecture
    windowsBuild      = [string]$WindowsBuild
    updateId          = $selectedUpdateId
    fileName          = $fileName
    downloadUrl       = $downloadUrl
    artifactPath      = $artifactRelativePath
    sha256            = $sha256
    size              = [int64]$fileInfo.Length
    ssuIncluded       = $ssuIncluded
    source            = "Microsoft Update Catalog"
    resolvedAtUtc     = [DateTime]::UtcNow.ToString("o")
}

$manifest = @(
    $resolvedUpdate
)

$manifestJson = $manifest |
    ConvertTo-Json `
        -Depth 10

$manifestJson |
    Set-Content `
        -LiteralPath $ResolvedFile `
        -Encoding UTF8

# ============================================================
# Verify manifest
# ============================================================

if (!(Test-Path -LiteralPath $ResolvedFile -PathType Leaf)) {
    throw "Failed to create resolved update manifest."
}

Write-Host ""
Write-Host "============================================================"
Write-Host " Resolved Updates Manifest"
Write-Host "============================================================"
Write-Host "File:"
Write-Host "  $ResolvedFile"
Write-Host ""
Write-Host $manifestJson
Write-Host "============================================================"
Write-Host ""

# ============================================================
# Final safety verification
# ============================================================

$verify = Get-Content `
    -LiteralPath $ResolvedFile `
    -Raw |
    ConvertFrom-Json

if ($verify.Count -eq 0) {
    throw "Resolved manifest contains no updates."
}

if ($verify[0].kb -ne $selected.KB) {

    throw @"
Manifest KB mismatch.

Selected:
  $($selected.KB)

Manifest:
  $($verify[0].kb)
"@
}

if ($verify[0].fileName -ne $fileName) {

    throw @"
Manifest filename mismatch.

Resolved:
  $fileName

Manifest:
  $($verify[0].fileName)
"@
}

if ($verify[0].sha256 -ne $sha256) {

    throw @"
Manifest SHA-256 mismatch.

Calculated:
  $sha256

Manifest:
  $($verify[0].sha256)
"@
}

Write-Host ""
Write-Host "============================================================"
Write-Host " Update Resolution Successful"
Write-Host "============================================================"
Write-Host "KB:"
Write-Host "  $($selected.KB)"
Write-Host ""
Write-Host "Build:"
Write-Host "  $($selected.Build)"
Write-Host ""
Write-Host "Architecture:"
Write-Host "  $Architecture"
Write-Host ""
Write-Host "UpdateID:"
Write-Host "  $selectedUpdateId"
Write-Host ""
Write-Host "Package:"
Write-Host "  $fileName"
Write-Host ""
Write-Host "SHA-256:"
Write-Host "  $sha256"
Write-Host ""
Write-Host "Manifest:"
Write-Host "  $ResolvedFile"
Write-Host "============================================================"
Write-Host ""

exit 0