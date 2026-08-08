```groovy
pipeline {

    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
    }

    stages {

        stage('Checkout') {
            steps {
                echo "Managed GUI: checkout"
                echo "Branch: ${params.BRANCH}"
            }
        }

        stage('Clean') {
            when {
                expression {
                    params.CLEAN_BUILD
                }
            }

            steps {
                echo 'Managed GUI: clean build'
            }
        }

        stage('Build') {
            steps {
                echo 'Managed GUI: build'
            }
        }

        stage('Test') {
            steps {
                echo 'Managed GUI: test'
            }
        }

        stage('Package') {
            steps {
                echo 'Managed GUI: package'
            }
        }
    }

    post {
        success {
            echo 'Managed GUI completed successfully'
        }

        failure {
            echo 'Managed GUI failed'
        }
    }
}
```
