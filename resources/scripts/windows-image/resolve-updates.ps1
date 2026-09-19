
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
    [string]$ArtifactoryRepo
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Configuration
# ============================================================

$WorkRoot =
    [System.IO.Path]::GetFullPath($WorkRoot)

$DownloadDir =
    Join-Path $WorkRoot 'download'

$UpdatesDir =
    Join-Path $DownloadDir 'updates'

$ResolvedFile =
    Join-Path $DownloadDir 'resolved-updates.json'

$TempDir =
    Join-Path $DownloadDir 'catalog-temp'

$WindowsVersion =
    '24H2'

$MicrosoftCatalogSearchUrl =
    'https://www.catalog.update.microsoft.com/Search.aspx'

$ArtifactoryBaseUrl =
    $ArtifactoryBaseUrl.TrimEnd('/')

$Architecture =
    $Architecture.ToLowerInvariant()

$WindowsBuild =
    $WindowsBuild.Trim()


# ============================================================
# Validation
# ============================================================

if ($Architecture -notin @('x64', 'amd64')) {

    throw @"
Unsupported architecture:

  $Architecture

This resolver currently supports x64/amd64.
"@
}

$Architecture = 'x64'


if ($WindowsBuild -notmatch '^\d+$') {

    throw @"
Invalid Windows build:

  $WindowsBuild
"@
}


New-Item `
    -ItemType Directory `
    -Force `
    -Path $DownloadDir |
    Out-Null

New-Item `
    -ItemType Directory `
    -Force `
    -Path $UpdatesDir |
    Out-Null

