def call(Map args = [:]) {

    args.packages.each { pkg ->

        def source =
            "${args.buildRoot}\\${pkg.source}"

        def destination =
            "${args.zipRoot}\\${pkg.name}.zip"

        echo "Creating package: ${pkg.name}.zip"

        bat """
            if not exist "${source}" (
                echo ERROR: Build output not found:
                echo ${source}
                exit /b 1
            )

            if not exist "${args.zipRoot}" (
                mkdir "${args.zipRoot}"
            )

            "${args.sevenZip}" a -r ^
                "${destination}" ^
                "${source}\\*"

            if errorlevel 1 (
                echo ERROR: Failed to create package
                echo ${destination}
                exit /b 1
            )
        """
    }
}