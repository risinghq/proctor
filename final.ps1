#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION - EDIT THIS SECTION ONLY
# ============================================================================
$CONFIG = @{
    NetworkShareBase   = "\\192.168.5.30\sidera\Examenes"
    UsernameTemplate   = "Dispositivo {0:D2}"
    StudentPassword    = "alumno"
    TotalStudents      = 30
    PollInterval       = 30
}

# ============================================================================
# SETUP
# ============================================================================
$KioskDir = "C:\ExamKiosk"
$ScriptsDir = "C:\Scripts"
$LogFile = "$ScriptsDir\deploy_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    
    $Color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        default   { "White" }
    }
    Write-Host $Entry -ForegroundColor $Color
}

foreach ($Dir in @($ScriptsDir, $KioskDir)) {
    if (-not (Test-Path $Dir)) {
        New-Item -Path $Dir -ItemType Directory -Force | Out-Null
    }
}

Write-Host "`n========================================"
Write-Host "   EXAM KIOSK DEPLOYMENT"
Write-Host "========================================`n"

# ============================================================================
# CHECK WINDOWS EDITION
# ============================================================================
$Edition = (Get-WmiObject -Class Win32_OperatingSystem).Caption
Write-Log "Windows: $Edition"

if ($Edition -match "Home") {
    Write-Log "Windows Home detected - requires Pro or Enterprise" -Level "ERROR"
    exit 1
}

# ============================================================================
# PROMPT FOR STUDENT NUMBER
# ============================================================================
Write-Host "Available: 1 to $($CONFIG.TotalStudents)`n"

do {
    $Input = Read-Host "Enter student number"
    $StudentNum = 0
    
    if ([int]::TryParse($Input, [ref]$StudentNum)) {
        if ($StudentNum -ge 1 -and $StudentNum -le $CONFIG.TotalStudents) {
            break
        }
    }
    Write-Host "Invalid. Enter 1-$($CONFIG.TotalStudents)" -ForegroundColor Red
} while ($true)

$UserName = $CONFIG.UsernameTemplate -f $StudentNum
$NetworkFolder = "$($CONFIG.NetworkShareBase)\$UserName"

Write-Log "User: $UserName"
Write-Log "Network: $NetworkFolder"

# ============================================================================
# VERIFY USER EXISTS
# ============================================================================
try {
    $null = Get-LocalUser -Name $UserName -ErrorAction Stop
    Write-Log "User account found" -Level "SUCCESS"
}
catch {
    Write-Log "User '$UserName' does not exist" -Level "ERROR"
    exit 1
}

# ============================================================================
# GENERATE FETCH SCRIPT
# ============================================================================
$FetchScript = @"
`$NetworkFolder = "$NetworkFolder"
`$LocalPDF = "C:\ExamKiosk\Exam.pdf"
`$LogFile = "C:\Scripts\fetch_runtime.log"

function Log(`$Msg) {
    "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - `$Msg" | Add-Content `$LogFile -ErrorAction SilentlyContinue
}

Log "Fetch started for $UserName"
Log "Monitoring: `$NetworkFolder"

if (Test-Path `$LocalPDF) {
    Remove-Item `$LocalPDF -Force -ErrorAction SilentlyContinue
    Log "Removed existing local PDF"
}

`$NetworkWait = 0
while (-not (Test-Path `$NetworkFolder -ErrorAction SilentlyContinue) -and `$NetworkWait -lt 60) {
    Start-Sleep -Seconds 5
    `$NetworkWait += 5
}

if (-not (Test-Path `$NetworkFolder)) {
    Log "ERROR: Cannot access network folder after 60 seconds"
}

while (`$true) {
    try {
        `$RemotePDF = Get-ChildItem -Path `$NetworkFolder -Filter "*.pdf" -ErrorAction SilentlyContinue | 
            Sort-Object LastWriteTime -Descending | 
            Select-Object -First 1
        
        if (`$RemotePDF) {
            if (-not (Test-Path `$LocalPDF)) {
                Copy-Item -Path `$RemotePDF.FullName -Destination `$LocalPDF -Force
                Log "PDF copied: `$(`$RemotePDF.Name)"
            }
            else {
                `$LocalTime = (Get-Item `$LocalPDF).LastWriteTime
                if (`$RemotePDF.LastWriteTime -gt `$LocalTime) {
                    Copy-Item -Path `$RemotePDF.FullName -Destination `$LocalPDF -Force
                    Log "PDF updated: `$(`$RemotePDF.Name)"
                }
            }
        }
    }
    catch {
        Log "ERROR: `$(`$_.Exception.Message)"
    }
    
    Start-Sleep -Seconds $($CONFIG.PollInterval)
}
"@

Set-Content -Path "$ScriptsDir\FetchExam.ps1" -Value $FetchScript -Force
Write-Log "Fetch script generated" -Level "SUCCESS"

# ============================================================================
# GENERATE HTML INTERFACE
# ============================================================================
$Html = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Examen</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { 
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: #fff;
            height: 100vh;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            overflow: hidden;
        }
        .badge {
            position: absolute;
            top: 20px;
            right: 20px;
            background: rgba(255,255,255,0.2);
            padding: 10px 20px;
            border-radius: 20px;
            font-weight: 600;
        }
        h1 { font-size: 2.5rem; margin-bottom: 1rem; }
        p { font-size: 1.1rem; opacity: 0.9; margin-bottom: 2rem; }
        .spinner {
            width: 40px;
            height: 40px;
            border: 3px solid rgba(255,255,255,0.3);
            border-top-color: #fff;
            border-radius: 50%;
            animation: spin 1s linear infinite;
        }
        .status { margin-top: 1rem; opacity: 0.7; }
        iframe {
            position: absolute;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            border: none;
            background: #fff;
            display: none;
        }
        @keyframes spin {
            to { transform: rotate(360deg); }
        }
    </style>
