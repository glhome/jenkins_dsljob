def call(Map cfg = [:]) {

    def workRoot = cfg.workRoot
    def baseIsoPath = cfg.baseIsoPath
    def windowsBuild = cfg.windowsBuild ?: '26100'
    def architecture = cfg.architecture ?: 'x64'
    def artifactoryBaseUrl = cfg.artifactoryBaseUrl ?: ''
    def artifactoryRepo = cfg.artifactoryRepo ?: 'windows-updates'

    if (!workRoot?.trim()) {
        error 'workRoot is required'
    }

    if (!baseIsoPath?.trim()) {
        error 'baseIsoPath is required'
    }

    echo '============================================================'
    echo ' Windows Image Download / Update Resolution'
    echo '============================================================'
    echo "Work root       : ${workRoot}"
    echo "Base ISO        : ${baseIsoPath}"
    echo "Windows build   : ${windowsBuild}"
    echo "Architecture    : ${architecture}"
    echo "Artifactory     : ${artifactoryBaseUrl}"
    echo "Repository      : ${artifactoryRepo}"

    def downloadDir = "${workRoot}\\download"
    def baseIso = "${downloadDir}\\base.iso"

    powershell(
        '''
$ErrorActionPreference = 'Stop'

$sourceIso = '__SOURCE_ISO__'
$downloadDir = '__DOWNLOAD_DIR__'
$baseIso = '__BASE_ISO__'

Write-Host "Checking source ISO..."
Write-Host "  $sourceIso"

if (!(Test-Path -LiteralPath $sourceIso -PathType Leaf)) {
    throw "Base ISO not found: $sourceIso"
}

New-Item `
    -ItemType Directory `
    -Force `
    -Path $downloadDir | Out-Null

Write-Host "Copying base ISO..."
Write-Host "  Source      : $sourceIso"
Write-Host "  Destination : $baseIso"

Copy-Item `
    -LiteralPath $sourceIso `
    -Destination $baseIso `
    -Force

if (!(Test-Path -LiteralPath $baseIso -PathType Leaf)) {
    throw "Failed to stage base ISO: $baseIso"
}

$hash = Get-FileHash `
    -LiteralPath $baseIso `
    -Algorithm SHA256

Write-Host "Base ISO staged successfully."
Write-Host "SHA-256: $($hash.Hash)"
'''
        .replace('__SOURCE_ISO__', baseIsoPath)
        .replace('__DOWNLOAD_DIR__', downloadDir)
        .replace('__BASE_ISO__', baseIso)
    )

    def resolver = libraryResource(
        'scripts/windows-image/resolve-updates.ps1'
    )

    writeFile(
        file: 'resolve-updates.ps1',
        text: resolver
    )

    powershell(
        '''
$ErrorActionPreference = 'Stop'

& '__WORKSPACE__\\resolve-updates.ps1' `
    -WorkRoot '__WORK_ROOT__' `
    -WindowsBuild '__WINDOWS_BUILD__' `
    -Architecture '__ARCHITECTURE__' `
    -ArtifactoryBaseUrl '__ARTIFACTORY_URL__' `
    -ArtifactoryRepo '__ARTIFACTORY_REPO__'
'''
        .replace('__WORKSPACE__', env.WORKSPACE)
        .replace('__WORK_ROOT__', workRoot)
        .replace('__WINDOWS_BUILD__', windowsBuild)
        .replace('__ARCHITECTURE__', architecture)
        .replace('__ARTIFACTORY_URL__', artifactoryBaseUrl)
        .replace('__ARTIFACTORY_REPO__', artifactoryRepo)
    )

    powershell(
        '''
$ErrorActionPreference = 'Stop'

$manifest = '__MANIFEST__'
$updateDir = '__UPDATE_DIR__'

Write-Host "Verifying resolved update files..."

if (!(Test-Path -LiteralPath $manifest -PathType Leaf)) {
    throw "Resolved update manifest was not created: $manifest"
}

if (!(Test-Path -LiteralPath $updateDir -PathType Container)) {
    throw "Update directory was not created: $updateDir"
}

$updates = @(
    Get-ChildItem -LiteralPath $updateDir -File |
    Where-Object {
        $_.Extension -in @('.msu', '.cab')
    }
)

if ($updates.Count -eq 0) {
    throw "No update packages were resolved in: $updateDir"
}

Write-Host "Resolved update packages:"

foreach ($update in $updates) {

    $hash = Get-FileHash `
        -LiteralPath $update.FullName `
        -Algorithm SHA256

    Write-Host "  $($update.Name)"
    Write-Host "    Size   : $([math]::Round($update.Length / 1MB, 2)) MB"
    Write-Host "    SHA256 : $($hash.Hash)"
}

Write-Host ""
Write-Host "Resolved update manifest:"
Get-Content -LiteralPath $manifest
'''
        .replace('__MANIFEST__', "${downloadDir}\\resolved-updates.json")
        .replace('__UPDATE_DIR__', "${downloadDir}\\updates")
    )
}