param(
    [string]$JenkinsHome = "C:\ProgramData\Jenkins\.jenkins"
)

$ErrorActionPreference = "Stop"

Write-Host "========================================="
Write-Host " Jenkins Bootstrap"
Write-Host "========================================="

$RepoRoot = Split-Path -Parent $PSScriptRoot

$CascSource = Join-Path $RepoRoot "casc"
$CascTarget = Join-Path $JenkinsHome "casc"

Write-Host "Jenkins Home : $JenkinsHome"
Write-Host "Config Source: $CascSource"
Write-Host "Config Target: $CascTarget"

# Create JCasC directory
New-Item `
    -ItemType Directory `
    -Force `
    -Path $CascTarget | Out-Null

# Copy JCasC configuration
Copy-Item `
    -Path "$CascSource\*.yaml" `
    -Destination $CascTarget `
    -Force

Write-Host ""
Write-Host "JCasC configuration copied."

Write-Host ""
Write-Host "Configuration files:"

Get-ChildItem $CascTarget |
    Select-Object Name, Length |
    Format-Table

Write-Host ""
Write-Host "========================================="
Write-Host " Bootstrap complete"
Write-Host "========================================="