pipelineJob('managed/utilities/repo-scanner') {

    description(
        'Scan repositories and identify languages, build systems and CI configuration'
    )

    logRotator {
        daysToKeep(30)
        numToKeep(50)
    }

    parameters {

        stringParam(
            'REPOSITORY_ROOT',
            '',
            'Directory containing repositories to scan'
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
                    'pipelines/utilities/repo-scanner.groovy'
                )
            )

            sandbox()
        }
    }
}