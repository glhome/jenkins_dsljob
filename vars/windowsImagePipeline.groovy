def call(Map cfg = [:]) {
    def baseIsoPath = cfg.baseIsoPath ?: ''
    def baseIsoSha256 = cfg.baseIsoSha256 ?: ''
    def windowsBuild = cfg.windowsBuild ?: '26100'
    def architecture = cfg.architecture ?: 'x64'
    def imageIndex = cfg.imageIndex ?: 1
    def outputName = cfg.outputName ?: 'Windows-Custom'
    def agentLabel = cfg.agentLabel ?: 'windows-image-builder'

    if (!baseIsoPath.trim()) {
        error 'baseIsoPath is required'
    }

    node(agentLabel) {

        def workRoot = "${env.WORKSPACE}\\windows-image"

        echo "Workspace: ${env.WORKSPACE}"
        echo "Work root: ${workRoot}"
        echo "Base ISO: ${baseIsoPath}"

        stage('Prepare') {
            windowsImagePrepare(
                workRoot: workRoot,
                baseIsoPath: baseIsoPath
            )
        }

        stage('Download') {
            windowsImageDownload(
                workRoot: workRoot,
                baseIsoPath: baseIsoPath,
                baseIsoSha256: baseIsoSha256,
                windowsBuild: windowsBuild,
                architecture: architecture
            )
        }

        stage('Extract ISO') {
            windowsImageExtract(
                workRoot: workRoot,
                imageIndex: imageIndex
            )
        }

        stage('Service Windows Image') {
            windowsImageService(
                workRoot: workRoot,
                imageIndex: imageIndex,
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
                architecture: architecture
            )
        }

        stage('Archive Artifacts') {
            archiveArtifacts(
                artifacts: 'windows-image/output/*.iso,windows-image/output/*.sha256,windows-image/output/manifest.json',
                fingerprint: true
            )
        }
    }
}