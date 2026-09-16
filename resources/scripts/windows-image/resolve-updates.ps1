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
New-Item -ItemType Directory -Force -Path $updateDir | Out-Null

# ------------------------------------------------------------
# Normalize values
# ------------------------------------------------------------

if ($Architecture -match "(?i)^(amd64|x64)$") {
    $Architecture = "x64"
}
elseif ($Architecture -match "(?i)^arm64$") {
    $Architecture = "arm64"
}
else {
    throw "Unsupported architecture: $Architecture"
}

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

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File not found for SHA-256 calculation: $Path"
    }

    return (
        Get-FileHash `
            -LiteralPath $Path `
            -Algorithm SHA256
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

    if (!$response.Content) {
        throw "Microsoft Update Catalog returned an empty response."
    }

    return $response.Content
}

function Get-CatalogDownloadUrls {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UpdateId
    )

    Write-Host "Resolving Microsoft download URL"
    Write-Host "  UpdateID: $UpdateId"

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

    if (!$response.Content) {
        throw "DownloadDialog returned an empty response for UpdateID $UpdateId"
    }

    $content = $response.Content

    $content = $content.Replace("&amp;", "&")

    $pattern = 'https?://[^"''\s<>]+'

    $matches = [regex]::Matches(
        $content,
        $pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $urls = @()

    foreach ($match in $matches) {

        $url = $match.Value

        $url = $url.TrimEnd(
            "'",
            '"',
            ')',
            ';'
        )

        if (
            $url -match '(?i)download\.windowsupdate\.com' -or
            $url -match '(?i)delivery\.mp\.microsoft\.com' -or
            $url -match '(?i)windowsupdate\.com'
        ) {
            if ($urls -notcontains $url) {
                $urls += $url
            }
        }
    }

    if ($urls.Count -eq 0) {
        throw "No Microsoft download URL found for UpdateID $UpdateId"
    }

    Write-Host "Microsoft download URLs found: $($urls.Count)"

    foreach ($url in $urls) {
        Write-Host "  $url"
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

        if (
            $ArtifactoryUser -and
            $ArtifactoryPassword
        ) {
            $token = [Convert]::ToBase64String(
                [Text.Encoding]::ASCII.GetBytes(
                    "$ArtifactoryUser`:$ArtifactoryPassword"
                )
            )

            $request.Headers["Authorization"] = "Basic $token"
        }

        $response = $request.GetResponse()

        try {
            $response.Close()
        }
        catch {
        }

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

    if (
        $ArtifactoryUser -and
        $ArtifactoryPassword
    ) {
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

    if (!(Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw "Artifactory download failed: $Destination"
    }

    $length = (Get-Item -LiteralPath $Destination).Length

    if ($length -eq 0) {
        throw "Artifactory returned an empty artifact: $Destination"
    }
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

    if (
        $ArtifactoryUser -and
        $ArtifactoryPassword
    ) {
        $token = [Convert]::ToBase64String(
            [Text.Encoding]::ASCII.GetBytes(
                "$ArtifactoryUser`:$ArtifactoryPassword"
            )
        )

        $headers["Authorization"] = "Basic $token"
    }

    # Never overwrite an existing artifact.
    $existing = Find-ArtifactoryFile `
        -RelativePath $RelativePath

    if ($existing) {
        Write-Host "Artifact already exists."
        Write-Host "Immutable repository; not overwriting."

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

function Test-MsuFileNameMatchesKb {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string]$Kb
    )

    $kbNumber = $Kb -replace '(?i)^KB', ''

    $pattern = "(?i)kb$([regex]::Escape($kbNumber))(?:[^0-9]|$)"

    return ($FileName -match $pattern)
}

function Get-MsuMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MsuPath
    )

    if (!(Test-Path -LiteralPath $MsuPath -PathType Leaf)) {
        throw "MSU not found: $MsuPath"
    }

    Write-Host ""
    Write-Host "Reading MSU package metadata:"
    Write-Host "  $MsuPath"

    $tempRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("WindowsImageMSU_" + [guid]::NewGuid().ToString("N"))

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $tempRoot | Out-Null

    try {

        & "$env:SystemRoot\System32\expand.exe" `
            -F:* `
            $MsuPath `
            $tempRoot | Out-Host

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to expand MSU. Exit code: $LASTEXITCODE"
        }

        $cabFiles = @(
            Get-ChildItem `
                -LiteralPath $tempRoot `
                -Recurse `
                -Filter "*.cab" `
                -File
        )

        if ($cabFiles.Count -eq 0) {
            throw "No CAB file found inside MSU: $MsuPath"
        }

        $xmlFiles = @(
            Get-ChildItem `
                -LiteralPath $tempRoot `
                -Recurse `
                -Filter "*.xml" `
                -File
        )

        $packageXml = $xmlFiles |
            Where-Object {
                $_.Name -match '(?i)metadata|package'
            } |
            Select-Object -First 1

        [pscustomobject]@{
            CabFiles    = @($cabFiles)
            XmlFiles    = @($xmlFiles)
            PackageXml  = $packageXml
            ExtractRoot = $tempRoot
        }
    }
    catch {
        Remove-Item `
            -LiteralPath $tempRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

        throw
    }
}

function Test-MsuPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MsuPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedKb,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedArchitecture
    )

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " Validating MSU"
    Write-Host "============================================================"

    $fileName = Split-Path `
        -Leaf `
        $MsuPath

    Write-Host "File:"
    Write-Host "  $fileName"

    # --------------------------------------------------------
    # Filename must contain selected KB.
    # --------------------------------------------------------

    if (!(Test-MsuFileNameMatchesKb `
        -FileName $fileName `
        -Kb $ExpectedKb)) {

        throw @"
MSU validation FAILED.

The downloaded MSU does not match the selected KB.

Expected:
  $ExpectedKb

Actual file:
  $fileName

This indicates that the Microsoft Update Catalog UpdateID
and download URL do not correspond to the selected update.

The image build has been stopped intentionally.
"@
    }

    Write-Host "KB filename validation: PASS"

    # --------------------------------------------------------
    # Architecture must match.
    # --------------------------------------------------------

    if (
        $ExpectedArchitecture -eq "x64" -and
        $fileName -notmatch "(?i)(x64|amd64)"
    ) {
        throw @"
MSU validation FAILED.

Expected x64 package but filename does not indicate x64/amd64:

$fileName
"@
    }

    if (
        $ExpectedArchitecture -eq "arm64" -and
        $fileName -notmatch "(?i)arm64"
    ) {
        throw @"
MSU validation FAILED.

Expected ARM64 package but filename does not indicate ARM64:

$fileName
"@
    }

    Write-Host "Architecture filename validation: PASS"

    # --------------------------------------------------------
    # Validate MSU can be expanded.
    # --------------------------------------------------------

    $metadata = Get-MsuMetadata `
        -MsuPath $MsuPath

    try {

        Write-Host "CAB files inside MSU: $($metadata.CabFiles.Count)"

        foreach ($cab in $metadata.CabFiles) {
            Write-Host "  $($cab.Name)"
        }

        if ($metadata.XmlFiles.Count -gt 0) {

            Write-Host "XML files inside MSU: $($metadata.XmlFiles.Count)"

            foreach ($xml in $metadata.XmlFiles) {
                Write-Host "  $($xml.Name)"
            }
        }

        Write-Host "MSU extraction validation: PASS"

        return $true
    }
    finally {

        if ($metadata.ExtractRoot) {

            Remove-Item `
                -LiteralPath $metadata.ExtractRoot `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

# ------------------------------------------------------------
# Locate base ISO
# ------------------------------------------------------------

$baseIso = Join-Path `
    $downloadDir `
    "base.iso"

if (!(Test-Path -LiteralPath $baseIso -PathType Leaf)) {
    throw "Base ISO not found: $baseIso"
}

Write-Host "Base ISO:"
Write-Host "  $baseIso"
Write-Host ""

# ------------------------------------------------------------
# Locate install.wim if extraction already happened.
# ------------------------------------------------------------

$sourceDir = Join-Path `
    $WorkRoot `
    "source"

$wimPath = Join-Path `
    $sourceDir `
    "sources\install.wim"

if (Test-Path -LiteralPath $wimPath -PathType Leaf) {

    Write-Host "Found install.wim:"
    Write-Host "  $wimPath"

    try {

        $wimInfo = & "$env:SystemRoot\System32\dism.exe" `
            "/Get-WimInfo" `
            "/WimFile:$wimPath" `
            2>&1

        Write-Host ($wimInfo -join [Environment]::NewLine)

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Unable to query WIM information."
        }
    }
    catch {
        Write-Warning "Unable to query WIM information: $($_.Exception.Message)"
    }
}
else {

    Write-Host "install.wim is not extracted yet."
    Write-Host "Using supplied WindowsBuild/Architecture."
}

# ------------------------------------------------------------
# Microsoft Update Catalog search
# ------------------------------------------------------------

$query = "Windows 11 24H2 cumulative update $Architecture"

Write-Host ""
Write-Host "============================================================"
Write-Host " Searching Microsoft Update Catalog"
Write-Host "============================================================"
Write-Host "Query:"
Write-Host "  $query"
Write-Host ""

$html = Get-CatalogPage `
    -Query $query

# ------------------------------------------------------------
# Parse Catalog rows.
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

    if ($plain -match '(?i)\.NET') {
        continue
    }

    if ($plain -match '(?i)Dynamic Update') {
        continue
    }

    if ($plain -match '(?i)Preview') {
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

    $buildMatch = [regex]::Match(
        $plain,
        '\((26100\.\d+)\)'
    )

    $build = ""

    if ($buildMatch.Success) {
        $build = $buildMatch.Groups[1].Value
    }

    # --------------------------------------------------------
    # Date
    # --------------------------------------------------------

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
    else {

        $date = [datetime]::MinValue
    }

    # --------------------------------------------------------
    # UpdateID
    #
    # Only accept a GUID from this exact row.
    # --------------------------------------------------------

    $guidMatches = [regex]::Matches(
        $row,
        '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
    )

    if ($guidMatches.Count -eq 0) {
        continue
    }

    $updateId = $null

    foreach ($guidMatch in $guidMatches) {

        $guid = $guidMatch.Groups[1].Value

        $start = [Math]::Max(
            0,
            $guidMatch.Index - 500
        )

        $length = [Math]::Min(
            1000,
            $row.Length - $start
        )

        $context = $row.Substring(
            $start,
            $length
        )

        if (
            $context -match '(?i)updateID' -or
            $context -match '(?i)updateId' -or
            $context -match '(?i)uidInfo'
        ) {

            $updateId = $guid

            break
        }
    }

    # If there is exactly one GUID in the row,
    # use it.

    if (
        !$updateId -and
        $guidMatches.Count -eq 1
    ) {

        $updateId = $guidMatches[0].Groups[1].Value
    }

    if (!$updateId) {

        Write-Warning `
            "Skipping KB $kb because UpdateID could not be unambiguously determined."

        continue
    }

    $candidates += [pscustomobject]@{
        KB       = $kb
        Build    = $build
        Date     = $date
        UpdateId = $updateId
        Title    = $plain
    }
}

# ------------------------------------------------------------
# Remove duplicate KB/UpdateID combinations.
# ------------------------------------------------------------

$candidates = @(
    $candidates |
        Sort-Object KB, UpdateId -Unique
)

if ($candidates.Count -eq 0) {

    throw `
        "Could not find a Windows 11 24H2 $Architecture LCU in Microsoft Update Catalog."
}

Write-Host ""
Write-Host "Catalog candidates found: $($candidates.Count)"
Write-Host ""

foreach ($candidate in $candidates) {

    Write-Host (
        "  {0} | {1} | {2} | {3}" -f
        $candidate.KB,
        $candidate.Build,
        $candidate.Date.ToString("yyyy-MM-dd"),
        $candidate.UpdateId
    )
}

# ------------------------------------------------------------
# Select newest release.
# ------------------------------------------------------------

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
Write-Host "UpdateID : $($selected.UpdateId)"
Write-Host "Title    : $($selected.Title)"
Write-Host ""

# ------------------------------------------------------------
# Resolve Microsoft download URLs.
# ------------------------------------------------------------

$downloadUrls = Get-CatalogDownloadUrls `
    -UpdateId $selected.UpdateId

# ------------------------------------------------------------
# Find an MSU whose filename matches BOTH:
#
#   selected KB
#   selected architecture
#
# Never blindly take the first URL.
# ------------------------------------------------------------

$downloadUrl = $null
$fileName = $null

foreach ($url in $downloadUrls) {

    try {

        $candidateFileName = Get-FileNameFromUrl `
            -Url $url

        Write-Host "Checking download candidate:"
        Write-Host "  $candidateFileName"

        if (
            $candidateFileName -notmatch '(?i)\.msu$'
        ) {

            Write-Host "  Rejected: not an MSU."

            continue
        }

        if (!(Test-MsuFileNameMatchesKb `
            -FileName $candidateFileName `
            -Kb $selected.KB)) {

            Write-Host `
                "  Rejected: KB does not match $($selected.KB)."

            continue
        }

        if (
            $Architecture -eq "x64" -and
            $candidateFileName -notmatch '(?i)(x64|amd64)'
        ) {

            Write-Host `
                "  Rejected: architecture does not match x64."

            continue
        }

        if (
            $Architecture -eq "arm64" -and
            $candidateFileName -notmatch '(?i)arm64'
        ) {

            Write-Host `
                "  Rejected: architecture does not match arm64."

            continue
        }

        $downloadUrl = $url
        $fileName = $candidateFileName

        Write-Host "  ACCEPTED"

        break
    }
    catch {

        Write-Host `
            "  Rejected: $($_.Exception.Message)"
    }
}

if (!$downloadUrl) {

    throw @"
Could not find an MSU download URL matching the selected update.

Selected KB:
  $($selected.KB)

Selected UpdateID:
  $($selected.UpdateId)

Architecture:
  $Architecture

Microsoft returned:
$($downloadUrls -join "`n")
"@
}

Write-Host ""
Write-Host "Selected Microsoft package:"
Write-Host "  File : $fileName"
Write-Host "  URL  : $downloadUrl"
Write-Host ""

# ------------------------------------------------------------
# Artifactory path
# ------------------------------------------------------------

$relativePath =
    "Windows11/24H2/$Architecture/LCU/$($selected.KB)/$fileName"

$localPackage = Join-Path `
    $updateDir `
    $fileName

$artifactUrl = $null

# ------------------------------------------------------------
# Check Artifactory first.
# ------------------------------------------------------------

$artifactUrl = Find-ArtifactoryFile `
    -RelativePath $relativePath

if ($artifactUrl) {

    Write-Host ""
    Write-Host "Found LCU in Artifactory:"
    Write-Host "  $artifactUrl"

    Download-ArtifactoryFile `
        -Url $artifactUrl `
        -Destination $localPackage
}
else {

    Write-Host ""
    Write-Host "LCU is not cached in Artifactory."
    Write-Host "Downloading from Microsoft..."
    Write-Host ""

    Invoke-WebRequest `
        -Uri $downloadUrl `
        -OutFile $localPackage `
        -UseBasicParsing `
        -TimeoutSec 3600

    if (!(Test-Path -LiteralPath $localPackage -PathType Leaf)) {
        throw "Microsoft download failed: $localPackage"
    }

    $length = (
        Get-Item -LiteralPath $localPackage
    ).Length

    if ($length -eq 0) {
        throw "Microsoft download produced an empty file: $localPackage"
    }

    Write-Host "Downloaded:"
    Write-Host "  $localPackage"
    Write-Host "  Size: $length bytes"

    if ($ArtifactoryBaseUrl) {

        $artifactUrl = Upload-ArtifactoryFile `
            -Source $localPackage `
            -RelativePath $relativePath
    }
}

# ------------------------------------------------------------
# Validate downloaded/cached MSU.
#
# This catches:
#
# Selected KB5129195
# downloaded KB5043080
# ------------------------------------------------------------

Test-MsuPackage `
    -MsuPath $localPackage `
    -ExpectedKb $selected.KB `
    -ExpectedArchitecture $Architecture |
    Out-Null

# ------------------------------------------------------------
# SHA-256
# ------------------------------------------------------------

$sha256 = Get-Sha256 `
    -Path $localPackage

Write-Host ""
Write-Host "SHA-256:"
Write-Host "  $sha256"
Write-Host ""

# ------------------------------------------------------------
# Current Windows 11 24H2 servicing behavior:
#
# The LCU includes the required SSU.
#
# Therefore resolve one package.
# ------------------------------------------------------------

$resolved = @(
    [pscustomobject]@{
        type            = "LCU"
        kb              = $selected.KB
        build           = $selected.Build
        architecture    = $Architecture
        windowsVersion  = "Windows 11 24H2"
        fileName        = $fileName
        sha256          = $sha256
        microsoftUrl    = $downloadUrl
        artifactoryUrl  = $artifactUrl
        artifactoryPath = $relativePath
        updateId        = $selected.UpdateId
        releaseDate     = $selected.Date.ToString("yyyy-MM-dd")
        ssuIncluded     = $true
        resolvedAtUtc   = [datetime]::UtcNow.ToString("o")
    }
)

# ------------------------------------------------------------
# Write manifest.
# ------------------------------------------------------------

$resolved |
    ConvertTo-Json -Depth 10 |
    Set-Content `
        -LiteralPath $manifest `
        -Encoding UTF8

if (!(Test-Path -LiteralPath $manifest -PathType Leaf)) {
    throw "Failed to create resolved update manifest: $manifest"
}

# ------------------------------------------------------------
# Validate manifest.
# ------------------------------------------------------------

try {

    $manifestObject = Get-Content `
        -LiteralPath $manifest `
        -Raw |
        ConvertFrom-Json

    if ($null -eq $manifestObject) {
        throw "Manifest contains no updates."
    }

    $manifestUpdate = @($manifestObject)[0]

    if ($manifestUpdate.kb -ne $selected.KB) {
        throw "Manifest KB mismatch."
    }

    if ($manifestUpdate.fileName -ne $fileName) {
        throw "Manifest filename mismatch."
    }

    if (
        $manifestUpdate.sha256.ToLowerInvariant() -ne
        $sha256.ToLowerInvariant()
    ) {
        throw "Manifest SHA-256 mismatch."
    }

    if ($manifestUpdate.updateId -ne $selected.UpdateId) {
        throw "Manifest UpdateID mismatch."
    }
}
catch {

    throw `
        "Manifest validation failed: $($_.Exception.Message)"
}

# ------------------------------------------------------------
# Final output
# ------------------------------------------------------------

Write-Host ""
Write-Host "============================================================"
Write-Host " Update resolution complete"
Write-Host "============================================================"
Write-Host ""
Write-Host "Selected LCU:"
Write-Host "  KB           : $($selected.KB)"
Write-Host "  Build        : $($selected.Build)"
Write-Host "  Architecture : $Architecture"
Write-Host "  Release      : $($selected.Date.ToString('yyyy-MM-dd'))"
Write-Host "  UpdateID     : $($selected.UpdateId)"
Write-Host ""
Write-Host "Package:"
Write-Host "  File         : $fileName"
Write-Host "  SHA-256      : $sha256"
Write-Host ""
Write-Host "Microsoft:"
Write-Host "  URL          : $downloadUrl"
Write-Host ""
Write-Host "Artifactory:"
Write-Host "  URL          : $artifactUrl"
Write-Host "  Path         : $relativePath"
Write-Host ""
Write-Host "SSU:"
Write-Host "  Included in LCU: YES"
Write-Host ""
Write-Host "Manifest:"
Write-Host "  $manifest"
Write-Host ""
Write-Host "============================================================"
Write-Host " Resolved manifest"
Write-Host "============================================================"

Get-Content `
    -LiteralPath $manifest