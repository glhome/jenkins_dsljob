```powershell
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Installs and verifies the Windows Jenkins build environment.

.DESCRIPTION
    Installs:
      - Visual Studio 2022 Enterprise
      - Qt 6.8.1 MSVC 2022 x64
      - Git
      - 7-Zip
      - CMake
      - Ninja
      - Python
      - Conan 2
      - JFrog CLI

    Designed for:
      - Jenkins Windows build agents
      - Packer Windows images
      - AWS EC2 Windows build machines

.NOTES
    Run from an elevated PowerShell session.

    For a fully reproducible build image, pin the versions below
    and preferably host installers in your internal Artifactory.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# CONFIGURATION
# ============================================================

$Config = @{
    # --------------------------------------------------------
    # Visual Studio
    # --------------------------------------------------------
    VS = @{
        Edition      = "Enterprise"
        InstallPath  = "C:\Program Files\Microsoft Visual Studio\2022\Enterprise"

        Bootstrapper = "https://aka.ms/vs/17/release/vs_enterprise.exe"

        Workloads = @(
            "Microsoft.VisualStudio.Workload.NativeDesktop"
        )

        Components = @(
            "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
            "Microsoft.VisualStudio.Component.VC.CMake.Project"
            "Microsoft.VisualStudio.Component.VC.v141"
            "Microsoft.VisualStudio.Component.Windows11SDK.22621"
        )
    }

    # --------------------------------------------------------
    # Qt
    # --------------------------------------------------------
    Qt = @{
        Version         = "6.8.1"
        Component       = "qt.qt6.681.win64_msvc2022_64"

        InstallRoot     = "C:\Qt"

        # Set this to your internal Qt installer when possible.
        #
        # Example:
        # Installer = "\\server\software\qt\qt-unified-windows-x64-online.exe"
        #
        # Or:
        # Installer = "C:\Installers\qt-unified-windows-x64-online.exe"
        #
        Installer       = $null

        InstallerUrl    = $null
    }

    # --------------------------------------------------------
    # Conan
    # --------------------------------------------------------
    Conan = @{
        Version = "2.*"
    }

    # --------------------------------------------------------
    # JFrog CLI
    # --------------------------------------------------------
    JFrog = @{
        # Set to a specific version for reproducible builds.
        #
        # Example:
        # Version = "2.88.0"
        #
        # $null = latest
        Version = $null

        InstallPath = "C:\Program Files\JFrog"
    }

    # --------------------------------------------------------
    # Working directory
    # --------------------------------------------------------
    WorkRoot = "C:\BuildTools"
}


# ============================================================
# LOGGING
# ============================================================

$LogRoot = Join-Path $Config.WorkRoot "logs"

New-Item `
    -ItemType Directory `
    -Path $LogRoot `
    -Force | Out-Null

$LogFile = Join-Path `
    $LogRoot `
    ("Install-BuildTools-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

Start-Transcript -Path $LogFile -Force


# ============================================================
# HELPER FUNCTIONS
# ============================================================

function Write-Step {
    param(
        [string]$Message
    )

    Write-Host ""
    Write-Host "============================================================"
    Write-Host $Message
    Write-Host "============================================================"
}


function Test-CommandExists {
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )

    return $null -ne (
        Get-Command $Command -ErrorAction SilentlyContinue
    )
}


function Add-MachinePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $machinePath = [Environment]::GetEnvironmentVariable(
        "Path",
        "Machine"
    )

    if (-not $machinePath) {
        $machinePath = ""
    }

    $paths = $machinePath -split ";" |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }

    if ($paths -notcontains $Path) {

        Write-Host "Adding to machine PATH: $Path"

        $newPath = (
            $paths + $Path
        ) -join ";"

        [Environment]::SetEnvironmentVariable(
            "Path",
            $newPath,
            "Machine"
        )
    }
}


function Refresh-Environment {
    Write-Host "Refreshing environment variables..."

    $machinePath = [Environment]::GetEnvironmentVariable(
        "Path",
        "Machine"
    )

    $userPath = [Environment]::GetEnvironmentVariable(
        "Path",
        "User"
    )

    $env:Path = @(
        $machinePath
        $userPath
    ) -join ";"
}


function Install-WingetPackage {
    param(
        [Parameter(Mandatory)]
        [string]$Id
    )

    Write-Host ""
    Write-Host "Installing WinGet package: $Id"

    winget install `
        --id $Id `
        --exact `
        --source winget `
        --silent `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity

    if ($LASTEXITCODE -ne 0) {
        throw "WinGet installation failed: $Id. Exit code: $LASTEXITCODE"
    }
}


function Download-File {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    Write-Host "Downloading:"
    Write-Host "  $Url"
    Write-Host "To:"
    Write-Host "  $Destination"

    Invoke-WebRequest `
        -Uri $Url `
        -OutFile $Destination `
        -UseBasicParsing
}


