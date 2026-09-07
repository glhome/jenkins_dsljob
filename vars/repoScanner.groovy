def call(Map config = [:]) {

    def repositoryPath = config.get('repositoryPath', '')

    if (!repositoryPath?.trim()) {
        error("REPOSITORY_PATH is required.")
    }

    echo "========================================"
    echo "Repository Scanner"
    echo "========================================"
    echo "Repository: ${repositoryPath}"
    echo "========================================"

    def scriptName = 'scan-repo.ps1'

    def scanScript = libraryResource(
        'scripts/scanner/scan-repo.ps1'
    )

    writeFile(
        file: scriptName,
        text: scanScript
    )

    powershell """
        & .\\${scriptName} `
            -RepositoryPath '${repositoryPath}' `
            -OutputFile 'repo-scan-results.json'

        if (\$LASTEXITCODE -ne 0) {
            exit \$LASTEXITCODE
        }
    """

    archiveArtifacts(
        artifacts: 'repo-scan-results.json',
        fingerprint: true
    )
}