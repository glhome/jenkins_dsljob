
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
    [string]$JfPath = 'jf.exe',

    [switch]$ForceMicrosoftDownload,
    [switch]$ResolveOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Normalize architecture
# ---------------------------------------------------------------------------

if ($Architecture -match '^(?i)(x64|amd64)$') {
    $Architecture = 'x64'
}

$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)

$DownloadDir = Join-Path $WorkRoot 'download'
$UpdatesDir  = Join-Path $DownloadDir 'updates'
$Manifest    = Join-Path $DownloadDir 'resolved-updates.json'

New-Item `
    -ItemType Directory `
    -Force `
    -Path $DownloadDir, $UpdatesDir |
    Out-Null

# ---------------------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------------------

$profileScript = Join-Path `
    (Split-Path -Parent $MyInvocation.MyCommand.Path) `
    'profiles.ps1'

if (-not (Test-Path -LiteralPath $profileScript -PathType Leaf)) {
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

# ---------------------------------------------------------------------------
# JFrog helpers
# ---------------------------------------------------------------------------

function Get-JFrogAuthArguments {

    if (-not [string]::IsNullOrWhiteSpace($ArtifactoryToken)) {

        return @(
            '--access-token'
            $ArtifactoryToken
        )
    }

    if (
        [string]::IsNullOrWhiteSpace($ArtifactoryUser) -or
        [string]::IsNullOrWhiteSpace($ArtifactoryPassword)
    ) {
        throw `
            'Artifactory authentication requires either ' +
            'ArtifactoryToken or ArtifactoryUser/ArtifactoryPassword.'
    }

    return @(
        '--user'
        $ArtifactoryUser
        '--password'
        $ArtifactoryPassword
    )
}

function Get-JFrogSafeAuthArguments {

    if (-not [string]::IsNullOrWhiteSpace($ArtifactoryToken)) {
        return @(
            '--access-token'
            '****'
        )
    }

    return @(
        '--user'
        $ArtifactoryUser
        '--password'
        '****'
    )
}

function Invoke-JFrog {

    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    if (-not (Get-Command $JfPath -ErrorAction SilentlyContinue)) {
        throw "JFrog CLI was not found: $JfPath"
    }

    $authArgs = Get-JFrogAuthArguments

    $fullArgs = @(
        $Arguments
        '--url'
        $ArtifactoryRoot
    ) + $authArgs

    $safeAuth = Get-JFrogSafeAuthArguments

    $safeArgs = @(
        $Arguments
        '--url'
        $ArtifactoryRoot
    ) + $safeAuth

    Write-Host "Executing:"
    Write-Host "  $JfPath $($safeArgs -join ' ')"

    & $JfPath @fullArgs

    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "JFrog command failed with exit code $exitCode."
    }

    return $exitCode
}

function ConvertTo-JFrogArtifactPath {

    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    return "$ArtifactoryRepo/$($RelativePath.TrimStart('/'))"
}

function Get-ArtifactoryUrl {

    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    return "$ArtifactoryRoot/$ArtifactoryRepo/$($RelativePath.TrimStart('/'))"
}

# ---------------------------------------------------------------------------
# Check whether an exact artifact exists.
#
# IMPORTANT:
# Do not use:
#
#   jf rt dl ... --fail-no-op=true
#
# as the existence test. JFrog can return exit code 2 and PowerShell can
# interpret informational stderr output as NativeCommandError.
#
# Instead use:
#
#   jf rt s <artifact> --count
#
# through cmd.exe with stdout/stderr captured separately.
# ---------------------------------------------------------------------------

