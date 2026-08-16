param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath,

    [Parameter(Mandatory = $true)]
    [hashtable]$ExtensionMap
)

$result = @{}

Get-ChildItem `
    -LiteralPath $RepositoryPath `
    -Recurse `
    -File `
    -ErrorAction SilentlyContinue |
Where-Object {
    $_.FullName -notmatch '\\.git\\' -and
    $_.FullName -notmatch '\\node_modules\\' -and
    $_.FullName -notmatch '\\build\\' -and
    $_.FullName -notmatch '\\out\\'
} |
ForEach-Object {

    $extension = $_.Extension.ToLowerInvariant()

    foreach ($language in $ExtensionMap.Keys) {

        if ($ExtensionMap[$language] -contains $extension) {

            if (-not $result.ContainsKey($language)) {
                $result[$language] = 0
            }

            $result[$language]++

            break
        }
    }
}

return $result