New-Item `
    -ItemType Directory `
    -Force `
    -Path $TempDir |
    Out-Null


# ============================================================
# Display configuration
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Windows Update Resolver"
Write-Host "============================================================"

Write-Host "WorkRoot:"
Write-Host "  $WorkRoot"

Write-Host ""
Write-Host "Windows:"
Write-Host "  Windows 11 $WindowsVersion"

Write-Host ""
Write-Host "Build:"
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
Write-Host "Resolved manifest:"
Write-Host "  $ResolvedFile"

Write-Host "============================================================"


# ============================================================
# Helper: Artifactory URL
# ============================================================

function Get-ArtifactoryUrl {

    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$ArtifactPath
    )


    $encodedPath =
        ($ArtifactPath -split '/') |
        ForEach-Object {
            [System.Uri]::EscapeDataString($_)
        }

    $encodedPath =
        $encodedPath -join '/'


    return "$($BaseUrl.TrimEnd('/'))/$Repository/$encodedPath"
}


# ============================================================
# Helper: Test Artifactory artifact
# ============================================================

function Test-ArtifactoryArtifact {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$ArtifactPath
    )


    $url =
        Get-ArtifactoryUrl `
            -BaseUrl $ArtifactoryBaseUrl `
            -Repository $Repository `
            -ArtifactPath $ArtifactPath


    try {

        $response =
            Invoke-WebRequest `
                -Uri $url `
                -Method Head `
                -UseBasicParsing `
                -ErrorAction Stop

        if ([int]$response.StatusCode -ge 200 -and
            [int]$response.StatusCode -lt 300) {

            return $true
        }

        return $false
    }
    catch {

        $statusCode = $null

        if ($_.Exception.Response) {

            try {
                $statusCode =
                    [int]$_.Exception.Response.StatusCode
            }
            catch {
                $statusCode = $null
            }
        }

        if ($statusCode -eq 404) {
            return $false
        }

        Write-Warning `
            "Unable to check Artifactory artifact: $url"

        return $false
    }
}


# ============================================================
# Helper: Download from Artifactory
# ============================================================

function Get-ArtifactoryArtifact {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$ArtifactPath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $false)]
        [string]$ExpectedSha256
    )


    $url =
        Get-ArtifactoryUrl `
            -BaseUrl $ArtifactoryBaseUrl `
            -Repository $Repository `
            -ArtifactPath $ArtifactPath


    Write-Host ""
    Write-Host "Downloading from Artifactory:"
    Write-Host "  $url"


    Invoke-WebRequest `
        -Uri $url `
        -OutFile $DestinationPath `
        -UseBasicParsing `
        -ErrorAction Stop


    if (-not (Test-Path -LiteralPath $DestinationPath)) {

        throw @"
Artifactory download failed.

URL:
  $url
"@
    }


    $file =
        Get-Item -LiteralPath $DestinationPath


    if ($file.Length -eq 0) {

        throw "Artifactory artifact is empty: $DestinationPath"
    }


    if ($ExpectedSha256) {

        $actualHash =
            (Get-FileHash `
                -LiteralPath $DestinationPath `
                -Algorithm SHA256).Hash.ToLowerInvariant()

        $expectedHash =
            $ExpectedSha256.Trim().ToLowerInvariant()


        Write-Host ""
        Write-Host "SHA256:"
        Write-Host "  Expected: $expectedHash"
        Write-Host "  Actual:   $actualHash"


        if ($actualHash -ne $expectedHash) {

            Remove-Item `
                -LiteralPath $DestinationPath `
                -Force `
                -ErrorAction SilentlyContinue

            throw @"
Artifactory artifact SHA256 mismatch.

Artifact:
  $ArtifactPath

Expected:
  $expectedHash

Actual:
  $actualHash
"@
        }
    }


    return $true
}


# ============================================================
# Helper: Search Microsoft Update Catalog
# ============================================================

function Search-MicrosoftCatalog {

    param(
        [Parameter(Mandatory = $true)]
        [string]$SearchText
    )


    Write-Host ""
    Write-Host "Searching Microsoft Update Catalog:"
    Write-Host "  $SearchText"


    $encodedSearch =
        [System.Uri]::EscapeDataString($SearchText)


    $url =
        "$MicrosoftCatalogSearchUrl?q=$encodedSearch"


    $response =
        Invoke-WebRequest `
            -Uri $url `
            -UseBasicParsing `
            -ErrorAction Stop


    return $response.Content
}


# ============================================================
# Helper: Extract KB numbers
# ============================================================

function Get-KbNumbers {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )


    $matches =
        [regex]::Matches(
            $Text,
            '(?i)\bKB\d{7}\b'
        )


    $result =
        New-Object System.Collections.Generic.List[string]


    foreach ($match in $matches) {

        $kb =
            $match.Value.ToUpperInvariant()

        if (-not $result.Contains($kb)) {

            $result.Add($kb)
        }
    }


    return @($result)
}


# ============================================================
# Helper: Parse Catalog result rows
# ============================================================

function Get-CatalogCandidates {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Html
    )


    $results =
        New-Object System.Collections.Generic.List[object]


    #
    # Microsoft Update Catalog pages contain result rows such as:
    #
    # Cumulative Update for Windows 11 Version 24H2...
    #
    # The HTML structure has changed over time, so this parser
    # intentionally collects the surrounding row rather than
    # depending on one exact table layout.
    #

    $rowMatches =
        [regex]::Matches(
            $Html,
            '(?is)<tr[^>]*>(.*?)</tr>'
        )


    foreach ($rowMatch in $rowMatches) {

        $row =
            $rowMatch.Groups[1].Value


        if ($row -notmatch '(?i)Windows 11') {
            continue
        }


        if ($row -notmatch '(?i)24H2') {
            continue
        }


        if ($row -notmatch '(?i)Cumulative Update') {
            continue
        }


        if ($row -notmatch '(?i)x64') {
            continue
        }


        if ($row -match '(?i)ARM64') {
            continue
        }


        if ($row -match '(?i)Preview') {
            continue
        }


        if ($row -match '(?i)Dynamic Update') {
            continue
        }


        if ($row -match '(?i)Setup Dynamic') {
            continue
        }


        if ($row -match '(?i)Safe OS Dynamic') {
            continue
        }


        $kbMatches =
            Get-KbNumbers -Text $row


        if ($kbMatches.Count -eq 0) {
            continue
        }


        $kb =
            $kbMatches[0]


        #
        # Extract update ID from Catalog links.
        #

        $updateId = $null


        $idMatch =
            [regex]::Match(
                $row,
                '(?i)(?:updateID|updateId)[^a-zA-Z0-9]+([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
            )


        if ($idMatch.Success) {

            $updateId =
                $idMatch.Groups[1].Value
        }


        #
        # Some Catalog pages place the ID in JavaScript.
        #

        if (-not $updateId) {

            $idMatch =
                [regex]::Match(
                    $row,
                    '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
                )


            if ($idMatch.Success) {

                $updateId =
                    $idMatch.Groups[1].Value
            }
        }


        #
        # Extract date.
        #

        $date = $null


        $dateMatch =
            [regex]::Match(
                $row,
                '\b(0?[1-9]|1[0-2])/(0?[1-9]|[12]\d|3[01])/20\d{2}\b'
            )


        if ($dateMatch.Success) {

            $date =
                $dateMatch.Value
        }


        #
        # Extract title text.
        #

        $title =
            [regex]::Replace(
                $row,
                '(?is)<[^>]+>',
                ' '
            )


        $title =
            [System.Net.WebUtility]::HtmlDecode($title)


        $title =
            [regex]::Replace(
                $title,
                '\s+',
                ' '
            ).Trim()


        #
        # Extract build number if it appears in the row.
        #

        $build = $null


        $buildMatches =
            [regex]::Matches(
                $title,
                '\b26\d{3}\.\d+\b'
            )


        if ($buildMatches.Count -gt 0) {

            $build =
                $buildMatches |
                Select-Object -Last 1 |
                ForEach-Object {
                    $_.Value
                }
        }


        $results.Add(
            [PSCustomObject]@{
                KB       = $kb
                UpdateId = $updateId
                Date     = $date
                Build    = $build
                Title    = $title
                Html     = $row
            }
        )
    }


    return @($results)
}


