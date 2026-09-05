pipelineJob('managed/bridge/gui') {

    description('Managed Bridge GUI Build')

    logRotator {
        daysToKeep(30)
        numToKeep(100)
    }

    parameters {

        stringParam(
            'BRANCH',
            'main',
            'Git branch to build'
        )

        booleanParam(
            'CLEAN_BUILD',
            false,
            'Perform a clean build'
        )
    }

    definition {

        cps {
            script(
                readFileFromWorkspace(
                    'jenkins-infra/pipelines/bridge/gui.groovy'
                )
            )

            sandbox()
        }
    }
}