[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [Parameter(Mandatory = $false)]
    [string]$WindowsBuild = "26100",

    [Parameter(Mandatory = $false)]
    [ValidateSet("x64", "amd64", "arm64")]
    [string]$Architecture = "x64",

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryBaseUrl = "",

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryRepo = "windows-updates",

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryUser = "",

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryPassword = "",

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryToken = "",

    [Parameter(Mandatory = $false)]
    [switch]$ForceMicrosoftDownload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================================
# Normalize
# ============================================================================

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
    Write-Warning `
        "WindowsBuild '$WindowsBuild' is outside the normal Windows 11 24H2 build family (26100)."
}

# ============================================================================
# Paths
# ============================================================================

$downloadDir = Join-Path $WorkRoot "download"
$updateDir   = Join-Path $downloadDir "updates"
$manifest    = Join-Path $downloadDir "resolved-updates.json"
$logDir      = Join-Path $WorkRoot "logs"

New-Item `
    -ItemType Directory `
    -Force `
    -Path $downloadDir, $updateDir, $logDir |
    Out-Null

$logFile = Join-Path `
    $logDir `
    "resolve-updated-$(
        Get-Date -Format 'yyyyMMdd-HHmmss'
    ).log"

# ============================================================================
# Logging
# ============================================================================

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $line = "[$timestamp] [$Level] $Message"

    Write-Host $line

    Add-Content `
        -LiteralPath $logFile `
        -Value $line
}

function Write-Section {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    Write-Log ""
    Write-Log "============================================================"
    Write-Log " $Title"
    Write-Log "============================================================"
}

# ============================================================================
# Header
# ============================================================================

Write-Section "Windows Image Update Resolver"

Write-Log "WorkRoot       : $WorkRoot"
Write-Log "WindowsBuild   : $WindowsBuild"
Write-Log "Architecture   : $Architecture"
Write-Log "Artifactory    : $ArtifactoryBaseUrl"
Write-Log "Repository     : $ArtifactoryRepo"
Write-Log "Force Download : $ForceMicrosoftDownload"
Write-Log "Manifest       : $manifest"
Write-Log "Log            : $logFile"

# ============================================================================
# HTTP helpers
# ============================================================================

function Get-ArtifactoryHeaders {

    $headers = @{}

    if (-not [string]::IsNullOrWhiteSpace($ArtifactoryToken)) {

        $headers["Authorization"] = "Bearer $ArtifactoryToken"

        return $headers
    }

    if (
        -not [string]::IsNullOrWhiteSpace($ArtifactoryUser) -and
        -not [string]::IsNullOrWhiteSpace($ArtifactoryPassword)
    ) {

        $encoded = [Convert]::ToBase64String(
            [Text.Encoding]::ASCII.GetBytes(
                "$ArtifactoryUser`:$ArtifactoryPassword"
            )
        )

        $headers["Authorization"] = "Basic $encoded"
    }

    return $headers
}

function Get-ArtifactoryUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($ArtifactoryBaseUrl)) {
        return $null
    }

    $base = $ArtifactoryBaseUrl.TrimEnd("/")

    $relative = $RelativePath.TrimStart("/")

    return "$base/$ArtifactoryRepo/$relative"
}

# ============================================================================
# SHA-256
# ============================================================================

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File not found: $Path"
    }

    return (
        Get-FileHash `
            -LiteralPath $Path `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()
}

# ============================================================================
# Microsoft Update Catalog
# ============================================================================

function Get-CatalogSearchUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    return (
        "https://www.catalog.update.microsoft.com/Search.aspx?q=" +
        [uri]::EscapeDataString($Query)
    )
}

