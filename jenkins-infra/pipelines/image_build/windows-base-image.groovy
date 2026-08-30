pipeline {

    agent {
        label 'windows-image-builder'
    }

    options {
        timestamps()
        disableConcurrentBuilds()
        skipDefaultCheckout(false)
    }

    triggers {
        // Weekly - Wednesday at a hashed time
        cron('H 2 * * 3')
    }

    environment {
        CONFIG_FILE = 'config/windows-base-image.json'
        SCRIPT_DIR = 'scripts/windows-base-image'
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Initialize') {
            steps {
                powershell '''
                    & "$env:SCRIPT_DIR\\Build-BaseImage.ps1" `
                        -ConfigFile "$env:CONFIG_FILE" `
                        -InitializeOnly
                '''
            }
        }

        stage('Download Base WIM') {
            steps {
                powershell '''
                    & "$env:SCRIPT_DIR\\Build-BaseImage.ps1" `
                        -ConfigFile "$env:CONFIG_FILE" `
                        -DownloadBaseImage
                '''
            }
        }

        stage('Inspect Base Image') {
            steps {
                powershell '''
                    & "$env:SCRIPT_DIR\\Build-BaseImage.ps1" `
                        -ConfigFile "$env:CONFIG_FILE" `
                        -Inspect
                '''
            }
        }

        stage('Get Windows Updates') {
            steps {
                powershell '''
                    & "$env:SCRIPT_DIR\\Get-WindowsUpdates.ps1" `
                        -ConfigFile "$env:CONFIG_FILE"
                '''
            }
        }

        stage('Apply Updates') {
            steps {
                powershell '''
                    & "$env:SCRIPT_DIR\\Apply-WindowsUpdates.ps1" `
                        -ConfigFile "$env:CONFIG_FILE"
                '''
            }
        }

        stage('Cleanup') {
            steps {
                powershell '''
                    & "$env:SCRIPT_DIR\\Cleanup-WindowsImage.ps1" `
                        -ConfigFile "$env:CONFIG_FILE"
                '''
            }
        }

        stage('Validate Image') {
            steps {
                powershell '''
                    & "$env:SCRIPT_DIR\\Validate-WindowsImage.ps1" `
                        -ConfigFile "$env:CONFIG_FILE"
                '''
            }
        }

        stage('Generate Update Manifest') {
            steps {
                powershell '''
                    & "$env:SCRIPT_DIR\\Generate-UpdateManifest.ps1" `
                        -ConfigFile "$env:CONFIG_FILE"
                '''
            }
        }

        stage('Generate Build Manifest') {
            steps {
                powershell '''
                    & "$env:SCRIPT_DIR\\Generate-BuildManifest.ps1" `
                        -ConfigFile "$env:CONFIG_FILE"
                '''
            }
        }

        stage('Publish') {
            steps {
                powershell '''
                    & "$env:SCRIPT_DIR\\Publish-BaseImage.ps1" `
                        -ConfigFile "$env:CONFIG_FILE"
                '''
            }
        }
    }

    post {

        always {
            archiveArtifacts(
                artifacts: 'output/**/*',
                allowEmptyArchive: true,
                fingerprint: true
            )
        }

        cleanup {
            powershell '''
                if (Test-Path "$env:WORKSPACE\\output") {
                    Write-Host "Build output retained for Jenkins artifact archival."
                }
            '''
        }
    }
}