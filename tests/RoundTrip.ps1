#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$root = Split-Path -Path $PSScriptRoot -Parent
$shareName = 'ProctorExamShare'
$shareDir = 'C:\proctor-share'
$deviceDir = Join-Path -Path $shareDir -ChildPath 'Device 01'
$fixture = Join-Path -Path $root -ChildPath 'tests\fixtures\exam.pdf'
$userName = 'Alumno-01'
$shareUser = 'proctor-share'
$sharePassword = 'CI-Share-Read-Only-7'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "ASSERT FAILED: $Message"
    }
    Write-Information "  ok: $Message"
}

Import-Module (Join-Path -Path $root -ChildPath 'proctor.psm1') -Force

Write-Information 'Setting up the exam share...'
New-Item -Path $deviceDir -ItemType Directory -Force | Out-Null
Copy-Item -Path $fixture -Destination (Join-Path $deviceDir 'exam.pdf') -Force

$securePassword = New-Object System.Security.SecureString
foreach ($c in $sharePassword.ToCharArray()) {
    $securePassword.AppendChar($c)
}
New-LocalUser -Name $shareUser -Password $securePassword -PasswordNeverExpires -AccountNeverExpires | Out-Null
New-SmbShare -Name $shareName -Path $shareDir -ReadAccess $shareUser -FullAccess 'Administrators' | Out-Null
& icacls.exe $shareDir /inheritance:r /grant 'Administrators:(OI)(CI)F' /grant 'SYSTEM:(OI)(CI)F' /grant "${shareUser}:(OI)(CI)R" | Out-Null

$shareAccess = (Get-SmbShareAccess -Name $shareName).AccountName
Assert-True (@($shareAccess | Where-Object { $_ -match 'Everyone|ANONYMOUS LOGON' }).Count -eq 0) 'share allows no Everyone or anonymous access'

$configPath = Join-Path -Path $env:TEMP -ChildPath 'proctor-ci.json'
@{
    server       = '127.0.0.1'
    share        = $shareName
    userPrefix   = 'Alumno'
    deviceNumber = '01'
    examTitle    = 'CI exam'
    language     = 'en'
    shareUser    = $shareUser
} | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8

$shareCredential = New-Object System.Management.Automation.PSCredential -ArgumentList $shareUser, $securePassword
# A PSCredential cannot cross a powershell.exe -File boundary; the string
# form is bound as a username and the binder prompts for a password, which
# hangs CI. Seed share.cred through the same function install uses, and
# pass shareUser in the config instead.
Install-ShareCredential -Credential $shareCredential -DataDir 'C:\ProgramData\proctor'

Write-Information ''
Write-Information 'Running install.ps1...'
& powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File (Join-Path -Path $root -ChildPath 'install.ps1') `
    -Config $configPath
Assert-True ($LASTEXITCODE -eq 0) 'install.ps1 exits 0'

$editionId = Get-WindowsEditionId
Write-Information ''
Write-Information "Edition: $editionId"
Write-Information "Lockdown: $(Get-LockdownMode -EditionId $editionId)"

Write-Information 'Checking install state...'
$account = Get-LocalUser -Name $userName -ErrorAction SilentlyContinue
Assert-True ($null -ne $account) "account $userName exists"
$sid = $account.SID.Value

$profileEntry = Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue
Assert-True ($null -ne $profileEntry) 'profile exists without a logon'
Assert-True (Test-Path (Join-Path $profileEntry.LocalPath 'NTUSER.DAT')) 'NTUSER.DAT exists'

$winlogon = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Assert-True ($winlogon.AutoAdminLogon -eq '1') 'auto-logon enabled'
Assert-True ($winlogon.DefaultUserName -eq $userName) 'auto-logon targets the student'

Assert-True ($null -ne (Get-NetFirewallRule -DisplayName "BlockInternet-$userName" -ErrorAction SilentlyContinue)) 'outbound block rule exists'
Assert-True ($null -eq (Get-NetFirewallRule -DisplayName "AllowSMB-$userName" -ErrorAction SilentlyContinue)) 'no SMB allow rule for the student'

# Read the hive before the probe: its logon loads the hive under HKU, and
# handles this process opens there would keep it loaded through uninstall.
$hive = Mount-UserHive -Sid $sid
try {
    Assert-True (Test-Path "$($hive.Root)\Software\Policies\Microsoft\Edge") 'Edge policies in the student hive'
    Assert-True (Test-Path "$($hive.Root)\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer") 'Explorer restrictions in the student hive'
    $runKey = Get-ItemProperty -Path "$($hive.Root)\Software\Microsoft\Windows\CurrentVersion\Run"
    Assert-True ($runKey.ProctorKiosk -like '*--kiosk*') 'kiosk autorun present'
}
finally {
    Dismount-UserHive -Hive $hive
}

$blockFilter = Get-NetFirewallRule -DisplayName "BlockInternet-$userName" | Get-NetFirewallSecurityFilter
Assert-True ($blockFilter.LocalUser -match [regex]::Escape($sid)) 'block rule applies to the student SID'

# Windows Firewall never filters loopback, so the probe dials an outside host.
# The admin control connection shows the host is reachable from this runner.
$probeTarget = ([System.Net.Dns]::GetHostAddresses('github.com') |
    Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).IPAddressToString
$control = New-Object System.Net.Sockets.TcpClient
$controlConnected = $false
try {
    $controlConnect = $control.BeginConnect($probeTarget, 443, $null, $null)
    $controlConnected = $controlConnect.AsyncWaitHandle.WaitOne(5000) -and $control.Connected
}
finally {
    $control.Close()
}
Assert-True $controlConnected "admin reaches $($probeTarget):443"

Write-Information "Checking the student cannot reach $($probeTarget):443..."
$probeScript = 'C:\Users\Public\fw-probe.ps1'
$probeResult = 'C:\Users\Public\fw-probe.txt'
if (Test-Path $probeResult) { Remove-Item $probeResult -Force }
@"
`$target = '$probeTarget'
`$result = "C:\Users\Public\fw-probe.txt"
try {
    `$client = New-Object System.Net.Sockets.TcpClient
    `$connect = `$client.BeginConnect(`$target, 443, `$null, `$null)
    if (`$connect.AsyncWaitHandle.WaitOne(5000) -and `$client.Connected) {
        "connected" | Set-Content -Path `$result
    } else {
        "blocked" | Set-Content -Path `$result
    }
} catch {
    "blocked" | Set-Content -Path `$result
}
"@ | Set-Content -Path $probeScript -Encoding UTF8

