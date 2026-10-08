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

if (-not (Get-Command jf.exe -ErrorAction SilentlyContinue)) {
    throw 'JFrog CLI was not found.'
}

# ============================================================
# Run jf.exe without allowing native stderr to become a
# PowerShell NativeCommandError.
# ============================================================

function Invoke-JfCapture {
    param(
        [Parameter(Mandatory = \$true)]
        [string[]] \$Arguments
    )

    \$tempRoot = Join-Path `
        \$env:TEMP `
        ('windows-image-jf-' + [guid]::NewGuid().ToString('N'))

    New-Item `
        -ItemType Directory `
        -Force `
        -Path \$tempRoot |
        Out-Null

    \$stdoutFile = Join-Path \$tempRoot 'stdout.txt'
    \$stderrFile = Join-Path \$tempRoot 'stderr.txt'

    try {

        \$process = Start-Process `
            -FilePath 'jf.exe' `
            -ArgumentList \$Arguments `
            -Wait `
            -PassThru `
            -NoNewWindow `
            -RedirectStandardOutput \$stdoutFile `
            -RedirectStandardError \$stderrFile

        \$stdout = ''

        if (Test-Path -LiteralPath \$stdoutFile) {
            \$stdout = Get-Content `
                -LiteralPath \$stdoutFile `
                -Raw `
                -ErrorAction SilentlyContinue
        }

        \$stderr = ''

        if (Test-Path -LiteralPath \$stderrFile) {
            \$stderr = Get-Content `
                -LiteralPath \$stderrFile `
                -Raw `
                -ErrorAction SilentlyContinue
        }

        return [pscustomobject]@{
            ExitCode = [int]\$process.ExitCode
            StdOut   = [string]\$stdout
            StdErr   = [string]\$stderr
        }
    }
    finally {

        if (Test-Path -LiteralPath \$tempRoot) {
            Remove-Item `
                -LiteralPath \$tempRoot `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================
# Paths / artifacts
# ============================================================

\$iso='${isoPath}'
\$sha='${shaPath}'
\$manifest='${manifestPath}'

\$isoArtifact='${artifactoryRepo}/${isoArtifact}'
\$shaArtifact='${artifactoryRepo}/${shaArtifact}'
\$manifestArtifact='${artifactoryRepo}/${manifestArtifact}'

# ============================================================
# Artifactory connection
# ============================================================

\$ping = Invoke-JfCapture @(
    'rt'
    'ping'
    '--server-id=local-artifactory'
)

if (\$ping.StdOut) {
    Write-Host \$ping.StdOut.Trim()
}

if (\$ping.StdErr) {
    Write-Host \$ping.StdErr.Trim()
}

if (\$ping.ExitCode -ne 0) {
    throw "Artifactory connection failed. JFrog exit code: \$ping.ExitCode"
}

# ============================================================
# Immutable publish checks
# ============================================================

Write-Host 'Publishing immutable patched Windows ISO...'

foreach (\$artifact in @(
    \$isoArtifact
    \$shaArtifact
    \$manifestArtifact
)) {

    Write-Host "Checking immutable artifact: \$artifact"

    \$search = Invoke-JfCapture @(
        'rt'
        's'
        '--server-id=local-artifactory'
        '--count'
        '--fail-no-op'
        \$artifact
    )

    if (-not [string]::IsNullOrWhiteSpace(\$search.StdErr)) {
        Write-Host \$search.StdErr.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace(\$search.StdOut)) {
        Write-Host \$search.StdOut.Trim()
    }

    switch (\$search.ExitCode) {

        0 {
            throw "Immutable artifact already exists: \$artifact"
        }

        2 {
            Write-Host `
                "Artifact does not exist; safe to publish: \$artifact"
        }

        default {
            throw (
                "Artifactory immutable check failed for " +
                "\$artifact with JFrog exit code \$search.ExitCode."
            )
        }
    }
}

# ============================================================
# Upload helper
# ============================================================

function Publish-JfArtifact {
    param(
        [Parameter(Mandatory = \$true)]
        [string] \$LocalPath,

        [Parameter(Mandatory = \$true)]
        [string] \$ArtifactPath,

        [Parameter(Mandatory = \$true)]
        [string] \$Description
    )

    Write-Host ""
    Write-Host "Publishing \$Description..."
    Write-Host "  Local:    \$LocalPath"
    Write-Host "  Artifact: \$ArtifactPath"

    \$result = Invoke-JfCapture @(
        'rt'
        'upload'
        '--server-id=local-artifactory'
        '--flat=true'
        '--detailed-summary'
        \$LocalPath
        \$ArtifactPath
    )

    if (-not [string]::IsNullOrWhiteSpace(\$result.StdOut)) {
        Write-Host \$result.StdOut.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace(\$result.StdErr)) {
        Write-Host \$result.StdErr.Trim()
    }

    if (\$result.ExitCode -ne 0) {
        throw (
            "\$Description upload failed with JFrog exit code " +
            "\$result.ExitCode."
        )
    }
}

# ============================================================
# Publish ISO
# ============================================================

Publish-JfArtifact `
    -LocalPath \$iso `
    -ArtifactPath \$isoArtifact `
    -Description 'ISO'

# ============================================================
# Publish SHA256
# ============================================================

Publish-JfArtifact `
    -LocalPath \$sha `
    -ArtifactPath \$shaArtifact `
    -Description 'SHA256'

# ============================================================
# Publish manifest
# ============================================================

Publish-JfArtifact `
    -LocalPath \$manifest `
    -ArtifactPath \$manifestArtifact `
    -Description 'manifest'

# ============================================================
# Update lastpatch pointer
#
# This remains mutable by design.
# ============================================================

\$lastPatchFile = Join-Path `
    \$env:TEMP `
    'windows-image-lastpatch.txt'

'${lcuBuild}' |
    Set-Content `
        -LiteralPath \$lastPatchFile `
        -Encoding ASCII `
        -NoNewline

\$lastPatchArtifact =
    '${artifactoryRepo}/${lastPatchPath}'

Write-Host ""
Write-Host "Updating lastpatch pointer: \$lastPatchArtifact"

Publish-JfArtifact `
    -LocalPath \$lastPatchFile `
    -ArtifactPath \$lastPatchArtifact `
    -Description 'lastpatch.txt'

Remove-Item `
    -LiteralPath \$lastPatchFile `
    -Force `
    -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Publish completed successfully.'
""")
}
