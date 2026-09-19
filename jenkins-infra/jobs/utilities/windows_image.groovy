pipelineJob('utilities/windows-image') {

    description(
        'Builds a serviced Windows ISO from an immutable Artifactory base ISO.'
    )

    logRotator {
        numToKeep(20)
        daysToKeep(30)
    }

    parameters {

        stringParam(
            'BASE_ISO_ARTIFACT',
            'Windows11/24H2/x64/base/en-us_windows_11_iot_enterprise_version_24h2_x64_dvd_3a99b72b.iso',
            'Immutable base Windows ISO path in Artifactory'
        )

        stringParam(
            'BASE_ISO_SHA256',
            '',
            'Expected SHA-256 checksum of the base ISO'
        )

        stringParam(
            'WINDOWS_BUILD',
            '26100',
            'Windows build number'
        )

        stringParam(
            'ARCHITECTURE',
            'x64',
            'Windows architecture'
        )

        stringParam(
            'UPDATE_MANIFEST_URL',
            '',
            'Optional update-selection manifest URL'
        )

        stringParam(
            'UPDATE_MANIFEST_FILE',
            '',
            'Optional workspace update-selection manifest'
        )

        stringParam(
            'ARTIFACTORY_BASE_URL',
            '',
            'JFrog Artifactory base URL'
        )

        stringParam(
            'ARTIFACTORY_REPO',
            'snapshot-generic-local',
            'Artifactory repository containing Windows base ISOs and updates'
        )

        stringParam(
            'IMAGE_INDEX',
            '1',
            'install.wim image index'
        )

        stringParam(
            'OUTPUT_NAME',
            'Windows-Custom',
            'Output ISO name without extension'
        )

        stringParam(
            'AGENT_LABEL',
            'windows-image-builder',
            'Jenkins agent label'
        )

        booleanParam(
            'KEEP_WORKSPACE',
            false,
            'Keep image workspace after the build'
        )
    }

    definition {

        cps {

            script('''
@Library('jenkins_dsljob') _

windowsImagePipeline(
    baseIsoArtifact: params.BASE_ISO_ARTIFACT,
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