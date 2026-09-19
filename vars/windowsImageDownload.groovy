def call(Map cfg = [:]) {

    def workRoot =
        cfg.workRoot

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
        cfg.artifactoryBaseUrl

    def artifactoryRepo =
        cfg.artifactoryRepo ?: 'snapshot-generic-local'


    if (!workRoot?.trim()) {
        error 'workRoot is required'
    }

    if (!baseIsoArtifact?.trim()) {
        error 'baseIsoArtifact is required'
    }

    if (!artifactoryBaseUrl?.trim()) {
        error 'artifactoryBaseUrl is required'
    }


    /*
     * Load scripts from the Shared Library.
     */

    def downloadScript = libraryResource(
        'scripts/windows-image/download.ps1'
    )

    def resolverScript = libraryResource(
        'scripts/windows-image/resolve-updates.ps1'
    )


    /*
     * Put both scripts in the Jenkins workspace.
     *
     * download.ps1 must not assume that resources/scripts/windows-image
     * exists on the agent.
     */

    def downloadScriptPath =
        "${env.WORKSPACE}\\download-windows-image.ps1"

    def resolverScriptPath =
        "${env.WORKSPACE}\\resolve-updates.ps1"


    writeFile(
        file: downloadScriptPath,
        text: downloadScript
    )

    writeFile(
        file: resolverScriptPath,
        text: resolverScript
    )


    echo """
============================================================
 Windows Image Download
============================================================

WorkRoot:
  ${workRoot}

Base ISO:
  ${baseIsoArtifact}

Artifactory Repository:
  ${artifactoryRepo}

Download Script:
  ${downloadScriptPath}

Resolver Script:
  ${resolverScriptPath}

============================================================
"""


    powershell(
        '''
$ErrorActionPreference = 'Stop'

& '__DOWNLOAD_SCRIPT_PATH__' `
    -WorkRoot '__WORK_ROOT__' `
    -BaseIsoArtifact '__BASE_ISO_ARTIFACT__' `
    -BaseIsoSha256 '__BASE_ISO_SHA256__' `
    -WindowsBuild '__WINDOWS_BUILD__' `
    -Architecture '__ARCHITECTURE__' `
    -UpdateManifestUrl '__UPDATE_MANIFEST_URL__' `
    -UpdateManifestFile '__UPDATE_MANIFEST_FILE__' `
    -ArtifactoryBaseUrl '__ARTIFACTORY_BASE_URL__' `
    -ArtifactoryRepo '__ARTIFACTORY_REPO__' `
    -ResolverScriptPath '__RESOLVER_SCRIPT_PATH__'
'''
        .replace('__DOWNLOAD_SCRIPT_PATH__', downloadScriptPath)
        .replace('__WORK_ROOT__', workRoot)
        .replace('__BASE_ISO_ARTIFACT__', baseIsoArtifact)
        .replace('__BASE_ISO_SHA256__', baseIsoSha256)
        .replace('__WINDOWS_BUILD__', windowsBuild.toString())
        .replace('__ARCHITECTURE__', architecture)
        .replace('__UPDATE_MANIFEST_URL__', updateManifestUrl)
        .replace('__UPDATE_MANIFEST_FILE__', updateManifestFile)
        .replace('__ARTIFACTORY_BASE_URL__', artifactoryBaseUrl)
        .replace('__ARTIFACTORY_REPO__', artifactoryRepo)
        .replace('__RESOLVER_SCRIPT_PATH__', resolverScriptPath)
    )
}