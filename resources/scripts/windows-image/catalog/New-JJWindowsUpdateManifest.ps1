[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidatePattern('^20\d{2}-(0[1-9]|1[0-2])$')]
    [string]$Month,

    [Parameter(Mandatory=$true)]
    [ValidateSet('windows10-21h2')]
    [string]$Profile,

    [string]$ImageUrl,
	# 0 means use the baseline manifest's image_index.
	[ValidateRange(0,5)]
	[int]$ImageIndex = 0,

    [string]$AdkUrl,
    [string]$AdkVersion,
    [string]$ArtifactBaseUrl,
    [string]$ArtifactSubPath,

    # Existing JJV manifest used as the source of truth for the SSU dependency.
    # Defaults to .\manifest.json in the current working directory.
    [string]$BaselineManifestPath = (Join-Path $PWD 'manifest.json'),

    # Set only when prerequisite analysis confirms that the selected LCU
    # requires a different/newer standalone SSU. Never auto-upgrade the SSU.
    [ValidatePattern('^\d{6,8}$')]
    [string]$RequiredSsuKb,

    [string]$Project = 'JJSVCommon',
    [string]$ProjectVersion = 'v1.0',
    [string]$Repo = 'installwim_update',
    [string]$OutputPath = (Join-Path $PWD 'manifest.json'),
    [switch]$DownloadPackages,
    [string]$DownloadRoot = (Join-Path $PWD 'catalog-downloads')
)

if ([string]::IsNullOrWhiteSpace($Month)) {
    $Month = (Get-Date).ToString('yyyy-MM')
    Write-Host "Month not specified. Using current month: $Month"
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WindowsImageProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    switch ($Name.ToLowerInvariant()) {
        'windows10-21h2' {
            [pscustomobject]@{
                Name           = 'windows10-21h2'
                Product        = 'Windows10'
                WindowsVersion = 'Windows 10 21H2'
                CatalogProductPattern = '(?i)Windows 10\s*,?\s*version 21H2'
                CatalogBuildRequired  = $false
                CatalogSecurityUpdatesRequired = $false
                Release        = '21H2'
                Build          = '19044'
                BuildRegex     = '19044\.\d+'
                CatalogQuery   = 'Windows 10 Version 21H2 cumulative update x64'
                ArtifactRoot   = 'Windows10/21H2'
                IsoPrefix      = 'Windows10-21H2'
                BaseIsoArtifact = 'Windows10/21H2/x64/base/en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso'
                BaseIsoSha256   = 'a0334f31ea7a3e6932b9ad7206608248f0bd40698bfb8fc65f14fc5e4976c160'
            }
        }
        default {
            throw "Unknown Windows image profile '$Name'. Supported profiles: windows10-21h2"
        }
    }
}

# The profile file remains the source of truth for supported Windows releases.

$profileInfo = Get-WindowsImageProfile -Name $Profile

if (-not (Get-Module -ListAvailable -Name OSD)) {
    throw 'OSD module is required. Install it with: Install-Module OSD -Scope CurrentUser'
}
Import-Module OSD -ErrorAction Stop
if (-not (Get-Command Get-MsUpCat -ErrorAction SilentlyContinue)) {
    throw 'Get-MsUpCat is not available in the installed OSD module.'
}

$monthStart = [datetime]::ParseExact("$Month-01", 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
$monthEnd = $monthStart.AddMonths(1).AddDays(-1)
$osLabel = if ($Profile -like 'windows10-*') { 'Windows 10' } else { 'Windows 11' }
$release = [string]$profileInfo.Release
$archToken = 'x64'

function Get-Prop {
    param([object]$InputObject, [string[]]$Names)
    if ($null -eq $InputObject) { return $null }
    foreach ($n in $Names) {
        $p = $InputObject.PSObject.Properties[$n]
        if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    }
    return $null
}

function Get-TitleDate {
    param(
        [string]$Title,
        [object]$Item
    )

    # 1. Prefer the actual Catalog release/publication date.
    $v = Get-Prop $Item @(
        'ReleaseDate',
        'DateReleased',
        'PublishedDate'
    )

    if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) {
        try {
            return ([datetime]$v).Date
        }
        catch {}
    }

    # 2. Extract a full YYYY-MM-DD date from the title.
    if ($Title -match '(?<y>20\d{2})-(?<m>0[1-9]|1[0-2])-(?<d>0[1-9]|[12]\d|3[01])') {
        try {
            return [datetime]::new(
                [int]$Matches.y,
                [int]$Matches.m,
                [int]$Matches.d
            )
        }
        catch {}
    }

    # 3. Fallback to Catalog last-updated date.
    $v = Get-Prop $Item @(
        'LastUpdated',
        'CatalogDate'
    )

    if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) {
        try {
            return ([datetime]$v).Date
        }
        catch {}
    }

    return $null
}

