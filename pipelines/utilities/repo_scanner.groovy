pipeline {

    agent any

    parameters {

        string(
            name: 'REPOSITORY_ROOT',
            defaultValue: ''
        )

        string(
            name: 'OUTPUT_FILE',
            defaultValue: 'repo-scan-results.json'
        )
    }

    stages {

        stage('Validate') {

            steps {

                powershell '''
                    if ([string]::IsNullOrWhiteSpace($env:REPOSITORY_ROOT)) {
                        throw "REPOSITORY_ROOT must be specified."
                    }

                    if (-not (Test-Path -LiteralPath $env:REPOSITORY_ROOT)) {
                        throw "Repository root does not exist: $env:REPOSITORY_ROOT"
                    }
                '''
            }
        }

        stage('Scan Repositories') {

            steps {

                powershell '''
                    & "$env:WORKSPACE\\scripts\\scanner\\scan-repos.ps1" `
                        -RepositoryRoot "$env:REPOSITORY_ROOT" `
                        -OutputFile "$env:OUTPUT_FILE"
                '''
            }
        }

        stage('Archive Results') {

            steps {

                archiveArtifacts(
                    artifacts: "${params.OUTPUT_FILE}",
                    fingerprint: true
                )
            }
        }
    }
}