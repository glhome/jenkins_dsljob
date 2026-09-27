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

    def downloadScript = libraryResource(
        'scripts/windows-image/download.ps1'
    )

    def resolverScript = libraryResource(
        'scripts/windows-image/resolve-updates.ps1'
    )

    def downloadScriptPath =
        "${env.WORKSPACE}\\download-windows-image.ps1"

    def resolverScriptPath =
        "${env.WORKSPACE}\\resolve-updates.ps1"

    writeFile(
        file: downloadScriptPath,
        text: downloadScript
    )

    writeFile(
        file: resolverScriptPath,
        text: resolverScript
    )

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

if ($LASTEXITCODE -ne 0) {
    throw "download.ps1 failed with exit code ${LASTEXITCODE}"
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

    /*
     * Everything below this point must remain CPS-serializable.
     *
     * Do NOT keep JsonSlurperClassic/JsonSlurper objects in variables.
     * readJSON(returnPojo: true) returns normal Maps/Lists.
     */

    def markerPath =
        "${workRoot}\\download\\patched-cache-hit.json"

    def resolvedPath =
        "${workRoot}\\download\\resolved-updates.json"

    if (!fileExists(resolvedPath)) {
        error "Resolved update file not found: ${resolvedPath}"
    }

    def resolvedJson = powershell(
        returnStdout: true,
        script: """
\$ErrorActionPreference = 'Stop'

Get-Content -LiteralPath '${resolvedPath}' -Raw |
    ConvertFrom-Json |
    ConvertTo-Json -Compress -Depth 20
"""
    ).trim()

    /*
     * Jenkins readJSON creates ordinary serializable Maps.
     */
    def resolved = readJSON(
        text: resolvedJson,
        returnPojo: true
    )

    def marker = [:]

    if (fileExists(markerPath)) {
        def markerJson = readFile(
            file: markerPath
        ).trim()

        if (markerJson) {
            marker = readJSON(
                text: markerJson,
                returnPojo: true
            )
        }
    }

    def lcuBuild = (resolved.build ?: '').toString()
    def kb = (resolved.kb ?: '').toString().toUpperCase()
    def releaseDate = (resolved.releaseDate ?: '').toString()

    def normalizedArchitecture =
        architecture.equalsIgnoreCase('amd64')
            ? 'x64'
            : architecture.toLowerCase()

    if (!lcuBuild || !kb) {
        error(
            "resolved-updates.json is missing build or KB. " +
            "build='${lcuBuild}', kb='${kb}'"
        )
    }

    def outputName =
        "Windows11-24H2-${normalizedArchitecture}-${lcuBuild}-${kb}"

    def patchedBase =
        "Windows11/24H2/${normalizedArchitecture}/patched/${lcuBuild}"

    def cacheHit =
        marker.cacheHit == true

    def manifestArtifactPath =
        marker.manifestArtifactPath?.toString()

    if (!manifestArtifactPath) {
        manifestArtifactPath =
            "${patchedBase}/manifest.json"
    }

    def isoArtifactPath =
        marker.isoArtifactPath?.toString()

    if (!isoArtifactPath) {
        isoArtifactPath =
            "${patchedBase}/${outputName}.iso"
    }

    echo ""
    echo "============================================================"
    echo " Resolved Windows Image"
    echo "============================================================"
    echo "LCU KB:"
    echo "  ${kb}"
    echo "LCU Build:"
    echo "  ${lcuBuild}"
    echo "Release Date:"
    echo "  ${releaseDate}"
    echo "Architecture:"
    echo "  ${normalizedArchitecture}"
    echo "Cache Hit:"
    echo "  ${cacheHit}"
    echo "Patched Manifest:"
    echo "  ${manifestArtifactPath}"
    echo "Patched ISO:"
    echo "  ${isoArtifactPath}"
    echo "============================================================"

    return [
        kb: kb,
        lcuBuild: lcuBuild,
        releaseDate: releaseDate,
        outputName: outputName,
        cacheHit: cacheHit,
        manifestArtifactPath: manifestArtifactPath,
        isoArtifactPath: isoArtifactPath
    ]
}