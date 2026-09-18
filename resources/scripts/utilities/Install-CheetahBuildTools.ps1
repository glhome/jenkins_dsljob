[CmdletBinding()]
param(
    [ValidateSet("INSTALL","REPAIR","VALIDATE")]
    [string]$Action = "VALIDATE",

    [string]$ArtifactoryUrl = "",
    [string]$ArtifactoryRepo = "windows-build-tools",
    [string]$ArtifactoryToken = "",

    [string]$ToolRoot = "C:\CheetahBuildTools",
    [string]$QtRoot = "C:\Qt",
    [string]$QtVersion = "6.8.1",
    [string]$QtArch = "msvc2022_64",

    [string]$QtPackageManifest = "",

    [string]$VisualStudioVersion = "17.12",
    [string]$WindowsSdkVersion = "10.0.26100.0",
    [string]$MsvcToolset = "14.42.34433",

    [string]$LlvmVersion = "12.0",
    [switch]$KeepInstallers
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$LogRoot = Join-Path $ToolRoot "Logs"
$StageRoot = Join-Path $ToolRoot "Staging"
$ReportPath = Join-Path $ToolRoot "CheetahBuildEnvironment.txt"
$LogPath = Join-Path $LogRoot ("Provision-{0}-{1}.log" -f $Action,(Get-Date -Format "yyyyMMdd-HHmmss"))

New-Item -ItemType Directory -Force -Path $ToolRoot,$LogRoot,$StageRoot | Out-Null
Start-Transcript -Path $LogPath -Append | Out-Null

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==== $Message ====" -ForegroundColor Cyan
}

function Require-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }
}

function Find-VsWhere {
    $paths = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    throw "vswhere.exe was not found."
}

function Get-VsInstallation {
    $vswhere = Find-VsWhere
    $items = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Workload.VCTools -format json 2>$null |
        ConvertFrom-Json

    if (-not $items) { return $null }

    foreach ($item in @($items)) {
        if ($item.installationVersion -like "$VisualStudioVersion.*") {
            return $item
        }
    }

    return $null
}

function Get-ArtifactUri([string]$RelativePath) {
    if ([string]::IsNullOrWhiteSpace($ArtifactoryUrl)) {
        throw "ArtifactoryUrl is required for INSTALL/REPAIR."
    }

    $base = $ArtifactoryUrl.TrimEnd("/")
    return "$base/artifactory/$ArtifactoryRepo/$RelativePath"
}

function Invoke-ArtifactDownload([string]$RelativePath,[string]$Destination) {
    $uri = Get-ArtifactUri $RelativePath
    Write-Host "Downloading $uri"

    $headers = @{}
    if ($ArtifactoryToken) {
        $headers["Authorization"] = "Bearer $ArtifactoryToken"
    }

    Invoke-WebRequest -Uri $uri -Headers $headers -OutFile $Destination -UseBasicParsing

    if (-not (Test-Path $Destination)) {
        throw "Download failed: $Destination"
    }

    $hash = (Get-FileHash -Path $Destination -Algorithm SHA256).Hash
    Write-Host "SHA256 $hash"
    return $hash
}

function Invoke-Installer([string]$File,[string[]]$Arguments) {
    Write-Host "Running: $File $($Arguments -join ' ')"
    $p = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        throw "Installer failed with exit code $($p.ExitCode): $File"
    }
}

function Install-VisualStudio {
    Write-Step "Provision Visual Studio 2022 17.12.x"

    $vs = Get-VsInstallation

    $vsInstaller = Join-Path $StageRoot "vs_buildtools.exe"
    if (-not $vs) {
        Invoke-ArtifactDownload "visual-studio/17.12/vs_buildtools.exe" $vsInstaller
        Invoke-Installer $vsInstaller @(
            "--quiet",
            "--wait",
            "--norestart",
            "--add","Microsoft.VisualStudio.Workload.VCTools",
            "--add","Microsoft.VisualStudio.ComponentGroup.NativeDesktop.Core",
            "--add","Microsoft.VisualStudio.Component.VC.14.42.17.12.x86.x64",
            "--add","Microsoft.VisualStudio.Component.VC.14.42.17.12.ATL",
            "--add","Microsoft.VisualStudio.Component.VC.14.42.17.12.MFC",
            "--add","Microsoft.VisualStudio.Component.Windows11SDK.26100"
        )
    }
    else {
        Write-Host "Existing VS 17.12 installation found: $($vs.installationPath)"

        $vsInstaller = Join-Path $StageRoot "vs_buildtools.exe"
        Invoke-ArtifactDownload "visual-studio/17.12/vs_buildtools.exe" $vsInstaller

        Invoke-Installer $vsInstaller @(
            "modify",
            "--installPath",$vs.installationPath,
            "--quiet",
            "--wait",
            "--norestart",
            "--add","Microsoft.VisualStudio.Workload.VCTools",
            "--add","Microsoft.VisualStudio.ComponentGroup.NativeDesktop.Core",
            "--add","Microsoft.VisualStudio.Component.VC.14.42.17.12.x86.x64",
            "--add","Microsoft.VisualStudio.Component.VC.14.42.17.12.ATL",
            "--add","Microsoft.VisualStudio.Component.VC.14.42.17.12.MFC",
            "--add","Microsoft.VisualStudio.Component.Windows11SDK.26100"
        )
    }
}

