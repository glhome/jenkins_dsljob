def call(Map cfg = [:]) {

    def workRoot = cfg.workRoot
    def baseIsoPath = cfg.baseIsoPath

    if (!workRoot?.trim()) {
        error 'workRoot is required'
    }

    if (!baseIsoPath?.trim()) {
        error 'baseIsoPath is required'
    }

    if (!fileExists(baseIsoPath)) {
        error "Base ISO not found: ${baseIsoPath}"
    }

    def downloadDir = "${workRoot}\\download"
    def baseIso = "${downloadDir}\\base.iso"

    powershell """
        New-Item -ItemType Directory -Force `
            -Path '${downloadDir}' | Out-Null

        Write-Host "Copying base ISO..."
        Write-Host "Source: ${baseIsoPath}"
        Write-Host "Destination: ${baseIso}"

        Copy-Item `
            -LiteralPath '${baseIsoPath}' `
            -Destination '${baseIso}' `
            -Force

        if (!(Test-Path -LiteralPath '${baseIso}')) {
            throw "Failed to stage base ISO: ${baseIso}"
        }

        Write-Host "Base ISO staged successfully:"
        Write-Host '${baseIso}'
    """
}