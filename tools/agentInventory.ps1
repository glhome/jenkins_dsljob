#Requires -Version 5.1

<#
.SYNOPSIS
    Inventory a Windows Jenkins build agent for migration to Docker.

.DESCRIPTION
    Read-only inventory collection for:
      - OS / hardware
      - Installed applications
      - Machine/User environment variables
      - PATH
      - Windows services
      - Windows optional features
      - PowerShell modules
      - Python packages
      - Java / .NET
      - Visual Studio / MSBuild
      - Qt
      - CMake
      - Conan
      - Git
      - 7-Zip
      - Jenkins agent information
      - Drivers
      - Scheduled tasks
      - Common build directories

    Output is written to a timestamped directory.

.NOTES
    Run as Administrator for the most complete inventory.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ComputerName = $env:COMPUTERNAME

$OutputRoot = Join-Path $PWD "jenkins-agent-inventory"
$OutputDir  = Join-Path $OutputRoot "$ComputerName-$Timestamp"

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$Inventory = [ordered]@{
    ComputerName = $ComputerName
    Timestamp    = (Get-Date).ToString("o")
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " Jenkins Windows Agent Inventory" -ForegroundColor Cyan
Write-Host " Computer : $ComputerName" -ForegroundColor Cyan
Write-Host " Output   : $OutputDir" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]
        $Data,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
}

function Write-CsvFile {
    param(
        [Parameter(Mandatory)]
        $Data,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($null -ne $Data) {
        $Data | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    }
}

function Get-CommandInfo {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string[]]$Arguments = @("--version")
    )

    $result = [ordered]@{
        Name      = $Name
        Found     = $false
        Path      = $null
        Version   = $null
        Output    = $null
    }

    try {
        $cmd = Get-Command $Name -ErrorAction Stop

        $result.Found = $true
        $result.Path  = $cmd.Source

        try {
            $output = & $Name @Arguments 2>&1 |
                Out-String

            $result.Output = $output.Trim()

            $firstLine = ($output -split "`r?`n" |
                Where-Object { $_.Trim() -ne "" } |
                Select-Object -First 1)

            $result.Version = $firstLine.Trim()
        }
        catch {
        }
    }
    catch {
    }

    return [PSCustomObject]$result
}

# ----------------------------------------------------------------------
# 1. Operating System
# ----------------------------------------------------------------------

Write-Host "[1/20] OS information..."

$OS = Get-CimInstance Win32_OperatingSystem

$OsInfo = [ordered]@{
    ComputerName    = $ComputerName
    Caption         = $OS.Caption
    Version         = $OS.Version
    BuildNumber     = $OS.BuildNumber
    Architecture    = $OS.OSArchitecture
    InstallDate     = $OS.InstallDate
    LastBoot        = $OS.LastBootUpTime
    SerialNumber    = $OS.SerialNumber
}

$Inventory.OS = $OsInfo

Write-JsonFile $OsInfo "$OutputDir\os.json"

# ----------------------------------------------------------------------
# 2. Hardware
# ----------------------------------------------------------------------

Write-Host "[2/20] Hardware..."

$ComputerSystem = Get-CimInstance Win32_ComputerSystem
$Processor = Get-CimInstance Win32_Processor |
    Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed
$Memory = Get-CimInstance Win32_PhysicalMemory |
    Select-Object Manufacturer, Capacity, Speed, PartNumber
$Disk = Get-CimInstance Win32_LogicalDisk |
    Select-Object DeviceID, FileSystem, Size, FreeSpace, VolumeName

$Hardware = [ordered]@{
    ComputerSystem = $ComputerSystem
    Processor      = $Processor
    Memory         = $Memory
    Disk           = $Disk
}

Write-JsonFile $Hardware "$OutputDir\hardware.json"

# ----------------------------------------------------------------------
# 3. Installed Applications
# ----------------------------------------------------------------------

Write-Host "[3/20] Installed applications..."

$UninstallPaths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

