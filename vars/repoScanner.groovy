def call() {

    echo "========================================"
    echo "Repository Scanner"
    echo "========================================"
    echo "Workspace: ${env.WORKSPACE}"
    echo "========================================"

    def scannerFiles = [
        'scan-repo.ps1',
        'config.json',
        'detect-language.ps1',
        'detect-build-system.ps1'
    ]

    scannerFiles.each { fileName ->

        def resourcePath = "scripts/scanner/${fileName}"

        echo "Loading Shared Library resource: ${resourcePath}"

        def content = libraryResource(resourcePath)

        writeFile(
            file: fileName,
            text: content
        )
    }

    powershell '''
        & .\\scan-repo.ps1 `
            -RepositoryPath "$env:WORKSPACE" `
            -OutputFile "repo-scan-results.json"

        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
    '''

    archiveArtifacts(
        artifacts: 'repo-scan-results.json',
        fingerprint: true
    )
}