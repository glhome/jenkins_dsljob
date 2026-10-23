[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkRoot,
    [Parameter(Mandatory=$true)][string]$VmName,
    [Parameter(Mandatory=$true)][string]$VhdxPath,
    [Parameter(Mandatory=$true)][string]$SwitchName,
    [Parameter(Mandatory=$true)][string]$TargetKB,
    [Parameter(Mandatory=$true)][string]$ExpectedBuild,
    [Parameter(Mandatory=$true)][string]$GuestUser,
    [Parameter(Mandatory=$true)][string]$GuestPassword,
    [bool]$KeepVm = $true
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $VhdxPath -PathType Leaf)) { throw "VHDX not found: $VhdxPath" }
$resolvedPath = Join-Path $WorkRoot 'download\resolved-updates.json'
if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) { throw "Resolved update manifest not found: $resolvedPath" }
$resolved = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json
if ([string]$resolved.kb -ine $TargetKB) { throw "Resolver KB '$($resolved.kb)' does not match '$TargetKB'." }
if ([string]$resolved.build -ne $ExpectedBuild) { throw "Resolver build '$($resolved.build)' does not match '$ExpectedBuild'." }
$packageName = [string]$resolved.lcu.msu.fileName
if ([string]::IsNullOrWhiteSpace($packageName)) { throw 'Resolved manifest does not contain lcu.msu.fileName.' }
$packagePath = Join-Path (Join-Path $WorkRoot 'download\updates') $packageName
if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) { throw "Resolved MSU is missing: $packagePath" }
$expectedSha = [string]$resolved.lcu.msu.sha256
$actualSha = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expectedSha -and $actualSha -ne $expectedSha.ToLowerInvariant()) { throw "MSU SHA256 mismatch. Expected $expectedSha; actual $actualSha." }
Write-Host "Verified update package $packageName SHA256=$actualSha"
$credential = [pscredential]::new($GuestUser, (ConvertTo-SecureString $GuestPassword -AsPlainText -Force))
$vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if ($null -eq $vm) {
    Write-Host "Creating test VM '$VmName' from supplied VHDX."
    New-VM -Name $VmName -Generation 2 -MemoryStartupBytes 4GB -VHDPath $VhdxPath -SwitchName $SwitchName | Out-Null
    Set-VM -Name $VmName -ProcessorCount 2 -AutomaticCheckpointsEnabled $false
    Enable-VMIntegrationService -VMName $VmName -Name 'Guest Service Interface' -ErrorAction SilentlyContinue
} else {
    Enable-VMIntegrationService -VMName $VmName -Name 'Guest Service Interface' -ErrorAction SilentlyContinue
    $diskPaths = @(Get-VMHardDiskDrive -VMName $VmName | ForEach-Object { [IO.Path]::GetFullPath($_.Path) })
    if ($diskPaths -notcontains [IO.Path]::GetFullPath($VhdxPath)) { throw "VM '$VmName' is not attached to the supplied VHDX. Refusing to modify it." }
}
$vm = Get-VM -Name $VmName
if ($vm.State -ne 'Running') { Start-VM -Name $VmName | Out-Null }
$deadline = (Get-Date).AddMinutes(20)
$sessionReady = $false
while ((Get-Date) -lt $deadline) {
    try { $null = Invoke-Command -VMName $VmName -Credential $credential -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop; $sessionReady = $true; break }
    catch { Start-Sleep -Seconds 15 }
}
if (-not $sessionReady) { throw "PowerShell Direct did not become available for '$VmName'. Verify the VHDX boots to Windows and guest credentials are valid." }
$guestInfo = Invoke-Command -VMName $VmName -Credential $credential -ScriptBlock {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    [pscustomobject]@{ Caption=(Get-CimInstance Win32_OperatingSystem).Caption; Build=([string]$cv.CurrentBuildNumber + '.' + [string]$cv.UBR) }
}
Write-Host "Guest OS: $($guestInfo.Caption); build before update: $($guestInfo.Build)"
if ($guestInfo.Build.Split('.')[0] -ne '19044') { throw "Guest is not Windows 10 21H2 build family 19044: $($guestInfo.Build)" }
if ($guestInfo.Caption -notmatch '(?i)IoT Enterprise LTSC') { throw "Guest edition is not identified as IoT Enterprise LTSC: $($guestInfo.Caption)" }
$guestPackage = 'C:\Windows\Temp\' + $packageName
Copy-VMFile -VMName $VmName -SourcePath $packagePath -DestinationPath $guestPackage -FileSource Host -CreateFullPath -Force
$install = Invoke-Command -VMName $VmName -Credential $credential -ArgumentList $guestPackage -ScriptBlock {
    param($MsuPath)
    $proc = Start-Process -FilePath 'wusa.exe' -ArgumentList @('"' + $MsuPath + '"','/quiet','/norestart') -Wait -PassThru
    [pscustomobject]@{ ExitCode=[int]$proc.ExitCode }
}
Write-Host "WUSA exit code: $($install.ExitCode)"
if ($install.ExitCode -notin @(0,3010,2359302)) { throw "WUSA failed with exit code $($install.ExitCode)." }
try { Invoke-Command -VMName $VmName -Credential $credential -ScriptBlock { Restart-Computer -Force } -ErrorAction Stop } catch { Write-Host 'Guest reboot initiated or connection closed during reboot.' }
$rebootDeadline = (Get-Date).AddMinutes(20)
$verified = $false
while ((Get-Date) -lt $rebootDeadline) {
    Start-Sleep -Seconds 15
    try {
        $post = Invoke-Command -VMName $VmName -Credential $credential -ArgumentList $TargetKB -ScriptBlock {
            param($KB)
            $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
            $hotfix = Get-HotFix -Id $KB -ErrorAction SilentlyContinue
            [pscustomobject]@{ Build=([string]$cv.CurrentBuildNumber + '.' + [string]$cv.UBR); HotfixFound=($null -ne $hotfix); Caption=(Get-CimInstance Win32_OperatingSystem).Caption }
        } -ErrorAction Stop
        if ($post.Build -eq $ExpectedBuild -and $post.HotfixFound) { $verified = $true; break }
    } catch { }
}
if (-not $verified) { throw "Post-reboot validation failed: expected build $ExpectedBuild and hotfix $TargetKB were not both confirmed." }
Write-Host "Online update verified: $TargetKB; build $($post.Build); edition $($post.Caption)"
if (-not $KeepVm) {
    Write-Host 'KEEP_VM=false: removing VM configuration only; preserving the VHDX.'
    Stop-VM -Name $VmName -TurnOff -ErrorAction SilentlyContinue
    Remove-VM -Name $VmName -Force
}
Write-Host 'Online VM update validation completed successfully.'