function Test-ArtifactoryFile {

    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $jfArtifact = ConvertTo-JFrogArtifactPath $RelativePath

    $stdoutFile = Join-Path `
        $env:TEMP `
        ("jf-search-" + [guid]::NewGuid().ToString('N') + '.out')

    $stderrFile = Join-Path `
        $env:TEMP `
        ("jf-search-" + [guid]::NewGuid().ToString('N') + '.err')

    try {

        $authArgs = Get-JFrogAuthArguments

        $args = @(
            'rt'
            'search'
            $jfArtifact
            '--count'
            '--url'
            $ArtifactoryRoot
        ) + $authArgs

        $quotedArgs = foreach ($arg in $args) {

            if ($arg -match '[\s"]') {
                '"' + ($arg -replace '"', '\"') + '"'
            }
            else {
                $arg
            }
        }

        $commandLine =
            '"' + $JfPath + '" ' +
            ($quotedArgs -join ' ') +
            ' > "' + $stdoutFile + '"' +
            ' 2> "' + $stderrFile + '"'

        Write-Host "Checking Artifactory artifact:"
        Write-Host "  $jfArtifact"

        $process = Start-Process `
            -FilePath 'cmd.exe' `
            -ArgumentList '/c', $commandLine `
            -Wait `
            -PassThru `
            -WindowStyle Hidden

        $stdout = ''

        if (Test-Path -LiteralPath $stdoutFile) {
            $stdout = Get-Content `
                -LiteralPath $stdoutFile `
                -Raw `
                -ErrorAction SilentlyContinue
        }

        $stderr = ''

        if (Test-Path -LiteralPath $stderrFile) {
            $stderr = Get-Content `
                -LiteralPath $stderrFile `
                -Raw `
                -ErrorAction SilentlyContinue
        }

        if ($process.ExitCode -ne 0) {

            if (
                $stderr -match '(?i)no artifacts found|no artifacts|not found'
            ) {
                return $false
            }

            Write-Host "JFrog search returned exit code $($process.ExitCode)."
            if (-not [string]::IsNullOrWhiteSpace($stderr)) {
                Write-Host $stderr.Trim()
            }

            return $false
        }

        $count = 0

        if (
            [int]::TryParse(
                $stdout.Trim(),
                [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$count
            )
        ) {
            return ($count -gt 0)
        }

        return (
            $stdout.Trim() -match '^[1-9][0-9]*$'
        )
    }
    finally {

        Remove-Item `
            -LiteralPath $stdoutFile `
            -Force `
            -ErrorAction SilentlyContinue

        Remove-Item `
            -LiteralPath $stderrFile `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Download an exact Artifactory artifact to an exact file.
#
# IMPORTANT:
# The JFrog destination must be a FILE, not the existing download directory.
# ---------------------------------------------------------------------------

function Download-ArtifactoryFile {

    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [string]$ExpectedSha256 = ''
    )

    $jfArtifact = ConvertTo-JFrogArtifactPath $RelativePath

    $parent = Split-Path -Parent $Destination

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $parent |
        Out-Null

    $temporary = "$Destination.download"

    Remove-Item `
        -LiteralPath $temporary `
        -Force `
        -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host 'Downloading from Artifactory:'
    Write-Host "  Artifact: $jfArtifact"
    Write-Host "  Destination: $Destination"
    Write-Host '  Threads: 4'

    try {

        Invoke-JFrog @(
            'rt'
            'download'
            $jfArtifact
            $temporary
            '--flat=true'
            '--threads=4'
        ) | Out-Null

        if (-not (Test-Path -LiteralPath $temporary -PathType Leaf)) {
            throw `
                "JFrog download completed but file was not created: $temporary"
        }

        if ((Get-Item -LiteralPath $temporary).Length -eq 0) {
            throw "JFrog downloaded an empty file: $temporary"
        }

        if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {

            $actual = Get-Sha256 -Path $temporary

            if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
                throw (
                    "SHA256 mismatch for Artifactory artifact. " +
                    "Expected=$ExpectedSha256 Actual=$actual"
                )
            }

            Write-Host "SHA256 verified: $actual"
        }

        Move-Item `
            -LiteralPath $temporary `
            -Destination $Destination `
            -Force
    }
    finally {

        Remove-Item `
            -LiteralPath $temporary `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Upload an exact local file to an exact Artifactory path.
# ---------------------------------------------------------------------------

function Publish-ArtifactoryFile {

    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalPath,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
        throw "Cannot publish missing file: $LocalPath"
    }

    $jfArtifact = ConvertTo-JFrogArtifactPath $RelativePath

    Write-Host ''
    Write-Host 'Publishing to Artifactory:'
    Write-Host "  Local:    $LocalPath"
    Write-Host "  Artifact: $jfArtifact"

    Invoke-JFrog @(
        'rt'
        'upload'
        $LocalPath
        $jfArtifact
    ) | Out-Null

    Write-Host 'Artifactory publish successful.'
}

# ---------------------------------------------------------------------------
# Generic download from Microsoft / arbitrary URL
# ---------------------------------------------------------------------------

function Download-Url {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [hashtable]$RequestHeaders = @{}
    )

    $parent = Split-Path -Parent $Destination

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $parent |
        Out-Null

    Write-Host ''
    Write-Host 'Downloading:'
    Write-Host "  $Url"
    Write-Host 'To:'
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

# ---------------------------------------------------------------------------
# SHA256
# ---------------------------------------------------------------------------

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

    Write-Host ''
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

        # IMPORTANT:
        # UpdateID is extracted from THIS SAME Catalog row.
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
    Write-Host 'Selected Catalog row:'
    Write-Host "  Type:  $ExpectedType"
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
# Resolve/download/cache one package
#
# Canonical paths:
#
#   LCU:
#     <Product>/<Release>/<Architecture>/LCU/<KB>/<FileName>
#
#   SSU:
#     <Product>/<Release>/<Architecture>/SSU/<KB>/<FileName>
#
# This function guarantees lookup and upload use the SAME path.
# ---------------------------------------------------------------------------

function Resolve-PackageFile {

    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Package,

        [Parameter(Mandatory = $true)]
        [ValidateSet('LCU', 'SSU')]
        [string]$PackageType
    )

    $relativePath =
        "$($profileInfo.Product)/$($profileInfo.Release)/$Architecture/" +
        "$PackageType/$($Package.KB)/$($Package.FileName)"

    $localPath = Join-Path $UpdatesDir $Package.FileName

    $artifactUrl = Get-ArtifactoryUrl `
        -RelativePath $relativePath

    Write-Host ''
    Write-Host '------------------------------------------------------------'
    Write-Host "Resolving $PackageType package"
    Write-Host '------------------------------------------------------------'
    Write-Host "KB:             $($Package.KB)"
    Write-Host "File:           $($Package.FileName)"
    Write-Host "UpdateID:       $($Package.UpdateId)"
    Write-Host "Artifact path:  $relativePath"
    Write-Host "Artifact URL:   $artifactUrl"
    Write-Host "Local path:     $localPath"
    Write-Host '------------------------------------------------------------'

    $source = 'Microsoft'

    $exists = $false

    if (-not $ForceMicrosoftDownload) {

        $exists = Test-ArtifactoryFile `
            -RelativePath $relativePath
    }

    if ($exists) {

        Write-Host ''
        Write-Host 'ARTIFACTORY CACHE HIT'
        Write-Host "  $relativePath"

        Download-ArtifactoryFile `
            -RelativePath $relativePath `
            -Destination $localPath

        $source = 'Artifactory'
    }
    else {

        Write-Host ''
        Write-Host 'ARTIFACTORY CACHE MISS'
        Write-Host "  $relativePath"
        Write-Host ''
        Write-Host 'Downloading from Microsoft Catalog.'

        Download-Url `
            -Url $Package.Url `
            -Destination $localPath

        if (-not $ForceMicrosoftDownload) {

            Write-Host ''
            Write-Host 'Publishing package to Artifactory.'

            # Re-check immediately before publishing to avoid overwriting
            # a package another resolver may have published concurrently.
            if (Test-ArtifactoryFile -RelativePath $relativePath) {

                Write-Host `
                    'Package appeared in Artifactory during resolution.'

                Remove-Item `
                    -LiteralPath $localPath `
                    -Force

                Download-ArtifactoryFile `
                    -RelativePath $relativePath `
                    -Destination $localPath

                $source = 'Artifactory'
            }
            else {

                Publish-ArtifactoryFile `
                    -LocalPath $localPath `
                    -RelativePath $relativePath

                $source = 'Microsoft'
            }
        }
        else {
            $source = 'Microsoft'
        }
    }

    $sha256 = Get-Sha256 -Path $localPath

    Write-Host ''
    Write-Host "Resolved $PackageType:"
    Write-Host "  KB:       $($Package.KB)"
    Write-Host "  File:     $($Package.FileName)"
    Write-Host "  SHA256:   $sha256"
    Write-Host "  Source:   $source"
    Write-Host "  Artifact: $relativePath"

    return [pscustomobject]@{
        Package       = $Package
        PackageType   = $PackageType
        LocalPath     = $localPath
        RelativePath  = $relativePath
        ArtifactUrl   = $artifactUrl
        Sha256        = $sha256
        Source        = $source
    }
}

