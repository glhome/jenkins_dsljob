def call(Map cfg = [:]) {
    def workRoot = cfg.workRoot
    if (!workRoot) error 'workRoot is required'
    def script = libraryResource('scripts/windows-image/prepare.ps1')
    def scriptPath = "${env.WORKSPACE}\prepare-windows-image.ps1"
    writeFile file: scriptPath, text: script
    powershell("& '${scriptPath}' -WorkRoot '${workRoot}'")
}
