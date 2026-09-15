[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [Parameter(Mandatory = $false)]
    [string]$WindowsBuild = "26100",

    [Parameter(Mandatory = $false)]
    [string]$Architecture = "x64",

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryBaseUrl = "",

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryRepo = "windows-updates",

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryUser = "",

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryPassword = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host "============================================================"
Write-Host " Windows Image Update Resolver"
Write-Host "============================================================"
Write-Host "WorkRoot       : $WorkRoot"
Write-Host "WindowsBuild   : $WindowsBuild"
Write-Host "Architecture   : $Architecture"
Write-Host "Artifactory    : $ArtifactoryBaseUrl"
Write-Host "Repository     : $ArtifactoryRepo"
Write-Host ""

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

$downloadDir = Join-Path $WorkRoot "download"
$updateDir   = Join-Path $downloadDir "updates"
$manifest    = Join-Path $downloadDir "resolved-updates.json"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
New-Item -ItemType Directory -Force -Path $updateDir   | Out-Null

# ------------------------------------------------------------
# Normalize values
# ------------------------------------------------------------

if ($Architecture -match "amd64|AMD64|x64") {
    $Architecture = "x64"
}
elseif ($Architecture -match "arm64|ARM64") {
    $Architecture = "arm64"
}
else {
    throw "Unsupported architecture: $Architecture"
}

# Windows 11 24H2 client build family
if ($WindowsBuild -notmatch "^26100") {
    Write-Warning "WindowsBuild '$WindowsBuild' is not the normal Windows 11 24H2 build family (26100)."
}

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (
        Get-FileHash -LiteralPath $Path -Algorithm SHA256
    ).Hash.ToLowerInvariant()
}

function Get-CatalogSearchUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    return "https://www.catalog.update.microsoft.com/Search.aspx?q=$(
        [uri]::EscapeDataString($Query)
    )"
}

function Get-CatalogPage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $url = Get-CatalogSearchUrl -Query $Query

    Write-Host "Microsoft Update Catalog:"
    Write-Host "  $url"

    $response = Invoke-WebRequest `
        -Uri $url `
        -UseBasicParsing `
        -TimeoutSec 120

    return $response.Content
}

function Get-CatalogDownloadUrls {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UpdateId
    )

    Write-Host "Getting Microsoft download URL for UpdateID:"
    Write-Host "  $UpdateId"

    $post = @{
        size     = 0
        updateID = $UpdateId
        uidInfo  = $UpdateId
    } | ConvertTo-Json -Compress

    $body = @{
        updateIDs = "[$post]"
    }

    $response = Invoke-WebRequest `
        -Uri "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" `
        -Method Post `
        -Body $body `
        -ContentType "application/x-www-form-urlencoded" `
        -UseBasicParsing `
        -TimeoutSec 120

    $content = $response.Content

    # Extract Microsoft download URLs.
    $pattern = 'https?://[^"''\s<>]+'

    $matches = [regex]::Matches(
        $content,
        $pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $urls = @()

    foreach ($match in $matches) {

        $url = $match.Value

        $url = $url.Replace(
            '&amp;',
            '&'
        )

        $url = $url.TrimEnd(
            "'",
            '"',
            ')',
            ';'
        )

        if (
            $url -match 'download\.windowsupdate\.com' -or
            $url -match 'delivery\.mp\.microsoft\.com' -or
            $url -match 'windowsupdate\.com'
        ) {
            if ($urls -notcontains $url) {
                $urls += $url
            }
        }
    }

    if ($urls.Count -eq 0) {
        throw "No Microsoft download URL found for UpdateID $UpdateId"
    }

    return $urls
}
function Get-FileNameFromUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $uri = [System.Uri]$Url

    $name = [System.IO.Path]::GetFileName(
        $uri.AbsolutePath
    )

    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "Could not determine file name from URL: $Url"
    }

    return $name
}

function Find-ArtifactoryFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($ArtifactoryBaseUrl)) {
        return $null
    }

    $base = $ArtifactoryBaseUrl.TrimEnd("/")
    $url  = "$base/$ArtifactoryRepo/$RelativePath"

    try {
        $request = [System.Net.WebRequest]::Create($url)
        $request.Method = "HEAD"

        if ($ArtifactoryUser -and $ArtifactoryPassword) {
            $token = [Convert]::ToBase64String(
                [Text.Encoding]::ASCII.GetBytes(
                    "$ArtifactoryUser`:$ArtifactoryPassword"
                )
            )

            $request.Headers["Authorization"] = "Basic $token"
        }

        $response = $request.GetResponse()
        $response.Close()

        return $url
    }
    catch {
        return $null
    }
}

