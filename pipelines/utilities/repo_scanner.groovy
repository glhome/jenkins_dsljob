pipeline {

    agent any

    parameters {

        string(
            name: 'REPOSITORY_ROOT',
            defaultValue: '',
            description: 'Directory containing repositories to scan'
        )

        string(
            name: 'OUTPUT_FILE',
            defaultValue: 'repo-scan-results.json',
            description: 'Scanner output file'
        )
    }

    stages {

        stage('Validate') {

            steps {

                script {

                    if (!params.REPOSITORY_ROOT?.trim()) {
                        error(
                            'REPOSITORY_ROOT must be specified.'
                        )
                    }

                    if (!fileExists(params.REPOSITORY_ROOT)) {
                        error(
                            "REPOSITORY_ROOT does not exist: ${params.REPOSITORY_ROOT}"
                        )
                    }
                }
            }
        }

        stage('Scan Repositories') {

            steps {

                powershell """
                    & "\$env:WORKSPACE\\scripts\\scanner\\scan-repos.ps1" `
                        -RepositoryRoot "${params.REPOSITORY_ROOT}" `
                        -OutputFile "\$env:WORKSPACE\\${params.OUTPUT_FILE}"

                    if (\$LASTEXITCODE -ne 0) {
                        throw "Repository scanner failed with exit code \$LASTEXITCODE"
                    }
                """
            }
        }

        stage('Archive Results') {

            steps {

                archiveArtifacts(
                    artifacts: params.OUTPUT_FILE,
                    fingerprint: true
                )
            }
        }
    }
}