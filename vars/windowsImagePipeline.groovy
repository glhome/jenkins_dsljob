def call(Map cfg = [:]) {

    def baseIsoArtifact = cfg.baseIsoArtifact
    def baseIsoSha256 = cfg.baseIsoSha256 ?: ''
    def windowsBuild = cfg.windowsBuild ?: '26100'
    def architecture = cfg.architecture ?: 'x64'
    def artifactoryBaseUrl = cfg.artifactoryBaseUrl ?: ''
    def artifactoryRepo = cfg.artifactoryRepo ?: 'snapshot-generic-local'
    def imageIndex = cfg.imageIndex ?: 1
    def agentLabel = cfg.agentLabel ?: 'windows-image-builder'
    def keepWorkspace = cfg.keepWorkspace ?: false

    if (!baseIsoArtifact?.trim()) error 'baseIsoArtifact is required'
    if (!artifactoryBaseUrl?.trim()) error 'artifactoryBaseUrl is required'

    node(agentLabel) {
        def workRoot = env.WORKSPACE
        def imageInfo = null

        echo """
============================================================
 Windows Image Factory
============================================================
Agent:
  ${env.NODE_NAME}
Workspace:
  ${env.WORKSPACE}
Base ISO Artifact:
  ${baseIsoArtifact}
Artifactory Repository:
  ${artifactoryRepo}
Windows Build:
  ${windowsBuild}
Architecture:
  ${architecture}
Image Index:
  ${imageIndex}
============================================================
"""

        try {
            stage('Prepare') {
                windowsImagePrepare(workRoot: workRoot)
            }

            stage('Download Base ISO and Updates') {
                imageInfo = windowsImageDownload(
                    workRoot: workRoot,
                    baseIsoArtifact: baseIsoArtifact,
                    baseIsoSha256: baseIsoSha256,
                    windowsBuild: windowsBuild,
                    architecture: architecture,
                    artifactoryBaseUrl: artifactoryBaseUrl,
                    artifactoryRepo: artifactoryRepo
                )
            }

            echo """
============================================================
 Resolved Windows Image
============================================================
LCU KB:
  ${imageInfo.kb}
LCU Build:
  ${imageInfo.lcuBuild}
Release Date:
  ${imageInfo.releaseDate}
ISO:
  ${imageInfo.outputName}.iso
Artifactory ISO:
  ${imageInfo.isoArtifactPath}
ISO Already Exists:
  ${imageInfo.isoExists}
============================================================
"""

            if (imageInfo.isoExists) {
                stage('Image Already Exists') {
                    echo 'Latest LCU ISO already exists in Artifactory.'
                    echo 'Skipping Extract, Service, Create ISO, and Publish.'
                    echo "ISO: ${imageInfo.isoArtifactPath}"
                }
            } else {
                stage('Extract Windows Image') {
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
                        outputName: imageInfo.outputName
                    )
                }

                stage('Generate Manifest') {
                    windowsImageManifest(
                        workRoot: workRoot,
                        outputName: imageInfo.outputName,
                        imageIndex: imageIndex,
                        architecture: architecture,
                        windowsBuild: windowsBuild
                    )
                }

                stage('Publish ISO') {
                    windowsImagePublish(
                        workRoot: workRoot,
                        outputName: imageInfo.outputName,
                        kb: imageInfo.kb,
                        lcuBuild: imageInfo.lcuBuild,
                        architecture: architecture,
                        artifactoryBaseUrl: artifactoryBaseUrl,
                        artifactoryRepo: artifactoryRepo
                    )
                }
            }
        } finally {
            if (keepWorkspace) {
                echo 'KEEP_WORKSPACE=true'
                echo "Preserving workspace: ${workRoot}"
            }
        }
    }
}
