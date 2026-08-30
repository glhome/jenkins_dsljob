[CmdletBinding()]
param(
    [string]$OutputDir = "$PSScriptRoot\LabVIEW-Server-Inventory"
)

$ErrorActionPreference = "Continue"

# ------------------------------------------------------------
# Initialization
# ------------------------------------------------------------

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$InventoryDir = Join-Path $OutputDir $timestamp

New-Item -ItemType Directory -Path $InventoryDir -Force | Out-Null

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " LabVIEW Build Server Inventory" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Output: $InventoryDir"
Write-Host ""

function Write-Json {
    param(
        [string]$Name,
        $Data
    )

    $path = Join-Path $InventoryDir $Name

    $Data |
        ConvertTo-Json -Depth 10 |
        Out-File -FilePath $path -Encoding UTF8

    Write-Host "Created: $Name"
}

function Write-Csv {
    param(
        [string]$Name,
        $Data
    )

    $path = Join-Path $InventoryDir $Name

    $Data |
        Export-Csv -Path $path -NoTypeInformation -Encoding UTF8

    Write-Host "Created: $Name"
}

# ------------------------------------------------------------
# System information
# ------------------------------------------------------------

Write-Host ""
Write-Host "[1] System information"

$ComputerInfo = Get-ComputerInfo |
    Select-Object `
        WindowsProductName,
        WindowsVersion,
        OsBuildNumber,
        OsArchitecture,
        CsName,
        CsManufacturer,
        CsModel,
        CsSystemType,
        CsProcessors,
        CsTotalPhysicalMemory,
        BiosManufacturer,
        BiosVersion,
        BiosReleaseDate

Write-Json "system.json" $ComputerInfo

# ------------------------------------------------------------
# Windows version
# ------------------------------------------------------------

$WindowsVersion = Get-ItemProperty `
    "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" |
    Select-Object `
        ProductName,
        DisplayVersion,
        CurrentBuild,
        CurrentBuildNumber,
        UBR

Write-Json "windows-version.json" $WindowsVersion

# ------------------------------------------------------------
# Installed Windows updates
# ------------------------------------------------------------

Write-Host "[2] Windows updates"

$Updates = Get-HotFix |
    Sort-Object InstalledOn -Descending |
    Select-Object `
        HotFixID,
        Description,
        InstalledBy,
        InstalledOn

Write-Csv "windows-updates.csv" $Updates

# ------------------------------------------------------------
# Environment variables
# ------------------------------------------------------------

Write-Host "[3] Environment variables"

$Environment = Get-ChildItem Env: |
    Sort-Object Name |
    Select-Object Name, Value

Write-Csv "environment.csv" $Environment

# ------------------------------------------------------------
# PATH
# ------------------------------------------------------------

$MachinePath = [Environment]::GetEnvironmentVariable(
    "Path",
    [EnvironmentVariableTarget]::Machine
)

$UserPath = [Environment]::GetEnvironmentVariable(
    "Path",
    [EnvironmentVariableTarget]::User
)

Write-Json "path.json" @{
    MachinePath = $MachinePath
    UserPath    = $UserPath
}

# ------------------------------------------------------------
# Installed software - 64-bit
# ------------------------------------------------------------

Write-Host "[4] Installed software"

$Software64 = Get-ItemProperty `
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } |
    Select-Object `
        DisplayName,
        DisplayVersion,
        Publisher,
        InstallDate,
        InstallLocation

# ------------------------------------------------------------
# Installed software - 32-bit
# ------------------------------------------------------------

$Software32 = Get-ItemProperty `
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } |
    Select-Object `
        DisplayName,
        DisplayVersion,
        Publisher,
        InstallDate,
        InstallLocation

$AllSoftware = @($Software64) + @($Software32) |
    Sort-Object DisplayName, DisplayVersion -Unique

Write-Csv "installed-software.csv" $AllSoftware

