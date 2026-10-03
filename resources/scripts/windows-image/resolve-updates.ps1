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

# Normalize architecture.
if ($Architecture -match '^(?i)(amd64|x64)$') {
    $Architecture = 'x64'
}

# ---------------------------------------------------------------------------
# Load Windows image profiles
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------

$downloadDirectory = Join-Path $WorkRoot 'download'
$updateDirectory   = Join-Path $downloadDirectory 'updates'
$resolvedManifest  = Join-Path $downloadDirectory 'resolved-updates.json'

New-Item -ItemType Directory -Force `
    -Path $downloadDirectory, $updateDirectory |
    Out-Null

# ---------------------------------------------------------------------------
# Artifactory configuration
# ---------------------------------------------------------------------------

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

function Get-ArtifactoryUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return "$ArtifactoryUrlRoot/$ArtifactoryRepo/$($Path.TrimStart('/'))"
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (
        Get-FileHash -LiteralPath $Path -Algorithm SHA256
    ).Hash.ToLowerInvariant()
}

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

function Download-File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [hashtable]$RequestHeaders = $null
    )

    Write-Host 'Downloading:'
    Write-Host "  $Url"
    Write-Host 'To:'
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

    Write-Host 'Catalog query:'
    Write-Host "  $Query"

    return (
        Invoke-WebRequest `
            -Uri $url `
            -UseBasicParsing `
            -TimeoutSec 120
    ).Content
}

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
            $url = $_.Value.TrimEnd("'", '"', ')', ';')

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

# ---------------------------------------------------------------------------
# Parse Catalog results
#
# Important:
# Keep UpdateIDs associated with the SAME <tr> as the KB.
# Do not fall back to scanning the entire page because that can associate
# another update's UpdateID with the selected KB.
# ---------------------------------------------------------------------------

function Get-CatalogCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Html
    )

    $out = @()

    foreach (
        $r in [regex]::Matches(
            $Html,
            '<tr[^>]*>(.*?)</tr>',
            [Text.RegularExpressions.RegexOptions]::Singleline
        )
    ) {

        $row = $r.Groups[1].Value

        $p = [Net.WebUtility]::HtmlDecode(
            ($row -replace '<[^>]+>', ' ')
        ) -replace '\s+', ' '

        $p = $p.Trim()

        # Product / release filter.
        if ($p -notmatch $profileInfo.CatalogProductPattern) {
            continue
        }

        # We want cumulative updates.
        if ($p -notmatch '(?i)Cumulative Update') {
            continue
        }

        # Do NOT require "Security Updates" here.
        #
        # Microsoft Catalog can use titles such as:
        #   Windows 11 ... Cumulative Update ...
        #   Windows 11 ... Cumulative Update ... Security Updates
        #
        # Both can be valid LCUs.
        #
        # Explicitly exclude update classes that are not the OS LCU.
        if (
            $p -match '(?i)Preview' -or
            $p -match '(?i)\.NET' -or
            $p -match '(?i)Dynamic Update' -or
            $p -match '(?i)Server' -or
            $p -match '(?i)Driver'
        ) {
            continue
        }

        # Architecture.
        if ($Architecture -eq 'x64') {

            if (
                $p -notmatch '(?i)x64-based Systems' -or
                $p -match '(?i)ARM64'
            ) {
                continue
            }
        }
        elseif ($Architecture -eq 'arm64') {

            if ($p -notmatch '(?i)ARM64-based Systems') {
                continue
            }
        }

        # KB.
        $k = [regex]::Match(
            $p,
            '(?i)\(KB(\d+)\)'
        )

        if (-not $k.Success) {
            continue
        }

        # Build.
        $build = ''

        if ($profileInfo.CatalogBuildRequired) {

            $b = [regex]::Match(
                $p,
                "\(($($profileInfo.BuildRegex))\)"
            )

            if (-not $b.Success) {
                continue
            }

            $build = $b.Groups[1].Value
        }

        # Release date.
        $d = [regex]::Match(
            $p,
            '(\d{1,2}/\d{1,2}/\d{4})'
        )

        if ($d.Success) {
            try {
                $releaseDate = [datetime]::Parse(
                    $d.Groups[1].Value
                )
            }
            catch {
                $releaseDate = [datetime]::MinValue
            }
        }
        else {
            $releaseDate = [datetime]::MinValue
        }

        # UpdateID must come from this row only.
        $ids =
            [regex]::Matches(
                $row,
                '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
            ) |
            ForEach-Object Value |
            Select-Object -Unique

        if (-not $ids) {
            continue
        }

        $out += [pscustomobject]@{
            KB        = "KB$($k.Groups[1].Value)"
            Build     = $build
            Date      = $releaseDate
            Title     = $p
            UpdateIds = @($ids)
        }
    }

    return @($out)
}