function Test-ReleaseMonth {
    param([string]$Title,[object]$Item,[string]$ExpectedMonth)
    if ($Title -match '^(?<y>20\d{2})-(?<m>0[1-9]|1[0-2])') {
        return (('{0}-{1}' -f $Matches.y,$Matches.m) -eq $ExpectedMonth)
    }
    $d = Get-TitleDate -Title $Title -Item $Item
    return ($d -and $d.ToString('yyyy-MM') -eq $ExpectedMonth)
}


function Get-CatalogDownload {
    param(
        [Parameter(Mandatory=$true)][string]$UpdateId,
        [Parameter(Mandatory=$true)][string]$ExpectedKb,
        [Parameter(Mandatory=$true)][string]$Architecture
    )

    if ([string]::IsNullOrWhiteSpace($UpdateId)) {
        throw "Microsoft Update Catalog candidate for KB$ExpectedKb has no UpdateID."
    }

    $guid = [guid]::Empty
    if (-not [guid]::TryParse($UpdateId, [ref]$guid)) {
        throw "Microsoft Update Catalog returned an invalid UpdateID '$UpdateId' for KB$ExpectedKb."
    }

    # Use the known-working DownloadDialog payload.
    $obj = @{
        size     = 0
        updateID = $guid.ToString()
        uidInfo  = $guid.ToString()
    } | ConvertTo-Json -Compress

    $body = @{ updateIDs = "[$obj]" }

    $response = Invoke-WebRequest `
        -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' `
        -Method Post `
        -Body $body `
        -ContentType 'application/x-www-form-urlencoded' `
        -UseBasicParsing `
        -TimeoutSec 120

    $content = [string]$response.Content

    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "DownloadDialog returned an empty response for KB$ExpectedKb (UpdateID $UpdateId)."
    }

    # IMPORTANT:
    # ErrorInline.aspx appears in the normal page's generic JavaScript
    # window.onerror handler. It is NOT evidence of a failed request.
    #
    # Extract the actual downloadInformation file records instead.
    $urlAssignments = [regex]::Matches(
        $content,
        '(?is)downloadInformation\[(?<update>\d+)\]\.files\[(?<file>\d+)\]\.url\s*=\s*''(?<url>[^'']+)''\s*;'
    )

    $expectedNumber = $ExpectedKb -replace '(?i)^KB', ''

    foreach ($assignment in $urlAssignments) {
        $updateIndex = $assignment.Groups['update'].Value
        $fileIndex = $assignment.Groups['file'].Value

        $url = [Net.WebUtility]::HtmlDecode(
            $assignment.Groups['url'].Value
        ).Replace('&amp;', '&')

        # Read filename and digest from the SAME file record.
        $fileNamePattern = '(?is)downloadInformation\[' +
            [regex]::Escape($updateIndex) +
            '\]\.files\[' + [regex]::Escape($fileIndex) +
            '\]\.fileName\s*=\s*''(?<name>[^'']+)''\s*;'

        $digestPattern = '(?is)downloadInformation\[' +
            [regex]::Escape($updateIndex) +
            '\]\.files\[' + [regex]::Escape($fileIndex) +
            '\]\.digest\s*=\s*''(?<digest>[^'']*)''\s*;'

        $nameMatch = [regex]::Match($content, $fileNamePattern)
        $digestMatch = [regex]::Match($content, $digestPattern)

        if (-not $nameMatch.Success) {
            continue
        }

        $fileName = [Net.WebUtility]::HtmlDecode(
            $nameMatch.Groups['name'].Value
        )

        if ($fileName -notmatch '(?i)\.msu$') {
            continue
        }

        if ($fileName -notmatch "(?i)kb$([regex]::Escape($expectedNumber))(?:[^0-9]|$)") {
            continue
        }

        switch ($Architecture.ToLowerInvariant()) {
            { $_ -in 'x64', 'amd64' } {
                if ($fileName -notmatch '(?i)(x64|amd64)') {
                    continue
                }
            }
            'arm64' {
                if ($fileName -notmatch '(?i)arm64') {
                    continue
                }
            }
            'x86' {
                if ($fileName -notmatch '(?i)x86') {
                    continue
                }
            }
            default {
                throw "Unsupported Catalog package architecture '$Architecture'."
            }
        }

        $uri = $null
        if (-not [uri]::TryCreate(
            $url,
            [System.UriKind]::Absolute,
            [ref]$uri
        )) {
            continue
        }

        if ($uri.Scheme -notin @('http', 'https')) {
            continue
        }

        if ($uri.Host -notmatch '(?i)(^|\.)windowsupdate\.com$|(^|\.)delivery\.mp\.microsoft\.com$') {
            continue
        }

        # Catalog digest is already Base64-encoded SHA-1.
        $digest = $null
        $digestAlgorithm = $null

        if ($digestMatch.Success) {
            $candidateDigest = $digestMatch.Groups['digest'].Value.Trim()

            if (-not [string]::IsNullOrWhiteSpace($candidateDigest)) {
                try {
                    $digestBytes = [Convert]::FromBase64String($candidateDigest)

                    if ($digestBytes.Length -eq 20) {
                        $digest = [Convert]::ToBase64String($digestBytes)
                        $digestAlgorithm = 'SHA1'
                    }
                }
                catch {
                    throw "Catalog returned an invalid SHA-1 digest for KB$expectedNumber ($fileName)."
                }
            }
        }

        return [pscustomobject]@{
            Url             = $url
            FileName        = $fileName
            SizeBytes       = $null
            Digest          = $digest
            DigestAlgorithm = $digestAlgorithm
        }
    }

    $titleMatch = [regex]::Match(
        $content,
        '(?is)<title[^>]*>(?<title>.*?)</title>'
    )

    $pageTitle = if ($titleMatch.Success) {
        [Net.WebUtility]::HtmlDecode(
            ($titleMatch.Groups['title'].Value -replace '<[^>]+>', ' ')
        ) -replace '\s+', ' '
    }
    else {
        'unknown page'
    }

    throw "Catalog DownloadDialog contained no usable $Architecture MSU record matching KB$expectedNumber for UpdateID $UpdateId. Page='$pageTitle'."
}


