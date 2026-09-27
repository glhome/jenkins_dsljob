def call(Map cfg = [:]) {
    def workRoot = cfg.workRoot
    def outputName = cfg.outputName ?: 'Windows-Custom'
    def imageIndex = cfg.imageIndex ?: 1
    def architecture = cfg.architecture ?: 'x64'
    def windowsVersion = cfg.windowsVersion ?: ''
    def windowsBuild = cfg.windowsBuild ?: ''
    if (!workRoot?.trim()) error 'workRoot is required'
    def script = libraryResource('scripts/windows-image/generate-manifest.ps1')
    def scriptPath = "${env.WORKSPACE}\\generate-windows-manifest.ps1"
    writeFile(file: scriptPath, text: script)
    powershell("& '${scriptPath}' -WorkRoot '${workRoot}' -OutputName '${outputName}' -ImageIndex ${imageIndex} -Architecture '${architecture}' -WindowsVersion '${windowsVersion}' -WindowsBuild '${windowsBuild}'")
}
