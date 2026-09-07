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
            name: 'REPOSITORY_PATH',
            defaultValue: '',
            description: 'Full path to the repository to scan'
        )
    }

    stages {

        stage('Repository Scan') {

            steps {

                repoScanner(
                    repositoryPath: params.REPOSITORY_PATH
                )
            }
        }
    }
}