pipelineJob('managed/bridge/installer') {

    description('Managed Bridge Installer Build')

    logRotator {
        daysToKeep(30)
        numToKeep(100)
    }

    parameters {

        stringParam(
            'PRODUCT_VERSION',
            'v7.2',
            'Catalys Product Version'
        )

        stringParam(
            'BRIDGE_VERSION',
            'v1.0',
            'Bridge Version'
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
                    'pipelines/bridge/installer.groovy'
                )
            )

            sandbox()
        }
    }
}