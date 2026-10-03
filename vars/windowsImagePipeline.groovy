def call(Map cfg = [:]) {

    def profile = cfg.profile ?: 'windows11-24h2'
    def architecture = cfg.architecture ?: 'x64'

    def artifactoryBaseUrl =
        cfg.artifactoryBaseUrl ?: ''

    def artifactoryRepo =
        cfg.artifactoryRepo ?: 'snapshot-generic-local'

    def imageIndex =
        cfg.imageIndex ?: 1

    def agentLabel =
        cfg.agentLabel ?: 'windows-image-builder'

    def keepWorkspace =
        cfg.keepWorkspace ?: false

    /*
     * Production default.
     *
     * The test job must explicitly pass publish:false.
     */
    def publish =
        cfg.containsKey('publish') ? cfg.publish : true

    def profileBaseIsoArtifact = [
        'windows11-24h2':
            'Windows11/24H2/x64/base/' +
            'en-us_windows_11_iot_enterprise_version_24h2_x64_dvd_3a99b72b.iso',

        'windows10-21h2':
            'Windows10/21H2/x64/base/' +
            'en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso'
    ]

    def profileBaseIsoSha256 = [
        'windows11-24h2':
            'eceb8dc167077e07f9a9bd04e472ea542944974b81b2ebc25477772a71bdbb69',

        'windows10-21h2':
            'a0334f31ea7a3e6932b9ad7206608248f0bd40698bfb8fc65f14fc5e4976c160'
    ]

    if (!profileBaseIsoArtifact.containsKey(profile)) {
        error "Unknown Windows image profile: ${profile}"
    }

    def suppliedBaseIso =
        cfg.baseIsoArtifact?.toString()?.trim()

    def suppliedChecksum =
        cfg.baseIsoSha256?.toString()?.trim()

    def baseIsoArtifact =
        (!suppliedBaseIso ||
         suppliedBaseIso == '__PROFILE_DEFAULT__')
            ? profileBaseIsoArtifact[profile]
            : suppliedBaseIso

    def baseIsoSha256 =
        (!suppliedChecksum ||
         suppliedChecksum == '__PROFILE_DEFAULT__')
            ? profileBaseIsoSha256[profile]
            : suppliedChecksum

    if (!baseIsoArtifact?.trim()) {
        error 'baseIsoArtifact is required'
    }

    if (!baseIsoSha256?.trim()) {
        error 'baseIsoSha256 is required'
    }

    if (!artifactoryBaseUrl?.trim()) {
        error 'artifactoryBaseUrl is required'
    }

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
  ${workRoot}

Profile:
  ${profile}

Architecture:
  ${architecture}

Base ISO:
  ${baseIsoArtifact}

Publish:
  ${publish}

Artifactory:
  ${artifactoryRepo}
============================================================
"""

        try {

            stage('Prepare') {
                windowsImagePrepare(
                    workRoot: workRoot
                )
            }

            stage('Resolve / Download') {

                imageInfo = windowsImageDownload(
                    workRoot: workRoot,
                    baseIsoArtifact: baseIsoArtifact,
                    baseIsoSha256: baseIsoSha256,
                    profile: profile,
                    architecture: architecture,
                    artifactoryBaseUrl: artifactoryBaseUrl,
                    artifactoryRepo: artifactoryRepo,
                    artifactTransferMethod: params.ARTIFACT_TRANSFER_METHOD
                )
            }

            echo """
============================================================
 Resolved Windows Image
============================================================
Profile:
  ${imageInfo.profile}

Windows:
  ${imageInfo.windowsVersion}

Base Build:
  ${imageInfo.windowsBuild}

KB:
  ${imageInfo.kb}

LCU Build:
  ${imageInfo.lcuBuild}

Release:
  ${imageInfo.releaseDate}

Output:
  ${imageInfo.outputName}.iso

Cache Hit:
  ${imageInfo.cacheHit}

Publish:
  ${publish}
============================================================
"""

            if (imageInfo.cacheHit) {

                stage('Patched Image Cache Hit') {

                    echo '''
Matching patched image already exists.

Base ISO and update download are skipped.

Extract, Service, Create ISO and Generate Manifest are skipped.
'''
                }

                if (!publish) {
                    echo 'TEST MODE: no publish operation requested.'
                }

                return
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
                    outputName: imageInfo.outputName
                )
            }

            stage('Generate Manifest') {

                windowsImageManifest(
                    workRoot: workRoot,
                    outputName: imageInfo.outputName,
                    imageIndex: imageIndex,
                    architecture: architecture,
                    windowsVersion: imageInfo.windowsVersion,
                    windowsBuild: imageInfo.windowsBuild
                )
            }

            if (publish) {

                stage('Publish ISO') {

                    windowsImagePublish(
                        workRoot: workRoot,
                        outputName: imageInfo.outputName,
                        kb: imageInfo.kb,
                        lcuBuild: imageInfo.lcuBuild,
                        architecture: architecture,
                        windowsProduct: imageInfo.windowsProduct,
                        windowsRelease: imageInfo.windowsRelease,
                        artifactoryBaseUrl: artifactoryBaseUrl,
                        artifactoryRepo: artifactoryRepo
                    )
                }
            }
            else {

                stage('Publish Skipped') {

                    echo '''
============================================================
 TEST MODE
============================================================
Image was resolved, extracted, serviced, ISO-created and
manifest-generated.

Artifactory publishing is intentionally disabled.
============================================================
'''
                }
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