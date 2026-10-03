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

if ($Architecture -match '^(?i)(x64|amd64)$') {
    $Architecture = 'x64'
}

$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)

$DownloadDir = Join-Path $WorkRoot 'download'
$UpdatesDir  = Join-Path $DownloadDir 'updates'
$Manifest    = Join-Path $DownloadDir 'resolved-updates.json'

New-Item -ItemType Directory -Force -Path $DownloadDir, $UpdatesDir |
    Out-Null

# ---------------------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------------------

$profileScript = Join-Path `
    (Split-Path -Parent $MyInvocation.MyCommand.Path) `
    'profiles.ps1'

if (-not (Test-Path -LiteralPath $profileScript)) {
    throw "profiles.ps1 not found: $profileScript"
}

. $profileScript

$profileInfo = Get-WindowsImageProfile -Name $Profile

# ---------------------------------------------------------------------------
# Artifactory
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($ArtifactoryBaseUrl)) {
    throw 'ArtifactoryBaseUrl is required.'
}

$ArtifactoryBaseUrl = $ArtifactoryBaseUrl.TrimEnd('/')

if ($ArtifactoryBaseUrl -notmatch '/artifactory$') {
    $ArtifactoryRoot = "$ArtifactoryBaseUrl/artifactory"
}
else {
    $ArtifactoryRoot = $ArtifactoryBaseUrl
}

$Headers = @{}

if (-not [string]::IsNullOrWhiteSpace($ArtifactoryToken)) {
    $Headers['Authorization'] = "Bearer $ArtifactoryToken"
}
elseif (
    -not [string]::IsNullOrWhiteSpace($ArtifactoryUser) -and
    -not [string]::IsNullOrWhiteSpace($ArtifactoryPassword)
) {
    $pair = "$ArtifactoryUser`:$ArtifactoryPassword"
    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes($pair)
    )
    $Headers['Authorization'] = "Basic $encoded"
}

function Get-ArtifactoryUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    return "$ArtifactoryRoot/$ArtifactoryRepo/$($RelativePath.TrimStart('/'))"
}

function Test-ArtifactoryFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $url = Get-ArtifactoryUrl $RelativePath

    try {
        if ($Headers.Count -gt 0) {
            Invoke-WebRequest `
                -Uri $url `
                -Headers $Headers `
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

function Download-Url {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [hashtable]$RequestHeaders = @{}
    )

    Write-Host "Downloading:"
    Write-Host "  $Url"
    Write-Host "To:"
    Write-Host "  $Destination"

    if ($RequestHeaders.Count -gt 0) {
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

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw "Download did not create file: $Destination"
    }

    if ((Get-Item -LiteralPath $Destination).Length -eq 0) {
        throw "Downloaded file is empty: $Destination"
    }
}

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

# ---------------------------------------------------------------------------
# Microsoft Update Catalog
# ---------------------------------------------------------------------------

function Get-CatalogHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $url =
        'https://www.catalog.update.microsoft.com/Search.aspx?q=' +
        [uri]::EscapeDataString($Query)

    Write-Host "Catalog query: $Query"

    return (
        Invoke-WebRequest `
            -Uri $url `
            -UseBasicParsing `
            -TimeoutSec 120
    ).Content
}

function Get-CatalogDownloadUrls {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UpdateId
    )

    $item = @{
        size     = 0
        updateID = $UpdateId
        uidInfo  = $UpdateId
    } | ConvertTo-Json -Compress

    $body = @{
        updateIDs = "[$item]"
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

    return @(
        [regex]::Matches(
            $content,
            'https?://[^"''\s<>]+'
        ) |
        ForEach-Object {
            $_.Value.TrimEnd("'", '"', ')', ';')
        } |
        Where-Object {
            $_ -match '(?i)download\.windowsupdate\.com' -or
            $_ -match '(?i)windowsupdate\.com' -or
            $_ -match '(?i)delivery\.mp\.microsoft\.com'
        } |
        Select-Object -Unique
    )
}

