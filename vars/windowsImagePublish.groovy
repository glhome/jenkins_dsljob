def call(Map cfg = [:]) {
    def workRoot = cfg.workRoot
    def outputName = cfg.outputName ?: 'Windows-Custom'
    def kb = cfg.kb
    def lcuBuild = cfg.lcuBuild
    def architecture = (cfg.architecture ?: 'x64').toLowerCase()
    def artifactoryBaseUrl = cfg.artifactoryBaseUrl
    def artifactoryRepo = cfg.artifactoryRepo ?: 'snapshot-generic-local'

    if (!workRoot?.trim()) error 'workRoot is required'
    if (!kb?.trim()) error 'kb is required'
    if (!lcuBuild?.trim()) error 'lcuBuild is required'
    if (!artifactoryBaseUrl?.trim()) error 'artifactoryBaseUrl is required'

    def isoPath = "${workRoot}\\output\\${outputName}.iso"
    def shaPath = "${isoPath}.sha256"
    def manifestPath = "${workRoot}\\output\\manifest.json"

    if (!fileExists(isoPath)) error "ISO not found: ${isoPath}"
    if (!fileExists(shaPath)) error "ISO checksum not found: ${shaPath}"
    if (!fileExists(manifestPath)) error "Manifest not found: ${manifestPath}"

    def artifactBase = "Windows11/24H2/${architecture}/${lcuBuild}"
    def isoArtifact = "${artifactBase}/${outputName}.iso"
    def shaArtifact = "${artifactBase}/${outputName}.iso.sha256"
    def manifestArtifact = "${artifactBase}/manifest.json"
    def latestPath = "Windows11/24H2/${architecture}/latest.txt"

    powershell(
        """
\$ErrorActionPreference = 'Stop'
\$env:JFROG_CLI_HOME_DIR = 'C:\\Jenkins\\jfrog'

if (-not (Get-Command jf.exe -ErrorAction SilentlyContinue)) {
    throw 'JFrog CLI was not found.'
}

jf rt ping --server-id=local-artifactory
if (\$LASTEXITCODE -ne 0) {
    throw 'Artifactory connection failed.'
}

\$iso = '${isoPath}'
\$sha = '${shaPath}'
\$manifest = '${manifestPath}'

\$isoArtifact = '${artifactoryRepo}/${isoArtifact}'
\$shaArtifact = '${artifactoryRepo}/${shaArtifact}'
\$manifestArtifact = '${artifactoryRepo}/${manifestArtifact}'

Write-Host ""
Write-Host "Publishing immutable Windows ISO..."
Write-Host "  ISO      : \$isoArtifact"
Write-Host "  SHA256   : \$shaArtifact"
Write-Host "  Manifest : \$manifestArtifact"

& jf rt upload --server-id=local-artifactory --flat=true --detailed-summary "\$iso" "\$isoArtifact" 2>&1
if (\$LASTEXITCODE -ne 0) { throw "ISO upload failed with exit code \$LASTEXITCODE" }

& jf rt upload --server-id=local-artifactory --flat=true --detailed-summary "\$sha" "\$shaArtifact" 2>&1
if (\$LASTEXITCODE -ne 0) { throw "SHA256 upload failed with exit code \$LASTEXITCODE" }

& jf rt upload --server-id=local-artifactory --flat=true --detailed-summary "\$manifest" "\$manifestArtifact" 2>&1
if (\$LASTEXITCODE -ne 0) { throw "Manifest upload failed with exit code \$LASTEXITCODE" }

\$latestFile = Join-Path \$env:TEMP 'windows-image-latest.txt'
"Windows11/24H2/${architecture}/${lcuBuild}/${outputName}.iso" | Set-Content -LiteralPath \$latestFile -Encoding ASCII -NoNewline

\$latestArtifact = '${artifactoryRepo}/${latestPath}'
Write-Host ""
Write-Host "Updating latest pointer:"
Write-Host "  \$latestArtifact"

& jf rt upload --server-id=local-artifactory --flat=true --detailed-summary "\$latestFile" "\$latestArtifact" 2>&1
if (\$LASTEXITCODE -ne 0) { throw "latest.txt upload failed with exit code \$LASTEXITCODE" }

Write-Host ""
Write-Host "Publish completed successfully."
Write-Host "latest.txt -> Windows11/24H2/${architecture}/${lcuBuild}/${outputName}.iso"
Remove-Item -LiteralPath \$latestFile -Force -ErrorAction SilentlyContinue
"""
    )
}
