param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir,

    [Parameter(Mandatory = $false)]
    [long]$ChunkSize = 95MB
)

# Validate source file
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "Source EXE not found: $Source"
}

# Create output directory
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Write-Host "Source:     $Source"
Write-Host "Output Dir: $OutputDir"
Write-Host "Chunk Size: $ChunkSize bytes"

$input = [System.IO.File]::OpenRead($Source)
$buffer = New-Object byte[] $ChunkSize
$part = 1

try {
    while (($bytesRead = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {

        $partFile = Join-Path $OutputDir (
            "{0}.part{1:D3}" -f (Split-Path $Source -Leaf), $part
        )

        Write-Host "Creating: $partFile"

        $output = [System.IO.File]::OpenWrite($partFile)

        try {
            $output.Write($buffer, 0, $bytesRead)
        }
        finally {
            $output.Dispose()
        }

        $part++
    }
}
finally {
    $input.Dispose()
}

Write-Host "Split completed successfully."