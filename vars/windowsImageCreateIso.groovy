def call(Map cfg = [:]) {
    def workRoot = cfg.workRoot
    if (!workRoot) error 'workRoot is required'
    def outputName = cfg.outputName ?: 'Windows-Custom'
    def script = libraryResource('scripts/windows-image/create-iso.ps1')
    def scriptPath = "${env.WORKSPACE}\create-windows-iso.ps1"
    writeFile file: scriptPath, text: script
    powershell("& '${scriptPath}' -WorkRoot '${workRoot}' -OutputName '${outputName}'")
}
