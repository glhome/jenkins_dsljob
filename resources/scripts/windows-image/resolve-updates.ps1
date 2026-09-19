[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkRoot,

    [Parameter(Mandatory = $false)]
    [string]$WindowsBuild = '26100',

    [Parameter(Mandatory = $false)]
    [ValidateSet('x64', 'amd64', 'arm64')]
    [string]$Architecture = 'x64',

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryBaseUrl = '',

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryRepo = 'snapshot-generic-local',

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryUser = '',

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryPassword = '',

    [Parameter(Mandatory = $false)]
    [string]$ArtifactoryToken = '',

    [Parameter(Mandatory = $false)]
    [switch]$ForceMicrosoftDownload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# Normalize architecture
# ============================================================

if ($Architecture -match '^(?i)(amd64|x64)$') {
    $Architecture = 'x64'
}
elseif ($Architecture -match '^(?i)arm64$') {
    $Architecture = 'arm64'
}
else {
    throw "Unsupported architecture: $Architecture"
}

if ($WindowsBuild -notmatch '^26100') {
    Write-Warning `
        "WindowsBuild '$WindowsBuild' is outside the normal Windows 11 24H2 build family (26100)."
}

# ============================================================
# Normalize Artifactory URL
#
# Accept:
#
#   http://server:8082
#
# or:
#
#   http://server:8082/artifactory
#
# Internally:
#
#   http://server:8082/artifactory
# ============================================================

if ([string]::IsNullOrWhiteSpace($ArtifactoryBaseUrl)) {
    throw 'ArtifactoryBaseUrl is required.'
}

if ([string]::IsNullOrWhiteSpace($ArtifactoryRepo)) {
    throw 'ArtifactoryRepo is required.'
}

$ArtifactoryBaseUrl =
    $ArtifactoryBaseUrl.TrimEnd('/')

if ($ArtifactoryBaseUrl.EndsWith('/artifactory')) {
    $ArtifactoryUrlRoot = $ArtifactoryBaseUrl
}
else {
    $ArtifactoryUrlRoot =
        "$ArtifactoryBaseUrl/artifactory"
}

# ============================================================
# Paths
# ============================================================

$downloadDir =
    Join-Path $WorkRoot 'download'

$updateDir =
    Join-Path $downloadDir 'updates'

$manifest =
    Join-Path $downloadDir 'resolved-updates.json'

$logDir =
    Join-Path $WorkRoot 'logs'

New-Item `
    -ItemType Directory `
    -Force `
    -Path $downloadDir, $updateDir, $logDir |
    Out-Null

$logFile =
    Join-Path `
        $logDir `
        "resolve-updates-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# ============================================================
# Logging
# ============================================================

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp =
        Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $line =
        "[$timestamp] [$Level] $Message"

    Write-Host $line

    Add-Content `
        -LiteralPath $logFile `
        -Value $line
}

function Write-Section {
    param(
        [string]$Message = ''
    )

    Write-Host ''
    Write-Host '============================================================'

    if ([string]::IsNullOrWhiteSpace($Message)) {
        Write-Host 'Windows Image Update Resolver'
    }
    else {
        Write-Host $Message
    }

    Write-Host '============================================================'
    Write-Host ''
}

# ============================================================
# Header
# ============================================================

Write-Section 'Windows Image Update Resolver'

Write-Log "WorkRoot       : $WorkRoot"
Write-Log "WindowsBuild   : $WindowsBuild"
Write-Log "Architecture   : $Architecture"
Write-Log "Artifactory    : $ArtifactoryUrlRoot"
Write-Log "Repository     : $ArtifactoryRepo"
Write-Log "Force Download : $ForceMicrosoftDownload"
Write-Log "Manifest       : $manifest"
Write-Log "Log            : $logFile"

# ============================================================
# HTTP headers
# ============================================================

function Get-ArtifactoryHeaders {

    $headers = @{}

    if (-not [string]::IsNullOrWhiteSpace($ArtifactoryToken)) {

        $headers['Authorization'] =
            "Bearer $ArtifactoryToken"

        return $headers
    }

    if (
        -not [string]::IsNullOrWhiteSpace($ArtifactoryUser) -and
        -not [string]::IsNullOrWhiteSpace($ArtifactoryPassword)
    ) {

        $credentialPair =
            '{0}:{1}' -f `
                $ArtifactoryUser, `
                $ArtifactoryPassword

        $encoded =
            [Convert]::ToBase64String(
                [Text.Encoding]::ASCII.GetBytes(
                    $credentialPair
                )
            )

        $headers['Authorization'] =
            "Basic $encoded"
    }

    return $headers
}

# ============================================================
# Artifactory URL
#
# Example:
#
# snapshot-generic-local/
# Windows11/
# 24H2/
# x64/
# base/
# en-us_windows_11_iot_enterprise_version_24h2_x64_dvd_3a99b72b.iso
#
# becomes:
#
# http://server:8082/artifactory/
# snapshot-generic-local/
# Windows11/24H2/x64/base/<file>
# ============================================================

function Get-ArtifactoryUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $relative =
        $RelativePath.TrimStart('/')

    return (
        "$ArtifactoryUrlRoot/" +
        "$ArtifactoryRepo/" +
        $relative
    )
}