# ------------------------------------------------------------
# LabVIEW installations
# ------------------------------------------------------------

Write-Host "[5] LabVIEW installations"

$LabVIEWCandidates = @(
    "C:\Program Files\National Instruments",
    "C:\Program Files (x86)\National Instruments"
)

$LabVIEWInstallations = @()

foreach ($Root in $LabVIEWCandidates) {

    if (-not (Test-Path $Root)) {
        continue
    }

    Get-ChildItem $Root -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match "^LabVIEW"
        } |
        ForEach-Object {

            $LabVIEWRoot = $_.FullName

            $LabVIEWExe = Join-Path $LabVIEWRoot "LabVIEW.exe"

            $Architecture = if ($LabVIEWRoot -match "Program Files \(x86\)") {
                "32-bit"
            }
            else {
                "64-bit"
            }

            $Version = $null
            $FileVersion = $null

            if (Test-Path $LabVIEWExe) {

                $FileInfo = Get-Item $LabVIEWExe

                $Version = $FileInfo.VersionInfo.ProductVersion
                $FileVersion = $FileInfo.VersionInfo.FileVersion
            }

            $LabVIEWInstallations += [PSCustomObject]@{
                Architecture = $Architecture
                RootPath     = $LabVIEWRoot
                Executable   = $LabVIEWExe
                Exists       = Test-Path $LabVIEWExe
                ProductVersion = $Version
                FileVersion    = $FileVersion
            }
        }
}

Write-Csv "labview-installations.csv" $LabVIEWInstallations

# ------------------------------------------------------------
# LabVIEW executable details
# ------------------------------------------------------------

$LabVIEWDetails = @()

foreach ($LV in $LabVIEWInstallations) {

    if (Test-Path $LV.Executable) {

        $File = Get-Item $LV.Executable

        $LabVIEWDetails += [PSCustomObject]@{
            Architecture = $LV.Architecture
            Path         = $LV.Executable
            ProductName  = $File.VersionInfo.ProductName
            ProductVersion = $File.VersionInfo.ProductVersion
            FileVersion  = $File.VersionInfo.FileVersion
            CompanyName  = $File.VersionInfo.CompanyName
        }
    }
}

Write-Csv "labview-version.csv" $LabVIEWDetails

# ------------------------------------------------------------
# NI software
# ------------------------------------------------------------

Write-Host "[6] National Instruments software"

$NISoftware = $AllSoftware |
    Where-Object {
        $_.Publisher -match "National Instruments" -or
        $_.DisplayName -match "\bNI\b|National Instruments|LabVIEW"
    }

Write-Csv "ni-software.csv" $NISoftware

# ------------------------------------------------------------
# NI Package Manager
# ------------------------------------------------------------

Write-Host "[7] NI Package Manager"

$NIPackageManagerPaths = @(
    "C:\Program Files\National Instruments\NI Package Manager",
    "C:\Program Files (x86)\National Instruments\NI Package Manager"
)

$NIPackageManager = @()

foreach ($Path in $NIPackageManagerPaths) {

    if (Test-Path $Path) {

        $NIPackageManager += [PSCustomObject]@{
            Path = $Path
            Exists = $true
        }
    }
}

Write-Csv "ni-package-manager.csv" $NIPackageManager

# ------------------------------------------------------------
# NI package list
# ------------------------------------------------------------

$NIPkgExe = @(
    "C:\Program Files\National Instruments\NI Package Manager\nipkg.exe",
    "C:\Program Files (x86)\National Instruments\NI Package Manager\nipkg.exe"
) |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1

if ($NIPkgExe) {

    Write-Host "Found nipkg.exe: $NIPkgExe"

    try {

        $PackageList = & $NIPkgExe list 2>&1

        $PackageList |
            Out-File `
                (Join-Path $InventoryDir "ni-packages.txt") `
                -Encoding UTF8
    }
    catch {

        "Unable to query NI packages: $($_.Exception.Message)" |
            Out-File `
                (Join-Path $InventoryDir "ni-packages.txt") `
                -Encoding UTF8
    }
}
else {

    "nipkg.exe was not found." |
        Out-File `
            (Join-Path $InventoryDir "ni-packages.txt") `
            -Encoding UTF8
}