# ============================================================
# Helper: Get Catalog download dialog
# ============================================================

function Get-CatalogDownloadDialog {

    param(
        [Parameter(Mandatory = $true)]
        [string]$UpdateId
    )


    $dialogUrl =
        "https://www.catalog.update.microsoft.com/DownloadDialog.aspx?updateIds=$UpdateId"


    Write-Host ""
    Write-Host "Getting Microsoft download information:"
    Write-Host "  Update ID: $UpdateId"


    $response =
        Invoke-WebRequest `
            -Uri $dialogUrl `
            -UseBasicParsing `
            -ErrorAction Stop


    return $response.Content
}


# ============================================================
# Helper: Extract MSU download URL
# ============================================================

function Get-MsuDownloadUrl {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Html
    )


    #
    # Catalog download dialogs normally contain links to:
    #
    # https://catalog.s.download.windowsupdate.com/...
    #
    # or:
    #
    # https://catalog.sf.dl.delivery.mp.microsoft.com/...
    #


    $urlMatches =
        [regex]::Matches(
            $Html,
            '(?i)https?://[^"''<>\s]+'
        )


    foreach ($match in $urlMatches) {

        $url =
            $match.Value


        $url =
            [System.Net.WebUtility]::HtmlDecode($url)


        $url =
            $url.Replace('\u0026', '&')


        if ($url -match '(?i)\.msu(?:\?|$)') {

            return $url
        }
    }


    #
    # Some pages encode the URL inside JavaScript.
    #

    $encodedMatches =
        [regex]::Matches(
            $Html,
            '(?i)(https?%3A%2F%2F[^"''<>\s]+)'
        )


    foreach ($match in $encodedMatches) {

        try {

            $url =
                [System.Uri]::UnescapeDataString(
                    $match.Value
                )


            if ($url -match '(?i)\.msu(?:\?|$)') {

                return $url
            }
        }
        catch {
            continue
        }
    }


    throw @"
Unable to locate an MSU download URL in the Microsoft Update Catalog dialog.
"@
}


# ============================================================
# Helper: Determine MSU filename
# ============================================================

function Get-MsuFileName {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )


    try {

        $uri =
            [System.Uri]$Url

        $fileName =
            [System.IO.Path]::GetFileName(
                $uri.AbsolutePath
            )


        if ($fileName -and
            $fileName -match '(?i)\.msu$') {

            return $fileName
        }
    }
    catch {
        # Continue with regex fallback.
    }


    $match =
        [regex]::Match(
            $Url,
            '(?i)([^/?&]+\.msu)(?:\?|$)'
        )


    if ($match.Success) {

        return $match.Groups[1].Value
    }


    throw "Unable to determine MSU filename from URL: $Url"
}


# ============================================================
# Helper: Convert Catalog date
# ============================================================

function Convert-CatalogDate {

    param(
        [Parameter(Mandatory = $false)]
        [string]$Date
    )


    if (-not $Date) {
        return $null
    }


    $parsed =
        [datetime]::MinValue


    $formats =
        @(
            'M/d/yyyy',
            'MM/dd/yyyy',
            'M/d/yy',
            'MM/dd/yy'
        )


    foreach ($format in $formats) {

        if (
            [datetime]::TryParseExact(
                $Date,
                $format,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None,
                [ref]$parsed
            )
        ) {

            return $parsed
        }
    }


    return $null
}


# ============================================================
# Search Catalog
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Search Microsoft Update Catalog"
Write-Host "============================================================"


#
# Search terms are deliberately restrictive.
#

$searchTerms =
    @(
        "Windows 11 Version 24H2 x64 Cumulative Update",
        "Windows 11 24H2 x64 Cumulative Update"
    )


$allCandidates =
    New-Object System.Collections.Generic.List[object]


foreach ($searchTerm in $searchTerms) {

    try {

        $html =
            Search-MicrosoftCatalog `
                -SearchText $searchTerm


        $candidates =
            Get-CatalogCandidates `
                -Html $html


        foreach ($candidate in $candidates) {

            $allCandidates.Add($candidate)
        }
    }
    catch {

        Write-Warning `
            "Catalog search failed for '$searchTerm': $($_.Exception.Message)"
    }
}