# ============================================================
# SHA256
# ============================================================

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (
        Test-Path `
            -LiteralPath $Path `
            -PathType Leaf
    )) {
        throw "File not found: $Path"
    }

    return (
        Get-FileHash `
            -LiteralPath $Path `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()
}

# ============================================================
# Microsoft Update Catalog
# ============================================================

function Get-CatalogSearchUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    return (
        'https://www.catalog.update.microsoft.com/Search.aspx?q=' +
        [uri]::EscapeDataString($Query)
    )
}

function Get-CatalogPage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $url =
        Get-CatalogSearchUrl -Query $Query

    Write-Log 'Microsoft Update Catalog query:'
    Write-Log "  $Query"
    Write-Log "  $url"

    $response =
        Invoke-WebRequest `
            -Uri $url `
            -UseBasicParsing `
            -TimeoutSec 120

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        throw 'Microsoft Update Catalog returned an empty response.'
    }

    return $response.Content
}

# ============================================================
# Resolve Catalog download URLs
# ============================================================

function Get-CatalogDownloadUrls {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UpdateId
    )

    Write-Log 'Resolving Catalog download URLs'
    Write-Log "UpdateID: $UpdateId"

    $updateObject = @{
        size     = 0
        updateID = $UpdateId
        uidInfo  = $UpdateId
    } | ConvertTo-Json -Compress

    $body = @{
        updateIDs = "[$updateObject]"
    }

    $response =
        Invoke-WebRequest `
            -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' `
            -Method Post `
            -Body $body `
            -ContentType 'application/x-www-form-urlencoded' `
            -UseBasicParsing `
            -TimeoutSec 120

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        throw 'DownloadDialog returned an empty response.'
    }

    $content =
        $response.Content.Replace('&amp;', '&')

    $pattern =
        'https?://[^"''\s<>]+'

    $matches =
        [regex]::Matches(
            $content,
            $pattern,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

    $urls =
        New-Object System.Collections.Generic.List[string]

    foreach ($match in $matches) {

        $url =
            $match.Value.TrimEnd(
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

            if (-not $urls.Contains($url)) {
                $urls.Add($url)
            }
        }
    }

    if ($urls.Count -eq 0) {
        throw `
            "No Microsoft download URLs found for UpdateID $UpdateId."
    }

    foreach ($url in $urls) {
        Write-Log "Catalog URL: $url"
    }

    return @($urls)
}

# ============================================================
# Filename from URL
# ============================================================

function Get-FileNameFromUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $uri =
        [System.Uri]$Url

    $name =
        [System.IO.Path]::GetFileName(
            $uri.AbsolutePath
        )

    if ([string]::IsNullOrWhiteSpace($name)) {
        throw `
            "Unable to determine filename from URL: $Url"
    }

    return $name
}

