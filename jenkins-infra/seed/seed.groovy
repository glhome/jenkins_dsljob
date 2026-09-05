pipeline {

    agent any

    stages {

        stage('Checkout') {
            steps {
                git(
                    branch: 'update_var',
                    credentialsId: 'github-credentials',
                    url: 'https://github.com/glhome/jenkins_dsljob.git'
                )
            }
        }

        stage('Generate Jenkins Configuration') {
            steps {
                jobDsl(
                    targets: '''
                        folders/**/*.groovy
                        views/**/*.groovy
                        jobs/**/*.groovy
                    ''',

                    lookupStrategy: 'SEED_JOB',

                    removedJobAction: 'IGNORE',

                    removedViewAction: 'IGNORE'
                )
            }
        }
    }
}