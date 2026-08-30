pipeline {

    agent any

    parameters {

        string(
            name: 'GIT_URL',
            defaultValue: '',
            description: 'Git repository URL'
        )

        string(
            name: 'BRANCH',
            defaultValue: 'main',
            description: 'Git branch to scan'
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

                    if (!params.GIT_URL?.trim()) {
                        error('GIT_URL must be specified.')
                    }

                    if (!params.BRANCH?.trim()) {
                        error('BRANCH must be specified.')
                    }

                    echo "Repository: ${params.GIT_URL}"
                    echo "Branch: ${params.BRANCH}"
                }
            }
        }

        stage('Checkout Repository') {

            steps {

                dir('repository') {

                    git(
                        url: params.GIT_URL,
                        branch: params.BRANCH
                    )
                }
            }
        }

        stage('Scan Repository') {

            steps {

                powershell """

                    \$repoPath = "\$env:WORKSPACE\\repository"

                    Write-Host "Scanning:"
                    Write-Host \$repoPath

                    & "\$env:WORKSPACE\\scripts\\scanner\\scan-repos.ps1" `
                        -RepositoryRoot \$repoPath `
                        -OutputFile "\$env:WORKSPACE\\${params.OUTPUT_FILE}"

                    if (\$LASTEXITCODE -ne 0) {
                        throw "Repository scanner failed."
                    }
                """
            }
        }

        stage('Display Results') {

            steps {

                powershell """

                    Get-Content `
                        "\$env:WORKSPACE\\${params.OUTPUT_FILE}"
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

    post {

        always {

            deleteDir()
        }
    }
}