function Download-ArtifactoryFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    Write-Host "Downloading cached artifact:"
    Write-Host "  $Url"

    $headers = @{}

    if ($ArtifactoryUser -and $ArtifactoryPassword) {
        $token = [Convert]::ToBase64String(
            [Text.Encoding]::ASCII.GetBytes(
                "$ArtifactoryUser`:$ArtifactoryPassword"
            )
        )

        $headers["Authorization"] = "Basic $token"
    }

    Invoke-WebRequest `
        -Uri $Url `
        -OutFile $Destination `
        -Headers $headers `
        -UseBasicParsing `
        -TimeoutSec 1800
}

function Upload-ArtifactoryFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($ArtifactoryBaseUrl)) {
        throw "ArtifactoryBaseUrl is required when an update is not already cached."
    }

    $base = $ArtifactoryBaseUrl.TrimEnd("/")
    $url  = "$base/$ArtifactoryRepo/$RelativePath"

    Write-Host "Publishing immutable update:"
    Write-Host "  $url"

    $headers = @{}

    if ($ArtifactoryUser -and $ArtifactoryPassword) {
        $token = [Convert]::ToBase64String(
            [Text.Encoding]::ASCII.GetBytes(
                "$ArtifactoryUser`:$ArtifactoryPassword"
            )
        )

        $headers["Authorization"] = "Basic $token"
    }

    # Do not overwrite an existing artifact.
    $existing = Find-ArtifactoryFile -RelativePath $RelativePath

    if ($existing) {
        Write-Host "Artifact already exists. Immutable repository; not overwriting."
        return $existing
    }

    Invoke-WebRequest `
        -Uri $url `
        -Method Put `
        -InFile $Source `
        -Headers $headers `
        -ContentType "application/octet-stream" `
        -UseBasicParsing `
        -TimeoutSec 3600

    return $url
}

# ------------------------------------------------------------
# Locate install.wim
# ------------------------------------------------------------

$baseIso = Join-Path $downloadDir "base.iso"

if (!(Test-Path -LiteralPath $baseIso -PathType Leaf)) {
    throw "Base ISO not found: $baseIso"
}

$sourceDir = Join-Path $WorkRoot "source"
$wimPath   = Join-Path $sourceDir "sources\install.wim"

if (!(Test-Path -LiteralPath $wimPath -PathType Leaf)) {
    Write-Host "install.wim is not extracted yet."
    Write-Host "Update resolver will use the supplied WindowsBuild/Architecture."
}
else {
    Write-Host "Found install.wim:"
    Write-Host "  $wimPath"
}

# ------------------------------------------------------------
# Search Microsoft Update Catalog
#
# We intentionally search for the LCU rather than a specific KB.
# This allows future builds to automatically pick up the newest
# release.
# ------------------------------------------------------------

$query = "Windows 11 24H2 cumulative update $Architecture"

Write-Host ""
Write-Host "Searching Microsoft Update Catalog:"
Write-Host "  $query"
Write-Host ""

$html = Get-CatalogPage -Query $query

# ------------------------------------------------------------
# Parse Catalog rows.
#
# We look specifically for:
#
#   Windows 11, version 24H2
#   x64-based Systems
#   Cumulative Update
#   Security Updates
#
# Preview updates are deliberately excluded.
# .NET updates are excluded.
# Dynamic Updates are excluded.
# Server updates are excluded.
# ARM64 is excluded for x64.
# ------------------------------------------------------------

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

    if ($plain -notmatch 'Windows 11') {
        continue
    }

    if ($plain -notmatch 'version 24H2') {
        continue
    }

    if ($plain -notmatch 'Cumulative Update') {
        continue
    }

    if ($plain -notmatch 'x64-based Systems') {
        continue
    }

    if ($plain -match 'arm64') {
        continue
    }

    if ($plain -match 'Cumulative Update for .*\.NET') {
        continue
    }

    if ($plain -match 'Dynamic Update') {
        continue
    }

    if ($plain -match 'Preview') {
        continue
    }

    if ($plain -notmatch 'Security Updates') {
        continue
    }

    # KB
    $kbMatch = [regex]::Match(
        $plain,
        '\(KB(\d+)\)'
    )

    if (!$kbMatch.Success) {
        continue
    }

    $kb = "KB$($kbMatch.Groups[1].Value)"

    # Build
    $buildMatch = [regex]::Match(
        $plain,
        '\((26100\.\d+)\)'
    )

    $build = ""

    if ($buildMatch.Success) {
        $build = $buildMatch.Groups[1].Value
    }

    # Date
    $dateMatch = [regex]::Match(
        $plain,
        '(\d{1,2}/\d{1,2}/\d{4})'
    )

    $date = $null

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
    else {
        $date = [datetime]::MinValue
    }

    # Find UpdateID GUID in the row.
    $guidMatch = [regex]::Match(
        $row,
        '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
    )

    if (!$guidMatch.Success) {
        continue
    }

    $updateId = $guidMatch.Groups[1].Value

    $candidates += [pscustomobject]@{
        KB          = $kb
        Build       = $build
        Date        = $date
        UpdateId    = $updateId
        Title       = $plain
    }
}

if ($candidates.Count -eq 0) {
    throw "Could not find a Windows 11 24H2 x64 LCU in Microsoft Update Catalog."
}

# Newest date, then highest build.
$selected = $candidates |
    Sort-Object `
        @{ Expression = { $_.Date }; Descending = $true }, `
        @{ Expression = {
            if ($_.Build) {
                [version]$_.Build
            }
            else {
                [version]"0.0"
            }
        }; Descending = $true } |
    Select-Object -First 1

Write-Host ""
Write-Host "Selected LCU:"
Write-Host "  KB       : $($selected.KB)"
Write-Host "  Build    : $($selected.Build)"
Write-Host "  Date     : $($selected.Date.ToString('yyyy-MM-dd'))"
Write-Host "  UpdateID : $($selected.UpdateId)"
Write-Host "  Title    : $($selected.Title)"
Write-Host ""

# ------------------------------------------------------------
# Determine download URL
# ------------------------------------------------------------

$downloadUrls = Get-CatalogDownloadUrls `
    -UpdateId $selected.UpdateId