# ---------------------------------------------------------------------------
# Header
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
Write-Host "Artifactory  : $ArtifactoryRoot"
Write-Host "Repository   : $ArtifactoryRepo"
Write-Host "Force MS     : $ForceMicrosoftDownload"
Write-Host "ResolveOnly  : $ResolveOnly"
Write-Host '============================================================'

# ---------------------------------------------------------------------------
# Windows 11 24H2
#
# One cumulative MSU.
#
# Canonical cache:
#
# Windows11/24H2/x64/LCU/KB5129195/<filename>.msu
# ---------------------------------------------------------------------------

if ($Profile -eq 'windows11-24h2') {

    $selected = Resolve-CatalogPackage `
        -Query $profileInfo.CatalogQuery `
        -ExpectedType 'LCU'

    if ($selected.FileName -notmatch '(?i)\.msu$') {
        throw "Windows 11 LCU is not an MSU: $($selected.FileName)"
    }

    $resolved = Resolve-PackageFile `
        -Package $selected `
        -PackageType 'LCU'

    # Inspect MSU for SSU payload.
    $sevenZip = Find-SevenZip

    $listing = @(
        & $sevenZip l $resolved.LocalPath 2>&1
    )

    if ($LASTEXITCODE -ne 0) {
        throw "7-Zip failed to inspect $($resolved.LocalPath)"
    }

    $ssuIncluded = (
        $listing -match '(?i)SSU-\d+\.\d+-[^ ]+\.cab'
    )

    $resolvedObject = [ordered]@{
        schemaVersion = '1.3'
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
        sha256   = $resolved.Sha256

        microsoftUrl = $selected.Url

        artifactoryUrl  = $resolved.ArtifactUrl
        artifactoryRepo = $ArtifactoryRepo
        artifactoryPath = $resolved.RelativePath

        source = $resolved.Source

        ssuRequired = $false
        ssuIncluded = [bool]$ssuIncluded
        ssuSource   = if ($ssuIncluded) { 'LCU-MSU' } else { 'none' }

        ssu = $null

        resolvedAtUtc =
            [datetime]::UtcNow.ToString('o')
    }

    $json = $resolvedObject |
        ConvertTo-Json -Depth 20

    [IO.File]::WriteAllText(
        $Manifest,
        $json,
        [Text.UTF8Encoding]::new($false)
    )

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' Windows 11 Resolution Complete'
    Write-Host '============================================================'
    Write-Host "KB:            $($selected.KB)"
    Write-Host "Build:         $($selected.Build)"
    Write-Host "MSU:           $($selected.FileName)"
    Write-Host "SHA256:        $($resolved.Sha256)"
    Write-Host "Source:        $($resolved.Source)"
    Write-Host "Artifact path: $($resolved.RelativePath)"
    Write-Host "SSU included:  $ssuIncluded"
    Write-Host "Manifest:      $Manifest"
    Write-Host '============================================================'

    exit 0
}

