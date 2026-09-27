def call(Map cfg = [:]) {
    def profile = cfg.profile ?: 'windows11-24h2'

    // Profile defaults. These are used when the Job DSL parameters contain
    // __PROFILE_DEFAULT__, so selecting a profile automatically selects its
    // matching base ISO and checksum. Explicit values still override them.
    def profileBaseIsoArtifact = [
        'windows11-24h2': 'Windows11/24H2/x64/base/en-us_windows_11_iot_enterprise_version_24h2_x64_dvd_3a99b72b.iso',
        'windows10-21h2': 'Windows10/21H2/x64/base/19044.1288.211006-0501.21h2_release_svc_refresh_CLIENT_BUSINESS_VOL_x64FRE_en-us.iso'
    ]
    def profileBaseIsoSha256 = [
        'windows11-24h2': 'eceb8dc167077e07f9a9bd04e472ea542944974b81b2ebc25477772a71bdbb69',
        'windows10-21h2': '1323fd1ef0cbfd4bf23fa56a6538ff69dd410ad49969983fee3df936a6c811c5'
    ]

    def suppliedBaseIsoArtifact = cfg.baseIsoArtifact?.toString()?.trim()
    def suppliedBaseIsoSha256 = cfg.baseIsoSha256?.toString()?.trim()

    def baseIsoArtifact = (!suppliedBaseIsoArtifact || suppliedBaseIsoArtifact == '__PROFILE_DEFAULT__')
        ? profileBaseIsoArtifact[profile]
        : suppliedBaseIsoArtifact
    def baseIsoSha256 = (!suppliedBaseIsoSha256 || suppliedBaseIsoSha256 == '__PROFILE_DEFAULT__')
        ? profileBaseIsoSha256[profile]
        : suppliedBaseIsoSha256
    def architecture = cfg.architecture ?: 'x64'
    def artifactoryBaseUrl = cfg.artifactoryBaseUrl ?: ''
    def artifactoryRepo = cfg.artifactoryRepo ?: 'snapshot-generic-local'
    def imageIndex = cfg.imageIndex ?: 1
    def agentLabel = cfg.agentLabel ?: 'windows-image-builder'
    def keepWorkspace = cfg.keepWorkspace ?: false

    if (!profileBaseIsoArtifact.containsKey(profile)) error "Unknown Windows image profile: ${profile}"
    if (!baseIsoArtifact?.trim()) error 'baseIsoArtifact is required'
    if (!baseIsoSha256?.trim()) error 'baseIsoSha256 is required'
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
Profile:
  ${profile}
Base ISO Artifact:
  ${baseIsoArtifact}
Artifactory Repository:
  ${artifactoryRepo}
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

            stage('Resolve / Download') {
                imageInfo = windowsImageDownload(
                    workRoot: workRoot,
                    baseIsoArtifact: baseIsoArtifact,
                    baseIsoSha256: baseIsoSha256,
                    profile: profile,
                    architecture: architecture,
                    artifactoryBaseUrl: artifactoryBaseUrl,
                    artifactoryRepo: artifactoryRepo
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
Windows Build:
  ${imageInfo.windowsBuild}
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
Patched Cache Hit:
  ${imageInfo.cacheHit}
============================================================
"""

            if (imageInfo.cacheHit) {
                stage('Patched Image Cache Hit') {
                    echo 'Matching patched image already exists in Artifactory.'
                    echo 'Base ISO and MSU downloads were skipped.'
                    echo "Manifest: ${imageInfo.manifestArtifactPath}"
                    echo "ISO:      ${imageInfo.isoArtifactPath}"
                    echo 'Skipping Extract, Service, Create ISO, Generate Manifest, and Publish.'
                }
            } else {
                stage('Extract Windows Image') {
                    windowsImageExtract(workRoot: workRoot, imageIndex: imageIndex)
                }

                stage('Service Windows Image') {
                    windowsImageService(workRoot: workRoot, imageIndex: imageIndex)
                }

                stage('Create ISO') {
                    windowsImageCreateIso(workRoot: workRoot, outputName: imageInfo.outputName)
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
        } finally {
            if (keepWorkspace) {
                echo 'KEEP_WORKSPACE=true'
                echo "Preserving workspace: ${workRoot}"
            }
        }
    }
}