function Get-CatalogPage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $url = Get-CatalogSearchUrl -Query $Query

    Write-Log "Microsoft Update Catalog query:"
    Write-Log "  $Query"
    Write-Log "  $url"

    $response = Invoke-WebRequest `
        -Uri $url `
        -UseBasicParsing `
        -TimeoutSec 120

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        throw "Microsoft Update Catalog returned an empty response."
    }

    return $response.Content
}

function Get-CatalogDownloadUrls {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UpdateId
    )

    Write-Log "Resolving Catalog download URLs"
    Write-Log "UpdateID: $UpdateId"

    $updateObject = @{
        size     = 0
        updateID = $UpdateId
        uidInfo  = $UpdateId
    } | ConvertTo-Json -Compress

    $body = @{
        updateIDs = "[$updateObject]"
    }

    $response = Invoke-WebRequest `
        -Uri "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" `
        -Method Post `
        -Body $body `
        -ContentType "application/x-www-form-urlencoded" `
        -UseBasicParsing `
        -TimeoutSec 120

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        throw "DownloadDialog returned an empty response."
    }

    $content = $response.Content.Replace("&amp;", "&")

    $pattern = 'https?://[^"''\s<>]+'

    $matches = [regex]::Matches(
        $content,
        $pattern,
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $urls = New-Object System.Collections.Generic.List[string]

    foreach ($match in $matches) {

        $url = $match.Value.TrimEnd(
            "'",
            '"',
            ')',
            ';'
        )

        if (
            $url -match "(?i)download\.windowsupdate\.com" -or
            $url -match "(?i)delivery\.mp\.microsoft\.com" -or
            $url -match "(?i)windowsupdate\.com"
        ) {

            if (-not $urls.Contains($url)) {
                $urls.Add($url)
            }
        }
    }

    if ($urls.Count -eq 0) {
        throw "No Microsoft download URLs found for UpdateID $UpdateId."
    }

    foreach ($url in $urls) {
        Write-Log "Catalog URL: $url"
    }

    return @($urls)
}

# ============================================================================
# URL filename
# ============================================================================

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
        throw "Unable to determine filename from URL: $Url"
    }

    return $name
}

# ============================================================================
# KB / architecture validation
# ============================================================================

function Test-MsuFileNameMatchesKb {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string]$Kb
    )

    $kbNumber = $Kb -replace "(?i)^KB", ""

    $pattern = "(?i)kb$([regex]::Escape($kbNumber))(?:[^0-9]|$)"

    return $FileName -match $pattern
}

function Test-MsuFileNameMatchesArchitecture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedArchitecture
    )

    if ($ExpectedArchitecture -eq "x64") {
        return $FileName -match "(?i)(x64|amd64)"
    }

    if ($ExpectedArchitecture -eq "arm64") {
        return $FileName -match "(?i)arm64"
    }

    return $false
}

# ============================================================================
# Artifactory existence
# ============================================================================

function Find-ArtifactoryFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $url = Get-ArtifactoryUrl -RelativePath $RelativePath

    if (-not $url) {
        return $null
    }

    $headers = Get-ArtifactoryHeaders

    Write-Log "Checking Artifactory:"
    Write-Log "  $url"

    try {

        $response = Invoke-WebRequest `
            -Uri $url `
            -Method Head `
            -Headers $headers `
            -UseBasicParsing `
            -TimeoutSec 60

        if (
            $response.StatusCode -ge 200 -and
            $response.StatusCode -lt 300
        ) {
            return $url
        }

        return $null
    }
    catch {

        if (
            $_.Exception.Response -and
            $_.Exception.Response.StatusCode.value__ -eq 404
        ) {
            return $null
        }

        Write-Log `
            "Artifactory HEAD failed: $($_.Exception.Message)" `
            "WARN"

        return $null
    }
}

# ============================================================================
# Artifactory download
# ============================================================================

