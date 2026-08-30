param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath,

    [Parameter(Mandatory = $true)]
    [hashtable]$BuildMap
)

$result = @()

$files = Get-ChildItem `
    -LiteralPath $RepositoryPath `
    -Recurse `
    -File `
    -ErrorAction SilentlyContinue |
Where-Object {
    $_.FullName -notmatch '\\.git\\' -and
    $_.FullName -notmatch '\\node_modules\\' -and
    $_.FullName -notmatch '\\build\\' -and
    $_.FullName -notmatch '\\out\\'
}

foreach ($buildSystem in $BuildMap.Keys) {

    foreach ($marker in $BuildMap[$buildSystem]) {

        $found = $false

        if ($marker.StartsWith('.')) {

            $found = $files |
                Where-Object {
                    $_.Extension -ieq $marker
                } |
                Select-Object -First 1
        }
        else {

            $found = $files |
                Where-Object {
                    $_.Name -ieq $marker
                } |
                Select-Object -First 1
        }

        if ($found) {

            $result += $buildSystem
            break
        }
    }
}

return $result