if ($allCandidates.Count -eq 0) {

    throw @"
No Windows 11 24H2 x64 cumulative updates were found in Microsoft Update Catalog.

Build:
  $WindowsBuild

Architecture:
  $Architecture
"@
}


# ============================================================
# Deduplicate candidates
# ============================================================

$uniqueCandidates =
    $allCandidates |
    Group-Object {
        if ($_.UpdateId) {
            $_.UpdateId
        }
        else {
            "$($_.KB)|$($_.Title)"
        }
    } |
    ForEach-Object {
        $_.Group[0]
    }


# ============================================================
# Display candidates
# ============================================================

Write-Host ""
Write-Host "Catalog candidates found:"
Write-Host ""


foreach ($candidate in $uniqueCandidates) {

    Write-Host "KB:"
    Write-Host "  $($candidate.KB)"

    Write-Host "Build:"
    Write-Host "  $($candidate.Build)"

    Write-Host "Date:"
    Write-Host "  $($candidate.Date)"

    Write-Host "Update ID:"
    Write-Host "  $($candidate.UpdateId)"

    Write-Host ""
}


# ============================================================
# Select newest candidate
# ============================================================

$rankedCandidates =
    foreach ($candidate in $uniqueCandidates) {

        $dateValue =
            Convert-CatalogDate `
                -Date $candidate.Date


        #
        # A Windows 11 24H2 LCU should have a KB and Update ID.
        #

        if (-not $candidate.KB) {
            continue
        }

        if (-not $candidate.UpdateId) {

            Write-Warning `
                "Skipping $($candidate.KB): no Catalog update ID."

            continue
        }


        #
        # If the Catalog exposes a build, prefer builds beginning
        # with the requested OS build.
        #

        $buildMatch = $false


        if ($candidate.Build) {

            if ($candidate.Build -match "^$([regex]::Escape($WindowsBuild))\.") {

                $buildMatch = $true
            }
        }


        [PSCustomObject]@{
            Candidate = $candidate
            Date      = $dateValue
            BuildMatch = $buildMatch
        }
    }


$matchingBuild =
    $rankedCandidates |
    Where-Object {
        $_.BuildMatch -eq $true
    }


if ($matchingBuild.Count -gt 0) {

    $selected =
        $matchingBuild |
        Sort-Object `
            @{Expression = 'Date'; Descending = $true} |
        Select-Object -First 1
}
else {

    #
    # If Catalog parsing does not expose the build field,
    # select by newest Catalog publication date while retaining
    # the strict Windows 11 24H2 x64 filtering above.
    #

    $selected =
        $rankedCandidates |
        Sort-Object `
            @{Expression = 'Date'; Descending = $true} |
        Select-Object -First 1
}


if (-not $selected) {

    throw "Unable to select a Windows 11 24H2 x64 cumulative update."
}


$candidate =
    $selected.Candidate


Write-Host ""
Write-Host "============================================================"
Write-Host " Selected Update"
Write-Host "============================================================"

Write-Host "KB:"
Write-Host "  $($candidate.KB)"

Write-Host "Build:"
Write-Host "  $($candidate.Build)"

Write-Host "Date:"
Write-Host "  $($candidate.Date)"

Write-Host "Update ID:"
Write-Host "  $($candidate.UpdateId)"

Write-Host "============================================================"


# ============================================================
# Obtain Microsoft download URL
# ============================================================

if (-not $candidate.UpdateId) {

    throw "Selected update does not have a Microsoft Update Catalog update ID."
}


$dialogHtml =
    Get-CatalogDownloadDialog `
        -UpdateId $candidate.UpdateId


$downloadUrl =
    Get-MsuDownloadUrl `
        -Html $dialogHtml


