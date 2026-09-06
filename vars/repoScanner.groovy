def call(Map config = [:]) {

    def project = config.get('project', '')
    def repository = config.get('repository', '')
    def scanBranches = config.get('scanBranches', true)
    def scanTags = config.get('scanTags', false)

    def scriptName = 'scan-repos.ps1'

    echo "Preparing repository scanner..."

    // Load PowerShell script from Shared Library resources
    def scanScript = libraryResource(
        'scripts/scanner/scan-repos.ps1'
    )

    writeFile(
        file: scriptName,
        text: scanScript
    )

    echo "Scanning Bitbucket repositories"
    echo "Project    : ${project}"
    echo "Repository : ${repository ?: 'ALL'}"

    powershell """
        .\\${scriptName} `
            -BitbucketProject '${project}' `
            -Repository '${repository}' `
            -ScanBranches:${scanBranches} `
            -ScanTags:${scanTags}
    """
}