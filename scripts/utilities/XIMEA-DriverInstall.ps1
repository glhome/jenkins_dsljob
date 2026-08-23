$installer = "C:\Users\ugliu\Downloads\XIMEA_Windows_SP_Stable.exe"

if (-not (Test-Path $installer)) {
    throw "XIMEA installer not found: $installer"
}

Write-Host "Installing XIMEA USB driver..."

$process = Start-Process `
    -FilePath $installer `
    -ArgumentList @(
        "/S",
        "/SecDrivers=ON",
        "/SecXiApi=OFF",
        "/SecXiApiNET=OFF",
        "/SecGenTL=OFF",
        "/SecPython=OFF",
        "/SecxiCamTool=OFF",
        "/SecxiCamToolExamples=OFF",
        "/SecxiCOP=OFF",
        "/SecXiLib=OFF",
        "/SecExamples=OFF",
        "/SecxiXiapiDNG=OFF"
    ) `
    -Wait `
    -PassThru `
    -NoNewWindow

if ($process.ExitCode -ne 0) {
    throw "XIMEA USB driver installation FAILED. Exit code: $($process.ExitCode)"
}

Write-Host "XIMEA USB driver installation completed successfully."