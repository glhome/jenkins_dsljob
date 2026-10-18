[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkRoot,
    [string]$OutputName='Windows-Custom',
    [int]$ImageIndex=1,
    [string]$Architecture='x64',
    [string]$WindowsVersion='',
    [string]$WindowsBuild=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$download=Join-Path $WorkRoot 'download'; $source=Join-Path $WorkRoot 'source'; $output=Join-Path $WorkRoot 'output'; $iso=Join-Path $output "$OutputName.iso"; $resolvedPath=Join-Path $download 'resolved-updates.json'
function Hash($p){if(Test-Path -LiteralPath $p -PathType Leaf){return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()};return $null}
$resolved=$null;if(Test-Path -LiteralPath $resolvedPath -PathType Leaf){$resolved=Get-Content -LiteralPath $resolvedPath -Raw|ConvertFrom-Json}
if($resolved){if(!$WindowsVersion){$WindowsVersion=[string]$resolved.windowsVersion};if(!$WindowsBuild){$WindowsBuild=[string]$resolved.windowsBuild}}
# Build a stable, auditable list from the resolved-update manifest. Do not
# hardcode checkpoint KBs: future Catalog responses can contain any number of
# required checkpoint packages.
$updatePackageRecords = @()
$lcuPackageRecords = @()
$ssuRecord = $null

if ($resolved) {
    if ($resolved.ssu) {
        $ssu = $resolved.ssu
        $ssuRecord = [ordered]@{
            component             = 'SSU'
            role                  = 'prerequisite'
            kb                    = [string]$ssu.kb
            fileName              = [string]$ssu.fileName
            sha256                = [string]$ssu.sha256
            artifactPath          = [string]$ssu.artifactPath
            source                = [string]$ssu.source
            updateId              = [string]$ssu.updateId
            artifactoryRecorded   = [bool]$ssu.artifactoryRecorded
        }
        $updatePackageRecords += $ssuRecord
    }

    if ($resolved.lcu -and $resolved.lcu.packages) {
        foreach ($package in @($resolved.lcu.packages)) {
            $record = [ordered]@{
                component             = 'LCU'
                role                  = [string]$package.type
                kb                    = [string]$package.kb
                fileName              = [string]$package.fileName
                sha256                = [string]$package.sha256
                artifactPath          = [string]$package.artifactPath
                source                = [string]$package.source
                updateId              = [string]$package.updateId
                artifactoryRecorded   = [bool]$package.artifactoryRecorded
            }
            $lcuPackageRecords += $record
            $updatePackageRecords += $record
        }
    }

    if ($lcuPackageRecords.Count -eq 0) {
        throw 'Cannot generate image manifest: resolved LCU package inventory is empty.'
    }

    if (
        [string]$resolved.profile -eq 'windows10-21h2' -and
        $null -eq $ssuRecord
    ) {
        throw 'Cannot generate Windows 10 image manifest: required SSU record is missing.'
    }

    # The resolved result is not publishable as an image manifest until every
    # required package has a verified Artifactory record and hash.
    $unrecorded = @(
        $updatePackageRecords | Where-Object {
            -not $_.artifactoryRecorded -or
            [string]::IsNullOrWhiteSpace([string]$_.artifactPath) -or
            [string]::IsNullOrWhiteSpace([string]$_.sha256)
        }
    )

    if ($unrecorded.Count -gt 0) {
        $unrecordedText = @(
            $unrecorded | ForEach-Object {
                "  $($_.component) $($_.kb) $($_.fileName)"
            }
        ) -join "`r`n"
        throw "Cannot generate image manifest: update packages lack verified Artifactory records:`r`n$unrecordedText"
    }
}

$lcu = $null
if ($resolved) {
    $lcu = [ordered]@{
        kb             = $resolved.kb
        build          = $resolved.build
        releaseDate    = $resolved.releaseDate
        updateId       = $resolved.updateId
        fileName       = $resolved.fileName
        sha256         = $resolved.sha256
        artifactoryUrl = $resolved.artifactoryUrl
        artifactoryPath = $resolved.artifactoryPath
        source         = $resolved.source
        packages       = @($lcuPackageRecords)
    }
}

$m = [ordered]@{
    schemaVersion = '1.1'
    image = [ordered]@{
        outputName    = $OutputName
        imageIndex    = $ImageIndex
        architecture  = $Architecture
        windowsVersion = $WindowsVersion
        windowsBuild  = $WindowsBuild
    }
    source = [ordered]@{
        baseIsoSha256 = (Hash (Join-Path $download 'base.iso'))
    }
    updates = [ordered]@{
        lcu         = $lcu
        ssu         = $ssuRecord
        packages    = @($updatePackageRecords)
        ssuIncluded = if ($resolved) { [bool]$resolved.ssuIncluded } else { $null }
    }
    servicedImage = [ordered]@{
        installWimSha256 = (Hash (Join-Path $source 'sources\install.wim'))
    }
    output = [ordered]@{
        isoFileName = [IO.Path]::GetFileName($iso)
        isoSha256   = (Hash $iso)
    }
    build = [ordered]@{
        timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}
$json=$m|ConvertTo-Json -Depth 20
[IO.File]::WriteAllText((Join-Path $output 'manifest.json'),$json,(New-Object System.Text.UTF8Encoding($false)))
