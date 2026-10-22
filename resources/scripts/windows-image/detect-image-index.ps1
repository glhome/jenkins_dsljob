param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('windows10-21h2', 'windows11-24h2')]
    [string]$Profile,

    [Parameter(Mandatory = $true)]
    [string]$WimFile,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $WimFile -PathType Leaf)) {
    throw "WIM file not found: $WimFile"
}

Write-Host "Inspecting WIM: $WimFile"

$dismOutput = & dism.exe /English /Get-WimInfo "/WimFile:$WimFile" 2>&1
$dismExitCode = $LASTEXITCODE

if ($dismExitCode -ne 0) {
    $dismOutput | ForEach-Object { Write-Host $_ }
    throw "DISM /Get-WimInfo failed with exit code $dismExitCode."
}

# Parse each image's Index, Name, and Description from DISM output.
$images = @()
$current = $null

foreach ($lineObject in $dismOutput) {
    $line = [string]$lineObject

    if ($line -match '^\s*Index\s*:\s*(\d+)\s*$') {
        if ($null -ne $current) {
            $images += [pscustomobject]$current
        }

        $current = [ordered]@{
            Index       = [int]$Matches[1]
            Name        = ''
            Description = ''
        }
        continue
    }

    if ($null -ne $current -and $line -match '^\s*Name\s*:\s*(.*?)\s*$') {
        $current.Name = $Matches[1].Trim()
        continue
    }

    if ($null -ne $current -and $line -match '^\s*Description\s*:\s*(.*?)\s*$') {
        $current.Description = $Matches[1].Trim()
    }
}

if ($null -ne $current) {
    $images += [pscustomobject]$current
}

if ($images.Count -eq 0) {
    throw "No WIM image indexes were found in DISM output."
}

switch ($Profile) {
    'windows10-21h2' {
        $pattern = '^Windows\s+10\s+IoT\s+Enterprise\s+LTSC(?:\s|,|$)'
    }
    'windows11-24h2' {
        $pattern = '^Windows\s+11\s+IoT\s+Enterprise(?:\s|,|$)'
    }
}

$matches = @(
    $images | Where-Object { $_.Name -match $pattern }
)

if ($matches.Count -ne 1) {
    Write-Host "Available WIM editions:"
    $images | Format-Table Index, Name, Description -AutoSize

    throw "Expected exactly one edition matching '$pattern' for profile '$Profile'; found $($matches.Count). Refusing to guess."
}

$selected = $matches[0]

$selection = [ordered]@{
    profile          = $Profile
    imageIndex       = [int]$selected.Index
    imageName        = [string]$selected.Name
    imageDescription = [string]$selected.Description
    wimFile          = [System.IO.Path]::GetFullPath($WimFile)
}

$outputDirectory = Split-Path -Parent $OutputFile
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$json = $selection | ConvertTo-Json -Depth 4
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllText(
    [System.IO.Path]::GetFullPath($OutputFile),
    $json,
    $utf8NoBom
)

Write-Host "Selected edition: $($selected.Name)"
Write-Host "Selected index:   $($selected.Index)"
Write-Host "Selection file:   $OutputFile"