function Convert-DigestToBase64 {
    param([object]$Download)
    if ($null -eq $Download -or -not $Download.Digest -or $Download.DigestAlgorithm -notmatch '(?i)^SHA-?1$') { return $null }
    $d = ([string]$Download.Digest).Trim()
    if ($d -match '^[A-Fa-f0-9]{40}$') {
        $bytes = New-Object byte[] 20
        for ($i=0; $i -lt 20; $i++) { $bytes[$i] = [Convert]::ToByte($d.Substring($i*2,2),16) }
        return [Convert]::ToBase64String($bytes)
    }
    try {
        $bytes = [Convert]::FromBase64String($d)
        if ($bytes.Length -eq 20) { return [Convert]::ToBase64String($bytes) }
    } catch {}
    return $null
}

function Get-CatalogCandidates {
    param([string]$Query)
    Write-Host "Catalog query: $Query"
    return @(Get-MsUpCat -Search $Query)
}

function Test-ApplicableTitle {
    param([string]$Title,[string]$Kind)
    if ($Title -notmatch [string]$profileInfo.CatalogProductPattern) { return $false }
    if ($Title -notmatch '(?i)(x64|64-based|64-bit)') { return $false }
    if ($Title -match '(?i)(ARM64|ARM-based|x86|32-bit|Preview)') { return $false }
    switch ($Kind) {
        'SSU' { return ($Title -match '(?i)Servicing Stack Update') }
        'LCU' { return (($Title -match '(?i)Cumulative Update') -and ($Title -notmatch '(?i)\.NET Framework')) }
        'DOTNET' { return (($Title -match '(?i)\.NET Framework') -and ($Title -match '(?i)\b4\.8\b') -and ($Title -notmatch '(?i)4\.8\.1')) }
    }
    return $false
}