# ---------------------------------------------------------------------------
# Validate downloaded MSU filename
# ---------------------------------------------------------------------------

function Test-MsuName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$KB
    )

    $number = $KB -replace '^KB', ''

    $kbMatch = $Name -match (
        "(?i)kb$([regex]::Escape($number))(?:[^0-9]|$)"
    )

    $msuMatch = $Name -match '(?i)\.msu$'

    if ($Architecture -eq 'x64') {
        $architectureMatch = $Name -match '(?i)(x64|amd64)'
    }
    elseif ($Architecture -eq 'arm64') {
        $architectureMatch = $Name -match '(?i)arm64'
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

# ---------------------------------------------------------------------------
# Determine resulting Windows build from the LCU package.
#
# Windows 10 21H2 Catalog entries do not reliably contain the resulting
# OS build. The authoritative build is contained in the LCU package itself.
# ---------------------------------------------------------------------------

function Get-LcuBuildFromMsu {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MsuPath,

        [Parameter(Mandatory = $true)]
        [string]$KB,

        [Parameter(Mandatory = $true)]
        [string]$Profile,

        [string]$CatalogBuild = ''
    )

    if (-not (Test-Path -LiteralPath $MsuPath -PathType Leaf)) {
        throw "LCU MSU not found: $MsuPath"
    }

    $msuFile = Get-Item -LiteralPath $MsuPath -ErrorAction Stop

    if ($msuFile.Length -eq 0) {
        throw "LCU MSU is empty: $MsuPath"
    }

    # -----------------------------------------------------------------------
    # Locate 7-Zip.
    # -----------------------------------------------------------------------

    $sevenZip = @(
        'C:\Program Files\7-Zip\7z.exe',
        'C:\Program Files (x86)\7-Zip\7z.exe'
    ) |
        Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        } |
        Select-Object -First 1

    if (-not $sevenZip) {

        $command = Get-Command 7z.exe -ErrorAction SilentlyContinue

        if ($command) {
            $sevenZip = $command.Source
        }
    }

    if (-not $sevenZip) {
        throw (
            '7-Zip was not found. Expected ' +
            'C:\Program Files\7-Zip\7z.exe'
        )
    }

    $kbNumber = $KB -replace '^KB', ''

    Write-Host ''
    Write-Host 'Inspecting LCU MSU:'
    Write-Host "  MSU       : $($msuFile.FullName)"
    Write-Host "  Size      : $($msuFile.Length) bytes"
    Write-Host "  Profile   : $Profile"
    Write-Host "  KB        : $KB"
    Write-Host "  7-Zip     : $sevenZip"

    # -----------------------------------------------------------------------
    # Windows 11 24H2
    #
    # Windows 11 24H2 cumulative updates contain the LCU payload as a WIM
    # rather than the Windows 10-style LCU CAB.
    #
    # The Microsoft Catalog provides the resulting 26100.x build, so we
    # verify that the requested KB WIM exists and use the Catalog build.
    # -----------------------------------------------------------------------

    if ($Profile -eq 'windows11-24h2') {

        if ([string]::IsNullOrWhiteSpace($CatalogBuild)) {
            throw (
                "Windows 11 24H2 requires a Catalog build for $KB."
            )
        }

        $expectedWimPattern =
            "(?i)^Windows11\.0-KB$([regex]::Escape($kbNumber))-[^-]+\.wim$"

        Write-Host ''
        Write-Host 'Inspecting Windows 11 MSU contents...'

        $listing = @(
            & $sevenZip `
                l `
                $MsuPath `
                2>&1
        )

        if ($LASTEXITCODE -ne 0) {
            throw (
                "7-Zip could not inspect Windows 11 MSU: " +
                $MsuPath
            )
        }

        $wimName = $null

        foreach ($line in $listing) {

            $text = [string]$line

            if (
                $text -match
                '(?i)Windows11\.0-KB\d+-[^ ]+\.wim$'
            ) {

                $candidateName =
                    $Matches[0]

                if ($candidateName -match $expectedWimPattern) {
                    $wimName = $candidateName
                    break
                }
            }
        }

        if (-not $wimName) {

            throw (
                "Windows 11 LCU WIM for $KB was not found " +
                "inside the MSU: $MsuPath"
            )
        }

        Write-Host ''
        Write-Host 'Windows 11 LCU payload found:'
        Write-Host "  WIM: $wimName"

        # Verify the SSU is also present in the combined MSU.
        $ssuName = $null

        foreach ($line in $listing) {

            $text = [string]$line

            if ($text -match '(?i)SSU-\d+\.\d+-[^ ]+\.cab$') {
                $ssuName = $Matches[0]
                break
            }
        }

        if ($ssuName) {
            Write-Host "  SSU: $ssuName"
        }
        else {
            Write-Host '  SSU: not detected'
        }

        Write-Host ''
        Write-Host "Catalog LCU build: $CatalogBuild"
        Write-Host 'Package validation: WIM payload found'

        return $CatalogBuild
    }

    # -----------------------------------------------------------------------
    # Windows 10 21H2
    #
    # Windows 10 cumulative MSUs contain the LCU as a CAB such as:
    #
    #   Windows10.0-KB5129236-x64.cab
    #
    # Extract the MSU with 7-Zip, locate that CAB, then inspect its MUM
    # metadata for the actual package version.
    # -----------------------------------------------------------------------

    if ($Profile -eq 'windows10-21h2') {

        $extractDirectory = Join-Path `
            (Split-Path -Parent $MsuPath) `
            ("extract-" + [IO.Path]::GetFileNameWithoutExtension($MsuPath))

        if (Test-Path -LiteralPath $extractDirectory) {

            Remove-Item `
                -LiteralPath $extractDirectory `
                -Recurse `
                -Force
        }

        New-Item `
            -ItemType Directory `
            -Path $extractDirectory `
            -Force |
            Out-Null

        Write-Host ''
        Write-Host 'Extracting Windows 10 MSU with 7-Zip:'
        Write-Host "  $extractDirectory"

        & $sevenZip `
            x `
            $MsuPath `
            "-o$extractDirectory" `
            '-y' `
            2>&1 |
            ForEach-Object {
                Write-Host $_
            }

        if ($LASTEXITCODE -ne 0) {
            throw (
                "7-Zip failed to extract Windows 10 MSU: " +
                $MsuPath
            )
        }

        $cabs = @(
            Get-ChildItem `
                -LiteralPath $extractDirectory `
                -Filter '*.cab' `
                -Recurse `
                -File
        )

        if ($cabs.Count -eq 0) {
            throw (
                "No CAB files found after extracting Windows 10 MSU: " +
                $MsuPath
            )
        }

        Write-Host ''
        Write-Host 'CAB files found:'

        foreach ($cab in $cabs) {
            Write-Host "  $($cab.Name)"
        }

        # -------------------------------------------------------------------
        # Locate the LCU CAB by the exact KB.
        #
        # This avoids relying on DISM /Get-PackageInfo, which is not
        # available on the DISM version installed on this build agent.
        # -------------------------------------------------------------------

        $lcuCab = $cabs |
            Where-Object {
                $_.Name -match (
                    "(?i)^Windows10\.0-KB$([regex]::Escape($kbNumber))-"
                )
            } |
            Select-Object -First 1

        if (-not $lcuCab) {

            throw (
                "Windows 10 LCU CAB for $KB was not found in MSU: " +
                $MsuPath
            )
        }

        Write-Host ''
        Write-Host 'Selected Windows 10 LCU CAB:'
        Write-Host "  $($lcuCab.FullName)"

        # -------------------------------------------------------------------
        # Extract the LCU CAB.
        #
        # The CAB itself is small enough for 7-Zip to process normally.
        # -------------------------------------------------------------------

        $cabExtractDirectory = Join-Path `
            $extractDirectory `
            'lcu-cab'

        New-Item `
            -ItemType Directory `
            -Path $cabExtractDirectory `
            -Force |
            Out-Null

        Write-Host ''
        Write-Host 'Extracting LCU CAB...'

        & $sevenZip `
            x `
            $lcuCab.FullName `
            "-o$cabExtractDirectory" `
            '-y' `
            2>&1 |
            ForEach-Object {
                Write-Host $_
            }

        if ($LASTEXITCODE -ne 0) {
            throw (
                "7-Zip failed to extract LCU CAB: " +
                $lcuCab.FullName
            )
        }

        # -------------------------------------------------------------------
        # Locate MUM package metadata.
        # -------------------------------------------------------------------

        $mumFiles = @(
            Get-ChildItem `
                -LiteralPath $cabExtractDirectory `
                -Filter '*.mum' `
                -Recurse `
                -File
        )

        if ($mumFiles.Count -eq 0) {
            throw (
                "No MUM package metadata found in LCU CAB: " +
                $lcuCab.FullName
            )
        }

        Write-Host ''
        Write-Host "MUM files found: $($mumFiles.Count)"

        # -------------------------------------------------------------------
        # Find the package whose identity/version corresponds to the target
        # cumulative update.
        # -------------------------------------------------------------------

        $matchingMums = @()

        foreach ($mum in $mumFiles) {

            try {
                $mumText = Get-Content `
                    -LiteralPath $mum.FullName `
                    -Raw `
                    -ErrorAction Stop
            }
            catch {
                continue
            }

            if (
                $mumText -match
                "(?i)KB$([regex]::Escape($kbNumber))"
            ) {

                $matchingMums += [pscustomobject]@{
                    Path = $mum.FullName
                    Text = $mumText
                }
            }
        }

        # If the KB is not explicitly present in the MUM, look for
        # Package_for_RollupFix as a fallback.
        if ($matchingMums.Count -eq 0) {

            foreach ($mum in $mumFiles) {

                try {
                    $mumText = Get-Content `
                        -LiteralPath $mum.FullName `
                        -Raw `
                        -ErrorAction Stop
                }
                catch {
                    continue
                }

                if (
                    $mumText -match
                    '(?i)Package_for_RollupFix'
                ) {

                    $matchingMums += [pscustomobject]@{
                        Path = $mum.FullName
                        Text = $mumText
                    }
                }
            }
        }

        if ($matchingMums.Count -eq 0) {

            throw (
                "Unable to identify the LCU package metadata for " +
                "$KB in $($lcuCab.Name)."
            )
        }

        Write-Host ''
        Write-Host 'Matching LCU package metadata:'

        foreach ($mum in $matchingMums) {
            Write-Host "  $($mum.Path)"
        }

        # -------------------------------------------------------------------
        # Extract Windows package versions.
        #
        # Expected:
        #
        #   10.0.19044.7727
        #
        # The MUM package identity may also contain:
        #
        #   ~~19044.7727.1.1
        # -------------------------------------------------------------------

        $versions = @()

        foreach ($mum in $matchingMums) {

            $text = $mum.Text

            $matches = [regex]::Matches(
                $text,
                '10\.0\.(\d+\.\d+)'
            )

            foreach ($match in $matches) {

                $versions += $match.Groups[1].Value
            }

            # Package identity fallback.
            $revisionMatches = [regex]::Matches(
                $text,
                '~~(\d+\.\d+)\.\d+\.\d+'
            )

            foreach ($match in $revisionMatches) {

                $versions += $match.Groups[1].Value
            }
        }

        $versions =
            $versions |
            Where-Object {
                $_ -match '^\d+\.\d+$'
            } |
            Sort-Object -Unique

        if ($versions.Count -eq 0) {

            throw (
                "Unable to determine Windows build from LCU MUM metadata: " +
                $lcuCab.FullName
            )
        }

        # Select the highest package version.
        $packageBuild =
            $versions |
            Sort-Object {
                [version]$_
            } -Descending |
            Select-Object -First 1

        if ($packageBuild -notmatch '^\d+\.\d+$') {

            throw (
                "Invalid Windows build extracted from LCU package: " +
                $packageBuild
            )
        }

        Write-Host ''
        Write-Host "Detected Windows 10 LCU build: $packageBuild"

        return $packageBuild
    }

    throw "Unsupported Windows image profile: $Profile"
}