# ------------------------------------------------------------
# VIPM
# ------------------------------------------------------------

Write-Host "[8] VIPM"

$VIPMPaths = @(
    "C:\Program Files\JKI\VI Package Manager",
    "C:\Program Files (x86)\JKI\VI Package Manager"
)

$VIPM = @()

foreach ($Path in $VIPMPaths) {

    if (Test-Path $Path) {

        $VIPM += [PSCustomObject]@{
            Path = $Path
            Exists = $true
        }
    }
}

Write-Csv "vipm-installation.csv" $VIPM

# ------------------------------------------------------------
# Visual Studio
# ------------------------------------------------------------

Write-Host "[9] Visual Studio / Build Tools"

$VSWhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"

if (Test-Path $VSWhere) {

    try {

        $VSInfo = & $VSWhere `
            -products * `
            -format json `
            -utf8

        $VSInfo |
            Out-File `
                (Join-Path $InventoryDir "visual-studio.json") `
                -Encoding UTF8
    }
    catch {

        "Unable to query Visual Studio." |
            Out-File `
                (Join-Path $InventoryDir "visual-studio.json") `
                -Encoding UTF8
    }
}
else {

    "vswhere.exe not found." |
        Out-File `
            (Join-Path $InventoryDir "visual-studio.json") `
            -Encoding UTF8
}

# ------------------------------------------------------------
# MSBuild
# ------------------------------------------------------------

$MSBuildPaths = @(
    "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
    "C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe",
    "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
)

$MSBuildInfo = @()

foreach ($Path in $MSBuildPaths) {

    if (Test-Path $Path) {

        $File = Get-Item $Path

        $MSBuildInfo += [PSCustomObject]@{
            Path = $Path
            Version = $File.VersionInfo.ProductVersion
        }
    }
}

Write-Csv "msbuild.csv" $MSBuildInfo

# ------------------------------------------------------------
# Git
# ------------------------------------------------------------

Write-Host "[10] Git"

$Git = Get-Command git.exe -ErrorAction SilentlyContinue

if ($Git) {

    $GitVersion = & git --version

    Write-Json "git.json" @{
        Path = $Git.Source
        Version = $GitVersion
    }
}

# ------------------------------------------------------------
# Java
# ------------------------------------------------------------

Write-Host "[11] Java"

$Java = Get-Command java.exe -ErrorAction SilentlyContinue

if ($Java) {

    $JavaVersion = & java -version 2>&1

    Write-Json "java.json" @{
        Path = $Java.Source
        Version = ($JavaVersion -join "`n")
    }
}

# ------------------------------------------------------------
# Python
# ------------------------------------------------------------

Write-Host "[12] Python"

$Python = Get-Command python.exe -ErrorAction SilentlyContinue

if ($Python) {

    $PythonVersion = & python --version 2>&1

    Write-Json "python.json" @{
        Path = $Python.Source
        Version = $PythonVersion
    }
}

# ------------------------------------------------------------
# PowerShell
# ------------------------------------------------------------

Write-Json "powershell.json" @{
    Version = $PSVersionTable
}

# ------------------------------------------------------------
# Windows optional features
# ------------------------------------------------------------

Write-Host "[13] Windows features"

$Features = Get-WindowsOptionalFeature -Online |
    Select-Object FeatureName, State

Write-Csv "windows-features.csv" $Features

# ------------------------------------------------------------
# Services
# ------------------------------------------------------------

Write-Host "[14] Services"

$Services = Get-Service |
    Sort-Object Name |
    Select-Object Name, DisplayName, Status, StartType

