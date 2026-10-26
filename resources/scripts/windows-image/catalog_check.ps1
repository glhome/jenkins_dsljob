$ErrorActionPreference = 'Stop'
$SelectionMode = 'Latest'

if (-not (Get-Module -ListAvailable -Name OSD)) {
Install-Module OSD -Scope CurrentUser -Force
}
Import-Module OSD -ErrorAction Stop

$queries = [ordered]@{
LCU   = 'Windows 10 Version 21H2 x64 cumulative update'
SSU   = 'Windows 10 Version 21H2 x64 servicing stack update'
NET48 = 'Windows 10 Version 21H2 x64 .NET Framework 4.8 cumulative update'
}

$now = Get-Date
$currentMonth = Get-Date -Year $now.Year -Month $now.Month -Day 1

foreach ($type in $queries.Keys) {
Write-Host "`n========== $type ==========" -ForegroundColor Cyan
Write-Host "Query: $($queries[$type])"
Write-Host "Selection mode: $SelectionMode"

try {
    $results = @(Get-MsUpCat -Search $queries[$type])

    # Filter each query to its intended update category.
    $candidates = foreach ($item in $results) {
        $title = [string]$item.Title
        $classification = [string]$item.Classification

        if ($classification -notmatch 'Security Updates') {
            continue
        }

        $matchesCategory = switch ($type) {
            'LCU' {
                ($title -match 'Cumulative Update for Windows 10 Version 21H2') -and
                ($title -notmatch '\.NET Framework') -and
                ($title -notmatch '\bPreview\b')
            }
            'SSU' {
                $title -match 'Servicing Stack Update for Windows 10 Version 21H2'
            }
            'NET48' {
                ($title -match '\.NET Framework 3\.5 and 4\.8') -and
                ($title -match 'Windows 10 Version 21H2') -and
                ($title -match 'x64')
            }
        }

        if (-not $matchesCategory) {
            continue
        }

        # Catalog titles commonly start with YYYY-MM.
        # Use that release month instead of the record's LastUpdated date.
        $releaseMonth = $null
        if ($title -match '^(?<Year>20\d{2})-(?<Month>0[1-9]|1[0-2])\b') {
            $releaseMonth = [datetime]::new(
                [int]$Matches.Year,
                [int]$Matches.Month,
                1
            )
        }

        [pscustomobject]@{
            Item         = $item
            ReleaseMonth = $releaseMonth
            LastUpdated  = [datetime]$item.LastUpdated
            Title        = $title
        }
    }

    $candidates = @($candidates)

    if ($SelectionMode -eq 'CurrentMonth') {
        $candidates = @(
            $candidates | Where-Object {
                $_.ReleaseMonth -eq $currentMonth
            }
        )
    }

    if ($candidates.Count -eq 0) {
        Write-Warning "No matching security update found for $type in mode '$SelectionMode'."
        continue
    }

    # Prefer the newest release month; use LastUpdated to break ties.
    $selected = $candidates |
        Sort-Object `
            @{ Expression = {
                if ($_.ReleaseMonth) { $_.ReleaseMonth }
                else { [datetime]::MinValue }
            }; Descending = $true },
            @{ Expression = { $_.LastUpdated }; Descending = $true } |
        Select-Object -First 1

    $item = $selected.Item

    $kb = if ($item.Title -match '\((KB\d+)\)') {
        $Matches[1]
    } else {
        'KB not found in title'
    }

    [pscustomobject]@{
        Category       = $type
        ReleaseMonth   = if ($selected.ReleaseMonth) {
            $selected.ReleaseMonth.ToString('yyyy-MM')
        } else {
            'Unknown'
        }
        KB             = $kb
        Title          = $item.Title
        Products       = $item.Products
        Classification = $item.Classification
        LastUpdated    = $item.LastUpdated
        Size           = $item.Size
        Guid           = $item.Guid
    } | Format-List

    Write-Host "Matching candidates: $($candidates.Count)"
}
catch {
    Write-Warning "Query failed for ${type}: $($_.Exception.Message)"
}

}