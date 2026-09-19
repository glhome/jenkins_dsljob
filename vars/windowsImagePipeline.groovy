def call(Map cfg = [:]) {

    def baseIsoArtifact =
        cfg.baseIsoArtifact

    def baseIsoSha256 =
        cfg.baseIsoSha256 ?: ''

    def windowsBuild =
        cfg.windowsBuild ?: '26100'

    def architecture =
        cfg.architecture ?: 'x64'

    def updateManifestUrl =
        cfg.updateManifestUrl ?: ''

    def updateManifestFile =
        cfg.updateManifestFile ?: ''

    def artifactoryBaseUrl =
        cfg.artifactoryBaseUrl ?: ''

    def artifactoryRepo =
        cfg.artifactoryRepo ?: 'snapshot-generic-local'

    def imageIndex =
        cfg.imageIndex ?: 1

    def outputName =
        cfg.outputName ?: 'Windows-Custom'

    def agentLabel =
        cfg.agentLabel ?: 'windows-image-builder'

    def keepWorkspace =
        cfg.keepWorkspace ?: false


    if (!baseIsoArtifact?.trim()) {
        error 'baseIsoArtifact is required'
    }

    if (!artifactoryBaseUrl?.trim()) {
        error 'artifactoryBaseUrl is required'
    }


    node(agentLabel) {

        /*
         * env.WORKSPACE is the authoritative Jenkins workspace.
         *
         * Jenkins may assign:
         *
         *   windows-image
         *   windows-image@2
         *   windows-image@3
         *
         * Do not construct or modify this path.
         */

        def workRoot = env.WORKSPACE


        echo """
============================================================
 Windows Image Factory
============================================================

Agent:
  ${env.NODE_NAME}

Workspace:
  ${env.WORKSPACE}

WorkRoot:
  ${workRoot}

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

Output:
  ${outputName}

============================================================
"""


        try {

            stage('Prepare') {

                windowsImagePrepare(
                    workRoot: workRoot
                )
            }


            stage('Download Base ISO and Updates') {

                windowsImageDownload(
                    workRoot: workRoot,
                    baseIsoArtifact: baseIsoArtifact,
                    baseIsoSha256: baseIsoSha256,
                    windowsBuild: windowsBuild,
                    architecture: architecture,
                    updateManifestUrl: updateManifestUrl,
                    updateManifestFile: updateManifestFile,
                    artifactoryBaseUrl: artifactoryBaseUrl,
                    artifactoryRepo: artifactoryRepo
                )
            }


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
                    outputName: outputName
                )
            }


            stage('Generate Manifest') {

                windowsImageManifest(
                    workRoot: workRoot,
                    outputName: outputName
                )
            }

        }
        finally {

            if (keepWorkspace) {

                echo "KEEP_WORKSPACE=true"
                echo "Preserving workspace: ${workRoot}"

            }
        }
    }
}