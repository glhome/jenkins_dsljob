def call(Map cfg = [:]) {

    validateConfig(cfg)

    pipeline {

        agent {
            node {
                label cfg.nodeLabel

                if (cfg.customWorkspace) {
                    customWorkspace cfg.customWorkspace
                }
            }
        }

        options {
            disableConcurrentBuilds()
            timestamps()
        }

        environment {
            PRODUCT_NAME = "${cfg.productName}"
            JOB_BASE_NAME = "${cfg.jobBaseName ?: cfg.productName}"

            LABVIEW_PATH = "${cfg.labview.path}"

            SEVEN_ZIP = "${cfg.sevenZip ?: 'C:\\Program Files\\7-Zip\\7z.exe'}"

            BUILD_ROOT =
                "${cfg.buildRoot ?: 'C:\\builds\\${cfg.jobBaseName ?: cfg.productName}'}"

            ZIP_ROOT =
                "${cfg.zipRoot ?: 'zipfolder'}"
        }

        stages {

            stage('Initialize') {
                steps {
                    script {
                        labviewEnvironment.initialize(
                            buildRoot: env.BUILD_ROOT,
                            zipRoot: env.ZIP_ROOT
                        )
                    }
                }
            }

            stage('Verify Build Environment') {
                steps {
                    script {
                        labviewEnvironment.verify(
                            labviewPath: env.LABVIEW_PATH,
                            sevenZip: env.SEVEN_ZIP,
                            projects: cfg.projects,
                            workspace: env.WORKSPACE
                        )
                    }
                }
            }

            stage('Clone Dependencies') {
                when {
                    expression {
                        cfg.dependencies &&
                        !cfg.dependencies.isEmpty()
                    }
                }

                steps {
                    script {
                        cfg.dependencies.each { dependency ->

                            if (dependency.enabled != false) {

                                labviewEnvironment.cloneDependency(
                                    dependency
                                )
                            }
                        }
                    }
                }
            }

            stage('Build') {
                steps {
                    script {

                        labviewBuild(
                            projects: cfg.projects,
                            workspace: env.WORKSPACE,
                            labviewPath: env.LABVIEW_PATH
                        )
                    }
                }
            }

            stage('Additional Files') {
                when {
                    expression {
                        cfg.additionalFiles &&
                        !cfg.additionalFiles.isEmpty()
                    }
                }

                steps {
                    script {

                        labviewConfig.copyAdditionalFiles(
                            files: cfg.additionalFiles,
                            workspace: env.WORKSPACE,
                            buildRoot: env.BUILD_ROOT
                        )
                    }
                }
            }

            stage('Package') {
                when {
                    expression {
                        cfg.packaging &&
                        !cfg.packaging.isEmpty()
                    }
                }

                steps {
                    script {

                        labviewPackage(
                            packages: cfg.packaging,
                            buildRoot: env.BUILD_ROOT,
                            zipRoot: env.ZIP_ROOT,
                            sevenZip: env.SEVEN_ZIP
                        )
                    }
                }
            }

            stage('Copy Configuration') {
                when {
                    expression {
                        cfg.configCopies &&
                        !cfg.configCopies.isEmpty()
                    }
                }

                steps {
                    script {

                        labviewConfig.copyConfigFolders(
                            copies: cfg.configCopies
                        )
                    }
                }
            }

            stage('Unit Tests') {
                when {
                    expression {
                        cfg.unitTests &&
                        !cfg.unitTests.isEmpty()
                    }
                }

                steps {
                    script {

                        labviewUnitTest(
                            tests: cfg.unitTests,
                            workspace: env.WORKSPACE,
                            zipRoot: env.ZIP_ROOT,
                            sevenZip: env.SEVEN_ZIP
                        )
                    }
                }
            }

            stage('Build Metadata') {
                when {
                    expression {
                        cfg.metadata?.enabled != false
                    }
                }

                steps {
                    script {

                        labviewMetadata(
                            productName: env.PRODUCT_NAME,
                            executable: cfg.metadata.executable,
                            workspace: env.WORKSPACE,
                            outputFile:
                                cfg.metadata.outputFile ?: 'build.txt',
                            lastReleaseFile:
                                cfg.metadata.lastReleaseFile ?: 'lastRelease.txt'
                        )
                    }
                }
            }

            stage('Publish') {
                when {
                    expression {
                        cfg.artifactory?.enabled != false
                    }
                }

                steps {
                    script {

                        artifactoryPublish(
                            config: cfg.artifactory ?: [:],
                            workspace: env.WORKSPACE,
                            productVersion:
                                cfg.productVersion ?: 'v1.0',
                            jobBaseName: env.JOB_BASE_NAME
                        )
                    }
                }
            }
        }

        post {

            always {
                script {

                    if (cfg.notifications?.notifyBitbucket != false) {
                        notifyBitbucket()
                    }
                }
            }

            success {
                script {

                    labviewNotifications.email(
                        config: cfg.notifications ?: [:],
                        result: currentBuild.currentResult,
                        jobName: env.JOB_NAME,
                        buildNumber: env.BUILD_NUMBER,
                        nodeName: env.NODE_NAME,
                        buildUrl: env.BUILD_URL,
                        productVersion:
                            cfg.productVersion ?: 'v1.0',
                        jobBaseName: env.JOB_BASE_NAME
                    )
                }
            }

            failure {
                script {

                    labviewNotifications.email(
                        config: cfg.notifications ?: [:],
                        result: currentBuild.currentResult,
                        jobName: env.JOB_NAME,
                        buildNumber: env.BUILD_NUMBER,
                        nodeName: env.NODE_NAME,
                        buildUrl: env.BUILD_URL,
                        productVersion:
                            cfg.productVersion ?: 'v1.0',
                        jobBaseName: env.JOB_BASE_NAME,
                        attachLog: true
                    )
                }
            }

            cleanup {
                cleanWs(
                    disableDeferredWipeout: true,
                    deleteDirs: true
                )
            }
        }
    }
}


def validateConfig(Map cfg) {

    if (!cfg.productName) {
        error(
            'labviewPipeline: productName is required'
        )
    }

    if (!cfg.nodeLabel) {
        error(
            'labviewPipeline: nodeLabel is required'
        )
    }

    if (!cfg.labview?.path) {
        error(
            'labviewPipeline: labview.path is required'
        )
    }

    if (!cfg.projects) {
        error(
            'labviewPipeline: projects are required'
        )
    }

    cfg.projects.each { project ->

        if (!project.path) {
            error(
                'labviewPipeline: project.path is required'
            )
        }

        if (!project.buildSpecs) {
            error(
                "No Build Specs configured for ${project.path}"
            )
        }
    }

    if (
        cfg.metadata?.enabled != false &&
        !cfg.metadata?.executable
    ) {
        error(
            'labviewPipeline: metadata.executable is required'
        )
    }
}