# ============================================================
# INITIALIZE
# ============================================================

Write-Step "Initializing build tools installation"

New-Item `
    -ItemType Directory `
    -Path $Config.WorkRoot `
    -Force | Out-Null

Refresh-Environment


# ============================================================
# CHECK ADMINISTRATOR
# ============================================================

Write-Step "Checking administrator privileges"

$currentIdentity = `
    [Security.Principal.WindowsIdentity]::GetCurrent()

$principal = `
    New-Object Security.Principal.WindowsPrincipal(
        $currentIdentity
    )

if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw "This script must be run as Administrator."
}

Write-Host "[OK] Running as Administrator"


# ============================================================
# CHECK WINGET
# ============================================================

Write-Step "Checking WinGet"

if (-not (Test-CommandExists "winget")) {

    throw @"
WinGet is not available.

Install/enable WinGet before running this image provisioning
script, or replace the WinGet installations with your internal
installer repository.
"@
}

Write-Host "[OK] WinGet found"

winget --version


# ============================================================
# BASIC BUILD TOOLS
# ============================================================

Write-Step "Installing Git, 7-Zip, CMake, Ninja and Python"

$WingetPackages = @(
    "Git.Git"
    "7zip.7zip"
    "Kitware.CMake"
    "Ninja-build.Ninja"
    "Python.Python.3.12"
)

foreach ($package in $WingetPackages) {
    Install-WingetPackage -Id $package
}

Refresh-Environment


# ============================================================
# VERIFY BASIC TOOLS
# ============================================================

Write-Step "Verifying basic tools"

$BasicCommands = @(
    "git"
    "git-lfs"
    "cmake"
    "ninja"
    "python"
    "py"
    "7z"
)

foreach ($command in $BasicCommands) {

    if (Test-CommandExists $command) {

        try {
            $version = & $command --version 2>&1 |
                Select-Object -First 1

            Write-Host "[OK] $command : $version"
        }
        catch {
            Write-Host "[OK] $command"
        }

    }
    else {

        Write-Warning "[MISSING] $command"
    }
}


# ============================================================
# GIT LFS
# ============================================================

Write-Step "Initializing Git LFS"

if (Test-CommandExists "git-lfs") {

    git lfs install --system

    if ($LASTEXITCODE -ne 0) {
        throw "Git LFS initialization failed."
    }

    Write-Host "[OK] Git LFS initialized"
}


# ============================================================
# VISUAL STUDIO 2022
# ============================================================

Write-Step "Installing Visual Studio 2022"

$VSInstallPath = $Config.VS.InstallPath

$VSExecutable = Join-Path `
    $Config.WorkRoot `
    "vs_enterprise.exe"

if (-not (Test-Path $VSInstallPath)) {

    if (-not (Test-Path $VSExecutable)) {

        Download-File `
            -Url $Config.VS.Bootstrapper `
            -Destination $VSExecutable
    }

    $VSArguments = @(
        "--installPath"
        "`"$VSInstallPath`""
    )

    foreach ($workload in $Config.VS.Workloads) {
        $VSArguments += "--add"
        $VSArguments += $workload
    }

    foreach ($component in $Config.VS.Components) {
        $VSArguments += "--add"
        $VSArguments += $component
    }

    $VSArguments += "--includeRecommended"
    $VSArguments += "--quiet"
    $VSArguments += "--wait"
    $VSArguments += "--norestart"

    Write-Host "Visual Studio installation path:"
    Write-Host "  $VSInstallPath"

    $argumentString = $VSArguments -join " "

    Write-Host ""
    Write-Host "Running:"
    Write-Host "$VSExecutable $argumentString"

    $process = Start-Process `
        -FilePath $VSExecutable `
        -ArgumentList $argumentString `
        -Wait `
        -PassThru

    # VS returns 0 for success and 3010 for success/reboot required.
    if (
        $process.ExitCode -ne 0 -and
        $process.ExitCode -ne 3010
    ) {
        throw "Visual Studio installation failed. Exit code: $($process.ExitCode)"
    }

}
else {

    Write-Host "[OK] Visual Studio already installed"
}


# ============================================================
# VERIFY VISUAL STUDIO
# ============================================================

Write-Step "Verifying Visual Studio"

if (-not (Test-Path $VSInstallPath)) {
    throw "Visual Studio installation was not found at $VSInstallPath"
}

$MSBuild = Join-Path `
    $VSInstallPath `
    "MSBuild\Current\Bin\MSBuild.exe"

$VsDevShell = Join-Path `
    $VSInstallPath `
    "Common7\Tools\Launch-VsDevShell.ps1"

if (-not (Test-Path $MSBuild)) {
    throw "MSBuild was not found: $MSBuild"
}

