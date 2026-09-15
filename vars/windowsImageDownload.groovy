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

    def downloadDir = "${workRoot}\\download"
    def baseIso = "${downloadDir}\\base.iso"

    powershell """
        \$ErrorActionPreference = 'Stop'

        \$sourceIso = '${baseIsoPath}'
        \$downloadDir = '${downloadDir}'
        \$baseIso = '${baseIso}'

        New-Item -ItemType Directory -Force `
            -Path \$downloadDir | Out-Null

        if (!(Test-Path -LiteralPath \$sourceIso -PathType Leaf)) {
            throw "Base ISO not found: \$sourceIso"
        }

        Write-Host "Copying local base ISO..."
        Write-Host "Source      : \$sourceIso"
        Write-Host "Destination : \$baseIso"

        Copy-Item `
            -LiteralPath \$sourceIso `
            -Destination \$baseIso `
            -Force

        if (!(Test-Path -LiteralPath \$baseIso -PathType Leaf)) {
            throw "Failed to create working base ISO: \$baseIso"
        }
    """

    def resolver = libraryResource(
        'scripts/windows-image/resolve-updates.ps1'
    )

    writeFile(
        file: 'resolve-updates.ps1',
        text: resolver
    )

    powershell """
        & '${env.WORKSPACE}\\resolve-updates.ps1' `
            -WorkRoot '${workRoot}' `
            -WindowsBuild '${windowsBuild}' `
            -Architecture '${architecture}' `
            -ArtifactoryBaseUrl '${artifactoryBaseUrl}' `
            -ArtifactoryRepo '${artifactoryRepo}'
    """
}