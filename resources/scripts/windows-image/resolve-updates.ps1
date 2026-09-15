param(
    [Parameter(Mandatory)]
    [string]$WorkRoot,

    [Parameter(Mandatory)]
    [string]$WindowsBuild,

    [Parameter(Mandatory)]
    [string]$Architecture,

    [string]$ArtifactoryBaseUrl,

    [string]$ArtifactoryRepo = "windows-updates"
)

$ErrorActionPreference = "Stop"

$downloadDir = Join-Path $WorkRoot "download"
$updateDir = Join-Path $downloadDir "updates"
$manifest = Join-Path $downloadDir "resolved-updates.json"

New-Item -ItemType Directory -Force -Path $updateDir | Out-Null

Write-Host "=========================================="
Write-Host "Automatic Windows Update Resolution"
Write-Host "=========================================="
Write-Host "Build        : $WindowsBuild"
Write-Host "Architecture : $Architecture"
Write-Host "Artifactory  : $ArtifactoryBaseUrl"
Write-Host "Repository   : $ArtifactoryRepo"
Write-Host ""

# Resolver implementation goes here.
#
# It must:
#
# 1. Find the current applicable SSU.
# 2. Find the current applicable LCU.
# 3. Check Artifactory.
# 4. Download missing packages from Microsoft.
# 5. SHA256 validate packages.
# 6. Publish missing packages to Artifactory.
# 7. Write resolved-updates.json.