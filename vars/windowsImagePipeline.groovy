def call(Map cfg = [:]) {

    def baseIsoPath       = cfg.baseIsoPath
    def baseIsoSha256     = cfg.baseIsoSha256 ?: ''
    def windowsBuild      = cfg.windowsBuild ?: '26100'
    def architecture      = cfg.architecture ?: 'x64'
    def updateManifestUrl = cfg.updateManifestUrl ?: ''
    def updateManifestFile = cfg.updateManifestFile ?: ''
    def artifactoryBaseUrl = cfg.artifactoryBaseUrl ?: ''
    def artifactoryRepo   = cfg.artifactoryRepo ?: 'windows-updates'
    def imageIndex        = cfg.imageIndex ?: 1
    def outputName        = cfg.outputName ?: 'Windows-Custom'
    def agentLabel        = cfg.agentLabel ?: 'windows-image-builder'
    def keepWorkspace     = cfg.keepWorkspace ?: false

    if (!baseIsoPath?.trim()) {
        error 'baseIsoPath is required'
    }

    node(agentLabel) {

        // IMPORTANT:
        // WorkRoot is the Jenkins workspace itself.
        // Do NOT append \\windows-image here.
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

 Base ISO:
   ${baseIsoPath}

 Windows Build:
   ${windowsBuild}

 Architecture:
   ${architecture}

 Artifactory:
   ${artifactoryBaseUrl}

 Repository:
   ${artifactoryRepo}

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
                    baseIsoPath: baseIsoPath,
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

            if (!keepWorkspace) {

                echo "Workspace cleanup is enabled."

                // Do not blindly delete the workspace here.
                // The service script is responsible for DISM cleanup.
                // Jenkins Workspace Cleanup can be added separately.
            }
            else {

                echo "KEEP_WORKSPACE=true - preserving:"
                echo workRoot
            }
        }
    }
}