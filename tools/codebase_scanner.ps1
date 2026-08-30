param(
    [Parameter(Mandatory=$true)]
    [string]$RepoPath
)

# Language mapping by file extension
$LanguageMap = @{
    ".c"       = "C"
    ".h"       = "C/C++ Header"
    ".cpp"     = "C++"
    ".cc"      = "C++"
    ".cxx"     = "C++"
    ".hpp"     = "C++ Header"

    ".cs"      = "C#"
    ".java"    = "Java"
    ".py"      = "Python"
    ".js"      = "JavaScript"
    ".jsx"     = "JavaScript"
    ".ts"      = "TypeScript"
    ".tsx"     = "TypeScript"

    ".go"      = "Go"
    ".rs"      = "Rust"
    ".rb"      = "Ruby"
    ".php"     = "PHP"
    ".swift"   = "Swift"
    ".kt"      = "Kotlin"
    ".kts"     = "Kotlin"

    ".ps1"     = "PowerShell"
    ".bat"     = "Batch"
    ".cmd"     = "Batch"
    ".sh"      = "Shell"

    ".groovy"  = "Groovy"
    ".gradle"  = "Gradle"

    ".sql"     = "SQL"
    ".xml"     = "XML"
    ".json"    = "JSON"
    ".yaml"    = "YAML"
    ".yml"     = "YAML"

    ".html"    = "HTML"
    ".htm"     = "HTML"
    ".css"     = "CSS"
    ".scss"    = "SCSS"

    ".cmake"   = "CMake"
    ".make"    = "Makefile"
}

# Directories to ignore
$ExcludedDirectories = @(
    ".git",
    ".svn",
    ".hg",
    "node_modules",
    "bin",
    "obj",
    "build",
    "dist",
    "out",
    "target",
    ".vs",
    ".idea"
)

Write-Host "Scanning repository: $RepoPath"
Write-Host ""

$Files = Get-ChildItem `
    -Path $RepoPath `
    -File `
    -Recurse `
    -ErrorAction SilentlyContinue |
    Where-Object {
        $fullPath = $_.FullName

        $exclude = $false

        foreach ($dir in $ExcludedDirectories) {
            if ($fullPath -match "[\\/]$([regex]::Escape($dir))[\\/]") {
                $exclude = $true
                break
            }
        }

        -not $exclude
    }

$Results = @()

foreach ($File in $Files) {

    $Extension = $File.Extension.ToLower()

    if ($LanguageMap.ContainsKey($Extension)) {

        $Language = $LanguageMap[$Extension]

        $Results += [PSCustomObject]@{
            Language = $Language
            Extension = $Extension
            File = $File.FullName
            SizeKB = [math]::Round($File.Length / 1KB, 2)
        }
    }
}

if ($Results.Count -eq 0) {
    Write-Host "No recognized source files found."
    exit
}

# Summary
$Summary = $Results |
    Group-Object Language |
    ForEach-Object {

        $FileCount = $_.Count
        $TotalSize = ($_.Group | Measure-Object SizeKB -Sum).Sum

        [PSCustomObject]@{
            Language = $_.Name
            Files = $FileCount
            SizeMB = [math]::Round($TotalSize / 1024, 2)
            Percentage = [math]::Round(
                ($FileCount / $Results.Count) * 100,
                2
            )
        }
    } |
    Sort-Object Files -Descending

Write-Host "========================================"
Write-Host "Repository Language Summary"
Write-Host "========================================"

$Summary | Format-Table -AutoSize

Write-Host ""
Write-Host "Total recognized source files: $($Results.Count)"