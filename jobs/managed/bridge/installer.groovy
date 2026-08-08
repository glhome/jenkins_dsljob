pipelineJob('Bridge/Installer') {

    description('Bridge Installer Build')

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
    }

    definition {

        cps {

            script(
                readFileFromWorkspace(
                    'pipelines/managed/bridge/installer.groovy'
                )
            )

            sandbox()
        }
    }
}