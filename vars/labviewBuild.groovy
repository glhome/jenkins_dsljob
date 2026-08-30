def call(Map args = [:]) {

    args.projects.each { project ->

        echo "=========================================="
        echo "LabVIEW Project:"
        echo "${project.path}"
        echo "=========================================="

        project.buildSpecs.each { buildSpec ->

            def projectPath =
                "${args.workspace}\\${project.path}"

            echo "Building: ${buildSpec}"

            bat """
                LabVIEWCLI ^
                    -OperationName ExecuteBuildSpec ^
                    -PortNumber ${project.portNumber ?: 3364} ^
                    -ProjectPath "${projectPath}" ^
                    -TargetName "${project.targetName ?: 'My Computer'}" ^
                    -BuildSpecName "${buildSpec}" ^
                    -LabVIEWPath "${args.labviewPath}"

                if errorlevel 1 (
                    echo ERROR: LabVIEW build failed
                    echo Build Spec: ${buildSpec}
                    exit /b 1
                )
            """
        }
    }
}