def scanScript = libraryResource('scripts/scanner/scan-repos.ps1')

writeFile(
    file: 'scan-repos.ps1',
    text: scanScript
)

powershell '.\\scan-repos.ps1'