if (-not (Test-Path $VsDevShell)) {
    throw "Visual Studio Developer PowerShell was not found: $VsDevShell"
}

Write-Host "[OK] Visual Studio"
Write-Host "[OK] MSBuild: $MSBuild"
Write-Host "[OK] VS Developer Shell: $VsDevShell"

& $MSBuild -version


# ============================================================
# QT 6.8.1
# ============================================================

Write-Step "Installing Qt 6.8.1"

$QtRoot = Join-Path `
    $Config.Qt.InstallRoot `
    $Config.Qt.Version

$QtExecutable = Join-Path `
    $QtRoot `
    "msvc2022_64\bin\qmake.exe"


if (Test-Path $QtExecutable) {

    Write-Host "[OK] Qt 6.8.1 already installed:"
    Write-Host "     $QtRoot"

}
else {

    if (-not $Config.Qt.Installer) {

        throw @"
Qt 6.8.1 is not installed.

Set Config.Qt.Installer to your Qt Online Installer executable,
for example:

    C:\Installers\qt-unified-windows-x64-online.exe

or preferably an internal Artifactory/network-share copy.

The Qt installer may require Qt account credentials for your
license type.
"@
    }

    if (-not (Test-Path $Config.Qt.Installer)) {
        throw "Qt installer not found: $($Config.Qt.Installer)"
    }

    New-Item `
        -ItemType Directory `
        -Path $Config.Qt.InstallRoot `
        -Force | Out-Null

    $QtArguments = @(
        "--root"
        "`"$QtRoot`""
        "--accept-licenses"
        "--default-answer"
        "--confirm-command"
        "install"
        $Config.Qt.Component
    )

    $argumentString = $QtArguments -join " "

    Write-Host ""
    Write-Host "Qt component:"
    Write-Host "  $($Config.Qt.Component)"

    $process = Start-Process `
        -FilePath $Config.Qt.Installer `
        -ArgumentList $argumentString `
        -Wait `
        -PassThru

    if ($process.ExitCode -ne 0) {
        throw "Qt installation failed. Exit code: $($process.ExitCode)"
    }
}


# ============================================================
# VERIFY QT
# ============================================================

Write-Step "Verifying Qt 6.8.1"

if (-not (Test-Path $QtExecutable)) {

    throw "Qt qmake.exe was not found: $QtExecutable"
}

Write-Host "[OK] Qt:"
Write-Host "     $QtRoot"

Write-Host ""
Write-Host "Qt executable:"
Write-Host "     $QtExecutable"


# Add Qt to machine PATH
$QtBin = Join-Path `
    $QtRoot `
    "msvc2022_64\bin"

Add-MachinePath $QtBin

Refresh-Environment


# ============================================================
# CONAN
# ============================================================

Write-Step "Installing Conan 2"

if (-not (Test-CommandExists "python")) {
    throw "Python is required before installing Conan."
}

python -m pip install `
    --upgrade `
    pip

if ($LASTEXITCODE -ne 0) {
    throw "pip upgrade failed."
}

if ($Config.Conan.Version -eq "2.*") {

    python -m pip install `
        --upgrade `
        "conan>=2,<3"
}
else {

    python -m pip install `
        --upgrade `
        "conan==$($Config.Conan.Version)"
}

if ($LASTEXITCODE -ne 0) {
    throw "Conan installation failed."
}

Refresh-Environment


# ============================================================
# VERIFY CONAN
# ============================================================

Write-Step "Verifying Conan"