function Get-OfflineServicingRequirement {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsBuild,

        [Parameter(Mandatory = $true)]
        [string]$LcuBuild
    )

    if ($WindowsBuild -match '^26100') {

        return [pscustomobject]@{
            standaloneSsuRequired = $false
            ssuKb                 = $null
            ssuBuild              = $null
            reason                = 'Windows 11 24H2 combined SSU+LCU.'
        }
    }

    if ($WindowsBuild -match '^19044|^19045') {

        # ----------------------------------------------------
        # Windows 10 21H2/22H2:
        #
        # Current monthly LCUs contain the SSU.
        #
        # However, older offline media may require the
        # special standalone SSU KB5031539.
        #
        # The actual decision will be made by
        # windowsImagePrepare.ps1 after inspecting the image.
        # ----------------------------------------------------

        return [pscustomobject]@{
            standaloneSsuRequired = 'IMAGE_BASELINE_CHECK'
            ssuKb                 = 'KB5031539'
            ssuBuild              = '19041.3562'
            reason                = 'Windows 10 offline image must be checked for KB5028244-or-later baseline.'
        }
    }

    throw "Unsupported Windows build family: $WindowsBuild"
}
# ============================================================
# Servicing metadata
# ============================================================

function Get-BuildNumber {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Build
    )

    if ([string]::IsNullOrWhiteSpace($Build)) {
        return [int64]0
    }

    $match = [regex]::Match(
        $Build,
        '^\d+\.(\d+)$'
    )

    if (-not $match.Success) {
        return [int64]0
    }

    return [int64]$match.Groups[1].Value
}

