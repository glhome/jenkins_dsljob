pipelineJob('managed/utilities/repo_scanner') {

    description('Scan a single Git repository')

    parameters {

        stringParam(
            'REPOSITORY_URL',
            '',
            'Git repository URL to scan'
        )

        stringParam(
            'REPOSITORY_BRANCH',
            'main',
            'Git branch to scan'
        )
    }

    definition {
        cps {
            script("""
                @Library('jenkins_dsljob') _

                repoScannerPipeline()
            """.stripIndent())

            sandbox()
        }
    }
}