function Download-ArtifactoryFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    Write-Log "Downloading cached Artifactory artifact"
    Write-Log "  URL         : $Url"
    Write-Log "  Destination : $Destination"

    $headers = Get-ArtifactoryHeaders

    Invoke-WebRequest `
        -Uri $Url `
        -OutFile $Destination `
        -Headers $headers `
        -UseBasicParsing `
        -TimeoutSec 3600

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw "Artifactory download did not create: $Destination"
    }

    $length = (
        Get-Item -LiteralPath $Destination
    ).Length

    if ($length -le 0) {
        throw "Artifactory returned an empty file: $Destination"
    }

    Write-Log "Downloaded $length bytes from Artifactory."
}

# ============================================================================
# Artifactory upload
# ============================================================================

function Upload-ArtifactoryFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $url = Get-ArtifactoryUrl -RelativePath $RelativePath

    if (-not $url) {
        throw "ArtifactoryBaseUrl is required for publishing."
    }

    # ------------------------------------------------------------------------
    # Double-check immediately before upload.
    # ------------------------------------------------------------------------

    $existing = Find-ArtifactoryFile `
        -RelativePath $RelativePath

    if ($existing) {

        Write-Log "Artifact already exists."
        Write-Log "Repository is immutable; upload skipped."

        return $existing
    }

    $headers = Get-ArtifactoryHeaders

    Write-Log "Publishing immutable artifact:"
    Write-Log "  $url"

    Invoke-WebRequest `
        -Uri $url `
        -Method Put `
        -InFile $Source `
        -Headers $headers `
        -ContentType "application/octet-stream" `
        -UseBasicParsing `
        -TimeoutSec 3600

    # ------------------------------------------------------------------------
    # Verify artifact exists after upload.
    # ------------------------------------------------------------------------

    $verified = Find-ArtifactoryFile `
        -RelativePath $RelativePath

    if (-not $verified) {
        throw "Artifact upload could not be verified: $url"
    }

    return $verified
}

# ============================================================================
# Expand / validate MSU
# ============================================================================