# ---------------------------------------------------------------------------
# Windows 10 21H2
#
# Resolve standalone SSU first.
# Resolve LCU separately.
#
# Canonical caches:
#
#   Windows10/21H2/x64/SSU/<KB>/<filename>
#   Windows10/21H2/x64/LCU/<KB>/<filename>
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

    # -----------------------------------------------------------------------
    # Resolve SSU
    # -----------------------------------------------------------------------

    $resolvedSsu = Resolve-PackageFile `
        -Package $ssu `
        -PackageType 'SSU'

    # -----------------------------------------------------------------------
    # Resolve LCU
    # -----------------------------------------------------------------------

    $resolvedLcu = Resolve-PackageFile `
        -Package $lcu `
        -PackageType 'LCU'

    # -----------------------------------------------------------------------
    # Determine authoritative Windows 10 package build from the LCU payload.
    # -----------------------------------------------------------------------

    $packageBuild = Get-Windows10PackageBuild `
        -MsuPath $resolvedLcu.LocalPath `
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

    # -----------------------------------------------------------------------
    # Manifest
    # -----------------------------------------------------------------------

    $resolvedObject = [ordered]@{
        schemaVersion = '1.3'
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
        sha256   = $resolvedLcu.Sha256

        microsoftUrl = $lcu.Url

        artifactoryUrl  = $resolvedLcu.ArtifactUrl
        artifactoryRepo = $ArtifactoryRepo
        artifactoryPath = $resolvedLcu.RelativePath

        source = $resolvedLcu.Source

        ssuRequired = $true
        ssuIncluded = $false
        ssuSource   = 'standalone'

        ssu = [ordered]@{
            kb = $ssu.KB
            build = $ssu.Build
            releaseDate = $ssu.Date.ToString('yyyy-MM-dd')

            updateId = $ssu.UpdateId
            fileName = $ssu.FileName
            sha256 = $resolvedSsu.Sha256

            microsoftUrl = $ssu.Url

            artifactoryUrl = $resolvedSsu.ArtifactUrl
            artifactoryRepo = $ArtifactoryRepo
            artifactoryPath = $resolvedSsu.RelativePath

            source = $resolvedSsu.Source
        }

        lcu = [ordered]@{
            kb = $lcu.KB
            build = $resolvedBuild
            releaseDate = $lcu.Date.ToString('yyyy-MM-dd')

            updateId = $lcu.UpdateId
            fileName = $lcu.FileName
            sha256 = $resolvedLcu.Sha256

            microsoftUrl = $lcu.Url

            artifactoryUrl = $resolvedLcu.ArtifactUrl
            artifactoryRepo = $ArtifactoryRepo
            artifactoryPath = $resolvedLcu.RelativePath

            source = $resolvedLcu.Source
        }

        resolvedAtUtc =
            [datetime]::UtcNow.ToString('o')
    }

    $json = $resolvedObject |
        ConvertTo-Json -Depth 20

    [IO.File]::WriteAllText(
        $Manifest,
        $json,
        [Text.UTF8Encoding]::new($false)
    )

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' Windows 10 Updates Resolved'
    Write-Host '============================================================'
    Write-Host 'SSU:'
    Write-Host "  KB:            $($ssu.KB)"
    Write-Host "  File:          $($ssu.FileName)"
    Write-Host "  SHA256:        $($resolvedSsu.Sha256)"
    Write-Host "  Source:        $($resolvedSsu.Source)"
    Write-Host "  Artifact path: $($resolvedSsu.RelativePath)"
    Write-Host ''
    Write-Host 'LCU:'
    Write-Host "  KB:            $($lcu.KB)"
    Write-Host "  File:          $($lcu.FileName)"
    Write-Host "  Build:         $resolvedBuild"
    Write-Host "  SHA256:        $($resolvedLcu.Sha256)"
    Write-Host "  Source:        $($resolvedLcu.Source)"
    Write-Host "  Artifact path: $($resolvedLcu.RelativePath)"
    Write-Host ''
    Write-Host "Manifest:"
    Write-Host "  $Manifest"
    Write-Host '============================================================'

    exit 0
}

throw "Unsupported Windows image profile: $Profile"