function New-OriginRecord {
    param([object]$Item,[string]$Kind)
    $title = [string](Get-Prop $Item @('Title','UpdateTitle'))
    $updateId = [string](Get-Prop $Item @('Guid','UpdateID','UpdateId','Id'))
    $kb = $null
    if ($title -match '(?i)\bKB(?<kb>\d{6,8})\b') { $kb = $Matches.kb }
    if ([string]::IsNullOrWhiteSpace($kb)) {
        throw "Could not determine KB number from Catalog title: $title"
    }
    $download = Get-CatalogDownload -UpdateId $updateId -ExpectedKb $kb -Architecture $archToken
    $date = Get-TitleDate -Title $title -Item $Item
    $sizeBytes = if ($download -and $null -ne $download.SizeBytes) { [int64]$download.SizeBytes } else { $null }
    if ($null -eq $sizeBytes) {
        $sz = [string](Get-Prop $Item @('Size','UpdateSize'))
        if ($sz -match '([\d,.]+)\s*MB') { $sizeBytes = [int64]([double]($Matches[1] -replace ',','') * 1MB) }
        elseif ($sz -match '([\d,.]+)\s*GB') { $sizeBytes = [int64]([double]($Matches[1] -replace ',','') * 1GB) }
    }
    $filename = if ($download -and $download.FileName) { [string]$download.FileName } else { [string](Get-Prop $Item @('FileName','Filename')) }
    $class = [string](Get-Prop $Item @('Classification','UpdateType'))
    $originUrl = if ($download) { [string]$download.Url } else { $null }
    return [ordered]@{
        file=$filename
        desc=$title
        date=if ($date) { $date.ToString('MM/dd/yyyy') } else { $null }
        size_mb=if ($sizeBytes) { [math]::Round($sizeBytes / 1MB,1) } else { $null }
        id=$updateId
        arch='AMD64'
        class=$class
        url=$originUrl
        sha1=if ($download) { Convert-DigestToBase64 $download } else { $null }
        kb=$kb
        size_bytes=$sizeBytes
        kind=$Kind
    }
}

function Get-ArtifactUrl {
    param([string]$FileName)

    if ([string]::IsNullOrWhiteSpace($ArtifactBaseUrl)) {
        throw 'ArtifactBaseUrl is required. Update dependencies must use the local J&J Artifactory URL.'
    }

    $root = $ArtifactBaseUrl.TrimEnd('/')
    $sub = $ArtifactSubPath.Trim('/')
    $escaped = [uri]::EscapeDataString($FileName)

    if ($sub) {
        return "$root/$sub/$escaped"
    }

    return "$root/$escaped"
}

function New-UpdateDependency {
    param([object]$Origin,[string]$Kind)
    $file = [string]$Origin.file
    if ([string]::IsNullOrWhiteSpace($file)) {
        throw "Catalog did not return a filename for $($Origin.kb) ($($Origin.desc)). Cannot create a stable dependency key."
    }
    $label = switch ($Kind) { 'SSU' {'Windows update - SSU'} 'LCU' {'Windows update - CU for Windows'} 'DOTNET' {'Windows update - CU for .NET'} }
    $key = $file
    return @{
        Key=$key
        Value=[ordered]@{
            desc=$label
            tags=@('windows update','windows')
            url=(Get-ArtifactUrl -FileName $file)
            origin=$Origin
        }
    }
}

