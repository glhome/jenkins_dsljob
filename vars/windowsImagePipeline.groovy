def call(Map cfg = [:]) {
    def baseIsoUrl = cfg.baseIsoUrl ?: ''
    def baseIsoSha256 = cfg.baseIsoSha256 ?: ''
    def ssuUrl = cfg.ssuUrl ?: ''
    def ssuSha256 = cfg.ssuSha256 ?: ''
    def lcuUrl = cfg.lcuUrl ?: ''
    def lcuSha256 = cfg.lcuSha256 ?: ''
    def imageIndex = cfg.imageIndex ?: 1
    def outputName = cfg.outputName ?: 'Windows-Custom'
    def agentLabel = cfg.agentLabel ?: 'windows-image-builder'
    def workRoot = cfg.workRoot ?: "${env.WORKSPACE}\windows-image"
    def keepWorkspace = cfg.keepWorkspace ?: false

    if (!baseIsoUrl?.trim()) {
        error 'baseIsoUrl is required'
    }

    node(agentLabel) {
        currentBuild.description = "${outputName} | Index ${imageIndex}"

        try {
            stage('Prepare') {
                windowsImagePrepare(workRoot: workRoot)
            }
            stage('Download') {
                windowsImageDownload(
                    workRoot: workRoot,
                    baseIsoUrl: baseIsoUrl,
                    baseIsoSha256: baseIsoSha256,
                    ssuUrl: ssuUrl,
                    ssuSha256: ssuSha256,
                    lcuUrl: lcuUrl,
                    lcuSha256: lcuSha256
                )
            }
            stage('Extract ISO') {
                windowsImageExtract(workRoot: workRoot, imageIndex: imageIndex)
            }
            stage('Service Windows Image') {
                windowsImageService(workRoot: workRoot, imageIndex: imageIndex)
            }
            stage('Create ISO') {
                windowsImageCreateIso(workRoot: workRoot, outputName: outputName)
            }
            stage('Generate Manifest') {
                windowsImageManifest(
                    workRoot: workRoot,
                    outputName: outputName,
                    imageIndex: imageIndex,
                    baseIsoUrl: baseIsoUrl,
                    ssuUrl: ssuUrl,
                    lcuUrl: lcuUrl,
                    buildNumber: env.BUILD_NUMBER,
                    buildId: env.BUILD_ID
                )
            }
            stage('Archive Artifacts') {
                archiveArtifacts(
                    artifacts: 'windows-image/output/*.iso,windows-image/output/*.sha256,windows-image/output/manifest.json',
                    fingerprint: true
                )
            }
        } finally {
            if (!keepWorkspace) {
                stage('Cleanup') {
                    powershell("if (Test-Path -LiteralPath '${workRoot}') { Remove-Item -LiteralPath '${workRoot}' -Recurse -Force -ErrorAction SilentlyContinue }")
                }
            }
        }
    }
}