$fileName =
    Get-MsuFileName `
        -Url $downloadUrl


Write-Host ""
Write-Host "Microsoft download URL:"
Write-Host "  $downloadUrl"

Write-Host ""
Write-Host "MSU filename:"
Write-Host "  $fileName"


# ============================================================
# Validate filename
# ============================================================

if ($fileName -notmatch '(?i)\.msu$') {

    throw "Catalog download is not an MSU: $fileName"
}


if ($fileName -notmatch '(?i)windows11') {

    throw @"
Unexpected MSU filename.

Expected Windows 11 package.

Filename:
  $fileName
"@
}


if ($fileName -notmatch '(?i)kb\d{7}') {

    throw @"
Unable to identify KB from MSU filename:

  $fileName
"@
}


$fileKbMatch =
    [regex]::Match(
        $fileName,
        '(?i)(KB\d{7})'
    )


$fileKb =
    $fileKbMatch.Groups[1].Value.ToUpperInvariant()


Write-Host ""
Write-Host "Filename KB:"
Write-Host "  $fileKb"

Write-Host "Catalog KB:"
Write-Host "  $($candidate.KB)"


if ($fileKb -ne $candidate.KB.ToUpperInvariant()) {

    throw @"
CRITICAL UPDATE CORRELATION ERROR.

The Microsoft Catalog update ID and downloaded filename do not
refer to the same KB.

Catalog KB:
  $($candidate.KB)

Filename KB:
  $fileKb

Filename:
  $fileName

Update ID:
  $($candidate.UpdateId)

The package will NOT be downloaded or published.
"@
}


# ============================================================
# Determine Artifactory artifact path
# ============================================================

$artifactPath =
    "Windows11/24H2/$Architecture/LCU/$($candidate.KB)/$fileName"


$artifactUrl =
    Get-ArtifactoryUrl `
        -BaseUrl $ArtifactoryBaseUrl `
        -Repository $ArtifactoryRepo `
        -ArtifactPath $artifactPath


$localPackagePath =
    Join-Path $UpdatesDir $fileName


Write-Host ""
Write-Host "============================================================"
Write-Host " Artifact"
Write-Host "============================================================"

Write-Host "Repository:"
Write-Host "  $ArtifactoryRepo"

Write-Host "Artifact path:"
Write-Host "  $artifactPath"

Write-Host "Artifact URL:"
Write-Host "  $artifactUrl"

Write-Host "Local package:"
Write-Host "  $localPackagePath"

Write-Host "============================================================"


# ============================================================
# Check Artifactory first
# ============================================================

Write-Host ""
Write-Host "Checking Artifactory cache..."


$existsInArtifactory =
    Test-ArtifactoryArtifact `
        -Repository $ArtifactoryRepo `
        -ArtifactPath $artifactPath


