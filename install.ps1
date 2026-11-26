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
    [pscredential]$ShareCredential,
    [string]$Config
)

$ErrorActionPreference = 'Stop'
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
$proctor = Resolve-ProctorConfig -Parameters $parameters -File $fileValues

$credential = $ShareCredential
if ($null -eq $credential -and $proctor.ShareUser) {
    $password = Read-Host "Password for share account $($proctor.ShareUser)" -AsSecureString
    $credential = New-Object System.Management.Automation.PSCredential -ArgumentList $proctor.ShareUser, $password
}

$editionId = Get-WindowsEditionId
$lockdownMode = Get-LockdownMode -EditionId $editionId

Write-Information 'proctor'
Write-Information "  User:      $($proctor.UserName)"
Write-Information "  Exam:      $($proctor.ExamTitle)"
Write-Information "  Share:     $($proctor.NetworkPath)"
Write-Information "  Edition:   $editionId"
Write-Information "  Lockdown:  $lockdownMode"
Write-Information ''

Write-Information 'Creating kiosk folder...'
New-KioskFolder -Path $proctor.KioskDir

Write-Information 'Creating student account...'
$sid = Set-StudentAccount -UserName $proctor.UserName

Write-Information 'Creating user profile...'
$profilePath = New-LocalProfile -Sid $sid -UserName $proctor.UserName
Write-Information "  Profile: $profilePath"

Set-KioskAcl -Path $proctor.KioskDir -UserName $proctor.UserName

if ($credential) {
    Write-Information 'Storing share credential...'
    Install-ShareCredential -Credential $credential -DataDir $proctor.DataDir
}

Write-Information 'Setting auto-logon...'
Set-AutoLogon -UserName $proctor.UserName

Write-Information 'Enabling task scheduler history...'
Enable-TaskHistory

$hive = Mount-UserHive -Sid $sid
try {
    Write-Information 'Setting Edge policies...'
    Set-EdgePolicy -HiveRoot $hive.Root -KioskUrl $proctor.KioskUrl

    if ($lockdownMode -eq 'RegistryLockdown') {
        Write-Information 'Setting shell restrictions and kiosk autorun...'
        Set-ExplorerRestriction -HiveRoot $hive.Root
        Set-KioskAutorun -HiveRoot $hive.Root -CommandLine (Get-KioskCommandLine -Config $proctor)
    }
}
finally {
    Dismount-UserHive -Hive $hive
}

if ($lockdownMode -eq 'AssignedAccess') {
    Write-Information 'Configuring Assigned Access kiosk...'
    Set-AssignedAccessKiosk -Config $proctor -HelperPath (Join-Path $PSScriptRoot 'src\assigned-access.ps1')
}

Write-Information 'Setting firewall rules...'
Set-FirewallLockdown -Sid $sid -BlockRuleName $proctor.BlockRuleName

Write-Information 'Writing kiosk files...'
Install-KioskFile -Config $proctor -SourceRoot $PSScriptRoot

Write-Information 'Registering sync task...'
Register-SyncTask -TaskName $proctor.TaskName -ScriptPath "$($proctor.KioskDir)\sync-exam.ps1"

Write-Information ''
Write-Information 'Install complete'
