def call(Map cfg = [:]) {
    def workRoot = cfg.workRoot
    def profile = cfg.profile

    if (!workRoot?.trim()) {
        error 'workRoot is required'
    }
    if (!profile?.trim()) {
        error 'profile is required for WIM edition detection'
    }

    def script = libraryResource(
        'scripts/windows-image/extract-iso.ps1'
    )
    def scriptPath = "${env.WORKSPACE}\\extract-windows-image.ps1"

    writeFile(file: scriptPath, text: script)

    echo "Extract WorkRoot: ${workRoot}"

    powershell(
        '''
$ErrorActionPreference = 'Stop'

& '__SCRIPT_PATH__' `
    -WorkRoot '__WORK_ROOT__'
'''
        .replace('__SCRIPT_PATH__', scriptPath)
        .replace('__WORK_ROOT__', workRoot)
    )

    def detector = libraryResource(
        'scripts/windows-image/detect-image-index.ps1'
    )
    def detectorPath = "${env.WORKSPACE}\\detect-image-index.ps1"

    writeFile(file: detectorPath, text: detector)

    powershell(
        '''
$ErrorActionPreference = 'Stop'

& '__DETECTOR_PATH__' `
    -Profile '__PROFILE__' `
    -WimFile '__WIM_FILE__' `
    -OutputFile '__OUTPUT_FILE__'
'''
        .replace('__DETECTOR_PATH__', detectorPath)
        .replace('__PROFILE__', profile)
        .replace('__WIM_FILE__', "${workRoot}\\source\\sources\\install.wim")
        .replace('__OUTPUT_FILE__', "${workRoot}\\source\\image-selection.json")
    )

    def selectionJson = readFile(file: 'source/image-selection.json')
    def selection = new groovy.json.JsonSlurperClassic().parseText(selectionJson)
    def detectedIndex = selection.imageIndex as Integer

    if (detectedIndex < 1) {
        error "Invalid detected WIM index: ${detectedIndex}"
    }

    echo "Selected WIM edition: ${selection.imageName}"
    echo "Selected WIM index: ${detectedIndex}"

    return detectedIndex
}
