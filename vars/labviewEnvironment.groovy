def initialize(Map args = [:]) {

    bat """
        if exist "${args.buildRoot}" (
            rmdir /S /Q "${args.buildRoot}"
        )

        if exist "${args.zipRoot}" (
            rmdir /S /Q "${args.zipRoot}"
        )

        mkdir "${args.buildRoot}"
        mkdir "${args.zipRoot}"
    """
}


def verify(Map args = [:]) {

    bat """
        if not exist "${args.labviewPath}" (
            echo ERROR: LabVIEW executable not found:
            echo ${args.labviewPath}
            exit /b 1
        )

        if not exist "${args.sevenZip}" (
            echo ERROR: 7-Zip executable not found:
            echo ${args.sevenZip}
            exit /b 1
        )
    """

    args.projects.each { project ->

        def projectPath =
            "${args.workspace}\\${project.path}"

        bat """
            if not exist "${projectPath}" (
                echo ERROR: LabVIEW project not found:
                echo ${projectPath}
                exit /b 1
            )
        """
    }
}


def verifyDependency(String path) {

    bat """
        if not exist "${path}" (
            echo ERROR: Required dependency not found:
            echo ${path}
            exit /b 1
        )

        echo Dependency found:
        echo ${path}
    """
}


def cloneDependency(Map dependency) {

    if (!dependency.url) {
        error(
            "Dependency ${dependency.name ?: ''} has no Git URL."
        )
    }

    if (!dependency.target) {
        error(
            "Dependency ${dependency.name ?: ''} has no target."
        )
    }

    def branch =
        dependency.branch ?: 'develop'

    def credentials =
        dependency.credentialsId

    echo "Cloning dependency: ${dependency.name ?: dependency.url}"

    bat """
        if exist "${dependency.target}" (
            rmdir /S /Q "${dependency.target}"
        )

        mkdir "${dependency.target}"
    """

    dir(dependency.target) {

        checkout([
            $class: 'GitSCM',

            branches: [
                [
                    name: branch
                ]
            ],

            userRemoteConfigs: [
                [
                    url: dependency.url,
                    credentialsId: credentials
                ]
            ],

            extensions: [
                [
                    $class: 'CloneOption',
                    shallow: false,
                    noTags: false,
                    timeout: 30
                ]
            ]
        ])
    }
}