function Get-ServicingPlan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsBuild,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$SelectedLcu
    )

    $buildFamily = $WindowsBuild.Trim()

    # --------------------------------------------------------
    # Windows 11 24H2
    #
    # Current Windows 11 24H2 monthly LCUs use the combined
    # SSU+LCU servicing model.
    # --------------------------------------------------------

    if ($buildFamily -match '^26100') {

        return [pscustomobject]@{
            lcuContainsSsu       = $true
            standaloneSsuRequired = $false
            ssuKb                 = $null
            ssuUpdateId           = $null
            reason                = 'Windows 11 24H2 LCU uses combined SSU+LCU servicing.'
        }
    }

    # --------------------------------------------------------
    # Windows 10 21H2 / 22H2
    #
    # Current LCUs are combined SSU+LCU, but old offline media
    # can require a standalone prerequisite SSU.
    #
    # KB5129236 specifically documents:
    #
    #   media with KB5028244 or later -> no standalone SSU
    #
    #   older media -> KB5031539 first
    #
    # Do NOT hard-code this into the LCU selection itself.
    # The prerequisite belongs to the image state.
    # --------------------------------------------------------

    if ($buildFamily -match '^19044|^19045') {

        return [pscustomobject]@{
            lcuContainsSsu       = $true
            standaloneSsuRequired = $false
            ssuKb                 = $null
            ssuUpdateId           = $null
            reason                = 'Windows 10 LCU contains the current SSU; standalone SSU depends on offline image baseline.'
        }
    }

    throw "Unsupported Windows build family for servicing plan: $WindowsBuild"
}

