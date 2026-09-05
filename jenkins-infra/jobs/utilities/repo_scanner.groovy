pipelineJob('managed/utilities/repo_scanner') {

    description(
        'Scan repositories and identify languages, build systems and CI configuration'
    )

    logRotator {
        daysToKeep(30)
        numToKeep(50)
    }

    parameters {

        stringParam(
            'GIT_URL',
            '',
            'Git repository URL'
        )

        stringParam(
            'BRANCH',
            'main',
            'Git branch to scan'
        )

        stringParam(
            'OUTPUT_FILE',
            'repo-scan-results.json',
            'Scanner output file'
        )
    }
    definition {

        cps {

            script(
                readFileFromWorkspace(
                    'jenkins-infra/pipelines/utilities/repo_scanner.groovy'
                )
            )

            sandbox()
        }
    }
}