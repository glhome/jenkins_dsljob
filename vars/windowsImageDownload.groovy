def call(Map cfg = [:]) {
    def workRoot = cfg.workRoot
    def baseIsoArtifact = cfg.baseIsoArtifact
    def baseIsoSha256 = cfg.baseIsoSha256 ?: ''
    def profile = cfg.profile ?: 'windows11-24h2'
    def architecture = cfg.architecture ?: 'x64'
    def artifactoryBaseUrl = cfg.artifactoryBaseUrl
    def artifactoryRepo = cfg.artifactoryRepo ?: 'snapshot-generic-local'

    if (!workRoot?.trim()) {
        error 'workRoot is required'
    }

    if (!baseIsoArtifact?.trim()) {
        error 'baseIsoArtifact is required'
    }

    if (!artifactoryBaseUrl?.trim()) {
        error 'artifactoryBaseUrl is required'
    }

    // ========================================================
    // Load Windows image PowerShell resources
    // ========================================================

    def downloadScript = libraryResource(
        'scripts/windows-image/download.ps1'
    )

    def resolverScript = libraryResource(
        'scripts/windows-image/resolve-updates.ps1'
    )

    def profileScript = libraryResource(
        'scripts/windows-image/profiles.ps1'
    )

    // ========================================================
    // IMPORTANT:
    //
    // resolve-updates.ps1 expects profiles.ps1 in the same
    // directory as itself.
    //
    // download.ps1 receives ProfileScriptPath explicitly.
    // ========================================================

    def downloadScriptPath =
        "${env.WORKSPACE}\\download-windows-image.ps1"

    def resolverScriptPath =
        "${env.WORKSPACE}\\resolve-updates.ps1"

    def profileScriptPath =
        "${env.WORKSPACE}\\profiles.ps1"

    writeFile(
        file: downloadScriptPath,
        text: downloadScript
    )

    writeFile(
        file: resolverScriptPath,
        text: resolverScript
    )

    writeFile(
        file: profileScriptPath,
        text: profileScript
    )

    // ========================================================
    // Verify generated scripts
    // ========================================================

    powershell '''
$ErrorActionPreference = 'Stop'

$required = @(
    '__DOWNLOAD_SCRIPT_PATH__',
    '__RESOLVER_SCRIPT_PATH__',
    '__PROFILE_SCRIPT_PATH__'
)

foreach ($file in $required) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Required Windows image script not found: $file"
    }

    Write-Host "Verified Windows image script: $file"
}
'''
        .replace(
            '__DOWNLOAD_SCRIPT_PATH__',
            downloadScriptPath
        )
        .replace(
            '__RESOLVER_SCRIPT_PATH__',
            resolverScriptPath
        )
        .replace(
            '__PROFILE_SCRIPT_PATH__',
            profileScriptPath
        )

    // ========================================================
    // Run download / resolve script
    // ========================================================

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
    -Profile '__PROFILE__' `
    -Architecture '__ARCHITECTURE__' `
    -ArtifactoryBaseUrl '__ARTIFACTORY_BASE_URL__' `
    -ArtifactoryRepo '__ARTIFACTORY_REPO__' `
    -ArtifactoryUser $env:ARTIFACTORY_USER `
    -ArtifactoryPassword $env:ARTIFACTORY_PASSWORD `
    -ResolverScriptPath '__RESOLVER_SCRIPT_PATH__' `
    -ProfileScriptPath '__PROFILE_SCRIPT_PATH__'

if ($LASTEXITCODE -ne 0) {
    throw "download.ps1 failed with exit code ${LASTEXITCODE}"
}
'''
            .replace(
                '__DOWNLOAD_SCRIPT_PATH__',
                downloadScriptPath
            )
            .replace(
                '__WORK_ROOT__',
                workRoot
            )
            .replace(
                '__BASE_ISO_ARTIFACT__',
                baseIsoArtifact
            )
            .replace(
                '__BASE_ISO_SHA256__',
                baseIsoSha256
            )
            .replace(
                '__PROFILE__',
                profile
            )
            .replace(
                '__ARCHITECTURE__',
                architecture
            )
            .replace(
                '__ARTIFACTORY_BASE_URL__',
                artifactoryBaseUrl
            )
            .replace(
                '__ARTIFACTORY_REPO__',
                artifactoryRepo
            )
            .replace(
                '__RESOLVER_SCRIPT_PATH__',
                resolverScriptPath
            )
            .replace(
                '__PROFILE_SCRIPT_PATH__',
                profileScriptPath
            )
        )
    }

    // ========================================================
    // Read resolver output
    // ========================================================

    def markerPath =
        "${workRoot}\\download\\patched-cache-hit.json"

    def resolvedPath =
        "${workRoot}\\download\\resolved-updates.json"

    if (!fileExists(resolvedPath)) {
        error "Resolved update file not found: ${resolvedPath}"
    }

    def resolvedText = powershell(
        returnStdout: true,
        script: '''
$ErrorActionPreference = 'Stop'

$j = Get-Content `
    -LiteralPath '__RESOLVED_PATH__' `
    -Raw |
    ConvertFrom-Json

Write-Output ("PROFILE=" + [string]$j.profile)
Write-Output ("PRODUCT=" + [string]$j.product)
Write-Output ("RELEASE=" + [string]$j.release)
Write-Output ("WINDOWSVERSION=" + [string]$j.windowsVersion)
Write-Output ("WINDOWSBUILD=" + [string]$j.windowsBuild)
Write-Output ("BUILD=" + [string]$j.build)
Write-Output ("KB=" + [string]$j.kb)
Write-Output ("RELEASEDATE=" + [string]$j.releaseDate)
Write-Output ("ISOPREFIX=" + [string]$j.isoPrefix)
Write-Output ("ARTIFACTROOT=" + [string]$j.artifactRoot)
'''
            .replace(
                '__RESOLVED_PATH__',
                resolvedPath
            )
    ).trim()

    // ========================================================
    // Parse simple key/value output
    // ========================================================

    def resolvedProfile = ''
    def windowsProduct = ''
    def windowsRelease = ''
    def windowsVersion = ''
    def windowsBuild = ''
    def isoPrefix = ''
    def artifactRootFromResolver = ''
    def lcuBuild = ''
    def kb = ''
    def releaseDate = ''

    resolvedText.readLines().each { line ->

        if (line.startsWith('PROFILE=')) {
            resolvedProfile = line.substring(8).trim()
        }

        if (line.startsWith('PRODUCT=')) {
            windowsProduct = line.substring(8).trim()
        }

        if (line.startsWith('RELEASE=')) {
            windowsRelease = line.substring(8).trim()
        }

        if (line.startsWith('WINDOWSVERSION=')) {
            windowsVersion = line.substring(15).trim()
        }

        if (line.startsWith('WINDOWSBUILD=')) {
            windowsBuild = line.substring(13).trim()
        }

        if (line.startsWith('BUILD=')) {
            lcuBuild = line.substring(6).trim()
        }

        if (line.startsWith('KB=')) {
            kb = line.substring(3).trim().toUpperCase()
        }

        if (line.startsWith('RELEASEDATE=')) {
            releaseDate = line.substring(12).trim()
        }

        if (line.startsWith('ISOPREFIX=')) {
            isoPrefix = line.substring(10).trim()
        }

        if (line.startsWith('ARTIFACTROOT=')) {
            artifactRootFromResolver =
                line.substring(13).trim()
        }
    }

    // ========================================================
    // Validate resolver output
    // ========================================================

    if (
        !resolvedProfile ||
        !windowsVersion ||
        !windowsBuild ||
        !lcuBuild ||
        !kb
    ) {
        error(
            "resolved-updates.json is missing profile/build information. " +
            "profile='${resolvedProfile}', " +
            "windowsBuild='${windowsBuild}', " +
            "build='${lcuBuild}', " +
            "kb='${kb}'"
        )
    }

    // ========================================================
    // Cache marker
    // ========================================================

    def cacheHit = false
    def manifestArtifactPath = ''
    def isoArtifactPath = ''

    if (fileExists(markerPath)) {

        def markerText = powershell(
            returnStdout: true,
            script: '''
$ErrorActionPreference = 'Stop'

$j = Get-Content `
    -LiteralPath '__MARKER_PATH__' `
    -Raw |
    ConvertFrom-Json

Write-Output ("CACHEHIT=" + [string]$j.cacheHit)
Write-Output ("MANIFEST=" + [string]$j.manifestArtifactPath)
Write-Output ("ISO=" + [string]$j.isoArtifactPath)
'''
                .replace(
                    '__MARKER_PATH__',
                    markerPath
                )
        ).trim()

        markerText.readLines().each { line ->

            if (line.startsWith('CACHEHIT=')) {
                cacheHit =
                    line.substring(9)
                        .trim()
                        .equalsIgnoreCase('true')
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

    // ========================================================
    // Calculate artifact paths
    // ========================================================

    def normalizedArchitecture =
        architecture.equalsIgnoreCase('amd64')
            ? 'x64'
            : architecture.toLowerCase()

    def effectiveIsoPrefix =
        isoPrefix ?: "${windowsProduct}-${windowsRelease}"

    def effectiveArtifactRoot =
        artifactRootFromResolver

    if (!effectiveArtifactRoot) {
        effectiveArtifactRoot =
            "${windowsProduct}/${windowsRelease}"
    }

    def outputName =
        "${effectiveIsoPrefix}-${normalizedArchitecture}-${lcuBuild}-${kb}"

    def patchedBase =
        "${effectiveArtifactRoot}/${normalizedArchitecture}/patched/${lcuBuild}"

    if (!manifestArtifactPath) {
        manifestArtifactPath =
            "${patchedBase}/manifest.json"
    }

    if (!isoArtifactPath) {
        isoArtifactPath =
            "${patchedBase}/${outputName}.iso"
    }

    // ========================================================
    // Logging
    // ========================================================

    echo "Resolved profile: ${resolvedProfile} (${windowsVersion}, ${windowsBuild})"
    echo "Resolved LCU: ${kb} / ${lcuBuild}"
    echo "Patched manifest: ${manifestArtifactPath}"
    echo "Patched ISO: ${isoArtifactPath}"
    echo "Cache hit: ${cacheHit}"

    // ========================================================
    // Return image information
    // ========================================================

    return [
        profile: resolvedProfile,
        windowsProduct: windowsProduct,
        windowsRelease: windowsRelease,
        windowsVersion: windowsVersion,
        windowsBuild: windowsBuild,
        kb: kb,
        lcuBuild: lcuBuild,
        releaseDate: releaseDate,
        outputName: outputName,
        cacheHit: cacheHit,
        manifestArtifactPath: manifestArtifactPath,
        isoArtifactPath: isoArtifactPath
    ]
}