def call(Map cfg = [:]) {
    def workRoot = cfg.workRoot
    def baseIsoArtifact = cfg.baseIsoArtifact
    def baseIsoSha256 = cfg.baseIsoSha256 ?: ''
    def windowsBuild = cfg.windowsBuild ?: '26100'
    def architecture = cfg.architecture ?: 'x64'
    def artifactoryBaseUrl = cfg.artifactoryBaseUrl
    def artifactoryRepo = cfg.artifactoryRepo ?: 'snapshot-generic-local'

    if (!workRoot?.trim()) error 'workRoot is required'
    if (!baseIsoArtifact?.trim()) error 'baseIsoArtifact is required'
    if (!artifactoryBaseUrl?.trim()) error 'artifactoryBaseUrl is required'

    def downloadScript = libraryResource('scripts/windows-image/download.ps1')
    def resolverScript = libraryResource('scripts/windows-image/resolve-updates.ps1')
    def downloadScriptPath = "${env.WORKSPACE}\\download-windows-image.ps1"
    def resolverScriptPath = "${env.WORKSPACE}\\resolve-updates.ps1"

    writeFile(file: downloadScriptPath, text: downloadScript)
    writeFile(file: resolverScriptPath, text: resolverScript)

    withCredentials([
        usernamePassword(
            credentialsId: 'artifactory-credentials',
            usernameVariable: 'ARTIFACTORY_USER',
            passwordVariable: 'ARTIFACTORY_PASSWORD'
        )
    ]) {
        powershell(
            '''
$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "==========================================================="
Write-Host " Download Windows Base ISO and Resolve Updates"
Write-Host "==========================================================="
Write-Host ""

& '__DOWNLOAD_SCRIPT_PATH__' `
    -WorkRoot '__WORK_ROOT__' `
    -BaseIsoArtifact '__BASE_ISO_ARTIFACT__' `
    -BaseIsoSha256 '__BASE_ISO_SHA256__' `
    -WindowsBuild '__WINDOWS_BUILD__' `
    -Architecture '__ARCHITECTURE__' `
    -ArtifactoryBaseUrl '__ARTIFACTORY_BASE_URL__' `
    -ArtifactoryRepo '__ARTIFACTORY_REPO__' `
    -ArtifactoryUser $env:ARTIFACTORY_USER `
    -ArtifactoryPassword $env:ARTIFACTORY_PASSWORD `
    -ResolverScriptPath '__RESOLVER_SCRIPT_PATH__'

if ($LASTEXITCODE -ne 0) {
    throw "download.ps1 failed with exit code $LASTEXITCODE"
}
'''
            .replace('__DOWNLOAD_SCRIPT_PATH__', downloadScriptPath)
            .replace('__WORK_ROOT__', workRoot)
            .replace('__BASE_ISO_ARTIFACT__', baseIsoArtifact)
            .replace('__BASE_ISO_SHA256__', baseIsoSha256)
            .replace('__WINDOWS_BUILD__', windowsBuild)
            .replace('__ARCHITECTURE__', architecture)
            .replace('__ARTIFACTORY_BASE_URL__', artifactoryBaseUrl)
            .replace('__ARTIFACTORY_REPO__', artifactoryRepo)
            .replace('__RESOLVER_SCRIPT_PATH__', resolverScriptPath)
        )
    }

    def resolvedPath = "${workRoot}\\download\\resolved-updates.json"
    def resolvedJson = powershell(
        returnStdout: true,
        script: "(Get-Content -LiteralPath '${resolvedPath}' -Raw | ConvertFrom-Json | ConvertTo-Json -Compress)"
    ).trim()

    def resolved = new groovy.json.JsonSlurperClassic().parseText(resolvedJson)
    def lcuBuild = (resolved.build ?: '').toString()
    def kb = (resolved.kb ?: '').toString().toUpperCase()
    def releaseDate = (resolved.releaseDate ?: '').toString()
    def normalizedArchitecture = architecture.equalsIgnoreCase('amd64') ? 'x64' : architecture.toLowerCase()

    if (!lcuBuild || !kb) {
        error "resolved-updates.json is missing build or KB. build='${lcuBuild}', kb='${kb}'"
    }

    def outputName = "Windows11-24H2-${normalizedArchitecture}-${lcuBuild}-${kb}"
    def isoArtifactPath = "Windows11/24H2/${normalizedArchitecture}/${lcuBuild}/${outputName}.iso"

    def isoExists = powershell(
        returnStdout: true,
        script: """
\$ErrorActionPreference = 'Stop'
\$env:JFROG_CLI_HOME_DIR = 'C:\\Jenkins\\jfrog'

if (-not (Get-Command jf.exe -ErrorAction SilentlyContinue)) {
    throw 'JFrog CLI was not found.'
}

\$result = & jf rt s '${artifactoryRepo}/${isoArtifactPath}' --server-id=local-artifactory --count=1 2>&1
\$exitCode = \$LASTEXITCODE
if (\$exitCode -ne 0) {
    throw "JFrog search failed with exit code \$exitCode. \$result"
}

if (\$result -match '(?i)${outputName.replace('\\','\\\\')}\\.iso') {
    'true'
} else {
    'false'
}
"""
    ).trim().equalsIgnoreCase('true')

    echo "Resolved latest LCU: ${kb} / ${lcuBuild}"
    echo "ISO cache check: ${isoExists ? 'FOUND' : 'NOT FOUND'}"
    echo "ISO artifact: ${isoArtifactPath}"

    return [
        kb: kb,
        lcuBuild: lcuBuild,
        releaseDate: releaseDate,
        outputName: outputName,
        isoArtifactPath: isoArtifactPath,
        isoExists: isoExists
    ]
}
