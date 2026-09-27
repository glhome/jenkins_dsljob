def call(Map cfg = [:]) {
    def workRoot = cfg.workRoot
    def outputName = cfg.outputName ?: 'Windows-Custom'
    def kb = cfg.kb
    def lcuBuild = cfg.lcuBuild
    def architecture = (cfg.architecture ?: 'x64').toLowerCase()
    def windowsProduct = cfg.windowsProduct ?: 'Windows11'
    def windowsRelease = cfg.windowsRelease ?: '24H2'
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
    def artifactBase = "${windowsProduct}/${windowsRelease}/${architecture}/patched/${lcuBuild}"
    def isoArtifact = "${artifactBase}/${outputName}.iso"
    def shaArtifact = "${artifactBase}/${outputName}.iso.sha256"
    def manifestArtifact = "${artifactBase}/manifest.json"
    def lastPatchPath = "${windowsProduct}/${windowsRelease}/${architecture}/patched/lastpatch.txt"
    powershell("""
\$ErrorActionPreference = 'Stop'
\$env:JFROG_CLI_HOME_DIR = 'C:\\Jenkins\\jfrog'
if (-not (Get-Command jf.exe -ErrorAction SilentlyContinue)) { throw 'JFrog CLI was not found.' }
jf rt ping --server-id=local-artifactory 2>&1 | ForEach-Object { Write-Host \$_ }
if (\$LASTEXITCODE -ne 0) { throw 'Artifactory connection failed.' }
\$iso='${isoPath}'; \$sha='${shaPath}'; \$manifest='${manifestPath}'
\$isoArtifact='${artifactoryRepo}/${isoArtifact}'; \$shaArtifact='${artifactoryRepo}/${shaArtifact}'; \$manifestArtifact='${artifactoryRepo}/${manifestArtifact}'
Write-Host "Publishing immutable patched Windows ISO..."
foreach (\$artifact in @(\$isoArtifact,\$shaArtifact,\$manifestArtifact)) {
    & jf rt s --server-id=local-artifactory --count=1 "\$artifact" 2>&1 | Out-Null
    if (\$LASTEXITCODE -eq 0) { throw "Immutable artifact already exists: \$artifact" }
}
& jf rt upload --server-id=local-artifactory --flat=true --detailed-summary "\$iso" "\$isoArtifact" 2>&1 | ForEach-Object { Write-Host \$_ }
if (\$LASTEXITCODE -ne 0) { throw "ISO upload failed with exit code \${LASTEXITCODE}" }
& jf rt upload --server-id=local-artifactory --flat=true --detailed-summary "\$sha" "\$shaArtifact" 2>&1 | ForEach-Object { Write-Host \$_ }
if (\$LASTEXITCODE -ne 0) { throw "SHA256 upload failed with exit code \${LASTEXITCODE}" }
& jf rt upload --server-id=local-artifactory --flat=true --detailed-summary "\$manifest" "\$manifestArtifact" 2>&1 | ForEach-Object { Write-Host \$_ }
if (\$LASTEXITCODE -ne 0) { throw "Manifest upload failed with exit code \${LASTEXITCODE}" }
\$lastPatchFile=Join-Path \$env:TEMP 'windows-image-lastpatch.txt'
'${lcuBuild}' | Set-Content -LiteralPath \$lastPatchFile -Encoding ASCII -NoNewline
\$lastPatchArtifact='${artifactoryRepo}/${lastPatchPath}'
Write-Host "Updating lastpatch pointer: \$lastPatchArtifact"
& jf rt upload --server-id=local-artifactory --flat=true --detailed-summary "\$lastPatchFile" "\$lastPatchArtifact" 2>&1 | ForEach-Object { Write-Host \$_ }
if (\$LASTEXITCODE -ne 0) { throw "lastpatch.txt upload failed with exit code \${LASTEXITCODE}" }
Remove-Item -LiteralPath \$lastPatchFile -Force -ErrorAction SilentlyContinue
Write-Host 'Publish completed successfully.'
""")
}
