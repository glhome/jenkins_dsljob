@Library('jenkins_dsljob') _

pipeline {

    agent {
        label 'windows'
    }

    options {
        timestamps()
        disableConcurrentBuilds()
    }

    parameters {

        string(
            name: 'REPOSITORY_URL',
            defaultValue: '',
            description: 'Git repository URL to scan'
        )

        string(
            name: 'REPOSITORY_BRANCH',
            defaultValue: 'main',
            description: 'Git branch to scan'
        )
    }

    stages {

        stage('Checkout Repository') {

            steps {

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
    }
}