# ---------------------------------------------------------------------------
# Resolve latest LCU
# ---------------------------------------------------------------------------

Write-Host "Resolving $($profileInfo.WindowsVersion) $Architecture LCU..."

$catalogHtml = Get-CatalogHtml $profileInfo.CatalogQuery
$candidates = Get-CatalogCandidates $catalogHtml

if (-not $candidates) {

    throw (
        "No matching $($profileInfo.WindowsVersion) " +
        "$Architecture cumulative update found for build " +
        "$($profileInfo.Build)."
    )
}

Write-Host ''
Write-Host "Catalog candidates found: $($candidates.Count)"

# ---------------------------------------------------------------------------
# Select latest KB.
#
# Windows 11 24H2:
#   Prefer highest 26100.x build, then release date.
#
# Windows 10 21H2:
#   CatalogBuildRequired = false, so release date is used.
# ---------------------------------------------------------------------------

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
                if ([string]::IsNullOrWhiteSpace($_.Build)) {
                    [version]'0.0'
                }
                else {
                    try {
                        [version]$_.Build
                    }
                    catch {
                        [version]'0.0'
                    }
                }
            }
            Descending = $true
        }, @{
            Expression = { $_.Date }
            Descending = $true
        } |
    Select-Object -First 1

if (-not $selected) {
    throw 'Unable to select an LCU from Microsoft Update Catalog.'
}

