#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$CONFIG = @{
    NetworkShareBase = "\\192.168.5.30\sidera\Examenes"
    FolderTemplate   = "Dispositivo {0:D2}"
    StudentPassword  = "alumno"
    TotalStudents    = 30
    PollInterval     = 30
}

# ============================================================================
# PATHS
# ============================================================================
$KioskDir   = "C:\ExamKiosk"
$ScriptsDir = "C:\Scripts"
$LogFile    = "$ScriptsDir\deploy.log"

if (-not (Test-Path $ScriptsDir)) {
    New-Item $ScriptsDir -ItemType Directory -Force | Out-Null
}

# ============================================================================
# LOG
# ============================================================================
function Write-Log {
    param($Msg, $Level = "INFO")
    $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Msg"
    Add-Content $LogFile $Line -ErrorAction SilentlyContinue
    Write-Host $Line
}

Write-Log "=== DEPLOY START ==="

# ============================================================================
# CLEANUP FROM PREVIOUS RUNS
# ============================================================================
Write-Log "Cleaning up previous tasks and registry entries"

Unregister-ScheduledTask -TaskName "ExamFetch" -Confirm:$false -ErrorAction SilentlyContinue

$RunKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
Remove-ItemProperty -Path $RunKey -Name "ExamKiosk" -ErrorAction SilentlyContinue

# ============================================================================
# PREPARE DIRECTORIES (NON-INTERACTIVE)
# ============================================================================
foreach ($Dir in @($KioskDir, $ScriptsDir)) {
    if (-not (Test-Path $Dir)) {
        New-Item $Dir -ItemType Directory -Force | Out-Null
    }
    icacls $Dir /reset /t /c /q | Out-Null
}

# ============================================================================
# AUTO-DETECT STUDENT USERS
# ============================================================================
$Students = Get-LocalUser |
    Where-Object { $_.Name -match '^Alumno-(\d+)$' } |
    ForEach-Object {
        [PSCustomObject]@{
            UserName = $_.Name
            Number   = [int]$Matches[1]
        }
    } |
    Where-Object { $_.Number -ge 1 -and $_.Number -le $CONFIG.TotalStudents } |
    Sort-Object Number

if (-not $Students) {
    throw "No local users matching 'Alumno-XX' were found."
}

Write-Host ""
Write-Host "Detected students:"
$Students | ForEach-Object {
    Write-Host ("  {0,2}: {1}" -f $_.Number, $_.UserName)
}

do {
    $n = [int](Read-Host "Select student number (1-$($CONFIG.TotalStudents))")
} until ($Students.Number -contains $n)

$Selected      = $Students | Where-Object Number -eq $n
$UserName      = $Selected.UserName
$FolderName    = $CONFIG.FolderTemplate -f $n
$NetworkFolder = "$($CONFIG.NetworkShareBase)\$FolderName"

Write-Log "Resolved user: $UserName"
Write-Log "Network folder: $NetworkFolder"

# ============================================================================
# FETCH SCRIPT
# ============================================================================
$FetchScript = @"
`$NetworkFolder = "$NetworkFolder"
`$LocalPDF = "C:\ExamKiosk\Exam.pdf"

while (`$true) {
    try {
        `$pdf = Get-ChildItem `$NetworkFolder -Filter *.pdf -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending |
               Select-Object -First 1

        if (`$pdf) {
            Copy-Item `$pdf.FullName `$LocalPDF -Force
        }
    } catch {}
    Start-Sleep $($CONFIG.PollInterval)
}
"@

Set-Content "$ScriptsDir\FetchExam.ps1" $FetchScript -Force

# ============================================================================
# HTML
# ============================================================================
$Html = @"
<!DOCTYPE html>
<html>
<body style="margin:0">
<iframe src="Exam.pdf" style="border:0;width:100vw;height:100vh"></iframe>
</body>
</html>
"@

Set-Content "$KioskDir\index.html" $Html -Encoding UTF8 -Force

# ============================================================================
# LOCK KIOSK FOLDER (SID-SAFE)
# ============================================================================
$Acl = Get-Acl $KioskDir
$Acl.SetAccessRuleProtection($true, $false)

$SystemSID = New-Object System.Security.Principal.SecurityIdentifier "S-1-5-18"
$AdminsSID = New-Object System.Security.Principal.SecurityIdentifier "S-1-5-32-544"
$UsersSID  = New-Object System.Security.Principal.SecurityIdentifier "S-1-5-32-545"

$Acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $SystemSID, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
)))
$Acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $AdminsSID, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
)))
$Acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $UsersSID, "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow"
)))

Set-Acl $KioskDir $Acl

# ============================================================================
# AUTO LOGIN
# ============================================================================
$W = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty $W AutoAdminLogon 1
Set-ItemProperty $W DefaultUserName $UserName
Set-ItemProperty $W DefaultPassword $CONFIG.StudentPassword

# ============================================================================
# EDGE KIOSK (CONFIRMED PATH)
# ============================================================================
$Edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"

if (-not (Test-Path $Edge)) {
    throw "Microsoft Edge not found at expected path."
}

Set-ItemProperty $RunKey `
    ExamKiosk "`"$Edge`" --kiosk file:///C:/ExamKiosk/index.html --edge-kiosk-type=fullscreen"

Write-Log "Edge kiosk configured"

# ============================================================================
# SCHEDULED TASK
# ============================================================================
$Action  = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptsDir\FetchExam.ps1`""
$Trigger = New-ScheduledTaskTrigger -AtStartup

Register-ScheduledTask `
    -TaskName "ExamFetch" `
    -Action $Action `
    -Trigger $Trigger `
    -User $UserName `
    -Password $CONFIG.StudentPassword `
    -RunLevel Highest `
    -Force

Write-Log "Scheduled task registered"

Write-Log "DEPLOYMENT COMPLETE - REBOOT NOW"
Write-Log "=== DEPLOY END ==="