# ============================================================
# KB filename validation
# ============================================================

function Test-MsuFileNameMatchesKb {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string]$Kb
    )

    $kbNumber =
        $Kb -replace '(?i)^KB', ''

    $pattern =
        "(?i)kb$([regex]::Escape($kbNumber))(?:[^0-9]|$)"

    return $FileName -match $pattern
}

# ============================================================
# Architecture filename validation
# ============================================================

function Test-MsuFileNameMatchesArchitecture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedArchitecture
    )

    if ($ExpectedArchitecture -eq 'x64') {
        return $FileName -match '(?i)(x64|amd64)'
    }

    if ($ExpectedArchitecture -eq 'arm64') {
        return $FileName -match '(?i)arm64'
    }

    return $false
}

# ============================================================
# Find Artifactory artifact
# ============================================================

function Find-ArtifactoryFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $url =
        Get-ArtifactoryUrl -RelativePath $RelativePath

    $headers =
        Get-ArtifactoryHeaders

    Write-Log 'Checking Artifactory:'
    Write-Log "  $url"

    try {

        $response =
            Invoke-WebRequest `
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
            'WARN'

        return $null
    }
}

# ============================================================
# Download from Artifactory
# ============================================================

function Download-ArtifactoryFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    Write-Log 'Downloading cached Artifactory artifact'
    Write-Log "  URL         : $Url"
    Write-Log "  Destination : $Destination"

    $headers =
        Get-ArtifactoryHeaders

    Invoke-WebRequest `
        -Uri $Url `
        -OutFile $Destination `
        -Headers $headers `
        -UseBasicParsing `
        -TimeoutSec 3600

    if (-not (
        Test-Path `
            -LiteralPath $Destination `
            -PathType Leaf
    )) {
        throw `
            "Artifactory download did not create: $Destination"
    }

    $length =
        (Get-Item -LiteralPath $Destination).Length

    if ($length -le 0) {
        throw `
            "Artifactory returned an empty file: $Destination"
    }

    Write-Log "Downloaded $length bytes from Artifactory."
}

# ============================================================
# Upload to Artifactory
# ============================================================

