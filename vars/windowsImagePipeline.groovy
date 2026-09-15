def call(Map cfg = [:]) {

    def baseIsoPath = cfg.baseIsoPath ?: ''
    def baseIsoSha256 = cfg.baseIsoSha256 ?: ''

    def windowsBuild = cfg.windowsBuild ?: ''
    def architecture = cfg.architecture ?: 'x64'

    def updateManifestUrl = cfg.updateManifestUrl ?: ''
    def updateManifestFile = cfg.updateManifestFile ?: ''

    def artifactoryBaseUrl = cfg.artifactoryBaseUrl ?: ''
    def artifactoryRepo = cfg.artifactoryRepo ?: 'windows-updates'

    def imageIndex = cfg.imageIndex ?: 1
    def outputName = cfg.outputName ?: 'Windows-Custom'

    def agentLabel = cfg.agentLabel ?: 'windows-image-builder'
    def workRoot = cfg.workRoot ?: "${env.WORKSPACE}\\windows-image"
    def keepWorkspace = cfg.keepWorkspace ?: false

    if (!baseIsoPath?.trim()) {
        error 'baseIsoPath is required'
    }

    node(agentLabel) {

        currentBuild.description =
            "${outputName} | Windows ${windowsBuild} | ${architecture} | Index ${imageIndex}"

        try {

            stage('Prepare') {
                windowsImagePrepare(
                    workRoot: workRoot,
                    baseIsoPath: baseIsoPath
                )
            }

            /*stage('Download') {
                windowsImageDownload(
                    workRoot: workRoot,
                    baseIsoPath: baseIsoPath,
                    baseIsoSha256: baseIsoSha256,

                    windowsBuild: windowsBuild,
                    architecture: architecture,

                    updateManifestUrl: updateManifestUrl,
                    updateManifestFile: updateManifestFile,

                    artifactoryBaseUrl: artifactoryBaseUrl,
                    artifactoryRepo: artifactoryRepo
                )
            }*/

            stage('Extract ISO') {
                windowsImageExtract(
                    workRoot: workRoot,
                    imageIndex: imageIndex
                )
            }

            stage('Service Windows Image') {
                windowsImageService(
                    workRoot: workRoot,
                    imageIndex: imageIndex
                )
            }

            stage('Create ISO') {
                windowsImageCreateIso(
                    workRoot: workRoot,
                    outputName: outputName
                )
            }

            stage('Generate Manifest') {
                windowsImageManifest(
                    workRoot: workRoot,
                    outputName: outputName,
                    imageIndex: imageIndex,

                    baseIsoPath: baseIsoPath,
                    baseIsoSha256: baseIsoSha256,

                    windowsBuild: windowsBuild,
                    architecture: architecture,

                    artifactoryRepo: artifactoryRepo,

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
                    powershell("""
                        if (Test-Path -LiteralPath '${workRoot}') {
                            Remove-Item -LiteralPath '${workRoot}' `
                                -Recurse `
                                -Force `
                                -ErrorAction SilentlyContinue
                        }
                    """)
                }
            }
        }
    }
}