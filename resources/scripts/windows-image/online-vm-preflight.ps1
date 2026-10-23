[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$VhdxPath,
    [Parameter(Mandatory=$true)][string]$SwitchName,
    [Parameter(Mandatory=$true)][string]$VmName
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $VhdxPath -PathType Leaf)) { throw "BASE_VHDX_PATH does not exist: $VhdxPath" }
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { throw 'Hyper-V PowerShell cmdlets are unavailable on this agent.' }
$sw = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if ($null -eq $sw) { throw "Configured Hyper-V switch was not found: $SwitchName" }
$vmms = Get-Service -Name vmms -ErrorAction Stop
if ($vmms.Status -ne 'Running') { throw 'Hyper-V Virtual Machine Management service is not running.' }
$existing = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if ($null -ne $existing) {
    $paths = @(Get-VMHardDiskDrive -VMName $VmName | ForEach-Object { [IO.Path]::GetFullPath($_.Path) })
    if ($paths -notcontains [IO.Path]::GetFullPath($VhdxPath)) { throw "VM '$VmName' already exists but is not attached to the requested VHDX. Refusing to touch it." }
    Write-Host "Existing VM '$VmName' is associated with the requested VHDX. State: $($existing.State)"
} else {
    Write-Host "VM '$VmName' does not exist; it will be created from the supplied VHDX during the update stage."
}
Write-Host "Hyper-V switch: $($sw.Name) ($($sw.SwitchType))"
Write-Host "VHDX validated: $VhdxPath"
Write-Host "Hyper-V VMMS: $($vmms.Status)"