function Test-MsuPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MsuPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedKb,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedArchitecture
    )

    Write-Section "Validate MSU"

    $fileName = Split-Path `
        -Leaf `
        $MsuPath

    Write-Log "MSU: $fileName"

    # ------------------------------------------------------------------------
    # KB
    # ------------------------------------------------------------------------

    if (-not (
        Test-MsuFileNameMatchesKb `
            -FileName $fileName `
            -Kb $ExpectedKb
    )) {

        throw @"
MSU validation FAILED.

Expected KB:
  $ExpectedKb

Actual filename:
  $fileName
"@
    }

    Write-Log "KB filename check: PASS"

    # ------------------------------------------------------------------------
    # Architecture
    # ------------------------------------------------------------------------

    if (-not (
        Test-MsuFileNameMatchesArchitecture `
            -FileName $fileName `
            -ExpectedArchitecture $ExpectedArchitecture
    )) {

        throw @"
MSU validation FAILED.

Expected architecture:
  $ExpectedArchitecture

Actual filename:
  $fileName
"@
    }

    Write-Log "Architecture filename check: PASS"

    # ------------------------------------------------------------------------
    # Expand
    # ------------------------------------------------------------------------

    $tempRoot = Join-Path `
        ([IO.Path]::GetTempPath()) `
        ("WindowsImageMSU_" + [guid]::NewGuid().ToString("N"))

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $tempRoot |
        Out-Null

    try {

        Write-Log "Expanding MSU for structural validation."

        & "$env:SystemRoot\System32\expand.exe" `
            "-F:*" `
            $MsuPath `
            $tempRoot |
            Out-Host

        if ($LASTEXITCODE -ne 0) {
            throw "expand.exe failed with exit code $LASTEXITCODE."
        }

        $cabFiles = @(
            Get-ChildItem `
                -LiteralPath $tempRoot `
                -Recurse `
                -Filter "*.cab" `
                -File
        )

        if ($cabFiles.Count -eq 0) {
            throw "MSU contains no CAB files."
        }

        Write-Log "CAB count: $($cabFiles.Count)"

        foreach ($cab in $cabFiles) {
            Write-Log "  CAB: $($cab.Name)"
        }

        Write-Log "MSU structural validation: PASS"
    }
    finally {

        Remove-Item `
            -LiteralPath $tempRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# Parse Catalog candidates
# ============================================================================

function Get-CatalogCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Html
    )

    $rows = [regex]::Matches(
        $Html,
        '<tr[^>]*>(.*?)</tr>',
        [Text.RegularExpressions.RegexOptions]::Singleline
    )

    $candidates = @()

    foreach ($rowMatch in $rows) {

        $row = $rowMatch.Groups[1].Value

        $plain = [System.Net.WebUtility]::HtmlDecode(
            ($row -replace '<[^>]+>', ' ')
        )

        $plain = $plain -replace '\s+', ' '
        $plain = $plain.Trim()

        # --------------------------------------------------------------------
        # Windows 11
        # --------------------------------------------------------------------

        if ($plain -notmatch "(?i)Windows 11") {
            continue
        }

        if ($plain -notmatch "(?i)version 24H2") {
            continue
        }

        # --------------------------------------------------------------------
        # Cumulative update
        # --------------------------------------------------------------------

        if ($plain -notmatch "(?i)Cumulative Update") {
            continue
        }

        if ($plain -notmatch "(?i)Security Updates") {
            continue
        }

        # --------------------------------------------------------------------
        # Exclusions
        # --------------------------------------------------------------------

        if ($plain -match "(?i)Preview") {
            continue
        }

        if ($plain -match "(?i)\.NET") {
            continue
        }

        if ($plain -match "(?i)Dynamic Update") {
            continue
        }

        if ($plain -match "(?i)Server") {
            continue
        }

        # --------------------------------------------------------------------
        # Architecture
        # --------------------------------------------------------------------

        if ($Architecture -eq "x64") {

            if ($plain -notmatch "(?i)x64-based Systems") {
                continue
            }

            if ($plain -match "(?i)ARM64") {
                continue
            }
        }

        if ($Architecture -eq "arm64") {

            if ($plain -notmatch "(?i)ARM64-based Systems") {
                continue
            }
        }

        # --------------------------------------------------------------------
        # KB
        # --------------------------------------------------------------------

        $kbMatch = [regex]::Match(
            $plain,
            "(?i)\(KB(\d+)\)"
        )

        if (-not $kbMatch.Success) {
            continue
        }

        $kb = "KB$($kbMatch.Groups[1].Value)"

        # --------------------------------------------------------------------
        # Build
        # --------------------------------------------------------------------

        $build = ""

        $buildMatch = [regex]::Match(
            $plain,
            "\((26100\.\d+)\)"
        )

        if ($buildMatch.Success) {
            $build = $buildMatch.Groups[1].Value
        }

        # --------------------------------------------------------------------
        # Date
        # --------------------------------------------------------------------

        $date = [datetime]::MinValue

        $dateMatch = [regex]::Match(
            $plain,
            "(\d{1,2}/\d{1,2}/\d{4})"
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

        # --------------------------------------------------------------------
        # UpdateID GUIDs in row
        # --------------------------------------------------------------------

        $updateIds = @()

        $guidMatches = [regex]::Matches(
            $row,
            "(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        )

        foreach ($guid in $guidMatches) {

            if ($updateIds -notcontains $guid.Value) {
                $updateIds += $guid.Value
            }
        }

        $candidates += [pscustomobject]@{
            KB        = $kb
            Build     = $build
            Date      = $date
            Title     = $plain
            UpdateIds = @($updateIds)
        }
    }

    return @($candidates)
}

# ============================================================================
# Find UpdateID for selected KB
# ============================================================================

function Resolve-UpdateId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kb
    )

    Write-Section "Resolve UpdateID"

    $html = Get-CatalogPage -Query $Kb

    $candidates = Get-CatalogCandidates -Html $html

    $matches = @(
        $candidates |
            Where-Object {
                $_.KB -eq $Kb
            }
    )

    if ($matches.Count -eq 0) {

        throw @"
No matching Windows 11 24H2 $Architecture catalog row found for:

$Kb
"@
    }

    $updateIds = @()

    foreach ($candidate in $matches) {

        foreach ($id in $candidate.UpdateIds) {

            if ($updateIds -notcontains $id) {
                $updateIds += $id
            }
        }
    }

    # ------------------------------------------------------------------------
    # Fallback: search page for GUIDs.
    # ------------------------------------------------------------------------

    if ($updateIds.Count -eq 0) {

        $guidMatches = [regex]::Matches(
            $html,
            "(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        )

        foreach ($guid in $guidMatches) {

            if ($updateIds -notcontains $guid.Value) {
                $updateIds += $guid.Value
            }
        }
    }

    if ($updateIds.Count -eq 0 {
        throw "Unable to resolve a Catalog UpdateID for $Kb."
    }

    Write-Log "UpdateIDs found: $($updateIds.Count)"

    foreach ($id in $updateIds) {
        Write-Log "  $id"
    }

    return @($updateIds)
}

# ============================================================================
# Select matching MSU URL
# ============================================================================

function Resolve-MsuDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kb,

        [Parameter(Mandatory = $true)]
        [string[]]$UpdateIds
    )

    Write-Section "Resolve MSU Download"

    foreach ($updateId in $UpdateIds) {

        Write-Log "Testing UpdateID: $updateId"

        try {

            $urls = Get-CatalogDownloadUrls `
                -UpdateId $updateId

            foreach ($url in $urls) {

                try {

                    $candidateFileName =
                        Get-FileNameFromUrl -Url $url

                    Write-Log "Candidate: $candidateFileName"

                    if (
                        $candidateFileName -notmatch "(?i)\.msu$"
                    ) {
                        Write-Log "Rejected: not an MSU."
                        continue
                    }

                    if (-not (
                        Test-MsuFileNameMatchesKb `
                            -FileName $candidateFileName `
                            -Kb $Kb
                    )) {
                        Write-Log "Rejected: KB mismatch."
                        continue
                    }

                    if (-not (
                        Test-MsuFileNameMatchesArchitecture `
                            -FileName $candidateFileName `
                            -ExpectedArchitecture $Architecture
                    )) {
                        Write-Log "Rejected: architecture mismatch."
                        continue
                    }

                    Write-Log "ACCEPTED: $candidateFileName"

                    return [pscustomobject]@{
                        UpdateId = $updateId
                        Url      = $url
                        FileName = $candidateFileName
                    }
                }
                catch {

                    Write-Log `
                        "Candidate rejected: $($_.Exception.Message)" `
                        "WARN"
                }
            }
        }
        catch {

            Write-Log `
                "UpdateID failed: $($_.Exception.Message)" `
                "WARN"
        }
    }

    throw @"
Unable to resolve a valid MSU for:

KB:
  $Kb

Architecture:
  $Architecture
"@
}

# ============================================================================
# Locate base ISO
# ============================================================================

$baseIso = Join-Path `
    $downloadDir `
    "base.iso"

if (-not (Test-Path -LiteralPath $baseIso -PathType Leaf)) {

    throw @"
Base ISO was not found:

$baseIso
"@
}

Write-Log "Base ISO found: $baseIso"

# ============================================================================
# Optional WIM inspection
# ============================================================================

$sourceDir = Join-Path `
    $WorkRoot `
    "source"

$wimPath = Join-Path `
    $sourceDir `
    "sources\install.wim"

if (Test-Path -LiteralPath $wimPath -PathType Leaf) {

    Write-Section "Inspect Existing WIM"

    try {

        $wimInfo = & "$env:SystemRoot\System32\dism.exe" `
            "/Get-WimInfo" `
            "/WimFile:$wimPath" `
            2>&1

        $wimInfo |
            ForEach-Object {
                Write-Log "$_"
            }

        if ($LASTEXITCODE -ne 0) {
            Write-Log "DISM WIM inspection failed." "WARN"
        }
    }
    catch {

        Write-Log `
            "Unable to inspect WIM: $($_.Exception.Message)" `
            "WARN"
    }
}
else {

    Write-Log "install.wim not extracted yet."
}

