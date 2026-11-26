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
    [int]$Port,
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
foreach ($name in 'Server', 'Share', 'UserPrefix', 'DeviceNumber', 'ExamTitle', 'Language', 'ShareUser', 'Port') {
    if ($PSBoundParameters.ContainsKey($name)) {
        $parameters[$name] = $PSBoundParameters[$name]
    }
}
$proctor = Resolve-ProctorConfig -Parameters $parameters -File $fileValues

$credential = $ShareCredential
$credPath = Join-Path $proctor.DataDir 'share.cred'
if ($null -eq $credential -and $proctor.ShareUser -and -not (Test-Path $credPath)) {
    try {
        $password = Read-Host "Password for share account $($proctor.ShareUser)" -AsSecureString
    }
    catch {
        throw "Cannot prompt for the share password in a non-interactive session; pass -ShareCredential or pre-seed $credPath"
    }
    if ($password.Length -eq 0) {
        throw "Empty password for share account $($proctor.ShareUser)"
    }
    $credential = New-Object System.Management.Automation.PSCredential -ArgumentList $proctor.ShareUser, $password
}

$editionId = Get-WindowsEditionId
$lockdownMode = Get-LockdownMode -EditionId $editionId

Write-Information 'proctor'
Write-Information "  User:      $($proctor.UserName)"
Write-Information "  Exam:      $($proctor.ExamTitle)"
Write-Information "  Share:     $($proctor.NetworkPath)"
Write-Information "  Kiosk URL: $($proctor.KioskUrl)"
Write-Information "  Edition:   $editionId"
Write-Information "  Lockdown:  $lockdownMode"
Write-Information ''

# A recorded port is the port of a previous install: a different one would
# orphan its URL reservation, so a port change requires an uninstall first.
$priorInfo = $null
if (Test-Path (Join-Path $proctor.DataDir 'install.json')) {
    try {
        $priorInfo = Read-ProctorInstallInfo -DataDir $proctor.DataDir
    }
    catch {
        throw 'unreadable install.json; run uninstall.ps1 first'
    }
}
if (-not (Test-PortChangeAllowed -PriorInfo $priorInfo -Port $proctor.Port)) {
    throw "proctor is installed on port $($priorInfo.port); run uninstall.ps1 before installing on port $($proctor.Port)"
}

# A foreign reservation on the port means the kiosk server can never
# listen; fail before the install changes anything so a retry stays clean.
$reservation = Get-UrlAclReservation -Prefix $proctor.KioskUrl
$urlAclPlan = Get-UrlAclPlan -Exists ($null -ne $reservation) -Sddl $reservation.Sddl -PriorInfo $priorInfo -Port $proctor.Port
if ($urlAclPlan -eq 'Fail') {
    throw "URL prefix $($proctor.KioskUrl) is already reserved by $($reservation.User) (netsh http show urlacl url=$($proctor.KioskUrl)). Pick a different -Port or remove that reservation."
}

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
elseif ($proctor.ShareUser) {
    Write-Information 'Share credential already stored'
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

Write-Information 'Reserving the kiosk URL...'
$urlAclCreated = Add-KioskUrlAcl -Prefix $proctor.KioskUrl -Plan $urlAclPlan

Write-Information 'Writing install metadata...'
$urlAclSddl = if ($urlAclCreated) { Get-ProctorUrlAclSddl } else { $false }
Save-ProctorInstallInfo -Config $proctor -UrlAclCreated $urlAclCreated -UrlAclSddl $urlAclSddl

Write-Information 'Registering sync task...'
Register-SyncTask -TaskName $proctor.TaskName -ScriptPath "$($proctor.KioskDir)\sync-exam.ps1"

Write-Information 'Registering the kiosk server task...'
Register-ServerTask -TaskName $proctor.ServerTaskName -ScriptPath "$($proctor.KioskDir)\server.ps1" -Port $proctor.Port

Write-Information ''
Write-Information 'Install complete'