$Applications = foreach ($Path in $UninstallPaths) {

    Get-ItemProperty $Path |
        Where-Object {
            $_.DisplayName
        } |
        Select-Object `
            DisplayName,
            DisplayVersion,
            Publisher,
            InstallDate,
            InstallLocation,
            UninstallString,
            QuietUninstallString,
            PSPath
}

$Applications = $Applications |
    Sort-Object DisplayName, DisplayVersion -Unique

Write-CsvFile $Applications "$OutputDir\applications.csv"

# ----------------------------------------------------------------------
# 4. Environment Variables
# ----------------------------------------------------------------------

Write-Host "[4/20] Environment variables..."

$MachineEnvironment =
    [Environment]::GetEnvironmentVariables("Machine")

$UserEnvironment =
    [Environment]::GetEnvironmentVariables("User")

$ProcessEnvironment =
    [Environment]::GetEnvironmentVariables("Process")

$Environment = [ordered]@{
    Machine = @{}
    User    = @{}
    Process = @{}
}

foreach ($key in $MachineEnvironment.Keys) {
    $Environment.Machine[$key] = $MachineEnvironment[$key]
}

foreach ($key in $UserEnvironment.Keys) {
    $Environment.User[$key] = $UserEnvironment[$key]
}

foreach ($key in $ProcessEnvironment.Keys) {
    $Environment.Process[$key] = $ProcessEnvironment[$key]
}

Write-JsonFile $Environment "$OutputDir\environment.json"

# ----------------------------------------------------------------------
# 5. PATH
# ----------------------------------------------------------------------

Write-Host "[5/20] PATH..."

$MachinePath =
    [Environment]::GetEnvironmentVariable("Path", "Machine")

$UserPath =
    [Environment]::GetEnvironmentVariable("Path", "User")

$PathInfo = [ordered]@{
    MachinePath = $MachinePath
    UserPath    = $UserPath

    MachineEntries = @(
        $MachinePath -split ";" |
            Where-Object { $_ -and $_.Trim() }
    )

    UserEntries = @(
        $UserPath -split ";" |
            Where-Object { $_ -and $_.Trim() }
    )
}

Write-JsonFile $PathInfo "$OutputDir\path.json"

# ----------------------------------------------------------------------
# 6. Windows Services
# ----------------------------------------------------------------------

Write-Host "[6/20] Services..."

$Services = Get-CimInstance Win32_Service |
    Select-Object `
        Name,
        DisplayName,
        State,
        StartMode,
        StartName,
        PathName,
        Description

Write-CsvFile $Services "$OutputDir\services.csv"

# ----------------------------------------------------------------------
# 7. Windows Features
# ----------------------------------------------------------------------

Write-Host "[7/20] Windows features..."

try {
    $Features = Get-WindowsOptionalFeature -Online |
        Select-Object FeatureName, State
}
catch {
    $Features = Get-WmiObject Win32_OptionalFeature |
        Select-Object Name, InstallState
}

Write-CsvFile $Features "$OutputDir\windows-features.csv"

# ----------------------------------------------------------------------
# 8. PowerShell Modules
# ----------------------------------------------------------------------

Write-Host "[8/20] PowerShell modules..."

$Modules = Get-Module -ListAvailable |
    Select-Object Name, Version, Path, ModuleBase

Write-CsvFile $Modules "$OutputDir\powershell-modules.csv"

# ----------------------------------------------------------------------
# 9. Python
# ----------------------------------------------------------------------

Write-Host "[9/20] Python..."

$PythonInfo = @()

$PythonInfo += Get-CommandInfo "python" @("--version")
$PythonInfo += Get-CommandInfo "python3" @("--version")
$PythonInfo += Get-CommandInfo "pip" @("--version")
$PythonInfo += Get-CommandInfo "pip3" @("--version")

Write-JsonFile $PythonInfo "$OutputDir\python.json"

try {
    $PythonPackages =
        python -m pip list --format=json 2>&1

    $PythonPackages |
        Set-Content "$OutputDir\python-packages.json"
}
catch {
}

# ----------------------------------------------------------------------
# 10. Java / .NET
# ----------------------------------------------------------------------

Write-Host "[10/20] Java / .NET..."

$RuntimeInfo = @()

$RuntimeInfo += Get-CommandInfo "java" @("-version")
$RuntimeInfo += Get-CommandInfo "javac" @("-version")
$RuntimeInfo += Get-CommandInfo "dotnet" @("--info")
$RuntimeInfo += Get-CommandInfo "msbuild" @("-version")

Write-JsonFile $RuntimeInfo "$OutputDir\runtimes.json"

try {
    dotnet --list-sdks |
        Set-Content "$OutputDir\dotnet-sdks.txt"
}
catch {
}

try {
    dotnet --list-runtimes |
        Set-Content "$OutputDir\dotnet-runtimes.txt"
}
catch {
}

# ----------------------------------------------------------------------
# 11. Visual Studio
# ----------------------------------------------------------------------

Write-Host "[11/20] Visual Studio..."

$VSWhereCandidates = @(
    "$env:ProgramFiles(x86)\Microsoft Visual Studio\Installer\vswhere.exe",
    "$env:ProgramFiles\Microsoft Visual Studio\Installer\vswhere.exe"
)

$VSWhere = $VSWhereCandidates |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1

$VisualStudio = @()

if ($VSWhere) {

    try {
        $VisualStudio =
            & $VSWhere `
                -all `
                -products * `
                -format json 2>$null

        $VisualStudio |
            Set-Content "$OutputDir\visual-studio.json"
    }
    catch {
    }
}

# Search common MSBuild locations
$MSBuildPaths = @()

$MSBuildPaths += Get-ChildItem `
    "$env:ProgramFiles\Microsoft Visual Studio" `
    -Filter MSBuild.exe `
    -Recurse `
    -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName

$MSBuildPaths += Get-ChildItem `
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio" `
    -Filter MSBuild.exe `
    -Recurse `
    -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName

$MSBuildPaths |
    Sort-Object -Unique |
    Set-Content "$OutputDir\msbuild-paths.txt"

# ----------------------------------------------------------------------
# 12. Qt
# ----------------------------------------------------------------------

Write-Host "[12/20] Qt..."

$QtCandidates = @(
    "$env:ProgramFiles\Qt",
    "$env:USERPROFILE\Qt",
    "C:\Qt",
    "C:\qt"
)

$QtDirectories = @()

foreach ($Path in $QtCandidates) {
    if (Test-Path $Path) {
        $QtDirectories += Get-ChildItem $Path -Directory |
            Select-Object FullName, Name, LastWriteTime
    }
}

Write-JsonFile $QtDirectories "$OutputDir\qt.json"

# ----------------------------------------------------------------------
# 13. Build Tools
# ----------------------------------------------------------------------

Write-Host "[13/20] Build tools..."

$Tools = @()

$Tools += Get-CommandInfo "git"
$Tools += Get-CommandInfo "cmake" @("--version")
$Tools += Get-CommandInfo "conan" @("--version")
$Tools += Get-CommandInfo "7z" @()
$Tools += Get-CommandInfo "powershell" @("-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()")
$Tools += Get-CommandInfo "pwsh" @("--version")
$Tools += Get-CommandInfo "ninja" @("--version")
$Tools += Get-CommandInfo "make" @("--version")

Write-JsonFile $Tools "$OutputDir\build-tools.json"

# ----------------------------------------------------------------------
# 14. Common Executables
# ----------------------------------------------------------------------

Write-Host "[14/20] Executable discovery..."

$ExecutableNames = @(
    "git.exe",
    "cmake.exe",
    "conan.exe",
    "7z.exe",
    "msbuild.exe",
    "cl.exe",
    "nmake.exe",
    "ninja.exe",
    "qmake.exe",
    "windeployqt.exe",
    "python.exe",
    "java.exe",
    "javac.exe",
    "dotnet.exe"
)

$ExecutableInventory = foreach ($Name in $ExecutableNames) {

    $Matches = Get-Command $Name -All -ErrorAction SilentlyContinue

    foreach ($Match in $Matches) {

        [PSCustomObject]@{
            Name   = $Name
            Path   = $Match.Source
            CommandType = $Match.CommandType
        }
    }
}

Write-CsvFile `
    ($ExecutableInventory | Sort-Object Name, Path -Unique) `
    "$OutputDir\executables.csv"

# ----------------------------------------------------------------------
# 15. Jenkins
# ----------------------------------------------------------------------

Write-Host "[15/20] Jenkins..."

$JenkinsInfo = [ordered]@{
    ComputerName = $ComputerName

    JenkinsHome = $env:JENKINS_HOME

    JenkinsAgentName = $env:NODE_NAME

    JenkinsWorkspace = $env:WORKSPACE

    JenkinsUrl = $env:JENKINS_URL

    ExecutorNumber = $env:EXECUTOR_NUMBER

    JavaHome = $env:JAVA_HOME

    AgentWorkDir = $env:JENKINS_AGENT_WORKDIR

    UserProfile = $env:USERPROFILE

    CurrentDirectory = (Get-Location).Path
}

Write-JsonFile $JenkinsInfo "$OutputDir\jenkins.json"

# ----------------------------------------------------------------------
# 16. Scheduled Tasks
# ----------------------------------------------------------------------

Write-Host "[16/20] Scheduled tasks..."

try {

    $Tasks = Get-ScheduledTask |
        Select-Object `
            TaskName,
            TaskPath,
            State,
            Author,
            Description

    Write-CsvFile $Tasks "$OutputDir\scheduled-tasks.csv"
}
catch {
}

# ----------------------------------------------------------------------
# 17. Drivers
# ----------------------------------------------------------------------

Write-Host "[17/20] Drivers..."

try {

    $Drivers = Get-CimInstance Win32_PnPSignedDriver |
        Select-Object `
            DeviceName,
            Manufacturer,
            DriverVersion,
            DriverDate,
            InfName,
            IsSigned

    Write-CsvFile $Drivers "$OutputDir\drivers.csv"
}
catch {
}

# ----------------------------------------------------------------------
# 18. Network Configuration
# ----------------------------------------------------------------------

Write-Host "[18/20] Network..."

try {

    Get-NetAdapter |
        Select-Object `
            Name,
            InterfaceDescription,
            Status,
            MacAddress,
            LinkSpeed |
        Export-Csv `
            "$OutputDir\network-adapters.csv" `
            -NoTypeInformation

    Get-NetIPConfiguration |
        Format-List * |
        Out-File "$OutputDir\network-configuration.txt"
}
catch {
}

# ----------------------------------------------------------------------
# 19. Important directories
# ----------------------------------------------------------------------

Write-Host "[19/20] Build directories..."

$DirectoryCandidates = @(
    "C:\Program Files",
    "C:\Program Files (x86)",
    "C:\ProgramData",
    "C:\Qt",
    "C:\BuildTools",
    "C:\Tools",
    "C:\Jenkins",
    "C:\JenkinsAgent",
    "C:\workspace",
    "C:\src",
    "C:\dev",
    "$env:USERPROFILE\.conan",
    "$env:USERPROFILE\.conan2",
    "$env:USERPROFILE\.nuget",
    "$env:USERPROFILE\.m2",
    "$env:USERPROFILE\.gradle"
)

$Directories = foreach ($Path in $DirectoryCandidates) {

    if (Test-Path $Path) {

        $Item = Get-Item $Path

        [PSCustomObject]@{
            Path          = $Item.FullName
            Exists        = $true
            LastWriteTime = $Item.LastWriteTime
        }
    }
}

Write-CsvFile $Directories "$OutputDir\directories.csv"

# ----------------------------------------------------------------------
# 20. Registry / Windows build information
# ----------------------------------------------------------------------

Write-Host "[20/20] Registry/build information..."

$BuildInfo = [ordered]@{}

$BuildInfo.WindowsCurrentVersion =
    Get-ItemProperty `
        "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" |
    Select-Object `
        ProductName,
        DisplayVersion,
        CurrentBuild,
        CurrentBuildNumber,
        UBR,
        EditionID

$BuildInfo.RegistryEnvironment =
    Get-ItemProperty `
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"

Write-JsonFile $BuildInfo "$OutputDir\windows-build.json"

# ----------------------------------------------------------------------
# Generate summary
# ----------------------------------------------------------------------

$InventorySummary = [ordered]@{

    ComputerName = $ComputerName

    Timestamp = (Get-Date).ToString("o")

    OS = $OS.Caption

    OSVersion = $OS.Version

    InstalledApplications =
        @($Applications).Count

    Services =
        @($Services).Count

    WindowsFeatures =
        @($Features).Count

    PowerShellModules =
        @($Modules).Count

    VisualStudioFound =
        [bool]$VSWhere

    MSBuildExecutables =
        @($MSBuildPaths | Sort-Object -Unique).Count

    ExecutablesFound =
        @($ExecutableInventory).Count

    QtDirectories =
        @($QtDirectories).Count
}

Write-JsonFile `
    $InventorySummary `
    "$OutputDir\inventory-summary.json"

# ----------------------------------------------------------------------
# Create a human-readable report
# ----------------------------------------------------------------------

$Report = @"

============================================================
 Jenkins Windows Agent Inventory
============================================================

Computer       : $ComputerName
Timestamp      : $(Get-Date)

OS             : $($OS.Caption)
Version        : $($OS.Version)
Build          : $($OS.BuildNumber)

Installed Apps : $(@($Applications).Count)
Services       : $(@($Services).Count)
Features       : $(@($Features).Count)
PS Modules     : $(@($Modules).Count)

Visual Studio  : $([bool]$VSWhere)
MSBuild Paths  : $(@($MSBuildPaths | Sort-Object -Unique).Count)
Executables    : $(@($ExecutableInventory).Count)
Qt Locations   : $(@($QtDirectories).Count)

------------------------------------------------------------
Important Jenkins Variables
------------------------------------------------------------

JENKINS_HOME          = $env:JENKINS_HOME
NODE_NAME             = $env:NODE_NAME
WORKSPACE             = $env:WORKSPACE
JENKINS_URL           = $env:JENKINS_URL
JENKINS_AGENT_WORKDIR = $env:JENKINS_AGENT_WORKDIR
JAVA_HOME             = $env:JAVA_HOME

------------------------------------------------------------
Output
------------------------------------------------------------

$OutputDir

============================================================
"@

$Report |
    Set-Content "$OutputDir\REPORT.txt" -Encoding UTF8

# ----------------------------------------------------------------------
# ZIP everything
# ----------------------------------------------------------------------

$ZipFile =
    Join-Path `
        $OutputRoot `
        "$ComputerName-$Timestamp.zip"

Compress-Archive `
    -Path "$OutputDir\*" `
    -DestinationPath $ZipFile `
    -Force

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host " Inventory complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Directory:" -ForegroundColor Yellow
Write-Host " $OutputDir"
Write-Host ""
Write-Host "ZIP:" -ForegroundColor Yellow
Write-Host " $ZipFile"
Write-Host "==============================================" -ForegroundColor Green
Write-Host ""