</head>
<body onload="check()" oncontextmenu="return false;">
    <div class="badge">$UserName</div>
    <h1>Examen</h1>
    <p>Esperando instrucciones del docente</p>
    <div class="spinner"></div>
    <div class="status">Cargando examen...</div>
    <iframe id="pdf"></iframe>
    <script>
        function check() {
            fetch('Exam.pdf?t=' + Date.now(), {method: 'HEAD'})
                .then(r => r.ok ? show() : wait())
                .catch(wait);
        }
        function show() {
            document.getElementById('pdf').src = 'Exam.pdf?t=' + Date.now();
            document.getElementById('pdf').style.display = 'block';
            setInterval(() => {
                document.getElementById('pdf').src = 'Exam.pdf?t=' + Date.now();
            }, 30000);
        }
        function wait() {
            setTimeout(check, 10000);
        }
    </script>
</body>
</html>
"@

Set-Content -Path "$KioskDir\index.html" -Value $Html -Force -Encoding UTF8
Write-Log "HTML interface generated" -Level "SUCCESS"

# ============================================================================
# SECURE KIOSK FOLDER
# ============================================================================
$Acl = Get-Acl $KioskDir
$Acl.SetAccessRuleProtection($true, $false)

$Rules = @(
    New-Object System.Security.AccessControl.FileSystemAccessRule(
        "SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    New-Object System.Security.AccessControl.FileSystemAccessRule(
        "Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    New-Object System.Security.AccessControl.FileSystemAccessRule(
        "Users", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
)

foreach ($Rule in $Rules) { $Acl.AddAccessRule($Rule) }
Set-Acl $KioskDir $Acl
Write-Log "Folder permissions set" -Level "SUCCESS"

# ============================================================================
# CONFIGURE AUTO-LOGIN
# ============================================================================
$WinLogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $WinLogon -Name "AutoAdminLogon" -Value "1" -Force
Set-ItemProperty -Path $WinLogon -Name "DefaultUserName" -Value $UserName -Force
Set-ItemProperty -Path $WinLogon -Name "DefaultPassword" -Value $CONFIG.StudentPassword -Force
Set-ItemProperty -Path $WinLogon -Name "DefaultDomainName" -Value "" -Force

Write-Log "Auto-login configured" -Level "SUCCESS"

# ============================================================================
# APPLY SECURITY POLICIES
# ============================================================================
$Policies = @{
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" = @{
        "DisableTaskMgr" = 1
    }
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" = @{
        "DisableCMD" = 2
    }
    "HKLM:\SOFTWARE\Policies\Microsoft\Edge" = @{
        "DeveloperToolsAvailability" = 2
        "PrintingEnabled" = 0
        "DownloadRestrictions" = 3
        "InPrivateModeAvailability" = 1
        "HideFirstRunExperience" = 1
        "BrowserSignin" = 0
        "SyncDisabled" = 1
    }
}

foreach ($Path in $Policies.Keys) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    foreach ($Key in $Policies[$Path].Keys) {
        Set-ItemProperty -Path $Path -Name $Key -Value $Policies[$Path][$Key] -Type DWord -Force
    }
}

Write-Log "Security policies applied" -Level "SUCCESS"

# ============================================================================
# CONFIGURE EDGE KIOSK MODE
# ============================================================================
$EdgePath = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
if (-not (Test-Path $EdgePath)) {
    $EdgePath = "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
}

$KioskCmd = "`"$EdgePath`" --kiosk `"file:///C:/ExamKiosk/index.html`" --edge-kiosk-type=fullscreen --no-first-run --disable-features=EdgeEnableMediaRouter"

$RunKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
Set-ItemProperty -Path $RunKey -Name "ExamKiosk" -Value $KioskCmd -Force

Write-Log "Edge kiosk mode configured" -Level "SUCCESS"

# ============================================================================
# REGISTER FETCH TASK
# ============================================================================
$TaskName = "ExamFetch"
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$Action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptsDir\FetchExam.ps1`""

$Trigger = New-ScheduledTaskTrigger -AtStartup

$Principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Password -RunLevel Highest

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

try {
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
        -Principal $Principal -Settings $Settings -Force | Out-Null
    
    $Task = Get-ScheduledTask -TaskName $TaskName
    $Task.Principal.UserId = $UserName
    $Task | Set-ScheduledTask -User $UserName -Password $CONFIG.StudentPassword | Out-Null
    
    Write-Log "Scheduled task registered as $UserName" -Level "SUCCESS"
}
catch {
    Write-Log "Task registration failed: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host "`n========================================"
Write-Host "   DEPLOYMENT COMPLETE"
Write-Host "========================================`n"

Write-Log "User: $UserName" -Level "SUCCESS"
Write-Log "Network: $NetworkFolder" -Level "SUCCESS"
Write-Log "Auto-login: ENABLED" -Level "SUCCESS"
Write-Log "Kiosk mode: ENABLED" -Level "SUCCESS"

Write-Host "`nNext steps:"
Write-Host "1. Restart the laptop"
Write-Host "2. Auto-login to $UserName"
Write-Host "3. Edge launches fullscreen"
Write-Host "4. PDF appears when teacher drops it`n"

Read-Host "Press Enter to exit"
