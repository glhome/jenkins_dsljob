def call() {

    echo "========================================"
    echo "Repository Scanner"
    echo "========================================"
    echo "Target Repository: ${params.REPOSITORY_URL}"
    echo "Branch:           ${params.REPOSITORY_BRANCH}"
    echo "Workspace:        ${env.WORKSPACE}"
    echo "========================================"

    def scannerFiles = [
        'scan-repo.ps1',
        'config.json',
        'detect-language.ps1',
        'detect-build-system.ps1'
    ]

    scannerFiles.each { fileName ->

        def resourcePath = "scripts/scanner/${fileName}"

        def content = libraryResource(resourcePath)

        writeFile(
            file: fileName,
            text: content
        )
    }

    powershell """
        .\\scan-repo.ps1 `
            -RepositoryPath "\$env:WORKSPACE" `
            -RepositoryUrl "${params.REPOSITORY_URL}" `
            -OutputFile "repo-scan-results.json"

        if (\$LASTEXITCODE -ne 0) {
            exit \$LASTEXITCODE
        }
    """

    if (!fileExists('repo-scan-results.json')) {
        error('Repository scanner did not generate repo-scan-results.json')
    }
}