function Get-CatalogRows {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Html
    )

    $rows = @()

    foreach (
        $match in [regex]::Matches(
            $Html,
            '<tr[^>]*>(.*?)</tr>',
            [Text.RegularExpressions.RegexOptions]::Singleline
        )
    ) {
        $row = $match.Groups[1].Value

        $plainRow = $row -replace '<[^>]+>', ' '
        $text = [Net.WebUtility]::HtmlDecode([string]$plainRow)

        $text = $text -replace '\s+', ' '
        $text = $text.Trim()

        if ($text -notmatch $profileInfo.CatalogProductPattern) {
            continue
        }

        if ($text -notmatch '(?i)Cumulative Update') {
            continue
        }

        if (
            $text -match '(?i)Preview' -or
            $text -match '(?i)\.NET' -or
            $text -match '(?i)Dynamic Update' -or
            $text -match '(?i)Driver' -or
            $text -match '(?i)Server'
        ) {
            continue
        }

        if ($Architecture -eq 'x64') {
            if (
                $text -notmatch '(?i)x64-based Systems' -or
                $text -match '(?i)ARM64'
            ) {
                continue
            }
        }
        elseif ($Architecture -eq 'arm64') {
            if ($text -notmatch '(?i)ARM64-based Systems') {
                continue
            }
        }

        $kbMatch = [regex]::Match(
            $text,
            '(?i)\(KB(\d+)\)'
        )

        if (-not $kbMatch.Success) {
            continue
        }

        $build = ''

        if ($profileInfo.CatalogBuildRequired) {
            $buildMatch = [regex]::Match(
                $text,
                "\(($($profileInfo.BuildRegex))\)"
            )

            if (-not $buildMatch.Success) {
                continue
            }

            $build = $buildMatch.Groups[1].Value
        }

        $date = [datetime]::MinValue

        $dateMatch = [regex]::Match(
            $text,
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

        # CRITICAL:
        # UpdateID is extracted from this SAME row.
        $updateIds = @(
            [regex]::Matches(
                $row,
                '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
            ) |
            ForEach-Object Value |
            Select-Object -Unique
        )

        if ($updateIds.Count -eq 0) {
            continue
        }

        $rows += [pscustomobject]@{
            KB        = "KB$($kbMatch.Groups[1].Value)"
            Build     = $build
            Date      = $date
            Title     = $text
            UpdateIds = $updateIds
        }
    }

    return $rows
}

# ---------------------------------------------------------------------------
# Package inspection
# ---------------------------------------------------------------------------

function Find-SevenZip {
    $paths = @(
        'C:\Program Files\7-Zip\7z.exe',
        'C:\Program Files (x86)\7-Zip\7z.exe'
    )

    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $path
        }
    }

    $command = Get-Command 7z.exe -ErrorAction SilentlyContinue

    if ($command) {
        return $command.Source
    }

    throw '7-Zip was not found on the Windows image builder.'
}