# ============================================================================
# Search latest LCU
# ============================================================================

Write-Section "Find Latest Windows 11 24H2 LCU"

$query =
    "Windows 11 24H2 cumulative update $Architecture"

$html = Get-CatalogPage `
    -Query $query

$candidates = Get-CatalogCandidates `
    -Html $html

if ($candidates.Count -eq 0) {

    throw @"
No Windows 11 24H2 $Architecture cumulative update was found.

Query:
$query
"@
}

# ============================================================================
# Deduplicate KBs
# ============================================================================

$candidates =
    $candidates |
    Group-Object KB |
    ForEach-Object {
        $_.Group |
            Sort-Object Date -Descending |
            Select-Object -First 1
    }

# ============================================================================
# Select newest update
# ============================================================================

$selected =
    $candidates |
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

if (-not $selected) {
    throw "Unable to select the latest LCU."
}

Write-Section "Selected LCU"

Write-Log "KB    : $($selected.KB)"
Write-Log "Build : $($selected.Build)"
Write-Log "Date  : $($selected.Date.ToString('yyyy-MM-dd'))"
Write-Log "Title : $($selected.Title)"

# ============================================================================
# Resolve UpdateID
# ============================================================================

$updateIds = Resolve-UpdateId `
    -Kb $selected.KB

# ============================================================================
# Resolve actual MSU
# ============================================================================

$resolvedDownload = Resolve-MsuDownload `
    -Kb $selected.KB `
    -UpdateIds $updateIds

$selectedUpdateId = $resolvedDownload.UpdateId
$downloadUrl      = $resolvedDownload.Url
$fileName         = $resolvedDownload.FileName

Write-Section "Resolved Microsoft Package"

Write-Log "KB       : $($selected.KB)"
Write-Log "Build    : $($selected.Build)"
Write-Log "UpdateID : $selectedUpdateId"
Write-Log "File     : $fileName"
Write-Log "URL      : $downloadUrl"

# ============================================================================
# Artifactory path
#
# Immutable path:
#
# Windows11/24H2/x64/LCU/KBxxxxxxx/file.msu
# ============================================================================

$relativePath =
    "Windows11/24H2/$Architecture/LCU/$($selected.KB)/$fileName"

$localPackage = Join-Path `
    $updateDir `
    $fileName

$artifactUrl = $null
$sourceType  = $null

# ============================================================================
# Get artifact
# ============================================================================

if (-not $ForceMicrosoftDownload) {

    $artifactUrl = Find-ArtifactoryFile `
        -RelativePath $relativePath
}