Write-Host ''
Write-Host 'Selected Catalog update:'
Write-Host "  KB    : $($selected.KB)"
Write-Host "  Build : $($selected.Build)"
Write-Host "  Date  : $($selected.Date.ToString('yyyy-MM-dd'))"
Write-Host "  Title : $($selected.Title)"

# ---------------------------------------------------------------------------
# Resolve Microsoft Update Catalog UpdateID
# ---------------------------------------------------------------------------

$updateIds = @($selected.UpdateIds)

if (-not $updateIds) {

    throw (
        "Unable to resolve UpdateID from the Catalog result row for " +
        "$($selected.KB)."
    )
}

$chosen = $null

foreach ($id in $updateIds) {

    Write-Host ''
    Write-Host "Checking UpdateID: $id"

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

    throw (
        "Unable to resolve a valid MSU for $($selected.KB). " +
        "Catalog UpdateIDs: $($updateIds -join ', ')"
    )
}

Write-Host ''
Write-Host 'Resolved Microsoft package:'
Write-Host "  UpdateID : $($chosen.UpdateId)"
Write-Host "  MSU      : $($chosen.FileName)"
Write-Host "  URL      : $($chosen.Url)"

# ---------------------------------------------------------------------------
# Artifactory path
# ---------------------------------------------------------------------------

$relativePath =
    "$($profileInfo.ArtifactRoot)/$Architecture/LCU/" +
    "$($selected.KB)/$($chosen.FileName)"

$localPath =
    Join-Path $updateDirectory $chosen.FileName

$artifactoryUrl =
    Get-ArtifactoryUrl $relativePath

# ---------------------------------------------------------------------------
# SSU model
#
# Both Windows 10 21H2 and Windows 11 24H2 use combined LCU/SSU servicing.
#
# We intentionally DO NOT download an arbitrary standalone SSU merely
# because one happens to exist in the Catalog.
#
# A standalone SSU is only a prerequisite when Microsoft publishes one
# specifically for the target cumulative update.
# ---------------------------------------------------------------------------

$ssuRequired = $false
$ssuIncluded = $true
$ssuSource   = 'CombinedLCU'

$ssuObject = $null

if ($ResolveOnly) {

    $resolvedObject = [ordered]@{
        schemaVersion = '1.1'

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

        updateId = $chosen.UpdateId
        fileName = $chosen.FileName

        sha256 = ''

        microsoftUrl = $chosen.Url

        artifactoryUrl  = $artifactoryUrl
        artifactoryRepo = $ArtifactoryRepo
        artifactoryPath = $relativePath

        source = 'ResolveOnly'

        ssuIncluded = $ssuIncluded
        ssuRequired = $ssuRequired
        ssuSource   = $ssuSource
        ssu         = $ssuObject

        resolvedAtUtc =
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

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' LCU Resolved (Resolve Only)'
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
    Write-Host "SSU Required  : $ssuRequired"
    Write-Host "SSU Included  : $ssuIncluded"
    Write-Host "SSU Source    : $ssuSource"
    Write-Host "Manifest      : $resolvedManifest"
    Write-Host '============================================================'
    Write-Host ''

    exit 0
}

# ---------------------------------------------------------------------------
# Download from Artifactory if available.
# ---------------------------------------------------------------------------

$existingArtifact =
    Find-ArtifactoryArtifact $relativePath

if ($existingArtifact -and -not $ForceMicrosoftDownload) {

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

    # Check again before uploading.
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

            throw (
                "JFrog upload failed with exit code " +
                "${uploadExitCode}"
            )
        }
    }

    $existingArtifact =
        Find-ArtifactoryArtifact $relativePath

    if (-not $existingArtifact) {

        throw (
            "MSU upload completed but artifact cannot be found: " +
            $relativePath
        )
    }

    $artifactoryUrl = $existingArtifact
}

