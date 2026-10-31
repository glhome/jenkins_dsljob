[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkRoot,
    [Parameter(Mandatory=$true)][ValidateSet('windows10-21h2','windows11-24h2')][string]$Profile,
    [Parameter(Mandatory=$true)][int]$ImageIndex,
    [Parameter(Mandatory=$true)][string]$ResolverScriptPath,
    [Parameter(Mandatory=$true)][string]$Architecture,
    [string]$ArtifactoryBaseUrl = '',
    [string]$ArtifactoryRepo = 'snapshot-generic-local',
    [string]$ArtifactoryServerId = 'local-artifactory',
    [string]$ArtifactoryUser = '',
    [string]$ArtifactoryPassword = '',
    [string]$ArtifactoryToken = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
$Wim = Join-Path $WorkRoot 'source\sources\install.wim'
$Mount = Join-Path $WorkRoot 'mount\inventory'
$Inventory = Join-Path $WorkRoot 'download\installed-package-inventory.json'
$Resolved = Join-Path $WorkRoot 'download\resolved-updates.json'
if (-not (Test-Path -LiteralPath $Wim -PathType Leaf)) { throw "WIM not found: $Wim" }
if ($ImageIndex -lt 1) { throw 'ImageIndex must be greater than zero.' }
if (-not (Test-Path -LiteralPath $ResolverScriptPath -PathType Leaf)) { throw "Resolver not found: $ResolverScriptPath" }
New-Item -ItemType Directory -Force -Path $Mount,(Split-Path -Parent $Inventory) | Out-Null

# Mount read-only so inventory collection cannot alter the source WIM.
& dism.exe /Mount-Wim "/WimFile:$Wim" "/Index:$ImageIndex" "/MountDir:$Mount" /ReadOnly
if ($LASTEXITCODE -ne 0) { throw "DISM read-only mount failed: $LASTEXITCODE" }
try {
    $raw = & dism.exe "/Image:$Mount" /Get-Packages /English 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'DISM /Get-Packages failed for selected offline image.' }
    $text = $raw -join "`n"
    $packages = @()
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*Package Identity\s*:\s*(\S+)') {
            $identity = $Matches[1]
            $kb = ''
            if ($identity -match '(?i)KB(\d{6,8})') { $kb = 'KB' + $Matches[1] }
            $packages += [pscustomobject]@{ identity=$identity; kb=$kb }
        }
    }
    $record = [ordered]@{
        profile=$Profile; imageIndex=$ImageIndex; wimFile=[IO.Path]::GetFullPath($Wim)
        collectedUtc=[DateTime]::UtcNow.ToString('o'); packages=@($packages)
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Inventory -Encoding UTF8
}
finally {
    & dism.exe /Unmount-Wim "/MountDir:$Mount" /Discard
    if ($LASTEXITCODE -ne 0) { throw 'Failed to discard read-only inventory mount.' }
}

# Resolve/download only after edition-specific inventory is captured.
# Resolver records the exact WIM index and inventory in resolved-updates.json.
& $ResolverScriptPath -WorkRoot $WorkRoot -WindowsProfile $Profile -Architecture $Architecture `
    -ArtifactoryBaseUrl $ArtifactoryBaseUrl -ArtifactoryRepo $ArtifactoryRepo `
    -ArtifactoryUser $ArtifactoryUser -ArtifactoryPassword $ArtifactoryPassword -ArtifactoryToken $ArtifactoryToken `
    -ImageIndex $ImageIndex -InstalledPackageInventoryFile $Inventory
if (-not $?) { throw 'Update resolver failed after offline inventory collection.' }
if (-not (Test-Path -LiteralPath $Resolved -PathType Leaf)) { throw 'Resolver did not create resolved-updates.json.' }
Write-Host "Offline inventory: $Inventory"
Write-Host "Resolved manifest: $Resolved"