if ($artifactUrl) {

    Write-Section "Use Artifactory Cache"

    Write-Log "Cached artifact found:"
    Write-Log "  $artifactUrl"

    Download-ArtifactoryFile `
        -Url $artifactUrl `
        -Destination $localPackage

    $sourceType = "Artifactory"
}
else {

    Write-Section "Download From Microsoft"

    Write-Log "Artifact is not cached."

    Write-Log "Downloading:"
    Write-Log "  $downloadUrl"

    Invoke-WebRequest `
        -Uri $downloadUrl `
        -OutFile $localPackage `
        -UseBasicParsing `
        -TimeoutSec 3600

    if (-not (
        Test-Path `
            -LiteralPath $localPackage `
            -PathType Leaf
    )) {
        throw "Microsoft download failed."
    }

    $length = (
        Get-Item -LiteralPath $localPackage
    ).Length

    if ($length -le 0) {
        throw "Microsoft returned an empty MSU."
    }

    Write-Log "Downloaded $length bytes."

    $sourceType = "Microsoft"

    # ------------------------------------------------------------------------
    # Validate BEFORE publishing.
    # ------------------------------------------------------------------------

    Test-MsuPackage `
        -MsuPath $localPackage `
        -ExpectedKb $selected.KB `
        -ExpectedArchitecture $Architecture

    # ------------------------------------------------------------------------
    # Calculate SHA before publishing.
    # ------------------------------------------------------------------------

    $sha256 = Get-Sha256 `
        -Path $localPackage

    Write-Log "SHA-256: $sha256"

    # ------------------------------------------------------------------------
    # Publish only after successful validation.
    # ------------------------------------------------------------------------

    if ($ArtifactoryBaseUrl) {

        $artifactUrl = Upload-ArtifactoryFile `
            -Source $localPackage `
            -RelativePath $relativePath

        Write-Log "Artifact published:"
        Write-Log "  $artifactUrl"
    }
    else {

        Write-Log `
            "ArtifactoryBaseUrl not supplied; package remains local." `
            "WARN"
    }
}

