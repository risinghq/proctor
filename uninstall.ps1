#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$Server,
    [string]$Share,
    [string]$UserPrefix,
    [string]$DeviceNumber,
    [string]$ExamTitle,
    [ValidateSet('es', 'en')]
    [string]$Language,
    [string]$ShareUser,
    [string]$UserName,
    [string]$Config,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$InformationPreference = 'Continue'

Import-Module (Join-Path $PSScriptRoot 'proctor.psm1') -Force

$fileValues = @{}
if ($Config) {
    $fileValues = Read-ProctorConfigFile -Path $Config
}
$parameters = @{}
foreach ($name in 'Server', 'Share', 'UserPrefix', 'DeviceNumber', 'ExamTitle', 'Language', 'ShareUser') {
    if ($PSBoundParameters.ContainsKey($name)) {
        $parameters[$name] = $PSBoundParameters[$name]
    }
}

$userName = Get-UninstallUserName -UserName $UserName -Parameters $parameters -File $fileValues

if (-not $Force) {
    $answer = Read-Host "This will remove the proctor install for '$userName'. Type Y to continue"
    if ($answer -ne 'Y' -and $answer -ne 'y') {
        Write-Information 'Cancelled'
        exit 0
    }
}

$failed = @()

function Invoke-Step {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Label, [scriptblock]$Action)

    if (-not $PSCmdlet.ShouldProcess($Label)) {
        return
    }
    try {
        & $Action
        Write-Information "  $Label"
    }
    catch {
        $script:failed += "$Label - $($_.Exception.Message)"
        Write-Warning "  Failed: $Label - $($_.Exception.Message)"
    }
}

$account = Get-LocalUser -Name $userName -ErrorAction SilentlyContinue
$sid = if ($account) { $account.SID.Value } else { $null }

Write-Information 'Removing proctor install'

Invoke-Step 'Removed scheduled task' {
    Remove-SyncTask -TaskName "ExamSync-$userName"
}

Invoke-Step 'Removed firewall rules' {
    Remove-FirewallLockdown -BlockRuleName "BlockInternet-$userName"
}

Invoke-Step 'Cleared Assigned Access' {
    Clear-AssignedAccessKiosk -DataDir 'C:\ProgramData\proctor' `
        -HelperPath (Join-Path $PSScriptRoot 'src\assigned-access.ps1')
}

if ($sid) {
    Invoke-Step 'Removed per-user policies' {
        Remove-UserLockdown -Sid $sid
    }
}
else {
    Write-Information "  No account '$userName'; skipping per-user policies"
}

Invoke-Step 'Cleared auto-logon' {
    Clear-AutoLogon
}

Invoke-Step 'Removed kiosk files' {
    Remove-KioskFolder -Path 'C:\Kiosk'
}

Invoke-Step 'Removed proctor data' {
    Remove-ProctorData -DataDir 'C:\ProgramData\proctor'
}

Invoke-Step 'Removed student account and profile' {
    Remove-StudentAccount -UserName $userName
}

if ($failed.Count -gt 0) {
    Write-Information ''
    Write-Information 'Uninstall finished with failures:'
    $failed | ForEach-Object { Write-Information "  - $_" }
    exit 1
}

Write-Information ''
Write-Information 'Uninstall complete'
exit 0