function Install-Qt {
    Write-Step "Provision Qt $QtVersion"

    if (-not $QtPackageManifest) {
        throw "QtPackageManifest is required for INSTALL/REPAIR."
    }
    if (-not (Test-Path $QtPackageManifest)) {
        throw "Qt package manifest not found: $QtPackageManifest"
    }

    $packages = Get-Content $QtPackageManifest |
        Where-Object { $_.Trim() -and -not $_.Trim().StartsWith("#") }

    $bad = $packages | Where-Object { $_ -match "<REPLACE_WITH_APPROVED" }
    if ($bad) {
        throw "Qt package manifest contains unresolved placeholder package IDs."
    }

    $installer = Join-Path $StageRoot "qt-online-installer.exe"
    Invoke-ArtifactDownload "qt/$QtVersion/qt-online-installer.exe" $installer

    $args = @(
        "--root",$QtRoot,
        "--accept-licenses",
        "--default-answer",
        "--confirm-command",
        "install"
    ) + @($packages)

    Invoke-Installer $installer $args

    $qtPath = Join-Path $QtRoot "$QtVersion\$QtArch"
    if (-not (Test-Path $qtPath)) {
        throw "Qt installation not found: $qtPath"
    }

    [Environment]::SetEnvironmentVariable(
        "CheetahQtVersion",
        $qtPath,
        [EnvironmentVariableTarget]::Machine
    )
}

function Install-QtVsTools {
    Write-Step "Provision Qt VS Tools 3.3.1.1"

    $vs = Get-VsInstallation
    if (-not $vs) {
        throw "Visual Studio 17.12.x was not found after installation."
    }

    $vsix = Join-Path $StageRoot "qt-vs-tools-3.3.1.1.vsix"
    Invoke-ArtifactDownload "qt/$QtVersion/qt-vs-tools-3.3.1.1.vsix" $vsix

    $vsixInstaller = Join-Path $vs.installationPath "Common7\IDE\VSIXInstaller.exe"
    if (-not (Test-Path $vsixInstaller)) {
        throw "VSIXInstaller.exe not found: $vsixInstaller"
    }

    Invoke-Installer $vsixInstaller @(
        "/quiet",
        "/norestart",
        $vsix
    )
}

function Install-Llvm {
    Write-Step "Provision LLVM $LlvmVersion"

    $installer = Join-Path $StageRoot "llvm-installer.exe"
    Invoke-ArtifactDownload "llvm/$LlvmVersion/llvm-installer.exe" $installer

    Invoke-Installer $installer @("/S")

    $clang = "C:\Program Files\LLVM\bin\clang-format.exe"
    if (-not (Test-Path $clang)) {
        throw "clang-format was not found after LLVM installation: $clang"
    }
}

function Configure-Environment {
    Write-Step "Configure machine environment"

    $qtPath = Join-Path $QtRoot "$QtVersion\$QtArch"
    $llvmBin = "C:\Program Files\LLVM\bin"

    [Environment]::SetEnvironmentVariable(
        "CheetahQtVersion",
        $qtPath,
        [EnvironmentVariableTarget]::Machine
    )

    $machinePath = [Environment]::GetEnvironmentVariable(
        "Path",
        [EnvironmentVariableTarget]::Machine
    )

    $entries = @($llvmBin, (Join-Path $qtPath "bin"))

    foreach ($entry in $entries) {
        if ((Test-Path $entry) -and
            (($machinePath -split ";") -notcontains $entry)) {
            $machinePath = "$machinePath;$entry"
        }
    }

    [Environment]::SetEnvironmentVariable(
        "Path",
        $machinePath,
        [EnvironmentVariableTarget]::Machine
    )

    @"
Cheetah IFS GUI Build Environment
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Computer: $env:COMPUTERNAME

Visual Studio: $VisualStudioVersion.x
MSVC: $MsvcToolset
Windows SDK: $WindowsSdkVersion
Qt: $QtVersion $QtArch
Qt path: $qtPath
LLVM: $LlvmVersion
clang-format: C:\Program Files\LLVM\bin\clang-format.exe
CheetahQtVersion: $qtPath
"@ | Set-Content -Path (Join-Path $ToolRoot "EnvironmentConfiguration.txt")
}

