def call(Map cfg = [:]) {
    def workRoot = cfg.workRoot
    if (!workRoot) error 'workRoot is required'

    def script = libraryResource('scripts/windows-image/generate-manifest.ps1')
    def scriptPath = "${env.WORKSPACE}/generate-windows-manifest.ps1"
    writeFile file: scriptPath, text: script

    powershell(
        "& '${scriptPath}' " +
        "-WorkRoot '${workRoot}' " +
        "-OutputName '${cfg.outputName ?: 'Windows-Custom'}' " +
        "-ImageIndex ${cfg.imageIndex ?: 1} " +
        "-Architecture '${cfg.architecture ?: 'x64'}' " +
        "-WindowsBuild '${cfg.windowsBuild ?: ''}'"
    )
}
