[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfigFile
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

$dir = $config.build.updatesPath

New-Item `
    -Path $dir `
    -ItemType Directory `
    -Force | Out-Null

$catalog = Join-Path $dir "updates.json"

if (-not (Test-Path $catalog)) {

    $jfrog = if ($env:JFROG_CLI) {
        $env:JFROG_CLI
    }
    else {
        "jfrog"
    }

    $remote =
        "$($config.artifactory.sourceRepository)/windows-image/window10/1809/updates.json"

    Write-Host "Downloading update catalog: $remote"

    & $jfrog rt download `
        $remote `
        $catalog `
        --flat=true `
        --fail-no-op=true

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $catalog)) {
        throw "updates.json not found."
    }
}

$data = Get-Content $catalog -Raw | ConvertFrom-Json

if (-not $data.updates) {
    throw "No updates defined in updates.json."
}

$result = @()

foreach ($u in $data.updates) {

    if (-not $u.url) {
        throw "Update $($u.kb) has no URL."
    }

    $name =
        [IO.Path]::GetFileName(
            ([Uri]$u.url).AbsolutePath
        )

    if ($name -notmatch '\.(msu|cab)$') {
        throw "Invalid package URL for $($u.kb)."
    }

    $dest = Join-Path $dir $name

    Write-Host "Downloading $($u.kb): $name"

    Invoke-WebRequest `
        -Uri $u.url `
        -OutFile $dest `
        -UseBasicParsing

    $hash =
        (Get-FileHash `
            -Path $dest `
            -Algorithm SHA256).Hash

    if ($u.sha256) {

        $expected =
            $u.sha256.ToString().ToUpperInvariant()

        if ($hash -ne $expected) {
            throw @"
SHA256 mismatch for $name
Expected: $expected
Actual:   $hash
"@
        }
    }

    $result += [pscustomobject]@{
        kb            = $u.kb
        type          = $u.type
        package       = $name
        url           = $u.url
        sha256        = $hash
        downloadedUtc =
            (Get-Date).ToUniversalTime().ToString("o")
    }
}

$result |
    ConvertTo-Json -Depth 5 |
    Set-Content `
        (Join-Path $dir "download-manifest.json") `
        -Encoding UTF8

Write-Host "Downloaded $($result.Count) update(s)."