function Test-CheetahEnvironment {
    Write-Step "Validate Cheetah build environment"

    $errors = New-Object System.Collections.Generic.List[string]

    try {
        $vswhere = Find-VsWhere
        $vs = Get-VsInstallation
        if (-not $vs) {
            $errors.Add("Visual Studio 17.12.x with VC tools not found.")
        }
        else {
            Write-Host "Visual Studio: $($vs.installationVersion)"
            Write-Host "Path: $($vs.installationPath)"

            if ($vs.installationVersion -notlike "$VisualStudioVersion.*") {
                $errors.Add("Unexpected Visual Studio version: $($vs.installationVersion)")
            }

            $required = @(
                "Microsoft.VisualStudio.Workload.VCTools",
                "Microsoft.VisualStudio.Component.VC.14.42.17.12.x86.x64",
                "Microsoft.VisualStudio.Component.VC.14.42.17.12.ATL",
                "Microsoft.VisualStudio.Component.VC.14.42.17.12.MFC",
                "Microsoft.VisualStudio.Component.Windows11SDK.26100"
            )

            foreach ($component in $required) {
                $found = & $vswhere -products $vs.productId -version "$VisualStudioVersion.*" -requires $component -property installationPath 2>$null
                if (-not $found) {
                    $errors.Add("Missing Visual Studio component: $component")
                }
            }
        }
    }
    catch {
        $errors.Add($_.Exception.Message)
    }

    $qtPath = Join-Path $QtRoot "$QtVersion\$QtArch"
    if (-not (Test-Path $qtPath)) {
        $errors.Add("Qt path missing: $qtPath")
    }
    else {
        $qmake = Join-Path $qtPath "bin\qmake.exe"
        if (-not (Test-Path $qmake)) {
            $errors.Add("Qt qmake missing: $qmake")
        }

        $modules = @(
            "Qt6Multimedia",
            "Qt6Pdf",
            "Qt6StateMachine"
        )

        foreach ($module in $modules) {
            $dll = Join-Path $qtPath "bin\$module.dll"
            $cmake = Get-ChildItem (Join-Path $qtPath "lib\cmake") -Directory -Filter "$module*" -ErrorAction SilentlyContinue
            if (-not (Test-Path $dll) -and -not $cmake) {
                $errors.Add("Qt module not found: $module")
            }
        }
    }

    $clang = "C:\Program Files\LLVM\bin\clang-format.exe"
    if (-not (Test-Path $clang)) {
        $errors.Add("clang-format missing: $clang")
    }

    $sdkInclude = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Include\$WindowsSdkVersion"
    if (-not (Test-Path $sdkInclude)) {
        $errors.Add("Windows SDK include directory missing: $sdkInclude")
    }

    $envQt = [Environment]::GetEnvironmentVariable(
        "CheetahQtVersion",
        [EnvironmentVariableTarget]::Machine
    )

    if ($envQt -ne $qtPath) {
        $errors.Add("Machine CheetahQtVersion is '$envQt', expected '$qtPath'.")
    }

    @"
Cheetah IFS GUI Build Environment Validation
Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Computer: $env:COMPUTERNAME
Action: $Action

Visual Studio: $(if ($vs) { $vs.installationVersion } else { "NOT FOUND" })
Visual Studio Path: $(if ($vs) { $vs.installationPath } else { "NOT FOUND" })
MSVC Required: $MsvcToolset
Windows SDK Required: $WindowsSdkVersion
Qt Required: $QtVersion / $QtArch
Qt Path: $qtPath
LLVM Required: $LlvmVersion
clang-format: $clang
CheetahQtVersion: $envQt

Status: $(if ($errors.Count -eq 0) { "PASS" } else { "FAIL" })

Errors:
$(if ($errors.Count -eq 0) { "None" } else { $errors -join [Environment]::NewLine })
"@ | Set-Content -Path $ReportPath

    if ($errors.Count -gt 0) {
        Write-Host ""
        Write-Host "VALIDATION FAILED" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
        return $false
    }

    Write-Host ""
    Write-Host "VALIDATION PASSED" -ForegroundColor Green
    return $true
}

try {
    Require-Administrator

    Write-Step "Cheetah IFS GUI Build Node Provisioning"
    Write-Host "Computer : $env:COMPUTERNAME"
    Write-Host "Action   : $Action"

    if ($Action -eq "VALIDATE") {
        if (-not (Test-CheetahEnvironment)) {
            exit 1
        }
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($ArtifactoryUrl)) {
        throw "ArtifactoryUrl is required for $Action."
    }

    Install-VisualStudio
    Install-Qt
    Install-QtVsTools
    Install-Llvm
    Configure-Environment

    if (-not (Test-CheetahEnvironment)) {
        throw "Cheetah build environment validation failed."
    }

    if (-not $KeepInstallers) {
        Remove-Item -Path $StageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "Cheetah build node provisioning completed successfully." -ForegroundColor Green
    exit 0
}
catch {
    Write-Host ""
    Write-Host "PROVISIONING FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Log: $LogPath"
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
