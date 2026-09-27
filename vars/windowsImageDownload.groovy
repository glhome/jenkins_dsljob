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

    /*
    * Let PowerShell parse resolved-updates.json.
    * Return only simple text values to Groovy.
    */
    def resolvedText = powershell(
        returnStdout: true,
        script: '''
    $ErrorActionPreference = 'Stop'

    $j = Get-Content -LiteralPath '__RESOLVED_PATH__' -Raw |
        ConvertFrom-Json

    Write-Output ("BUILD=" + [string]$j.build)
    Write-Output ("KB=" + [string]$j.kb)
    Write-Output ("RELEASEDATE=" + [string]$j.releaseDate)
    '''
        .replace('__RESOLVED_PATH__', resolvedPath)
    ).trim()

    def lcuBuild = ''
    def kb = ''
    def releaseDate = ''

    resolvedText.readLines().each { line ->

        if (line.startsWith('BUILD=')) {
            lcuBuild = line.substring(6).trim()
        }

        if (line.startsWith('KB=')) {
            kb = line.substring(3).trim().toUpperCase()
        }

        if (line.startsWith('RELEASEDATE=')) {
            releaseDate = line.substring(12).trim()
        }
    }

    if (!lcuBuild || !kb) {
        error(
            "resolved-updates.json is missing build or KB. " +
            "build='${lcuBuild}', kb='${kb}'"
        )
    }

    /*
    * Read the cache marker.
    */
    def cacheHit = false
    def manifestArtifactPath = ''
    def isoArtifactPath = ''

    if (fileExists(markerPath)) {

        def markerText = powershell(
            returnStdout: true,
            script: '''
    $ErrorActionPreference = 'Stop'

    $j = Get-Content -LiteralPath '__MARKER_PATH__' -Raw |
        ConvertFrom-Json

    Write-Output ("CACHEHIT=" + [string]$j.cacheHit)
    Write-Output ("MANIFEST=" + [string]$j.manifestArtifactPath)
    Write-Output ("ISO=" + [string]$j.isoArtifactPath)
    '''
            .replace('__MARKER_PATH__', markerPath)
        ).trim()

        markerText.readLines().each { line ->

            if (line.startsWith('CACHEHIT=')) {
                cacheHit =
                    line.substring(9).trim().equalsIgnoreCase('true')
            }

            if (line.startsWith('MANIFEST=')) {
                manifestArtifactPath =
                    line.substring(9).trim()
            }

            if (line.startsWith('ISO=')) {
                isoArtifactPath =
                    line.substring(4).trim()
            }
        }
    }

    def normalizedArchitecture =
        architecture.equalsIgnoreCase('amd64')
            ? 'x64'
            : architecture.toLowerCase()

    def outputName =
        "Windows11-24H2-${normalizedArchitecture}-${lcuBuild}-${kb}"

    def patchedBase =
        "Windows11/24H2/${normalizedArchitecture}/patched/${lcuBuild}"

    if (!manifestArtifactPath) {
        manifestArtifactPath =
            "${patchedBase}/manifest.json"
    }

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