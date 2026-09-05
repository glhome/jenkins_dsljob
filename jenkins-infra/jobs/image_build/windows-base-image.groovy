
pipelineJob('managed/image_build/windows-base-image') {

    description('Weekly Windows IoT 1809 base image update pipeline')

    logRotator {
        numToKeep(20)
        artifactNumToKeep(10)
    }

    parameters {
        stringParam(
            'BASE_IMAGE',
            'windows_base_iot_1809.wim',
            'Base WIM filename'
        )

        booleanParam(
            'FORCE_BUILD',
            false,
            'Build even when no new updates are detected'
        )
    }

    definition {
        cps {
            script(
                readFileFromWorkspace(
                    'jenkins-infra/pipelines/image_build/windows-base-image.groovy'
                )
            )
            sandbox()
        }
    }
}