# Load the existing SSU dependency from the baseline JJV manifest. The
# baseline is authoritative: do not replace it merely because Catalog lists
# a newer SSU. A replacement is resolved only when RequiredSsuKb is explicitly
# supplied after prerequisite analysis confirms that the selected LCU needs it.
$baselineSsu = $null
$baselineManifest = $null
if (-not [string]::IsNullOrWhiteSpace($BaselineManifestPath) -and
    (Test-Path -LiteralPath $BaselineManifestPath -PathType Leaf)) {
    try {
        $baselineManifest = Get-Content -LiteralPath $BaselineManifestPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Could not parse baseline manifest '$BaselineManifestPath': $($_.Exception.Message)"
    }

    $expectedBaselinePrefix = if ($Profile -eq 'windows10-21h2') { '10_21H2/' } else { '11_24H2/' }
    $baselineVersion = [string](Get-Prop $baselineManifest @('version'))
    if ($baselineVersion -and -not $baselineVersion.StartsWith($expectedBaselinePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Baseline manifest version '$baselineVersion' does not match profile '$Profile' (expected '$expectedBaselinePrefix*')."
    }

    $baselineUpdates = $baselineManifest.dependencies.deps.'win/updates'
    if ($null -ne $baselineUpdates) {
        $baselineSsuMatches = @(
            foreach ($property in $baselineUpdates.PSObject.Properties) {
                $entry = $property.Value
                $origin = Get-Prop $entry @('origin')
                $kb = [string](Get-Prop $origin @('kb'))
                if ($kb -eq '5031539' -or $property.Name -match '(?i)^ssu[-_]') {
                    [pscustomobject]@{ Key=$property.Name; Value=$entry; KB=$kb }
                }
            }
        )
        if ($baselineSsuMatches.Count -gt 1) {
            throw "Baseline manifest contains multiple SSU dependencies. Keep exactly one SSU entry in '$BaselineManifestPath'."
        }
        if ($baselineSsuMatches.Count -eq 1) { $baselineSsu = $baselineSsuMatches[0] }
    }
}

$ssuDependency = $null
if ($baselineSsu -and
    ([string]::IsNullOrWhiteSpace($RequiredSsuKb) -or $RequiredSsuKb -eq $baselineSsu.KB)) {
    # Preserve the complete dependency object, including filename, URL,
    # Catalog origin metadata, SHA-1 and KB, without querying Catalog.
    $ssuDependency = [pscustomobject]@{
        Key=$baselineSsu.Key
        Value=$baselineSsu.Value
        KB=$baselineSsu.KB
    }
    Write-Host "Preserving baseline SSU KB$($baselineSsu.KB): $($baselineSsu.Key)"
}
elseif (-not [string]::IsNullOrWhiteSpace($RequiredSsuKb)) {
    $ssuQuery = "$osLabel $release servicing stack update KB$RequiredSsuKb $archToken"
    $ssuHits = foreach ($item in (Get-CatalogCandidates -Query $ssuQuery)) {
        $title = [string](Get-Prop $item @('Title','UpdateTitle'))
        if (-not (Test-ApplicableTitle -Title $title -Kind 'SSU')) { continue }
        if ($title -notmatch "(?i)\bKB$([regex]::Escape($RequiredSsuKb))\b") { continue }
        [pscustomobject]@{ Item=$item; Title=$title }
    }
    $ssuHits = @($ssuHits)
    if ($ssuHits.Count -ne 1) {
        throw "Required SSU KB$RequiredSsuKb was not resolved uniquely from Microsoft Update Catalog. Found $($ssuHits.Count) matches."
    }
    $newSsuOrigin = New-OriginRecord -Item $ssuHits[0].Item -Kind 'SSU'
    $newSsuDependency = New-UpdateDependency -Origin $newSsuOrigin -Kind 'SSU'
    $ssuDependency = [pscustomobject]@{
        Key=$newSsuDependency.Key
        Value=$newSsuDependency.Value
        KB=$RequiredSsuKb
    }
    Write-Host "Using explicitly required SSU KB$RequiredSsuKb."
}
elseif ($baselineSsu) {
    # This branch is defensive; the normal baseline case is handled above.
    $ssuDependency = $baselineSsu
}
else {
    Write-Warning "No baseline SSU was found in '$BaselineManifestPath'. No SSU will be added automatically. Supply -RequiredSsuKb only if prerequisite analysis confirms one is required."
}

# Resolve only monthly LCU and .NET records. SSU selection is deliberately
# separate and is never driven by the newest Catalog result.
$specs = @(
    [pscustomobject]@{Kind='LCU'; Query="$Month $osLabel $release cumulative update $archToken"; Monthly=$true},
    [pscustomobject]@{Kind='DOTNET'; Query="$Month $osLabel $release .NET Framework 4.8 cumulative update $archToken"; Monthly=$true}
)
$resolved = @{}
foreach ($spec in $specs) {
    $hits = foreach ($item in (Get-CatalogCandidates -Query $spec.Query)) {
        $title = [string](Get-Prop $item @('Title','UpdateTitle'))
        if (-not (Test-ApplicableTitle -Title $title -Kind $spec.Kind)) { continue }
        $classification = [string](Get-Prop $item @('Classification','UpdateType'))
        if ($spec.Kind -ne 'SSU' -and $classification -notmatch '(?i)Security Updates') { continue }
        $date = Get-TitleDate -Title $title -Item $item
        if (-not $date) { continue }
        if (-not (Test-ReleaseMonth -Title $title -Item $item -ExpectedMonth $Month)) { continue }
        [pscustomobject]@{ Item=$item; Date=$date; Title=$title }
    }
    $hits = @($hits)
    # Keep each same-month applicable record; do not silently discard distinct KBs.
    $resolved[$spec.Kind] = @($hits | Sort-Object Date,Title -Descending | Group-Object Title | ForEach-Object { $_.Group[0].Item })
}

foreach ($required in 'LCU','DOTNET') {
    if (@($resolved[$required]).Count -eq 0) {
        throw "No $required Security update found for $Profile in release month $Month. No manifest was written."
    }
}

# The external schema's version folder is intentionally stable and derived from
# the profile/month. The final date is the latest selected monthly update date.
# The external schema's version folder is stable and profile-driven.
# Its date must come from the selected LCU, not the .NET update.
$profileFolder = if ($Profile -eq 'windows10-21h2') {
    '10_21H2'
} else {
    '11_24H2'
}

$lcuDates = @(
    foreach ($item in @($resolved['LCU'])) {
        $title = [string](Get-Prop $item @('Title','UpdateTitle'))
        $date = Get-TitleDate -Title $title -Item $item

        if ($date) {
            $date
        }
    }
)

if ($lcuDates.Count -eq 0) {
    throw "Could not determine the release date of the selected LCU for $Profile in $Month."
}

$versionDate = (
    $lcuDates |
        Sort-Object -Descending |
        Select-Object -First 1
).ToString('yyyy-MM-dd')

$deps = [ordered]@{}
if ($AdkUrl) {
    $adkName = if ($AdkVersion) { $AdkVersion } else { 'Windows ADK' }
    $deps[$adkName] = [ordered]@{
        desc='Portable Windows ADK created by JJV'
        tags=@('windows adk','portable','jjv')
        version=$adkName
        url=$AdkUrl
    }
}

# Preserve the baseline ADK dependency unless a replacement URL is supplied.
$baselineAdk = $null

if ($baselineManifest) {
    $baselineDeps = $baselineManifest.dependencies.deps

    if ($null -ne $baselineDeps) {
        $baselineAdk = Get-Prop $baselineDeps @('Windows ADK')
    }
}

if (-not [string]::IsNullOrWhiteSpace($AdkUrl)) {
    $adkName = if ($AdkVersion) {
        $AdkVersion
    } else {
        'Windows ADK'
    }

    $deps[$adkName] = [ordered]@{
        desc    = 'Portable Windows ADK created by JJV'
        tags    = @('windows adk','portable','jjv')
        version = $adkName
        url     = $AdkUrl
    }
}
elseif ($null -ne $baselineAdk) {
    $deps['Windows ADK'] = $baselineAdk
    Write-Host 'Preserving baseline Windows ADK dependency.'
}
else {
    Write-Warning 'No ADK URL was supplied and no Windows ADK dependency was found in the baseline manifest.'
}

# Resolve base ISO URL and WIM image index.
$baselineIso = $null

if ($null -ne $baselineManifest) {
    $baselineDeps = $baselineManifest.dependencies.deps

    if ($null -ne $baselineDeps) {
        $isoMatches = @(
            foreach ($property in $baselineDeps.PSObject.Properties) {
                if ($property.Name -match '^win/.+\.iso$') {
                    [pscustomobject]@{
                        Key   = $property.Name
                        Value = $property.Value
                    }
                }
            }
        )

        if ($isoMatches.Count -gt 1) {
            throw "Baseline manifest contains multiple Windows ISO dependencies. Cannot determine which ISO to reuse."
        }

        if ($isoMatches.Count -eq 1) {
            $baselineIso = $isoMatches[0]
        }
    }
}

# Explicit arguments take precedence over baseline values.
$effectiveImageUrl = $ImageUrl

if ([string]::IsNullOrWhiteSpace($effectiveImageUrl)) {
    $effectiveImageUrl = [string](Get-Prop $baselineIso.Value @('url'))
}

if ([string]::IsNullOrWhiteSpace($effectiveImageUrl)) {
    throw "ImageUrl was not supplied and no ISO URL was found in baseline manifest '$BaselineManifestPath'."
}

$effectiveImageIndex = $ImageIndex

if ($effectiveImageIndex -eq 0) {
    $baselineIndex = Get-Prop $baselineIso.Value @('image_index')

    if ($null -eq $baselineIndex) {
        throw "ImageIndex was not supplied and no image_index was found in the baseline ISO dependency."
    }

    $effectiveImageIndex = [int]$baselineIndex
}

if ($effectiveImageIndex -lt 1 -or $effectiveImageIndex -gt 20) {
    throw "Invalid ImageIndex '$effectiveImageIndex'. Expected a value between 1 and 20."
}

$imageUri = $null
if (-not [uri]::TryCreate($effectiveImageUrl, [System.UriKind]::Absolute, [ref]$imageUri)) {
    throw "ImageUrl must be a valid absolute HTTP(S) URL: $effectiveImageUrl"
}

if ($imageUri.Scheme -notin @('http','https')) {
    throw "ImageUrl must use HTTP or HTTPS: $effectiveImageUrl"
}

$imageFileName = [Net.WebUtility]::UrlDecode([IO.Path]::GetFileName($imageUri.AbsolutePath))

if ([string]::IsNullOrWhiteSpace($imageFileName)) {
    throw "Could not determine ISO filename from ImageUrl: $effectiveImageUrl"
}

$isoKey = 'win/' + $imageFileName
$deps[$isoKey] = [ordered]@{
    desc='Windows installation ISO file'
    tags=@('windows iso','windows image','windows')
    version=[string]$profileInfo.WindowsVersion + ' x64'
    url=$effectiveImageUrl
	image_index=$effectiveImageIndex
}
$updateDeps = [ordered]@{}
if ($ssuDependency) {
    $updateDeps[$ssuDependency.Key] = $ssuDependency.Value
}
foreach ($kind in 'LCU','DOTNET') {
    foreach ($item in @($resolved[$kind])) {
        if ($null -eq $item) { continue }
        $origin = New-OriginRecord -Item $item -Kind $kind
        $dep = New-UpdateDependency -Origin $origin -Kind $kind
        $updateDeps[$dep.Key] = $dep.Value
    }
}
$deps['win/updates'] = $updateDeps

$manifest = [ordered]@{
    '$schema'='jjv_manifest-v1.schema.json'
    desc='Tool to create updated Windows ISO with selected latest Windows updates'
    project=$Project
    projectVersion=$ProjectVersion
    repo=$Repo
    version="$profileFolder/$versionDate"
    components=[ordered]@{}
    dependencies=[ordered]@{ deps=$deps }
    build=[ordered]@{
        id=''
        git_url=''
        git_commit=''
        'sha1.hex'=''
        url=''
        date='0000-00-00T00:00:00Z'
        output_dir='build/output'
    }
}

if ($DownloadPackages) {
    New-Item -ItemType Directory -Path $DownloadRoot -Force | Out-Null
    foreach ($kind in 'LCU','DOTNET') {
        foreach ($item in @($resolved[$kind])) {
            if ($null -eq $item) { continue }
            $origin = New-OriginRecord -Item $item -Kind $kind
            if (-not $origin.url -or -not $origin.file) { throw "Cannot download $($origin.kb): Catalog URL or filename missing." }
            $target = Join-Path $DownloadRoot $origin.file
            Invoke-WebRequest -Uri $origin.url -OutFile $target -UseBasicParsing
            $origin.sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
            $origin.downloaded_size_bytes = (Get-Item -LiteralPath $target).Length
            if ($origin.size_bytes -and $origin.downloaded_size_bytes -ne $origin.size_bytes) {
                throw "Downloaded size mismatch for $($origin.file). Catalog=$($origin.size_bytes), actual=$($origin.downloaded_size_bytes)"
            }
        }
    }
}

$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$json = $manifest | ConvertTo-Json -Depth 40
$fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
$tempManifestPath = "$fullOutputPath.tmp"
[IO.File]::WriteAllText($tempManifestPath,$json,[Text.UTF8Encoding]::new($false))
try {
    $null = Get-Content -LiteralPath $tempManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
} finally {
    Remove-Item -LiteralPath $tempManifestPath -Force -ErrorAction SilentlyContinue
}
[IO.File]::WriteAllText($fullOutputPath,$json,[Text.UTF8Encoding]::new($false))
Write-Host "Manifest written: $([IO.Path]::GetFullPath($OutputPath))"
Write-Host "Profile=$Profile Month=$Month Version=$($manifest.version)"
Write-Host "Updates: SSU=$(if ($ssuDependency) { 1 } else { 0 }), LCU=$(@($resolved.LCU).Count), .NET=$(@($resolved.DOTNET).Count)"