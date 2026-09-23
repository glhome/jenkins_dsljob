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
if ($LASTEXITCODE -ne 0) { throw "download.ps1 failed with exit code $LASTEXITCODE" }
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

    def markerPath = "${workRoot}\\download\\patched-cache-hit.json"
    def resolvedPath = "${workRoot}\\download\\resolved-updates.json"
    def json = powershell(returnStdout: true, script: "(Get-Content -LiteralPath '${resolvedPath}' -Raw | ConvertFrom-Json | ConvertTo-Json -Compress)").trim()
    def resolved = new groovy.json.JsonSlurperClassic().parseText(json)
    def markerExists = fileExists(markerPath)
    def marker = markerExists ? new groovy.json.JsonSlurperClassic().parseText(readFile(markerPath)) : [:]

    def lcuBuild = (resolved.build ?: '').toString()
    def kb = (resolved.kb ?: '').toString().toUpperCase()
    def releaseDate = (resolved.releaseDate ?: '').toString()
    def normalizedArchitecture = architecture.equalsIgnoreCase('amd64') ? 'x64' : architecture.toLowerCase()
    def outputName = "Windows11-24H2-${normalizedArchitecture}-${lcuBuild}-${kb}"
    def patchedBase = "Windows11/24H2/${normalizedArchitecture}/patched/${lcuBuild}"

    if (!lcuBuild || !kb) error "resolved-updates.json is missing build or KB. build='${lcuBuild}', kb='${kb}'"

    return [
        kb: kb,
        lcuBuild: lcuBuild,
        releaseDate: releaseDate,
        outputName: outputName,
        cacheHit: markerExists && marker.cacheHit == true,
        manifestArtifactPath: marker.manifestArtifactPath ?: "${patchedBase}/manifest.json",
        isoArtifactPath: marker.isoArtifactPath ?: "${patchedBase}/${outputName}.iso"
    ]
}