if (-not (Test-CommandExists "conan")) {

    # Python user Scripts path may not be in PATH.
    $PythonUserBase = `
        python -m site --user-base 2>$null

    if ($PythonUserBase) {

        $ConanScripts = Join-Path `
            $PythonUserBase `
            "Scripts"

        if (Test-Path $ConanScripts) {

            Add-MachinePath $ConanScripts

            Refresh-Environment
        }
    }
}

if (-not (Test-CommandExists "conan")) {
    throw "Conan executable was not found after installation."
}

conan --version


# ============================================================
# JFROG CLI
# ============================================================

Write-Step "Installing JFrog CLI"

$JFrogInstallPath = `
    $Config.JFrog.InstallPath

New-Item `
    -ItemType Directory `
    -Path $JFrogInstallPath `
    -Force | Out-Null


$JFrogExe = Join-Path `
    $JFrogInstallPath `
    "jf.exe"


if (-not (Test-Path $JFrogExe)) {

    if ($Config.JFrog.Version) {

        $JFrogUrl =
            "https://releases.jfrog.io/artifactory/jfrog-cli/v2-jf/" +
            "$($Config.JFrog.Version)/jfrog-cli-windows-amd64/jf.exe"

    }
    else {

        $JFrogUrl =
            "https://releases.jfrog.io/artifactory/jfrog-cli/" +
            "v2-jf/latest/jfrog-cli-windows-amd64/jf.exe"
    }

    Download-File `
        -Url $JFrogUrl `
        -Destination $JFrogExe

}
else {

    Write-Host "[OK] JFrog CLI already exists"
}


# Add JFrog to machine PATH
Add-MachinePath $JFrogInstallPath

Refresh-Environment


# ============================================================
# VERIFY JFROG
# ============================================================

Write-Step "Verifying JFrog CLI"

if (-not (Test-CommandExists "jf")) {

    throw "JFrog CLI 'jf.exe' was not found in PATH."
}

jf --version


# ============================================================
# CREATE BUILD ENVIRONMENT VARIABLES
# ============================================================

Write-Step "Creating machine environment variables"

[Environment]::SetEnvironmentVariable(
    "QT_ROOT",
    $QtRoot,
    "Machine"
)

[Environment]::SetEnvironmentVariable(
    "VS2022_ROOT",
    $VSInstallPath,
    "Machine"
)

[Environment]::SetEnvironmentVariable(
    "MSBUILD_EXE",
    $MSBuild,
    "Machine"
)

[Environment]::SetEnvironmentVariable(
    "JFROG_CLI_PATH",
    $JFrogExe,
    "Machine"
)

[Environment]::SetEnvironmentVariable(
    "CONAN_HOME",
    "C:\ProgramData\conan",
    "Machine"
)

New-Item `
    -ItemType Directory `
    -Path "C:\ProgramData\conan" `
    -Force | Out-Null

Refresh-Environment


# ============================================================
# FINAL VERIFICATION
# ============================================================

Write-Step "FINAL BUILD ENVIRONMENT VERIFICATION"

$Verification = @(
    @{
        Name = "Git"
        Command = "git"
        Arguments = "--version"
    }
    @{
        Name = "Git LFS"
        Command = "git-lfs"
        Arguments = "--version"
    }
    @{
        Name = "7-Zip"
        Command = "7z"
        Arguments = ""
    }
    @{
        Name = "CMake"
        Command = "cmake"
        Arguments = "--version"
    }
    @{
        Name = "Ninja"
        Command = "ninja"
        Arguments = "--version"
    }
    @{
        Name = "Python"
        Command = "python"
        Arguments = "--version"
    }
    @{
        Name = "Conan"
        Command = "conan"
        Arguments = "--version"
    }
    @{
        Name = "JFrog CLI"
        Command = "jf"
        Arguments = "--version"
    }
)

$Failures = @()

foreach ($tool in $Verification) {

    $command = Get-Command `
        $tool.Command `
        -ErrorAction SilentlyContinue

    if ($command) {

        Write-Host ""
        Write-Host "[OK] $($tool.Name)"
        Write-Host "     Path: $($command.Source)"

        if ($tool.Arguments) {

            try {

                $output = & $tool.Command `
                    $tool.Arguments `
                    2>&1 |
                    Select-Object -First 1

                Write-Host "     $output"
            }
            catch {
                Write-Host "     Version check failed"
            }
        }

    }
    else {

        Write-Host ""
        Write-Host "[FAIL] $($tool.Name)"

        $Failures += $tool.Name
    }
}


# ============================================================
# BUILD PATH SUMMARY
# ============================================================

Write-Step "BUILD ENVIRONMENT PATHS"

Write-Host "VS2022_ROOT     = $env:VS2022_ROOT"
Write-Host "MSBUILD_EXE     = $env:MSBUILD_EXE"
Write-Host "QT_ROOT         = $env:QT_ROOT"
Write-Host "JFROG_CLI_PATH  = $env:JFROG_CLI_PATH"
Write-Host "CONAN_HOME      = $env:CONAN_HOME"


# ============================================================
# RESULT
# ============================================================

if ($Failures.Count -gt 0) {

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "BUILD TOOL INSTALLATION FAILED"
    Write-Host "============================================================"

    Write-Host ""
    Write-Host "Missing tools:"

    foreach ($failure in $Failures) {
        Write-Host "  - $failure"
    }

    throw "One or more build tools failed verification."
}


Write-Host ""
Write-Host "============================================================"
Write-Host "BUILD TOOL INSTALLATION SUCCESSFUL"
Write-Host "============================================================"

Write-Host ""
Write-Host "Installed environment:"
Write-Host "  Visual Studio 2022 Enterprise"
Write-Host "  Qt 6.8.1 MSVC 2022 x64"
Write-Host "  Git"
Write-Host "  Git LFS"
Write-Host "  7-Zip"
Write-Host "  CMake"
Write-Host "  Ninja"
Write-Host "  Python"
Write-Host "  Conan 2"
Write-Host "  JFrog CLI"

Write-Host ""
Write-Host "Log:"
Write-Host "  $LogFile"

Stop-Transcript
```
