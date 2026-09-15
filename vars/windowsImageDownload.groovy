def call(Map cfg = [:]) {

    def workRoot = cfg.workRoot
    def baseIsoPath = cfg.baseIsoPath

    def windowsBuild = cfg.windowsBuild ?: '26100'
    def architecture = cfg.architecture ?: 'x64'

    def artifactoryBaseUrl =
        cfg.artifactoryBaseUrl ?: ''

    def artifactoryRepo =
        cfg.artifactoryRepo ?: 'windows-updates'

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

    // ---------------------------------------------------------
    // Stage local base ISO
    // ---------------------------------------------------------

    def downloadDir = "${workRoot}\\download"
    def baseIso = "${downloadDir}\\base.iso"

    powershell """
        \$ErrorActionPreference = 'Stop'

        \$sourceIso = '${baseIsoPath}'
        \$downloadDir = '${downloadDir}'
        \$baseIso = '${baseIso}'

        Write-Host 'Checking source ISO...'
        Write-Host "  \$sourceIso"

        if (!(Test-Path -LiteralPath \$sourceIso -PathType Leaf)) {
            throw "Base ISO not found: \$sourceIso"
        }

        New-Item `
            -ItemType Directory `
            -Force `
            -Path \$downloadDir | Out-Null

        Write-Host ''
        Write-Host 'Copying base ISO to workspace...'
        Write-Host "  Source      : \$sourceIso"
        Write-Host "  Destination : \$baseIso"

        Copy-Item `
            -LiteralPath \$sourceIso `
            -Destination \$baseIso `
            -Force

        if (!(Test-Path -LiteralPath \$baseIso -PathType Leaf)) {
            throw "Failed to stage base ISO: \$baseIso"
        }

        \$hash = Get-FileHash `
            -LiteralPath \$baseIso `
            -Algorithm SHA256

        Write-Host ''
        Write-Host 'Base ISO staged successfully.'
        Write-Host "  SHA-256: \$($hash.Hash)"
    """

    // ---------------------------------------------------------
    // Resolve newest Microsoft update
    // ---------------------------------------------------------

    def resolver = libraryResource(
        'scripts/windows-image/resolve-updates.ps1'
    )

    writeFile(
        file: 'resolve-updates.ps1',
        text: resolver
    )

    powershell """
        \$ErrorActionPreference = 'Stop'

        Write-Host ''
        Write-Host '============================================================'
        Write-Host ' Resolving Microsoft Windows Updates'
        Write-Host '============================================================'

        & '${env.WORKSPACE}\\resolve-updates.ps1' `
            -WorkRoot '${workRoot}' `
            -WindowsBuild '${windowsBuild}' `
            -Architecture '${architecture}' `
            -ArtifactoryBaseUrl '${artifactoryBaseUrl}' `
            -ArtifactoryRepo '${artifactoryRepo}'
    """

    // ---------------------------------------------------------
    // Verify the resolver produced exactly what the service
    // stage expects.
    // ---------------------------------------------------------

    powershell """
        \$ErrorActionPreference = 'Stop'

        \$downloadDir = '${downloadDir}'
        \$manifest = Join-Path \$downloadDir 'resolved-updates.json'
        \$updateDir = Join-Path \$downloadDir 'updates'

        Write-Host ''
        Write-Host 'Verifying resolved update files...'

        if (!(Test-Path -LiteralPath \$manifest -PathType Leaf)) {
            throw "Resolved update manifest was not created: \$manifest"
        }

        if (!(Test-Path -LiteralPath \$updateDir -PathType Container)) {
            throw "Update directory was not created: \$updateDir"
        }

        \$updates = @(
            Get-ChildItem `
                -LiteralPath \$updateDir `
                -File `
                -Include *.msu,*.cab
        )

        if (\$updates.Count -eq 0) {
            throw "No update packages were resolved in: \$updateDir"
        }

        Write-Host ''
        Write-Host 'Resolved update packages:'

        foreach (\$update in \$updates) {
            \$hash = Get-FileHash `
                -LiteralPath \$update.FullName `
                -Algorithm SHA256

            Write-Host "  \$($update.Name)"
            Write-Host "    Size   : \$([math]::Round(\$update.Length / 1MB, 2)) MB"
            Write-Host "    SHA256 : \$($hash.Hash)"
        }

        Write-Host ''
        Write-Host 'Resolved update manifest:'
        Get-Content -LiteralPath \$manifest
    """
}