def call() {

    pipeline {

        agent {
            label 'windows'
        }

        options {
            timestamps()
            disableConcurrentBuilds()
        }

        stages {

            stage('Validate Parameters') {
                steps {
                    script {

                        if (!params.REPOSITORY_URL?.trim()) {
                            error('REPOSITORY_URL is required.')
                        }

                        if (!params.REPOSITORY_BRANCH?.trim()) {
                            error('REPOSITORY_BRANCH is required.')
                        }

                        echo "Repository: ${params.REPOSITORY_URL}"
                        echo "Branch:     ${params.REPOSITORY_BRANCH}"
                        echo "Workspace:  ${env.WORKSPACE}"
                    }
                }
            }

            stage('Checkout Repository') {
                steps {

                    deleteDir()

                    checkout([
                        $class: 'GitSCM',

                        branches: [[
                            name: "*/${params.REPOSITORY_BRANCH}"
                        ]],

                        userRemoteConfigs: [[
                            url: params.REPOSITORY_URL,
                            credentialsId: 'github-credentials'
                        ]]
                    ])
                }
            }

            stage('Repository Scan') {
                steps {
                    repoScanner()
                }
            }

            stage('Archive Results') {
                steps {
                    archiveArtifacts(
                        artifacts: 'repo-scan-results.json',
                        fingerprint: true
                    )
                }
            }
        }

        post {
            success {
                echo 'Repository scan completed successfully.'
            }

            failure {
                echo 'Repository scan failed.'
            }
        }
    }
}