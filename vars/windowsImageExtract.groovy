def call(Map cfg = [:]) {
    def workRoot = cfg.workRoot
    if (!workRoot) error 'workRoot is required'
    def script = libraryResource('scripts/windows-image/extract-iso.ps1')
    def scriptPath = "${env.WORKSPACE}\extract-windows-image.ps1"
    writeFile file: scriptPath, text: script
    powershell("& '${scriptPath}' -WorkRoot '${workRoot}' -ImageIndex ${cfg.imageIndex ?: 1}")
}