function Get-Windows10PackageBuild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MsuPath,

        [Parameter(Mandatory = $true)]
        [string]$KB
    )

    $sevenZip = Find-SevenZip

    $extractDir = Join-Path `
        $UpdatesDir `
        ("inspect-" + [IO.Path]::GetFileNameWithoutExtension($MsuPath))

    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item `
            -LiteralPath $extractDir `
            -Recurse `
            -Force
    }

    New-Item `
        -ItemType Directory `
        -Path $extractDir `
        -Force |
        Out-Null

    & $sevenZip `
        x `
        $MsuPath `
        "-o$extractDir" `
        '-y' `
        2>&1 |
        ForEach-Object {
            Write-Host $_
        }

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to extract $MsuPath."
    }

    $kbNumber = $KB -replace '^KB', ''

    $lcuCab = Get-ChildItem `
        -LiteralPath $extractDir `
        -Recurse `
        -Filter '*.cab' `
        -File |
        Where-Object {
            $_.Name -match (
                "(?i)^Windows10\.0-KB$([regex]::Escape($kbNumber))-"
            )
        } |
        Select-Object -First 1

    if (-not $lcuCab) {
        throw "LCU CAB for $KB was not found in $MsuPath."
    }

    $cabDir = Join-Path $extractDir 'lcu-cab'

    New-Item `
        -ItemType Directory `
        -Path $cabDir `
        -Force |
        Out-Null

    & $sevenZip `
        x `
        $lcuCab.FullName `
        "-o$cabDir" `
        '-y' `
        2>&1 |
        ForEach-Object {
            Write-Host $_
        }

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to extract LCU CAB: $($lcuCab.FullName)"
    }

    $mum = Get-ChildItem `
        -LiteralPath $cabDir `
        -Recurse `
        -Filter '*.mum' `
        -File |
        Where-Object {
            $_.Name -match '(?i)lcu|cumulative|package'
        } |
        Select-Object -First 1

    if (-not $mum) {
        $mum = Get-ChildItem `
            -LiteralPath $cabDir `
            -Recurse `
            -Filter '*.mum' `
            -File |
            Select-Object -First 1
    }

    if (-not $mum) {
        throw "No MUM metadata found in LCU CAB: $($lcuCab.Name)"
    }

    [xml]$xml = Get-Content `
        -LiteralPath $mum.FullName `
        -Raw

    $version = $null

    $packageNode = $xml.package

    if ($packageNode -and $packageNode.Identity) {
        $version = [string]$packageNode.Identity.version
    }

    if ([string]::IsNullOrWhiteSpace($version)) {
        $version = [string]$packageNode.assemblyIdentity.version
    }

    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Could not determine package version from $($mum.FullName)"
    }

    $buildMatch = [regex]::Match(
        $version,
        '^\d+\.\d+\.(\d+)\.(\d+)$'
    )

    if (-not $buildMatch.Success) {
        throw "Unexpected Windows 10 package version: $version"
    }

    return "$($buildMatch.Groups[1].Value).$($buildMatch.Groups[2].Value)"
}

# ---------------------------------------------------------------------------
# Resolve one Catalog package
# ---------------------------------------------------------------------------

function Resolve-CatalogPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedType
    )

    $html = Get-CatalogHtml -Query $Query
    $rows = @(Get-CatalogRows -Html $html)

    if ($rows.Count -eq 0) {
        throw "No Microsoft Update Catalog candidates found for: $Query"
    }

    $row = $rows |
        Sort-Object Date -Descending |
        Select-Object -First 1

    Write-Host ''
    Write-Host "Selected Catalog row:"
    Write-Host "  KB:    $($row.KB)"
    Write-Host "  Build: $($row.Build)"
    Write-Host "  Date:  $($row.Date.ToString('yyyy-MM-dd'))"
    Write-Host "  Title: $($row.Title)"

    $download = $null
    $selectedId = $null

    foreach ($id in $row.UpdateIds) {
        $urls = @(Get-CatalogDownloadUrls -UpdateId $id)

        foreach ($url in $urls) {
            $name = [IO.Path]::GetFileName(
                ([uri]$url).AbsolutePath
            )

            if ($name -match '(?i)\.(msu|cab)$') {
                $download = $url
                $selectedId = $id
                break
            }
        }

        if ($download) {
            break
        }
    }

    if (-not $download) {
        throw "No downloadable package found for $($row.KB)."
    }

    $fileName = [IO.Path]::GetFileName(
        ([uri]$download).AbsolutePath
    )

    return [pscustomobject]@{
        Type       = $ExpectedType
        KB         = $row.KB
        Build      = $row.Build
        Date       = $row.Date
        Title      = $row.Title
        UpdateId   = $selectedId
        Url        = $download
        FileName   = $fileName
    }
}

# ---------------------------------------------------------------------------
# Main resolution
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '============================================================'
Write-Host ' Windows Update Resolver'
Write-Host '============================================================'
Write-Host "Profile      : $Profile"
Write-Host "Product      : $($profileInfo.Product)"
Write-Host "Windows      : $($profileInfo.WindowsVersion)"
Write-Host "Base Build   : $($profileInfo.Build)"
Write-Host "Architecture : $Architecture"
Write-Host '============================================================'

# ---------------------------------------------------------------------------
# Windows 11 24H2
#
# One cumulative MSU. The MSU contains the servicing payload required by
# Windows 11 24H2. The resolver records whether an SSU payload is present.
# ---------------------------------------------------------------------------

if ($Profile -eq 'windows11-24h2') {

    $query = $profileInfo.CatalogQuery

    $selected = Resolve-CatalogPackage `
        -Query $query `
        -ExpectedType 'LCU'

    if ($selected.FileName -notmatch '(?i)\.msu$') {
        throw "Windows 11 LCU is not an MSU: $($selected.FileName)"
    }

    $relativePath =
        "$($profileInfo.Product)/$($profileInfo.Release)/$Architecture/" +
        "updates/$($selected.FileName)"

    $localPath = Join-Path $UpdatesDir $selected.FileName
    $artifactoryUrl = Get-ArtifactoryUrl $relativePath

    $source = 'Microsoft'

    if (
        -not $ForceMicrosoftDownload -and
        (Test-ArtifactoryFile -RelativePath $relativePath)
    ) {
        Write-Host "Using cached Artifactory MSU."
        Download-Url `
            -Url $artifactoryUrl `
            -Destination $localPath `
            -RequestHeaders $Headers

        $source = 'Artifactory'
    }
    else {
        Write-Host "Downloading MSU from Microsoft Catalog."
        Download-Url `
            -Url $selected.Url `
            -Destination $localPath

        if (-not $ForceMicrosoftDownload) {
            Write-Host "Publishing resolved MSU to Artifactory."

            if (Test-ArtifactoryFile -RelativePath $relativePath) {
                Write-Host "Artifactory package already exists."
            }
            else {
                Invoke-WebRequest `
                    -Uri $artifactoryUrl `
                    -Method Put `
                    -Headers $Headers `
                    -InFile $localPath `
                    -UseBasicParsing `
                    -TimeoutSec 3600
            }
        }
    }

    $sha256 = Get-Sha256 $localPath

    # Inspect the MSU for the Windows 11 LCU WIM and SSU payload.
    $sevenZip = Find-SevenZip

    $listing = @(
        & $sevenZip l $localPath 2>&1
    )

    if ($LASTEXITCODE -ne 0) {
        throw "7-Zip failed to inspect $localPath"
    }

    $ssuIncluded = (
        $listing -match '(?i)SSU-\d+\.\d+-[^ ]+\.cab'
    )

    $resolvedObject = [ordered]@{
        schemaVersion = '1.2'
        type = 'LCU'

        profile        = $profileInfo.Name
        product        = $profileInfo.Product
        windowsVersion = $profileInfo.WindowsVersion
        release        = $profileInfo.Release
        windowsBuild   = $profileInfo.Build

        artifactRoot = $profileInfo.ArtifactRoot
        isoPrefix    = $profileInfo.IsoPrefix

        kb          = $selected.KB
        build       = $selected.Build
        releaseDate = $selected.Date.ToString('yyyy-MM-dd')

        architecture = $Architecture

        updateId = $selected.UpdateId
        fileName = $selected.FileName
        sha256   = $sha256

        microsoftUrl = $selected.Url

        artifactoryUrl  = $artifactoryUrl
        artifactoryRepo = $ArtifactoryRepo
        artifactoryPath = $relativePath

        source = $source

        ssuRequired = $false
        ssuIncluded = [bool]$ssuIncluded
        ssuSource   = if ($ssuIncluded) { 'LCU-MSU' } else { 'none' }

        ssu = $null

        resolvedAtUtc =
            [datetime]::UtcNow.ToString('o')
    }

    $json = $resolvedObject | ConvertTo-Json -Depth 10

    [IO.File]::WriteAllText(
        $Manifest,
        $json,
        [Text.UTF8Encoding]::new($false)
    )

    Write-Host ''
    Write-Host 'Windows 11 resolution complete.'
    Write-Host "KB:          $($selected.KB)"
    Write-Host "Build:       $($selected.Build)"
    Write-Host "MSU:         $($selected.FileName)"
    Write-Host "SHA256:      $sha256"
    Write-Host "SSU included: $ssuIncluded"

    exit 0
}

