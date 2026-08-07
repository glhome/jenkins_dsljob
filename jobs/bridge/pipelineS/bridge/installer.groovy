pipeline {

    agent {

        node {

            label 'InstallShield_VM135'

            customWorkspace 'C:\\Catalys_Bridge'

        }

    }

    environment {

        INSTALLER_PROJECT_NAME = "Catalys_Bridge"

        _7zip = "C:\\Program Files\\7-Zip\\7z.exe"

        ISCMDBLD = "C:\\Program Files (x86)\\InstallShield\\2019\\System\\IsCmdBld.exe"

    }

    stages {

        stage('Download Support Binaries') {

            steps {

                echo "Download stage"

            }

        }

        stage('Build Installer') {

            steps {

                echo "Build stage"

            }

        }

        stage('Upload') {

            steps {

                echo "Upload stage"

            }

        }

    }

}