# ============================================================================
# Final validation
# ============================================================================

Write-Section "Final Package Validation"

Test-MsuPackage `
    -MsuPath $localPackage `
    -ExpectedKb $selected.KB `
    -ExpectedArchitecture $Architecture

$sha256 = Get-Sha256 `
    -Path $localPackage

Write-Log "Final SHA-256:"
Write-Log "  $sha256"

# ============================================================================
# Manifest
# ============================================================================

$resolved = [pscustomobject]@{
    schemaVersion   = "1.0"

    type            = "LCU"

    kb              = $selected.KB
    build           = $selected.Build

    windowsVersion  = "Windows 11 24H2"

    windowsBuild    = $WindowsBuild

    architecture    = $Architecture

    updateId        = $selectedUpdateId

    releaseDate     = $selected.Date.ToString("yyyy-MM-dd")

    fileName        = $fileName

    sha256          = $sha256

    microsoftUrl    = $downloadUrl

    artifactoryUrl  = $artifactUrl

    artifactoryPath = $relativePath

    source          = $sourceType

    ssuIncluded     = $true

    resolvedAtUtc   = [datetime]::UtcNow.ToString("o")
}

# ============================================================================
# Write manifest atomically
# ============================================================================

$tempManifest = "$manifest.tmp"

$resolved |
    ConvertTo-Json -Depth 20 |
    Set-Content `
        -LiteralPath $tempManifest `
        -Encoding UTF8

Move-Item `
    -LiteralPath $tempManifest `
    -Destination $manifest `
    -Force

if (-not (
    Test-Path `
        -LiteralPath $manifest `
        -PathType Leaf
)) {
    throw "Failed to create resolved update manifest."
}

# ============================================================================
# Manifest validation
# ============================================================================

Write-Section "Validate Manifest"

$manifestObject =
    Get-Content `
        -LiteralPath $manifest `
        -Raw |
    ConvertFrom-Json

if ($manifestObject.kb -ne $selected.KB) {
    throw "Manifest KB mismatch."
}

if ($manifestObject.fileName -ne $fileName) {
    throw "Manifest filename mismatch."
}

if ($manifestObject.updateId -ne $selectedUpdateId) {
    throw "Manifest UpdateID mismatch."
}

if (
    $manifestObject.sha256.ToLowerInvariant() -ne
    $sha256.ToLowerInvariant()
) {
    throw "Manifest SHA-256 mismatch."
}

if (
    $manifestObject.artifactoryPath -ne
    $relativePath
) {
    throw "Manifest Artifactory path mismatch."
}

Write-Log "Manifest validation: PASS"

# ============================================================================
# Final
# ============================================================================

Write-Section "Update Resolution Complete"

Write-Log "Selected LCU"
Write-Log "  KB           : $($selected.KB)"
Write-Log "  Build        : $($selected.Build)"
Write-Log "  Architecture : $Architecture"
Write-Log "  Release      : $($selected.Date.ToString('yyyy-MM-dd'))"
Write-Log "  UpdateID     : $selectedUpdateId"

Write-Log ""
Write-Log "Package"
Write-Log "  File         : $fileName"
Write-Log "  SHA-256      : $sha256"
Write-Log "  Source       : $sourceType"

Write-Log ""
Write-Log "Microsoft"
Write-Log "  URL          : $downloadUrl"

Write-Log ""
Write-Log "Artifactory"
Write-Log "  URL          : $artifactUrl"
Write-Log "  Path         : $relativePath"

Write-Log ""
Write-Log "Servicing"
Write-Log "  SSU included : YES"

Write-Log ""
Write-Log "Manifest"
Write-Log "  $manifest"

Write-Log ""
Write-Log "Result: SUCCESS"

exit 0