function Upload-ArtifactoryFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $url =
        Get-ArtifactoryUrl `
            -RelativePath $RelativePath

    # --------------------------------------------------------
    # Immutable repository behavior:
    #
    # Never overwrite an existing artifact.
    # --------------------------------------------------------

    $existing =
        Find-ArtifactoryFile `
            -RelativePath $RelativePath

    if ($existing) {

        Write-Log 'Artifact already exists.'
        Write-Log 'Repository is immutable; upload skipped.'

        return $existing
    }

    $headers =
        Get-ArtifactoryHeaders

    Write-Log 'Publishing immutable artifact:'
    Write-Log "  $url"

    Invoke-WebRequest `
        -Uri $url `
        -Method Put `
        -InFile $Source `
        -Headers $headers `
        -ContentType 'application/octet-stream' `
        -UseBasicParsing `
        -TimeoutSec 3600

    $verified =
        Find-ArtifactoryFile `
            -RelativePath $RelativePath

    if (-not $verified) {
        throw `
            "Artifact upload could not be verified: $url"
    }

    return $verified
}

# ============================================================
# Validate MSU
# ============================================================

function Test-MsuPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MsuPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedKb,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedArchitecture
    )

    Write-Section 'Validate MSU'

    $fileName =
        Split-Path `
            -Leaf `
            $MsuPath

    Write-Log "MSU: $fileName"

    # --------------------------------------------------------
    # KB
    # --------------------------------------------------------

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

    Write-Log 'KB filename check: PASS'

    # --------------------------------------------------------
    # Architecture
    # --------------------------------------------------------

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

    Write-Log 'Architecture filename check: PASS'

    # --------------------------------------------------------
    # Expand MSU
    # --------------------------------------------------------

    $tempRoot =
        Join-Path `
            ([IO.Path]::GetTempPath()) `
            (
                'WindowsImageMSU_' +
                [guid]::NewGuid().ToString('N')
            )

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $tempRoot |
        Out-Null

    try {

        Write-Log "Validating MSU archive structure."

        $sevenZipCandidates = @(
            "${env:ProgramFiles}\7-Zip\7z.exe",
            "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
        )

        $sevenZip = $sevenZipCandidates |
            Where-Object {
                $_ -and (Test-Path -LiteralPath $_ -PathType Leaf)
            } |
            Select-Object -First 1

        if (-not $sevenZip) {
            throw "7-Zip was not found. Expected 7z.exe under Program Files or Program Files (x86)."
        }

        if (-not (Test-Path -LiteralPath $MsuPath -PathType Leaf)) {
            throw "MSU file does not exist: $MsuPath"
        }

        $msuItem = Get-Item -LiteralPath $MsuPath

        Write-Log "MSU:"
        Write-Log "  Path : $($msuItem.FullName)"
        Write-Log "  Size : $($msuItem.Length) bytes"
        Write-Log "7-Zip:"
        Write-Log "  Path : $sevenZip"

        & $sevenZip t $MsuPath

        $sevenZipExitCode = $LASTEXITCODE

        if ($sevenZipExitCode -ne 0) {
            throw "7-Zip MSU validation failed with exit code $sevenZipExitCode."
        }

        Write-Log "MSU archive validation: PASS"
    }
    finally {

        Remove-Item `
            -LiteralPath $tempRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

# ============================================================
# Parse Microsoft Update Catalog candidates
# ============================================================

function Get-CatalogCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Html
    )

    $rows =
        [regex]::Matches(
            $Html,
            '<tr[^>]*>(.*?)</tr>',
            [Text.RegularExpressions.RegexOptions]::Singleline
        )

    $candidates = @()

    foreach ($rowMatch in $rows) {

        $row =
            $rowMatch.Groups[1].Value

        $plain =
            [System.Net.WebUtility]::HtmlDecode(
                ($row -replace '<[^>]+>', ' ')
            )

        $plain =
            $plain -replace '\s+', ' '

        $plain =
            $plain.Trim()

        # ----------------------------------------------------
        # Windows 11
        # ----------------------------------------------------

        if ($plain -notmatch '(?i)Windows 11') {
            continue
        }

        if ($plain -notmatch '(?i)version 24H2') {
            continue
        }

        # ----------------------------------------------------
        # Cumulative security update
        # ----------------------------------------------------

        if ($plain -notmatch '(?i)Cumulative Update') {
            continue
        }

        if ($plain -notmatch '(?i)Security Updates') {
            continue
        }

        # ----------------------------------------------------
        # Exclude unwanted packages
        # ----------------------------------------------------

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

        # ----------------------------------------------------
        # Architecture
        # ----------------------------------------------------

        if ($Architecture -eq 'x64') {

            if ($plain -notmatch '(?i)x64-based Systems') {
                continue
            }

            if ($plain -match '(?i)ARM64') {
                continue
            }
        }

        if ($Architecture -eq 'arm64') {

            if ($plain -notmatch '(?i)ARM64-based Systems') {
                continue
            }
        }

        # ----------------------------------------------------
        # KB
        # ----------------------------------------------------

        $kbMatch =
            [regex]::Match(
                $plain,
                '(?i)\(KB(\d+)\)'
            )

        if (-not $kbMatch.Success) {
            continue
        }

        $kb =
            "KB$($kbMatch.Groups[1].Value)"

        # ----------------------------------------------------
        # Build
        # ----------------------------------------------------

        $build = ''

        $buildMatch =
            [regex]::Match(
                $plain,
                '\((26100\.\d+)\)'
            )

        if ($buildMatch.Success) {
            $build =
                $buildMatch.Groups[1].Value
        }

        # ----------------------------------------------------
        # Date
        # ----------------------------------------------------

        $date =
            [datetime]::MinValue

        $dateMatch =
            [regex]::Match(
                $plain,
                '(\d{1,2}/\d{1,2}/\d{4})'
            )

        if ($dateMatch.Success) {

            try {
                $date =
                    [datetime]::Parse(
                        $dateMatch.Groups[1].Value
                    )
            }
            catch {
                $date =
                    [datetime]::MinValue
            }
        }

        # ----------------------------------------------------
        # Update IDs
        # ----------------------------------------------------

        $updateIds = @()

        $guidMatches =
            [regex]::Matches(
                $row,
                '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
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

# ============================================================
# Resolve UpdateID
# ============================================================

function Resolve-UpdateId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kb
    )

    Write-Section 'Resolve UpdateID'

    $html =
        Get-CatalogPage -Query $Kb

    $candidates =
        Get-CatalogCandidates -Html $html

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

    # --------------------------------------------------------
    # Fallback: search entire page for GUIDs
    # --------------------------------------------------------

    if ($updateIds.Count -eq 0) {

        $guidMatches =
            [regex]::Matches(
                $html,
                '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
            )

        foreach ($guid in $guidMatches) {

            if ($updateIds -notcontains $guid.Value) {
                $updateIds += $guid.Value
            }
        }
    }

    if ($updateIds.Count -eq 0) {
        throw `
            "Unable to resolve a Catalog UpdateID for $Kb."
    }

    Write-Log "UpdateIDs found: $($updateIds.Count)"

    foreach ($id in $updateIds) {
        Write-Log "  $id"
    }

    return @($updateIds)
}

# ============================================================
# Resolve MSU download
# ============================================================

function Resolve-MsuDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kb,

        [Parameter(Mandatory = $true)]
        [string[]]$UpdateIds
    )

    Write-Section 'Resolve MSU Download'

    foreach ($updateId in $UpdateIds) {

        Write-Log "Testing UpdateID: $updateId"

        try {

            $urls =
                Get-CatalogDownloadUrls `
                    -UpdateId $updateId

            foreach ($url in $urls) {

                try {

                    $candidateFileName =
                        Get-FileNameFromUrl `
                            -Url $url

                    Write-Log `
                        "Candidate: $candidateFileName"

                    if (
                        $candidateFileName `
                            -notmatch '(?i)\.msu$'
                    ) {

                        Write-Log `
                            'Rejected: not an MSU.'

                        continue
                    }

                    if (-not (
                        Test-MsuFileNameMatchesKb `
                            -FileName $candidateFileName `
                            -Kb $Kb
                    )) {

                        Write-Log `
                            'Rejected: KB mismatch.'

                        continue
                    }

                    if (-not (
                        Test-MsuFileNameMatchesArchitecture `
                            -FileName $candidateFileName `
                            -ExpectedArchitecture $Architecture
                    )) {

                        Write-Log `
                            'Rejected: architecture mismatch.'

                        continue
                    }

                    Write-Log `
                        "ACCEPTED: $candidateFileName"

                    return [pscustomobject]@{
                        UpdateId = $updateId
                        Url      = $url
                        FileName = $candidateFileName
                    }
                }
                catch {

                    Write-Log `
                        "Candidate rejected: $($_.Exception.Message)" `
                        'WARN'
                }
            }
        }
        catch {

            Write-Log `
                "UpdateID failed: $($_.Exception.Message)" `
                'WARN'
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

# ============================================================
# Locate base ISO
# ============================================================

$baseIso =
    Join-Path `
        $downloadDir `
        'base.iso'

if (-not (
    Test-Path `
        -LiteralPath $baseIso `
        -PathType Leaf
)) {

    throw @"
Base ISO was not found:

$baseIso
"@
}

Write-Log "Base ISO found: $baseIso"

# ============================================================
# Search latest LCU
# ============================================================

Write-Section 'Find Latest Windows 11 24H2 LCU'

$query =
    "Windows 11 24H2 cumulative update $Architecture"

$html =
    Get-CatalogPage -Query $query

$candidates =
    Get-CatalogCandidates -Html $html

if ($candidates.Count -eq 0) {

    throw @"
No Windows 11 24H2 $Architecture cumulative update was found.

Query:
$query
"@
}

# ============================================================
# Deduplicate KBs
# ============================================================

$candidates =
    $candidates |
    Group-Object KB |
    ForEach-Object {

        $_.Group |
            Sort-Object Date -Descending |
            Select-Object -First 1
    }

# ============================================================
# Select newest LCU
# ============================================================

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
                    [version]'0.0'
                }
            }
            else {
                [version]'0.0'
            }

        }; Descending = $true } |
    Select-Object -First 1

if (-not $selected) {
    throw 'Unable to select the latest LCU.'
}

Write-Section 'Selected LCU'

Write-Log "KB    : $($selected.KB)"
Write-Log "Build : $($selected.Build)"
Write-Log "Date  : $($selected.Date.ToString('yyyy-MM-dd'))"
Write-Log "Title : $($selected.Title)"

# ============================================================
# Resolve UpdateID
# ============================================================

$updateIds =
    Resolve-UpdateId `
        -Kb $selected.KB

# ============================================================
# Resolve actual MSU
# ============================================================

$resolvedDownload =
    Resolve-MsuDownload `
        -Kb $selected.KB `
        -UpdateIds $updateIds

$selectedUpdateId =
    $resolvedDownload.UpdateId

$downloadUrl =
    $resolvedDownload.Url

$fileName =
    $resolvedDownload.FileName

Write-Section 'Resolved Microsoft Package'

Write-Log "KB       : $($selected.KB)"
Write-Log "Build    : $($selected.Build)"
Write-Log "UpdateID : $selectedUpdateId"
Write-Log "File     : $fileName"
Write-Log "URL      : $downloadUrl"

# ============================================================
# Artifactory immutable path
#
# Example:
#
# snapshot-generic-local/
# Windows11/
# 24H2/
# x64/
# LCU/
# KB5065426/
# windows11.0-kb5065426-x64.msu
# ============================================================

$relativePath =
    "Windows11/24H2/$Architecture/LCU/$($selected.KB)/$fileName"

$localPackage =
    Join-Path `
        $updateDir `
        $fileName

$artifactUrl = $null
$sourceType = $null

# ============================================================
# Artifactory cache lookup
# ============================================================

if (-not $ForceMicrosoftDownload) {

    $artifactUrl =
        Find-ArtifactoryFile `
            -RelativePath $relativePath
}

# ============================================================
# Use Artifactory cache
# ============================================================

if ($artifactUrl) {

    Write-Section 'Use Artifactory Cache'

    Write-Log 'Cached artifact found:'
    Write-Log "  $artifactUrl"

    Download-ArtifactoryFile `
        -Url $artifactUrl `
        -Destination $localPackage

    # Validate cached artifact too.
    Test-MsuPackage `
        -MsuPath $localPackage `
        -ExpectedKb $selected.KB `
        -ExpectedArchitecture $Architecture

    $sha256 =
        Get-Sha256 `
            -Path $localPackage

    $sourceType =
        'Artifactory'

    Write-Log "Cached artifact SHA-256: $sha256"
}

# ============================================================
# Download from Microsoft
# ============================================================

else {

    Write-Section 'Download From Microsoft'

    Write-Log 'Artifact is not cached.'

    Write-Log 'Downloading:'
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
        throw 'Microsoft download failed.'
    }

    $length =
        (Get-Item -LiteralPath $localPackage).Length

    if ($length -le 0) {
        throw 'Microsoft returned an empty MSU.'
    }

    Write-Log "Downloaded $length bytes."

    $sourceType =
        'Microsoft'

    # --------------------------------------------------------
    # Validate BEFORE publishing.
    # --------------------------------------------------------

    Test-MsuPackage `
        -MsuPath $localPackage `
        -ExpectedKb $selected.KB `
        -ExpectedArchitecture $Architecture

    # --------------------------------------------------------
    # Calculate SHA before publishing.
    # --------------------------------------------------------

    $sha256 =
        Get-Sha256 `
            -Path $localPackage

    Write-Log "SHA-256: $sha256"

    # --------------------------------------------------------
    # Publish to snapshot-generic-local.
    # --------------------------------------------------------

    $artifactUrl =
        Upload-ArtifactoryFile `
            -Source $localPackage `
            -RelativePath $relativePath

    Write-Log 'Artifact published:'
    Write-Log "  $artifactUrl"
}

# ============================================================
# Final validation
# ============================================================

Write-Section 'Final Package Validation'

Test-MsuPackage `
    -MsuPath $localPackage `
    -ExpectedKb $selected.KB `
    -ExpectedArchitecture $Architecture

$sha256 =
    Get-Sha256 `
        -Path $localPackage

Write-Log 'Final SHA-256:'
Write-Log "  $sha256"

# ============================================================
# Manifest
# ============================================================

$resolved =
    [pscustomobject]@{

        schemaVersion =
            '1.0'

        type =
            'LCU'

        kb =
            $selected.KB

        build =
            $selected.Build

        windowsVersion =
            'Windows 11 24H2'

        windowsBuild =
            $WindowsBuild

        architecture =
            $Architecture

        updateId =
            $selectedUpdateId

        releaseDate =
            $selected.Date.ToString('yyyy-MM-dd')

        fileName =
            $fileName

        sha256 =
            $sha256

        microsoftUrl =
            $downloadUrl

        artifactoryUrl =
            $artifactUrl

        artifactoryRepo =
            $ArtifactoryRepo

        artifactoryPath =
            $relativePath

        source =
            $sourceType

        ssuIncluded =
            $true

        resolvedAtUtc =
            [datetime]::UtcNow.ToString('o')
    }

# ============================================================
# Write manifest atomically
# ============================================================

$tempManifest =
    "$manifest.tmp"

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
    throw `
        'Failed to create resolved update manifest.'
}

# ============================================================
# Validate manifest
# ============================================================

Write-Section 'Validate Manifest'

$manifestObject =
    Get-Content `
        -LiteralPath $manifest `
        -Raw |
    ConvertFrom-Json

if ($manifestObject.kb -ne $selected.KB) {
    throw 'Manifest KB mismatch.'
}

if ($manifestObject.fileName -ne $fileName) {
    throw 'Manifest filename mismatch.'
}

if ($manifestObject.updateId -ne $selectedUpdateId) {
    throw 'Manifest UpdateID mismatch.'
}

if (
    $manifestObject.sha256.ToLowerInvariant() -ne
    $sha256.ToLowerInvariant()
) {
    throw 'Manifest SHA-256 mismatch.'
}

if (
    $manifestObject.artifactoryRepo -ne
    $ArtifactoryRepo
) {
    throw 'Manifest Artifactory repository mismatch.'
}

if (
    $manifestObject.artifactoryPath -ne
    $relativePath
) {
    throw 'Manifest Artifactory path mismatch.'
}

Write-Log 'Manifest validation: PASS'

# ============================================================
# Final
# ============================================================

Write-Section 'Update Resolution Complete'

Write-Log 'Selected LCU'
Write-Log "  KB           : $($selected.KB)"
Write-Log "  Build        : $($selected.Build)"
Write-Log "  Architecture : $Architecture"
Write-Log "  Release      : $($selected.Date.ToString('yyyy-MM-dd'))"
Write-Log "  UpdateID     : $selectedUpdateId"

Write-Log ''
Write-Log 'Package'
Write-Log "  File         : $fileName"
Write-Log "  SHA-256      : $sha256"
Write-Log "  Source       : $sourceType"

Write-Log ''
Write-Log 'Microsoft'
Write-Log "  URL          : $downloadUrl"

Write-Log ''
Write-Log 'Artifactory'
Write-Log "  Repository   : $ArtifactoryRepo"
Write-Log "  URL          : $artifactUrl"
Write-Log "  Path         : $relativePath"

Write-Log ''
Write-Log 'Servicing'
Write-Log '  SSU included : YES'

Write-Log ''
Write-Log 'Manifest'
Write-Log "  $manifest"

Write-Log ''
Write-Log 'Result: SUCCESS'

exit 0