if ($existsInArtifactory) {

    Write-Host ""
    Write-Host "Package already exists in Artifactory."

    Write-Host "Downloading cached package..."


    Get-ArtifactoryArtifact `
        -Repository $ArtifactoryRepo `
        -ArtifactPath $artifactPath `
        -DestinationPath $localPackagePath


    Write-Host ""
    Write-Host "Cached package retrieved."
}
else {

    Write-Host ""
    Write-Host "Package is not present in Artifactory."

    Write-Host ""
    Write-Host "Downloading from Microsoft Update Catalog..."


    Invoke-WebRequest `
        -Uri $downloadUrl `
        -OutFile $localPackagePath `
        -UseBasicParsing `
        -ErrorAction Stop


    if (-not (Test-Path -LiteralPath $localPackagePath)) {

        throw "Microsoft package download failed."
    }


    $downloadedFile =
        Get-Item -LiteralPath $localPackagePath


    if ($downloadedFile.Length -eq 0) {

        throw "Microsoft downloaded an empty package."
    }


    Write-Host ""
    Write-Host "Microsoft package downloaded."

    Write-Host "Size:"
    Write-Host "  $($downloadedFile.Length) bytes"
}


# ============================================================
# Calculate SHA256
# ============================================================

Write-Host ""
Write-Host "Calculating package SHA256..."


$sha256 =
    (Get-FileHash `
        -LiteralPath $localPackagePath `
        -Algorithm SHA256).Hash.ToLowerInvariant()


$fileInfo =
    Get-Item -LiteralPath $localPackagePath


Write-Host ""
Write-Host "Package:"
Write-Host "  $fileName"

Write-Host "Size:"
Write-Host "  $($fileInfo.Length) bytes"

Write-Host "SHA256:"
Write-Host "  $sha256"


# ============================================================
# Validate filename again against KB
# ============================================================

$localKbMatch =
    [regex]::Match(
        $fileName,
        '(?i)(KB\d{7})'
    )


if (-not $localKbMatch.Success) {

    throw "Downloaded package filename does not contain a KB number."
}


$localKb =
    $localKbMatch.Groups[1].Value.ToUpperInvariant()


if ($localKb -ne $candidate.KB.ToUpperInvariant()) {

    throw @"
Downloaded package KB mismatch.

Expected:
  $($candidate.KB)

Actual:
  $localKb

File:
  $fileName
"@
}


# ============================================================
# Publish to Artifactory
# ============================================================

if (-not $existsInArtifactory) {

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " Cache Package in Artifactory"
    Write-Host "============================================================"


    Write-Host "Repository:"
    Write-Host "  $ArtifactoryRepo"

    Write-Host "Artifact:"
    Write-Host "  $artifactPath"


    #
    # IMPORTANT:
    #
    # This uses PUT directly against the generic repository.
    #
    # Your Jenkins/Artifactory service account must have deploy
    # permission to snapshot-generic-local.
    #

    Write-Host ""
    Write-Host "Uploading package to Artifactory..."


    Invoke-WebRequest `
        -Uri $artifactUrl `
        -Method Put `
        -InFile $localPackagePath `
        -UseBasicParsing `
        -ErrorAction Stop


    Write-Host ""
    Write-Host "Package cached in Artifactory."
}
else {

    Write-Host ""
    Write-Host "Package already existed in Artifactory."
    Write-Host "No upload required."
}


# ============================================================
# Verify Artifactory package exists
# ============================================================

Write-Host ""
Write-Host "Verifying Artifactory artifact..."


if (
    -not (
        Test-ArtifactoryArtifact `
            -Repository $ArtifactoryRepo `
            -ArtifactPath $artifactPath
    )
) {

    throw @"
Artifactory verification failed.

Expected artifact:

Repository:
  $ArtifactoryRepo

Path:
  $artifactPath
"@
}


# ============================================================
# Create resolved update manifest
# ============================================================

$resolvedUpdate =
    [ordered]@{

        type =
            'LCU'

        kb =
            $candidate.KB

        build =
            $candidate.Build

        date =
            $candidate.Date

        architecture =
            $Architecture

        windowsBuild =
            $WindowsBuild

        updateId =
            $candidate.UpdateId

        fileName =
            $fileName

        downloadUrl =
            $downloadUrl

        artifactPath =
            $artifactPath

        sha256 =
            $sha256

        size =
            $fileInfo.Length

        ssuIncluded =
            $true

        source =
            'Microsoft Update Catalog'

        resolvedAtUtc =
            [DateTime]::UtcNow.ToString(
                'yyyy-MM-ddTHH:mm:ss.fffZ'
            )
    }


$resolvedJson =
    $resolvedUpdate |
    ConvertTo-Json -Depth 10


Set-Content `
    -LiteralPath $ResolvedFile `
    -Value $resolvedJson `
    -Encoding UTF8


# ============================================================
# Final verification
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " Resolution Complete"
Write-Host "============================================================"

Write-Host "Selected KB:"
Write-Host "  $($resolvedUpdate.kb)"

Write-Host ""
Write-Host "Build:"
Write-Host "  $($resolvedUpdate.build)"

Write-Host ""
Write-Host "Date:"
Write-Host "  $($resolvedUpdate.date)"

Write-Host ""
Write-Host "Update ID:"
Write-Host "  $($resolvedUpdate.updateId)"

Write-Host ""
Write-Host "Filename:"
Write-Host "  $($resolvedUpdate.fileName)"

Write-Host ""
Write-Host "Artifact:"
Write-Host "  $($resolvedUpdate.artifactPath)"

Write-Host ""
Write-Host "SHA256:"
Write-Host "  $($resolvedUpdate.sha256)"

Write-Host ""
Write-Host "Size:"
Write-Host "  $($resolvedUpdate.size) bytes"

Write-Host ""
Write-Host "Local package:"
Write-Host "  $localPackagePath"

Write-Host ""
Write-Host "Resolved manifest:"
Write-Host "  $ResolvedFile"

Write-Host ""
Write-Host "============================================================"
Write-Host " Windows Update Resolver SUCCESS"
Write-Host "============================================================"