Write-Csv "services.csv" $Services

# ------------------------------------------------------------
# Scheduled tasks
# ------------------------------------------------------------

Write-Host "[15] Scheduled tasks"

try {

    $Tasks = Get-ScheduledTask |
        Select-Object `
            TaskName,
            TaskPath,
            State

    Write-Csv "scheduled-tasks.csv" $Tasks
}
catch {
    Write-Warning "Unable to collect scheduled tasks."
}

# ------------------------------------------------------------
# Local users/groups
# ------------------------------------------------------------

Write-Host "[16] Local users and groups"

try {

    $Users = Get-LocalUser |
        Select-Object Name, Enabled, Description, LastLogon

    Write-Csv "local-users.csv" $Users

    $Groups = Get-LocalGroup |
        Select-Object Name, Description

    Write-Csv "local-groups.csv" $Groups
}
catch {
    Write-Warning "Unable to collect local users/groups."
}

# ------------------------------------------------------------
# Network configuration
# ------------------------------------------------------------

Write-Host "[17] Network configuration"

$Network = Get-NetIPConfiguration |
    Select-Object `
        InterfaceAlias,
        InterfaceIndex,
        IPv4Address,
        IPv6Address,
        IPv4DefaultGateway,
        DNSServer

Write-Json "network.json" $Network

# ------------------------------------------------------------
# Drives
# ------------------------------------------------------------

Write-Host "[18] Drives"

$Drives = Get-PSDrive -PSProvider FileSystem |
    Select-Object `
        Name,
        Root,
        Used,
        Free

Write-Csv "drives.csv" $Drives

# ------------------------------------------------------------
# Jenkins
# ------------------------------------------------------------

Write-Host "[19] Jenkins"

$JenkinsServices = Get-Service -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -match "jenkins" -or
        $_.DisplayName -match "jenkins"
    } |
    Select-Object Name, DisplayName, Status, StartType

Write-Csv "jenkins-services.csv" $JenkinsServices

$JenkinsDirectories = @(
    "C:\Program Files\Jenkins",
    "C:\ProgramData\Jenkins",
    "C:\Jenkins"
)

$ExistingJenkinsDirs = $JenkinsDirectories |
    Where-Object { Test-Path $_ } |
    ForEach-Object {
        [PSCustomObject]@{
            Path = $_
            Exists = $true
        }
    }

Write-Csv "jenkins-directories.csv" $ExistingJenkinsDirs

# ------------------------------------------------------------
# LabVIEW configuration directories
# ------------------------------------------------------------

Write-Host "[20] LabVIEW configuration directories"

$LVConfigDirs = @()

foreach ($LV in $LabVIEWInstallations) {

    $Root = $LV.RootPath

    $LVConfigDirs += Get-ChildItem `
        $Root `
        -Directory `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match "config|plugins|resource"
        } |
        Select-Object FullName
}

Write-Csv "labview-config-directories.csv" $LVConfigDirs

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

$Summary = [PSCustomObject]@{
    ComputerName = $env:COMPUTERNAME
    CollectionTime = Get-Date
    InventoryDirectory = $InventoryDir
    LabVIEWInstallations = $LabVIEWInstallations.Count
    LabVIEW32Bit = @(
        $LabVIEWInstallations |
        Where-Object Architecture -eq "32-bit"
    ).Count
    LabVIEW64Bit = @(
        $LabVIEWInstallations |
        Where-Object Architecture -eq "64-bit"
    ).Count
    InstalledSoftwareCount = $AllSoftware.Count
    NIsoftwareCount = $NISoftware.Count
    WindowsVersion = $WindowsVersion.DisplayVersion
    WindowsBuild = $WindowsVersion.CurrentBuild
}

Write-Json "inventory-summary.json" $Summary

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " Inventory complete" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Inventory directory:"
Write-Host $InventoryDir -ForegroundColor Yellow
Write-Host ""