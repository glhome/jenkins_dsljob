param(
    [Parameter(Mandatory = $true)]
    [string]$BitbucketUrl,

    [Parameter(Mandatory = $true)]
    [string]$ProjectKey,

    [Parameter(Mandatory = $true)]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [string]$Password
)

$pair = "$Username`:$Password"
$base64Auth = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes($pair)
)

$headers = @{
    Authorization = "Basic $base64Auth"
    Accept        = "application/json"
}

function Invoke-BitbucketApi {
    param(
        [string]$Uri
    )

    Invoke-RestMethod `
        -Uri $Uri `
        -Headers $headers `
        -Method Get
}

# ------------------------------------------------------------
# Get all repositories in the project
# ------------------------------------------------------------

$repos = @()
$start = 0
$limit = 100

do {
    $url = "$BitbucketUrl/rest/api/1.0/projects/$ProjectKey/repos?limit=$limit&start=$start"

    Write-Host "Getting repositories: $url"

    $response = Invoke-BitbucketApi -Uri $url

    $repos += $response.values

    $start += $response.values.Count

} while (-not $response.isLastPage)

Write-Host ""
Write-Host "Found $($repos.Count) repositories"
Write-Host ""

# ------------------------------------------------------------
# Get tags for every repository
# ------------------------------------------------------------

$results = @()

foreach ($repo in $repos) {

    Write-Host "==================================================" -ForegroundColor DarkGray
    Write-Host "Repository: $($repo.name)" -ForegroundColor Cyan
    Write-Host "Slug     : $($repo.slug)" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor DarkGray

    $tags = @()
    $start = 0

    do {
        $tagUrl =
            "$BitbucketUrl/rest/api/1.0/projects/$ProjectKey/repos/$($repo.slug)/tags" +
            "?limit=$limit&start=$start"

        $tagResponse = Invoke-BitbucketApi -Uri $tagUrl

        $tags += $tagResponse.values

        $start += $tagResponse.values.Count

    } while (-not $tagResponse.isLastPage)

    if ($tags.Count -eq 0) {
        Write-Host "  No tags found"
        continue
    }

    foreach ($tag in $tags) {

        Write-Host "  $($tag.displayId)"

        $results += [PSCustomObject]@{
            Project     = $ProjectKey
            Repository  = $repo.name
            RepoSlug    = $repo.slug
            Tag         = $tag.displayId
            Commit      = $tag.latestCommit
        }
    }

    Write-Host "  Total tags: $($tags.Count)"
    Write-Host ""
}

# ------------------------------------------------------------
# Export
# ------------------------------------------------------------

$output = ".\bitbucket-tags.csv"

$results |
    Sort-Object Repository, Tag |
    Export-Csv $output -NoTypeInformation

Write-Host ""
Write-Host "============================================"
Write-Host "Completed"
Write-Host "Repositories : $($repos.Count)"
Write-Host "Tags         : $($results.Count)"
Write-Host "CSV          : $((Resolve-Path $output).Path)"
Write-Host "============================================"