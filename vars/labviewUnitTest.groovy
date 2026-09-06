def call(Map args = [:]) {

    args.tests.each { test ->

        def vi =
            "${args.workspace}\\${test.vi}"

        def port =
            test.portNumber ?: 3364

        echo "Running Unit Test: ${test.name ?: test.vi}"

        bat """
            if not exist "${vi}" (
                echo ERROR: Unit Test VI not found:
                echo ${vi}
                exit /b 1
            )

            LabVIEWCLI ^
                -OperationName RunVI ^
                -PortNumber ${port} ^
                -VIPath "${vi}"

            if errorlevel 1 (
                echo ERROR: Unit Test failed:
                echo ${test.name ?: test.vi}
                exit /b 1
            )
        """

        if (test.report) {

            def report =
                "${args.workspace}\\${test.report}"

            def zipName =
                test.zipName ?: 'Unit_Tests.zip'

            bat """
                if not exist "${report}" (
                    echo ERROR: Unit Test report not found:
                    echo ${report}
                    exit /b 1
                )

                "${args.sevenZip}" a -r ^
                    "${args.zipRoot}\\${zipName}" ^
                    "${report}\\*"

                if errorlevel 1 (
                    echo ERROR: Failed to package Unit Test report.
                    exit /b 1
                )
            """
        }
    }
}