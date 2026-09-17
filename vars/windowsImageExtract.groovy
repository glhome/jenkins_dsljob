def call(Map cfg = [:]) {

    def workRoot = cfg.workRoot
    def imageIndex = cfg.imageIndex ?: 1

    if (!workRoot?.trim()) {
        error 'workRoot is required'
    }

    def script = libraryResource(
        'scripts/windows-image/extract-iso.ps1'
    )

    def scriptPath =
        "${env.WORKSPACE}\\extract-windows-image.ps1"

    writeFile(
        file: scriptPath,
        text: script
    )

    echo "Extract WorkRoot: ${workRoot}"

    powershell(
        '''
$ErrorActionPreference = 'Stop'

& '__SCRIPT_PATH__' `
    -WorkRoot '__WORK_ROOT__' `
    -ImageIndex __IMAGE_INDEX__
'''
        .replace('__SCRIPT_PATH__', scriptPath)
        .replace('__WORK_ROOT__', workRoot)
        .replace('__IMAGE_INDEX__', imageIndex.toString())
    )
}