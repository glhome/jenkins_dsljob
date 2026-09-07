def call(Map cfg = [:]) {
    def workRoot = cfg.workRoot
    def baseIsoUrl = cfg.baseIsoUrl
    if (!workRoot) error 'workRoot is required'
    if (!baseIsoUrl) error 'baseIsoUrl is required'

    def script = libraryResource('scripts/windows-image/download.ps1')
    def scriptPath = "${env.WORKSPACE}\download-windows-image.ps1"
    writeFile file: scriptPath, text: script

    def args = ["-WorkRoot '${workRoot}'", "-BaseIsoUrl '${baseIsoUrl}'"]
    if (cfg.baseIsoSha256) args << "-BaseIsoSha256 '${cfg.baseIsoSha256}'"
    if (cfg.ssuUrl) args << "-SsuUrl '${cfg.ssuUrl}'"
    if (cfg.ssuSha256) args << "-SsuSha256 '${cfg.ssuSha256}'"
    if (cfg.lcuUrl) args << "-LcuUrl '${cfg.lcuUrl}'"
    if (cfg.lcuSha256) args << "-LcuSha256 '${cfg.lcuSha256}'"

    powershell("& '${scriptPath}' ${args.join(' ')}")
}