# ---------------------------------------------------------------------------
# Windows 10 21H2
#
# IMPORTANT:
# Resolve the standalone SSU first.
# Then resolve the LCU separately.
#
# The resulting manifest contains:
#
#   ssu
#   lcu
#
# Service-image.ps1 applies:
#
#   SSU -> verify -> LCU
# ---------------------------------------------------------------------------

if ($Profile -eq 'windows10-21h2') {

    $ssuQuery = $profileInfo.SsuCatalogQuery

    if ([string]::IsNullOrWhiteSpace($ssuQuery)) {
        throw 'Windows 10 profile does not define SsuCatalogQuery.'
    }

    $lcuQuery = $profileInfo.CatalogQuery

    if ([string]::IsNullOrWhiteSpace($lcuQuery)) {
        throw 'Windows 10 profile does not define CatalogQuery.'
    }

    Write-Host ''
    Write-Host 'Resolving standalone Windows 10 SSU...'

    $ssu = Resolve-CatalogPackage `
        -Query $ssuQuery `
        -ExpectedType 'SSU'

    if ($ssu.FileName -notmatch '(?i)\.(msu|cab)$') {
        throw "Unexpected Windows 10 SSU package: $($ssu.FileName)"
    }

    Write-Host ''
    Write-Host 'Resolving Windows 10 LCU...'

    $lcu = Resolve-CatalogPackage `
        -Query $lcuQuery `
        -ExpectedType 'LCU'

    if ($lcu.FileName -notmatch '(?i)\.msu$') {
        throw "Windows 10 LCU must be an MSU: $($lcu.FileName)"
    }

    # Download SSU.
    $ssuRelative =
        "$($profileInfo.Product)/$($profileInfo.Release)/$Architecture/" +
        "updates/$($ssu.FileName)"

    $ssuLocal = Join-Path $UpdatesDir $ssu.FileName
    $ssuUrl = Get-ArtifactoryUrl $ssuRelative

    if (
        -not $ForceMicrosoftDownload -and
        (Test-ArtifactoryFile -RelativePath $ssuRelative)
    ) {
        Download-Url `
            -Url $ssuUrl `
            -Destination $ssuLocal `
            -RequestHeaders $Headers
    }
    else {
        Download-Url `
            -Url $ssu.Url `
            -Destination $ssuLocal

        if (-not $ForceMicrosoftDownload) {
            if (-not (Test-ArtifactoryFile -RelativePath $ssuRelative)) {
                Invoke-WebRequest `
                    -Uri $ssuUrl `
                    -Method Put `
                    -Headers $Headers `
                    -InFile $ssuLocal `
                    -UseBasicParsing `
                    -TimeoutSec 3600
            }
        }
    }

    # Download LCU.
    $lcuRelative =
        "$($profileInfo.Product)/$($profileInfo.Release)/$Architecture/" +
        "updates/$($lcu.FileName)"

    $lcuLocal = Join-Path $UpdatesDir $lcu.FileName
    $lcuUrl = Get-ArtifactoryUrl $lcuRelative

    if (
        -not $ForceMicrosoftDownload -and
        (Test-ArtifactoryFile -RelativePath $lcuRelative)
    ) {
        Download-Url `
            -Url $lcuUrl `
            -Destination $lcuLocal `
            -RequestHeaders $Headers
    }
    else {
        Download-Url `
            -Url $lcu.Url `
            -Destination $lcuLocal

        if (-not $ForceMicrosoftDownload) {
            if (-not (Test-ArtifactoryFile -RelativePath $lcuRelative)) {
                Invoke-WebRequest `
                    -Uri $lcuUrl `
                    -Method Put `
                    -Headers $Headers `
                    -InFile $lcuLocal `
                    -UseBasicParsing `
                    -TimeoutSec 3600
            }
        }
    }

    $ssuSha256 = Get-Sha256 $ssuLocal
    $lcuSha256 = Get-Sha256 $lcuLocal

    $packageBuild = Get-Windows10PackageBuild `
        -MsuPath $lcuLocal `
        -KB $lcu.KB

    if (
        -not [string]::IsNullOrWhiteSpace($lcu.Build) -and
        $packageBuild -ne $lcu.Build
    ) {
        Write-Warning (
            "Catalog build '$($lcu.Build)' differs from package build " +
            "'$packageBuild'. Package build will be authoritative."
        )
    }

    $resolvedBuild = $packageBuild

    $resolvedObject = [ordered]@{
        schemaVersion = '1.2'
        type = 'LCU'

        profile        = $profileInfo.Name
        product        = $profileInfo.Product
        windowsVersion = $profileInfo.WindowsVersion
        release        = $profileInfo.Release
        windowsBuild   = $profileInfo.Build

        artifactRoot = $profileInfo.ArtifactRoot
        isoPrefix    = $profileInfo.IsoPrefix

        kb          = $lcu.KB
        build       = $resolvedBuild
        releaseDate = $lcu.Date.ToString('yyyy-MM-dd')

        architecture = $Architecture

        updateId = $lcu.UpdateId
        fileName = $lcu.FileName
        sha256   = $lcuSha256

        microsoftUrl = $lcu.Url

        artifactoryUrl  = $lcuUrl
        artifactoryRepo = $ArtifactoryRepo
        artifactoryPath = $lcuRelative

        source = if (
            -not $ForceMicrosoftDownload -and
            (Test-ArtifactoryFile -RelativePath $lcuRelative)
        ) {
            'Artifactory'
        }
        else {
            'Microsoft'
        }

        ssuRequired = $true
        ssuIncluded = $false
        ssuSource   = 'standalone'

        ssu = [ordered]@{
            kb = $ssu.KB
            build = $ssu.Build
            releaseDate = $ssu.Date.ToString('yyyy-MM-dd')
            updateId = $ssu.UpdateId
            fileName = $ssu.FileName
            sha256 = $ssuSha256
            microsoftUrl = $ssu.Url
            artifactoryUrl = $ssuUrl
            artifactoryRepo = $ArtifactoryRepo
            artifactoryPath = $ssuRelative
            source = 'resolved'
        }

        lcu = [ordered]@{
            kb = $lcu.KB
            build = $resolvedBuild
            releaseDate = $lcu.Date.ToString('yyyy-MM-dd')
            updateId = $lcu.UpdateId
            fileName = $lcu.FileName
            sha256 = $lcuSha256
            microsoftUrl = $lcu.Url
            artifactoryUrl = $lcuUrl
            artifactoryRepo = $ArtifactoryRepo
            artifactoryPath = $lcuRelative
        }

        resolvedAtUtc =
            [datetime]::UtcNow.ToString('o')
    }

    $json = $resolvedObject | ConvertTo-Json -Depth 20

    [IO.File]::WriteAllText(
        $Manifest,
        $json,
        [Text.UTF8Encoding]::new($false)
    )

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' Windows 10 Updates Resolved'
    Write-Host '============================================================'
    Write-Host "SSU:"
    Write-Host "  $($ssu.KB)"
    Write-Host "  $($ssu.FileName)"
    Write-Host "  SHA256: $ssuSha256"
    Write-Host ''
    Write-Host "LCU:"
    Write-Host "  $($lcu.KB)"
    Write-Host "  $($lcu.FileName)"
    Write-Host "  Build: $resolvedBuild"
    Write-Host "  SHA256: $lcuSha256"
    Write-Host ''
    Write-Host "Manifest:"
    Write-Host "  $Manifest"
    Write-Host '============================================================'

    exit 0
}

throw "Unsupported Windows image profile: $Profile"