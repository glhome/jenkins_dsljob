def copyAdditionalFiles(Map args = [:]) {

    args.files.each { item ->

        def source =
            "${args.workspace}\\${item.source}"

        def destination =
            "${args.buildRoot}\\${item.destination}"

        bat """
            if not exist "${source}" (
                echo ERROR: Source not found:
                echo ${source}
                exit /b 1
            )

            if not exist "${destination}" (
                mkdir "${destination}"
            )

            xcopy "${source}\\*" ^
                "${destination}" ^
                /E /I /Y /R

            if errorlevel 1 (
                echo ERROR: Failed to copy additional files.
                exit /b 1
            )
        """
    }
}


def copyConfigFolders(Map args = [:]) {

    args.copies.each { item ->

        def source =
            "${env.WORKSPACE}\\${item.source}"

        def destination =
            item.destination

        bat """
            if not exist "${source}" (
                echo ERROR: Configuration source not found:
                echo ${source}
                exit /b 1
            )

            if exist "${destination}" (
                rmdir /S /Q "${destination}"
            )

            mkdir "${destination}"

            xcopy "${source}\\*" ^
                "${destination}" ^
                /E /I /Y /R

            if errorlevel 1 (
                echo ERROR: Configuration copy failed.
                exit /b 1
            )
        """
    }
}