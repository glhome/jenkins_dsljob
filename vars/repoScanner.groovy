def call() {

    echo "========================================"
    echo "Repository Scanner"
    echo "========================================"
    echo "Workspace: ${env.WORKSPACE}"
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
            -RepositoryPath '${env.WORKSPACE}' `
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