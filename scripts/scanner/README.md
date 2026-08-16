# Repository Scanner

The repository scanner is a utility component of the managed Jenkins infrastructure.

## Local usage

```powershell
.\scan-repos.ps1 `
    -RepositoryRoot C:\repos `
    -OutputFile repo-scan-results.json