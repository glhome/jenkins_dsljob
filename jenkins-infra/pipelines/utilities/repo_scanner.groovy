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
            name: 'BITBUCKET_PROJECT',
            defaultValue: '',
            description: 'Bitbucket project key'
        )

        string(
            name: 'BITBUCKET_REPO',
            defaultValue: '',
            description: 'Repository name. Blank = all repositories.'
        )

        booleanParam(
            name: 'SCAN_BRANCHES',
            defaultValue: true,
            description: 'Scan branches'
        )

        booleanParam(
            name: 'SCAN_TAGS',
            defaultValue: false,
            description: 'Scan tags'
        )
    }

    stages {

        stage('Repository Scan') {

            steps {

                repoScanner(
                    project: params.BITBUCKET_PROJECT,
                    repository: params.BITBUCKET_REPO,
                    scanBranches: params.SCAN_BRANCHES,
                    scanTags: params.SCAN_TAGS
                )
            }
        }
    }
}