def call(Map cfg = [:]) {

    def workRoot = cfg.workRoot
    def imageIndex = cfg.imageIndex ?: 1

    if (!workRoot?.trim()) {
        error 'workRoot is required'
    }

    def script = libraryResource(
        'scripts/windows-image/service-image.ps1'
    )

    writeFile(
        file: 'service-image.ps1',
        text: script
    )

    powershell """
        & '${env.WORKSPACE}\\service-image.ps1' `
            -WorkRoot '${workRoot}' `
            -ImageIndex ${imageIndex}
    """
}