# Start-Process -Credential logs on without loading the student profile, so
# the hive stays unloaded and uninstall can delete the profile afterwards.
$probePasswordPlain = "P!$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$probePassword = New-Object System.Security.SecureString
foreach ($c in $probePasswordPlain.ToCharArray()) { $probePassword.AppendChar($c) }
Set-LocalUser -Name $userName -Password $probePassword
try {
    $probeCredential = New-Object System.Management.Automation.PSCredential($userName, $probePassword)
    $probeProcess = Start-Process -FilePath 'powershell.exe' -Credential $probeCredential `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$probeScript`"" `
        -WorkingDirectory 'C:\Users\Public' -WindowStyle Hidden -Wait -PassThru
    Write-Information "  probe exit code: $($probeProcess.ExitCode)"
}
finally {
    try {
        Set-LocalUser -Name $userName -Password (New-Object System.Security.SecureString)
    } catch {
        Write-Warning "Could not restore the empty password: $($_.Exception.Message)"
    }
}

$probeOut = Get-Content -Path $probeResult -TotalCount 1 -ErrorAction SilentlyContinue
Write-Information "  probe result: $probeOut"
Assert-True ($probeProcess.ExitCode -eq 0) "probe ran (exit $($probeProcess.ExitCode))"
Assert-True ($probeOut -eq 'blocked') 'student cannot open an outbound connection'
Assert-True (-not (Test-Path "Registry::HKEY_USERS\$sid")) 'probe left the student hive unloaded'

Assert-True (Test-Path 'C:\Kiosk\index.html') 'index.html deployed'
Assert-True (Test-Path 'C:\Kiosk\sync-exam.ps1') 'sync-exam.ps1 deployed'

$kioskAcl = Get-Acl -Path 'C:\Kiosk'
$studentRights = $kioskAcl.Access | Where-Object { $_.IdentityReference -match [regex]::Escape($userName) }
Assert-True ($null -ne $studentRights) 'student has an explicit ACE on C:\Kiosk'
Assert-True (@($studentRights | Where-Object { $_.FileSystemRights -match 'Write|Modify|FullControl' }).Count -eq 0) 'student cannot write C:\Kiosk'

$credAcl = Get-Acl -Path 'C:\ProgramData\proctor\share.cred'
$credSids = $credAcl.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
Assert-True ($credSids.Count -eq 2 -and $credSids -contains 'S-1-5-18' -and $credSids -contains 'S-1-5-32-544') 'share.cred readable only by SYSTEM and Administrators'
Assert-True ((Get-Acl -Path 'C:\ProgramData\proctor').AreAccessRulesProtected) 'proctor data folder inherits no other ACEs'


$task = Get-ScheduledTask -TaskName "ExamSync-$userName" -ErrorAction SilentlyContinue
Assert-True ($null -ne $task) 'sync task registered'
Assert-True ($task.Principal.LogonType -eq 'ServiceAccount') 'task logon type is ServiceAccount'
Assert-True ($task.Principal.UserId -match 'SYSTEM') 'task runs as SYSTEM'

Write-Information ''
Write-Information 'Running the sync task...'
Start-ScheduledTask -TaskName "ExamSync-$userName"
$deadline = (Get-Date).AddMinutes(2)
do {
    Start-Sleep -Seconds 2
    $task = Get-ScheduledTask -TaskName "ExamSync-$userName"
} while ($task.State -eq 'Running' -and (Get-Date) -lt $deadline)
if ($task.State -eq 'Running') { throw "ExamSync-$userName still running after 2 minutes" }

$info = Get-ScheduledTaskInfo -TaskName "ExamSync-$userName"
Write-Information "  LastTaskResult: $($info.LastTaskResult)"
if ($info.LastTaskResult -ne 0) {
    Get-Content -Path 'C:\Kiosk\Logs\*.log' -ErrorAction SilentlyContinue
    Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -MaxEvents 30 |
        Format-Table TimeCreated, Id, Message -AutoSize | Out-String -Width 300
    throw "sync task failed with result $($info.LastTaskResult)"
}
Write-Information '  ok: sync task last result is 0'

Assert-True (Test-Path 'C:\Kiosk\Exam.pdf') 'Exam.pdf was copied from the share'
$localHash = (Get-FileHash -Path 'C:\Kiosk\Exam.pdf' -Algorithm SHA256).Hash
$fixtureHash = (Get-FileHash -Path $fixture -Algorithm SHA256).Hash
Write-Information "  copied:  $localHash"
Write-Information "  fixture: $fixtureHash"
Assert-True ($localHash -eq $fixtureHash) 'copied PDF matches the fixture'

Write-Information ''
Write-Information 'Checking the sync task fails without share access...'
$badPassword = New-Object System.Security.SecureString
foreach ($c in 'wrong-password'.ToCharArray()) {
    $badPassword.AppendChar($c)
}
Install-ShareCredential -Credential (New-Object System.Management.Automation.PSCredential -ArgumentList $shareUser, $badPassword) `
    -DataDir 'C:\ProgramData\proctor'
Start-ScheduledTask -TaskName "ExamSync-$userName"
$deadline = (Get-Date).AddMinutes(2)
do {
    Start-Sleep -Seconds 2
    $task = Get-ScheduledTask -TaskName "ExamSync-$userName"
} while ($task.State -eq 'Running' -and (Get-Date) -lt $deadline)
if ($task.State -eq 'Running') { throw "ExamSync-$userName still running after 2 minutes" }
$info = Get-ScheduledTaskInfo -TaskName "ExamSync-$userName"
Write-Information "  LastTaskResult: $($info.LastTaskResult)"
Assert-True ($info.LastTaskResult -ne 0) 'sync task fails with a bad credential'
Assert-True (Test-Path 'C:\Kiosk\Exam.pdf') 'Exam.pdf survives an unreachable share'

Install-ShareCredential -Credential $shareCredential -DataDir 'C:\ProgramData\proctor'

Write-Information ''
[gc]::Collect()
[gc]::WaitForPendingFinalizers()
Write-Information 'Running uninstall.ps1...'
& powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File (Join-Path -Path $root -ChildPath 'uninstall.ps1') -Force -UserName $userName
Assert-True ($LASTEXITCODE -eq 0) 'uninstall.ps1 exits 0'

Write-Information 'Checking the laptop is back to a clean state...'
Assert-True ($null -eq (Get-ScheduledTask -TaskName "ExamSync-$userName" -ErrorAction SilentlyContinue)) 'sync task removed'
Assert-True ($null -eq (Get-NetFirewallRule -DisplayName "BlockInternet-$userName" -ErrorAction SilentlyContinue)) 'block rule removed'
Assert-True ($null -eq (Get-LocalUser -Name $userName -ErrorAction SilentlyContinue)) 'student account removed'
Assert-True ($null -eq (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue)) 'profile removed'
Assert-True (-not (Test-Path "C:\Users\$userName")) 'profile folder removed'
Assert-True (-not (Test-Path 'C:\Kiosk')) 'C:\Kiosk removed'
Assert-True (-not (Test-Path 'C:\ProgramData\proctor')) 'C:\ProgramData\proctor removed'

$winlogon = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Assert-True ($winlogon.AutoAdminLogon -ne '1') 'auto-logon cleared'

Remove-SmbShare -Name $shareName -Force
Remove-LocalUser -Name $shareUser
Remove-Item -Path 'C:\Users\Public\fw-probe.ps1', 'C:\Users\Public\fw-probe.txt' -Force -ErrorAction SilentlyContinue
Write-Information ''
Write-Information 'Round trip passed'
