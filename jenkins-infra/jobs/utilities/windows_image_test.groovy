pipelineJob('utilities/windows-image-test') {

    description(
        '''
        Test job for the Windows image factory.

        This job uses the shared windowsImagePipeline with publishing
        disabled. It must not create or modify production Artifactory
        patched-image artifacts.
        '''
    )

    logRotator {
        numToKeep(20)
        daysToKeep(14)
    }

    parameters {

        choiceParam(
            'WINDOWS_PROFILE',
            [
                'windows11-24h2',
                'windows10-21h2'
            ],
            'Windows image profile to test.'
        )

        choiceParam(
            'TEST_MODE',
            [
                'RESOLVE_ONLY',
                'SERVICING_ONLY',
                'FULL'
            ],
            'Test scope.'
        )

        stringParam(
            'BASE_ISO_ARTIFACT',
            '__PROFILE_DEFAULT__',
            'Base ISO Artifactory path. Leave __PROFILE_DEFAULT__ to use the profile default.'
        )

        stringParam(
            'BASE_ISO_SHA256',
            '__PROFILE_DEFAULT__',
            'Base ISO SHA256. Leave __PROFILE_DEFAULT__ to use the profile default.'
        )

        stringParam(
            'ARTIFACTORY_BASE_URL',
            'http://localhost:8082/',
            'Artifactory server URL.'
        )

        stringParam(
            'ARTIFACTORY_REPO',
            'snapshot-generic-local',
            'Artifactory repository.'
        )

        choiceParam(
            'ARCHITECTURE',
            [
                'x64',
                'arm64'
            ],
            'Windows image architecture.'
        )

        stringParam(
            'IMAGE_INDEX',
            '1',
            'install.wim image index.'
        )

        booleanParam(
            'KEEP_WORKSPACE',
            true,
            'Keep workspace for troubleshooting.'
        )
    }

    definition {
        cps {
            script(
                '''
@Library('jenkins_dsljob') _

pipeline {
    agent none

    stages {

        stage('Resolve / Download') {
            when {
                expression {
                    params.TEST_MODE == 'RESOLVE_ONLY'
                }
            }

            steps {
                script {

                    windowsImagePipeline(
                        profile: params.WINDOWS_PROFILE,
                        architecture: params.ARCHITECTURE,

                        baseIsoArtifact:
                            params.BASE_ISO_ARTIFACT,

                        baseIsoSha256:
                            params.BASE_ISO_SHA256,

                        artifactoryBaseUrl:
                            params.ARTIFACTORY_BASE_URL,

                        artifactoryRepo:
                            params.ARTIFACTORY_REPO,

                        imageIndex:
                            params.IMAGE_INDEX as Integer,

                        keepWorkspace:
                            params.KEEP_WORKSPACE,

                        publish: false
                    )
                }
            }
        }

        stage('Full Image Test') {
            when {
                expression {
                    params.TEST_MODE == 'FULL'
                }
            }

            steps {
                script {

                    windowsImagePipeline(
                        profile: params.WINDOWS_PROFILE,
                        architecture: params.ARCHITECTURE,

                        baseIsoArtifact:
                            params.BASE_ISO_ARTIFACT,

                        baseIsoSha256:
                            params.BASE_ISO_SHA256,

                        artifactoryBaseUrl:
                            params.ARTIFACTORY_BASE_URL,

                        artifactoryRepo:
                            params.ARTIFACTORY_REPO,

                        imageIndex:
                            params.IMAGE_INDEX as Integer,

                        keepWorkspace:
                            params.KEEP_WORKSPACE,

                        publish: false
                    )
                }
            }
        }

        stage('Servicing Test') {
            when {
                expression {
                    params.TEST_MODE == 'SERVICING_ONLY'
                }
            }

            steps {
                script {

                    /*
                     * Servicing-only mode intentionally performs the
                     * shared pipeline because the resolver/download
                     * stages must establish:
                     *
                     *   download/resolved-updates.json
                     *   download/updates/*
                     *   source/sources/install.wim
                     *
                     * Publishing remains disabled.
                     */
                    windowsImagePipeline(
                        profile: params.WINDOWS_PROFILE,
                        architecture: params.ARCHITECTURE,

                        baseIsoArtifact:
                            params.BASE_ISO_ARTIFACT,

                        baseIsoSha256:
                            params.BASE_ISO_SHA256,

                        artifactoryBaseUrl:
                            params.ARTIFACTORY_BASE_URL,

                        artifactoryRepo:
                            params.ARTIFACTORY_REPO,

                        imageIndex:
                            params.IMAGE_INDEX as Integer,

                        keepWorkspace:
                            true,

                        publish: false
                    )
                }
            }
        }
    }
}
'''
            )

            sandbox()
        }
    }
}