# ---------------------------------------------------------------------------
# Validate local package
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $localPath)) {

    throw (
        "Resolved MSU was not found: $localPath"
    )
}

$sha256 = Get-Sha256 $localPath

# Always determine the actual LCU build from the downloaded MSU.
# This validates the package that will actually be applied to the image.
$catalogBuild = $selected.Build

Write-Host "Inspecting downloaded MSU to determine actual LCU build..."
$packageBuild = Get-LcuBuildFromMsu `
    -MsuPath $localPath `
    -KB $selected.KB `
    -Profile $Profile `
    -CatalogBuild $catalogBuild
 
if ([string]::IsNullOrWhiteSpace($packageBuild)) {
    throw "Unable to determine LCU build from MSU: $localPath"
}

# Windows 11 normally has a build from the Catalog.
# When present, use it as an additional consistency check.
if (-not [string]::IsNullOrWhiteSpace($catalogBuild) -and
    $catalogBuild -ne $packageBuild) {

    throw "LCU build mismatch. Catalog=$catalogBuild, MSU package=$packageBuild, KB=$($selected.KB)"
}

$resolvedBuild = $packageBuild

Write-Host "Catalog build : $catalogBuild"
Write-Host "Package build : $packageBuild"
Write-Host "Resolved build: $resolvedBuild"

# ---------------------------------------------------------------------------
# Final manifest
# ---------------------------------------------------------------------------

$resolvedObject = [ordered]@{
    schemaVersion = '1.1'

    type = 'LCU'

    profile        = $profileInfo.Name
    product        = $profileInfo.Product
    windowsVersion = $profileInfo.WindowsVersion
    release        = $profileInfo.Release
    windowsBuild   = $profileInfo.Build

    artifactRoot = $profileInfo.ArtifactRoot
    isoPrefix    = $profileInfo.IsoPrefix

    kb          = $selected.KB
    build       = $resolvedBuild
    releaseDate = $selected.Date.ToString('yyyy-MM-dd')

    architecture = $Architecture

    updateId = $chosen.UpdateId
    fileName = $chosen.FileName

    sha256 = $sha256

    microsoftUrl = $chosen.Url

    artifactoryUrl  = $artifactoryUrl
    artifactoryRepo = $ArtifactoryRepo
    artifactoryPath = $relativePath

    source = $source

    # Servicing stack information.
    #
    # The LCU contains the SSU servicing payload for these profiles.
    ssuIncluded = $ssuIncluded
    ssuRequired = $ssuRequired
    ssuSource   = $ssuSource
    ssu         = $ssuObject

    resolvedAtUtc =
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

# ---------------------------------------------------------------------------
# Final output
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '============================================================'
Write-Host ' LCU Resolved Successfully'
Write-Host '============================================================'
Write-Host "Profile       : $($profileInfo.Name)"
Write-Host "Windows       : $($profileInfo.WindowsVersion)"
Write-Host "Windows Build : $($profileInfo.Build)"
Write-Host "Architecture  : $Architecture"
Write-Host "KB            : $($selected.KB)"
Write-Host "LCU Build     : $($resolvedBuild)"
Write-Host "Release Date  : $($selected.Date.ToString('yyyy-MM-dd'))"
Write-Host "UpdateID      : $($chosen.UpdateId)"
Write-Host "MSU           : $($chosen.FileName)"
Write-Host "SHA256        : $sha256"
Write-Host "Source        : $source"
Write-Host "SSU Required  : $ssuRequired"
Write-Host "SSU Included  : $ssuIncluded"
Write-Host "SSU Source    : $ssuSource"
Write-Host "Artifactory   : $relativePath"
Write-Host "Local MSU     : $localPath"
Write-Host "Manifest      : $resolvedManifest"
Write-Host '============================================================'
Write-Host ''

exit 0