# Prefer MSU.
$downloadUrl = $downloadUrls |
    Where-Object { $_ -match '\.msu($|\?)' } |
    Select-Object -First 1

if (!$downloadUrl) {
    $downloadUrl = $downloadUrls | Select-Object -First 1
}

$fileName = Get-FileNameFromUrl -Url $downloadUrl

Write-Host "Microsoft package:"
Write-Host "  File : $fileName"
Write-Host "  URL  : $downloadUrl"
Write-Host ""

# ------------------------------------------------------------
# Artifactory path
#
# Immutable:
#
# windows-updates/
#   Windows11/
#     24H2/
#       x64/
#         LCU/
#           KB5129195/
#             windows11.0-kb5129195-x64.msu
# ------------------------------------------------------------

$relativePath = "Windows11/24H2/$Architecture/LCU/$($selected.KB)/$fileName"

$localPackage = Join-Path $updateDir $fileName

# ------------------------------------------------------------
# Check Artifactory first
# ------------------------------------------------------------

$artifactUrl = Find-ArtifactoryFile `
    -RelativePath $relativePath

if ($artifactUrl) {

    Write-Host "Found LCU in Artifactory."
    Write-Host "  $artifactUrl"

    Download-ArtifactoryFile `
        -Url $artifactUrl `
        -Destination $localPackage
}
else {

    Write-Host "LCU is not cached."
    Write-Host "Downloading from Microsoft..."

    Invoke-WebRequest `
        -Uri $downloadUrl `
        -OutFile $localPackage `
        -UseBasicParsing `
        -TimeoutSec 3600

    if (!(Test-Path -LiteralPath $localPackage -PathType Leaf)) {
        throw "Microsoft download failed: $localPackage"
    }

    if ((Get-Item -LiteralPath $localPackage).Length -eq 0) {
        throw "Microsoft download produced an empty file: $localPackage"
    }

    Write-Host "Downloaded:"
    Write-Host "  $localPackage"

    if ($ArtifactoryBaseUrl) {

        $artifactUrl = Upload-ArtifactoryFile `
            -Source $localPackage `
            -RelativePath $relativePath
    }
}

# ------------------------------------------------------------
# Verify SHA256
# ------------------------------------------------------------

$sha256 = Get-Sha256 -Path $localPackage

Write-Host ""
Write-Host "SHA-256:"
Write-Host "  $sha256"
Write-Host ""

# ------------------------------------------------------------
# Current Windows 11 24H2 behavior:
#
# The current LCU includes the required SSU.
#
# Therefore the manifest deliberately contains ONE package.
# service-image.ps1 will apply it as LCU.
#
# Do NOT invent a second SSU MSU.
# ------------------------------------------------------------

$resolved = @(
    [pscustomobject]@{
        type              = "LCU"
        kb                = $selected.KB
        build             = $selected.Build
        architecture      = $Architecture
        windowsVersion    = "Windows 11 24H2"
        fileName          = $fileName
        sha256            = $sha256
        microsoftUrl      = $downloadUrl
        artifactoryUrl    = $artifactUrl
        artifactoryPath   = $relativePath
        updateId          = $selected.UpdateId
        releaseDate       = $selected.Date.ToString("yyyy-MM-dd")
        ssuIncluded       = $true
        resolvedAtUtc     = [datetime]::UtcNow.ToString("o")
    }
)

$resolved |
    ConvertTo-Json -Depth 10 |
    Set-Content `
        -LiteralPath $manifest `
        -Encoding UTF8

# ------------------------------------------------------------
# Verify manifest
# ------------------------------------------------------------

if (!(Test-Path -LiteralPath $manifest -PathType Leaf)) {
    throw "Failed to create resolved update manifest: $manifest"
}

Write-Host ""
Write-Host "============================================================"
Write-Host " Update resolution complete"
Write-Host "============================================================"
Write-Host "Manifest:"
Write-Host "  $manifest"
Write-Host ""
Write-Host "Package:"
Write-Host "  $localPackage"
Write-Host ""
Write-Host "Selected:"
Write-Host "  $($selected.KB)"
Write-Host "  Build $($selected.Build)"
Write-Host ""
Write-Host "SSU:"
Write-Host "  Included in LCU: YES"
Write-Host ""

Get-Content -LiteralPath $manifest