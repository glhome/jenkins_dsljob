[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkRoot,[string]$OutputName="Windows-Custom")
$ErrorActionPreference="Stop"
$sourceRoot=Join-Path $WorkRoot "source"
$outputRoot=Join-Path $WorkRoot "output"
$bios=Join-Path $sourceRoot "boot\etfsboot.com"
$efi=Join-Path $sourceRoot "efi\microsoft\boot\efisys.bin"
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
if (-not (Test-Path $bios)) { throw "BIOS boot image not found." }
if (-not (Test-Path $efi)) { throw "EFI boot image not found." }
$oscdimg=$null
foreach ($p in @("$env:ProgramFiles(x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe","$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe")) { if (Test-Path $p) { $oscdimg=$p; break } }
if (-not $oscdimg) { $c=Get-Command oscdimg.exe -ErrorAction SilentlyContinue; if ($c) { $oscdimg=$c.Source } }
if (-not $oscdimg) { throw "oscdimg.exe was not found. Install Windows ADK Deployment Tools." }
$iso=Join-Path $outputRoot "$OutputName.iso"
if (Test-Path $iso) { Remove-Item $iso -Force }
$bootData="-bootdata:2#p0,e,b$bios#pEF,e,b$efi"
& $oscdimg -m -o -u2 -udfver102 $bootData $sourceRoot $iso
if ($LASTEXITCODE -ne 0) { throw "oscdimg failed with exit code $LASTEXITCODE." }
$hash=(Get-FileHash $iso -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $([IO.Path]::GetFileName($iso))" | Set-Content "$iso.sha256" -Encoding ASCII
