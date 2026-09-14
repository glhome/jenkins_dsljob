folder('utilities')

pipelineJob('utilities/windows-image') {

    description('Builds a serviced Windows ISO by applying SSU and LCU updates to an immutable Microsoft base Windows image.')

    logRotator {
        numToKeep(20)
        daysToKeep(30)
    }

    parameters {

        stringParam(
            'BASE_ISO_PATH',
            'E:\\en-us_windows_11_iot_enterprise_version_24h2_x64_dvd_3a99b72b.iso',
            'Base Windows ISO on the build agent'
        )

        stringParam(
            'BASE_ISO_SHA256',
            '',
            'Optional SHA-256 checksum for the base ISO'
        )

        stringParam(
            'WINDOWS_BUILD',
            '26100',
            'Windows build number, for example 26100'
        )

        stringParam(
            'ARCHITECTURE',
            'x64',
            'Windows architecture'
        )

        stringParam(
            'UPDATE_MANIFEST_URL',
            '',
            'URL of the update-selection manifest containing applicable SSU/LCU updates'
        )

        stringParam(
            'UPDATE_MANIFEST_FILE',
            '',
            'Optional workspace path to an update-selection manifest'
        )

        stringParam(
            'ARTIFACTORY_BASE_URL',
            '',
            'JFrog Artifactory base URL'
        )

        stringParam(
            'ARTIFACTORY_REPO',
            'windows-updates',
            'Immutable Artifactory repository used to cache Microsoft update packages'
        )

        stringParam(
            'IMAGE_INDEX',
            '1',
            'install.wim image index to service'
        )

        stringParam(
            'OUTPUT_NAME',
            'Windows-Custom',
            'Output ISO file name without extension'
        )

        stringParam(
            'AGENT_LABEL',
            'windows-image-builder',
            'Jenkins agent label'
        )

        booleanParam(
            'KEEP_WORKSPACE',
            false,
            'Keep the image workspace after the build'
        )
    }

    definition {
        cps {
            script('''
@Library('jenkins_dsljob') _

windowsImagePipeline(
    baseIsoPath: params.BASE_ISO_PATH,
    baseIsoSha256: params.BASE_ISO_SHA256,

    windowsBuild: params.WINDOWS_BUILD,
    architecture: params.ARCHITECTURE,

    updateManifestUrl: params.UPDATE_MANIFEST_URL,
    updateManifestFile: params.UPDATE_MANIFEST_FILE,

    artifactoryBaseUrl: params.ARTIFACTORY_BASE_URL,
    artifactoryRepo: params.ARTIFACTORY_REPO,

    imageIndex: params.IMAGE_INDEX,
    outputName: params.OUTPUT_NAME,

    agentLabel: params.AGENT_LABEL,
    keepWorkspace: params.KEEP_WORKSPACE
)
'''.stripIndent())
            sandbox()
        }
    }
}