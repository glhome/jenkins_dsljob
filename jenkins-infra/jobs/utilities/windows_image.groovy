
pipelineJob('utilities/windows-image') {
    description('Builds a serviced Windows ISO by applying SSU and LCU updates to a base Windows image.')

    properties {
        buildDiscarder {
            strategy {
                logRotator {
                    daysToKeep(30)
                    numToKeep(20)
                    artifactDaysToKeep(30)
                    artifactNumToKeep(10)
                }
            }
        }
    }

    parameters {
        stringParam(
            'BASE_ISO_URL',
            '',
            'URL of the base Windows ISO'
        )

        stringParam(
            'BASE_ISO_SHA256',
            '',
            'Optional SHA-256 checksum for the base ISO'
        )

        stringParam(
            'SSU_URL',
            '',
            'URL of the Servicing Stack Update (.msu)'
        )

        stringParam(
            'SSU_SHA256',
            '',
            'Optional SHA-256 checksum for the SSU'
        )

        stringParam(
            'LCU_URL',
            '',
            'URL of the Latest Cumulative Update (.msu)'
        )

        stringParam(
            'LCU_SHA256',
            '',
            'Optional SHA-256 checksum for the LCU'
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
    baseIsoUrl: params.BASE_ISO_URL,
    baseIsoSha256: params.BASE_ISO_SHA256,

    ssuUrl: params.SSU_URL,
    ssuSha256: params.SSU_SHA256,

    lcuUrl: params.LCU_URL,
    lcuSha256: params.LCU_SHA256,

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