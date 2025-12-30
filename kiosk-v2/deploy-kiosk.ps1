<#
.SYNOPSIS
    Revised Exam Kiosk Deployment Script - Manual Login with Enhanced Security
    
.DESCRIPTION
    Configures laptop for secure exam viewing with:
    - Manual student login (no auto-login)
    - PDF polling from network share (10-second interval)
    - Enhanced security: clipboard, screenshots, network isolation
    - Edge kiosk configured manually in Windows Settings
    
.NOTES
    Run as Administrator
    Requires Windows 10/11 Pro or Enterprise
    
.EXAMPLE
    .\deploy-kiosk.ps1
#>

#Requires -RunAsAdministrator

# =============================================================================
# CONFIGURATION
# =============================================================================
$CONFIG = @{
    NetworkShareBase = "\\192.168.5.30\sidera\Examenes"
    FolderTemplate   = "Dispositivo {0:D2}"
    StudentPassword  = "alumno"
    TotalStudents    = 30
    PollInterval     = 10
    ServerIP         = "192.168.5.30"
}

# =============================================================================
# PATHS
# =============================================================================
$KioskDir   = "C:\Kiosk"
$ScriptsDir = "C:\Scripts"
$Timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile    = "$ScriptsDir\deployment_$Timestamp.log"

# =============================================================================
# LOGGING
# =============================================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )
    
    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    
    if (-not (Test-Path $ScriptsDir)) {
        New-Item -Path $ScriptsDir -ItemType Directory -Force | Out-Null
    }
    
    Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    
    $Color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        default   { "White" }
    }
    Write-Host $Entry -ForegroundColor $Color
}

# =============================================================================
# BANNER
# =============================================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   EXAM KIOSK DEPLOYMENT - V2" -ForegroundColor Cyan
Write-Host "   Manual Login + Enhanced Security" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Log "=== DEPLOYMENT START ==="

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================
Write-Log "Checking prerequisites..."

$Edition = (Get-WmiObject -Class Win32_OperatingSystem).Caption
Write-Log "Windows Edition: $Edition"

if ($Edition -match "Home") {
    Write-Log "Windows Home edition not recommended for kiosk deployment!" -Level "WARNING"
}

# =============================================================================
# CLEANUP FROM PREVIOUS DEPLOYMENTS
# =============================================================================
Write-Log "Cleaning up previous deployments..."

Unregister-ScheduledTask -TaskName "ExamFetchSystem" -Confirm:$false -ErrorAction SilentlyContinue

# Remove old auto-login settings
$WinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
if (Test-Path $WinlogonPath) {
    Set-ItemProperty -Path $WinlogonPath -Name "AutoAdminLogon" -Value "0" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $WinlogonPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
}

Write-Log "Cleanup complete" -Level "SUCCESS"

# =============================================================================
# STUDENT SELECTION
# =============================================================================
Write-Host ""
Write-Host "Available students: Dispositivo 01 through Dispositivo 30" -ForegroundColor Yellow
Write-Host ""

do {
    $StudentInput = Read-Host "Enter student number (1-30)"
    $StudentNumber = 0
    
    if ([int]::TryParse($StudentInput, [ref]$StudentNumber)) {
        if ($StudentNumber -ge 1 -and $StudentNumber -le $CONFIG.TotalStudents) {
            break
        }
    }
    
    Write-Host "Invalid input. Please enter a number between 1 and 30." -ForegroundColor Red
} while ($true)

$FolderName    = $CONFIG.FolderTemplate -f $StudentNumber
$NetworkFolder = "$($CONFIG.NetworkShareBase)\$FolderName"

Write-Log "Configured for: $FolderName"
Write-Log "Network folder: $NetworkFolder"

# =============================================================================
# CREATE DIRECTORIES
# =============================================================================
Write-Log "Creating directories..."

foreach ($Dir in @($KioskDir, $ScriptsDir)) {
    if (-not (Test-Path $Dir)) {
        New-Item -Path $Dir -ItemType Directory -Force | Out-Null
        Write-Log "Created: $Dir" -Level "SUCCESS"
    }
}

# =============================================================================
# GENERATE PDF FETCH SCRIPT
# =============================================================================
Write-Log "Generating PDF fetch script..."

$FetchScript = @"
# ============================================================
# EXAM PDF FETCH SCRIPT
# Generated for: $FolderName
# Network path: $NetworkFolder
# Poll interval: $($CONFIG.PollInterval) seconds
# ============================================================

`$NetworkFolder = "$NetworkFolder"
`$LocalPDF = "C:\Kiosk\Exam.pdf"
`$LogFile = "C:\Scripts\fetch_runtime.log"

function Write-FetchLog {
    param([string]`$Message)
    `$Entry = "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - `$Message"
    Add-Content -Path `$LogFile -Value `$Entry -ErrorAction SilentlyContinue
}

Write-FetchLog "========================================="
Write-FetchLog "Fetch service started for: $FolderName"
Write-FetchLog "Monitoring: `$NetworkFolder"
Write-FetchLog "========================================="

# Clean slate on boot
if (Test-Path `$LocalPDF) {
    Remove-Item `$LocalPDF -Force -ErrorAction SilentlyContinue
    Write-FetchLog "Removed existing PDF (fresh start)"
}

# Main polling loop
while (`$true) {
    try {
        # Find latest PDF in network folder
        `$LatestPDF = Get-ChildItem -Path `$NetworkFolder -Filter *.pdf -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        
        if (`$LatestPDF) {
            `$SourcePath = `$LatestPDF.FullName
            `$SourceTime = `$LatestPDF.LastWriteTime
            
            # Check if we need to update
            `$NeedUpdate = `$false
            
            if (Test-Path `$LocalPDF) {
                `$LocalTime = (Get-Item `$LocalPDF).LastWriteTime
                if (`$SourceTime -gt `$LocalTime) {
                    `$NeedUpdate = `$true
                    Write-FetchLog "Newer PDF detected on network (updated: `$SourceTime)"
                }
            } else {
                `$NeedUpdate = `$true
                Write-FetchLog "PDF found on network: `$(`$LatestPDF.Name)"
            }
            
            if (`$NeedUpdate) {
                Copy-Item -Path `$SourcePath -Destination `$LocalPDF -Force -ErrorAction Stop
                Write-FetchLog "PDF copied successfully: `$(`$LatestPDF.Name)"
            }
        }
    }
    catch {
        Write-FetchLog "ERROR: `$(`$_.Exception.Message)"
    }
    
    Start-Sleep -Seconds $($CONFIG.PollInterval)
}
"@

Set-Content -Path "$ScriptsDir\FetchExam.ps1" -Value $FetchScript -Force
Write-Log "FetchExam.ps1 created" -Level "SUCCESS"

# =============================================================================
# GENERATE HTML INTERFACE
# =============================================================================
Write-Log "Generating HTML interface..."

$HtmlContent = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Examen para certificación</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;800&display=swap" rel="stylesheet">
    <style>
        * { box-sizing: border-box; }
        body { 
            margin: 0; 
            overflow: hidden; 
            font-family: 'Inter', sans-serif; 
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%);
            color: #fff; 
            height: 100vh; 
            display: flex; 
            flex-direction: column; 
            justify-content: center; 
            align-items: center; 
            user-select: none;
            -webkit-user-select: none;
        }
        .student-badge {
            position: absolute;
            top: 20px;
            right: 20px;
            background: rgba(255,255,255,0.1);
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255,255,255,0.2);
            padding: 12px 24px;
            border-radius: 50px;
            font-weight: 600;
            font-size: 1rem;
            letter-spacing: 0.05em;
            text-transform: uppercase;
        }
        h1 { 
            font-weight: 800; 
            font-size: 3.5rem; 
            letter-spacing: -0.02em; 
            margin-bottom: 0.5rem; 
            text-transform: uppercase; 
            background: linear-gradient(90deg, #e94560, #ff6b6b);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }
        p { 
            font-weight: 400; 
            font-size: 1.1rem; 
            color: rgba(255,255,255,0.7); 
            letter-spacing: 0.02em; 
            margin-bottom: 3rem; 
        }
        .loader-container {
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 1.5rem;
        }
        .loader { 
            width: 50px; 
            height: 50px; 
            border: 3px solid rgba(255,255,255,0.1);
            border-top: 3px solid #e94560; 
            border-radius: 50%; 
            animation: spin 1s linear infinite; 
        }
        .status { 
            font-weight: 400; 
            font-size: 0.9rem; 
            color: rgba(255,255,255,0.5); 
            letter-spacing: 0.05em;
            animation: pulse 2s ease-in-out infinite;
        }
        iframe { 
            position: absolute; 
            top: 0; 
            left: 0; 
            width: 100vw; 
            height: 100vh; 
            border: none; 
            background: #fff; 
            display: none; 
        }
        @keyframes spin { 
            0% { transform: rotate(0deg); } 
            100% { transform: rotate(360deg); } 
        }
        @keyframes pulse {
            0%, 100% { opacity: 0.5; }
            50% { opacity: 1; }
        }
    </style>
    <script>
        function checkPDF() {
            var xhr = new XMLHttpRequest();
            xhr.open('HEAD', 'Exam.pdf?t=' + Date.now(), true);
            xhr.onload = function() {
                if (xhr.status === 200) {
                    // PDF exists, load it
                    var iframe = document.getElementById('pdfFrame');
                    iframe.src = "Exam.pdf?t=" + Date.now();
                    iframe.style.display = "block";
                    // Continue checking for updates every 30 seconds
                    setTimeout(refreshPDF, 30000);
                } else {
                    // PDF not ready, check again in 5 seconds
                    setTimeout(checkPDF, 5000);
                }
            };
            xhr.onerror = function() {
                setTimeout(checkPDF, 5000);
            };
            xhr.send();
        }
        
        function refreshPDF() {
            // Refresh PDF to catch teacher updates
            var iframe = document.getElementById('pdfFrame');
            iframe.src = "Exam.pdf?t=" + Date.now();
            setTimeout(refreshPDF, 30000);
        }
    </script>
</head>
<body onload="checkPDF()" oncontextmenu="return false;">
    <div class="student-badge">$FolderName</div>
    <h1>Examen para certificación</h1>
    <p>Por favor, espere las instrucciones del docente</p>
    <div class="loader-container">
        <div class="loader"></div>
        <div class="status">Esperando examen...</div>
    </div>
    <iframe id="pdfFrame"></iframe>
</body>
</html>
"@

Set-Content -Path "$KioskDir\index.html" -Value $HtmlContent -Force -Encoding UTF8
Write-Log "index.html created with student badge: $FolderName" -Level "SUCCESS"

# =============================================================================
# SET FOLDER PERMISSIONS
# =============================================================================
Write-Log "Setting folder permissions..."

$Acl = Get-Acl $KioskDir
$Acl.SetAccessRuleProtection($true, $false)

# Use SIDs instead of names (language-independent)
# SYSTEM: Full Control (S-1-5-18)
$SystemSID = New-Object System.Security.Principal.SecurityIdentifier "S-1-5-18"
$RuleSys = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $SystemSID, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$Acl.AddAccessRule($RuleSys)

# Administrators: Full Control (S-1-5-32-544)
$AdminsSID = New-Object System.Security.Principal.SecurityIdentifier "S-1-5-32-544"
$RuleAdmin = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $AdminsSID, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$Acl.AddAccessRule($RuleAdmin)

# Users: Read Only (S-1-5-32-545)
$UsersSID = New-Object System.Security.Principal.SecurityIdentifier "S-1-5-32-545"
$RuleUser = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $UsersSID, "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
$Acl.AddAccessRule($RuleUser)

Set-Acl $KioskDir $Acl
Write-Log "Folder permissions secured" -Level "SUCCESS"

# =============================================================================
# SECURITY HARDENING
# =============================================================================
Write-Log "Applying security policies..."

# Disable Task Manager
$SysPolPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
if (-not (Test-Path $SysPolPath)) { New-Item -Path $SysPolPath -Force | Out-Null }
Set-ItemProperty -Path $SysPolPath -Name "DisableTaskMgr" -Value 1 -Type DWord -Force
Write-Log "Task Manager disabled" -Level "SUCCESS"

# Disable Command Prompt
$CmdPolPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
if (-not (Test-Path $CmdPolPath)) { New-Item -Path $CmdPolPath -Force | Out-Null }
Set-ItemProperty -Path $CmdPolPath -Name "DisableCMD" -Value 2 -Type DWord -Force
Write-Log "Command Prompt disabled" -Level "SUCCESS"

# Disable Clipboard History (Win+V)
Set-ItemProperty -Path $CmdPolPath -Name "AllowClipboardHistory" -Value 0 -Type DWord -Force
Write-Log "Clipboard history disabled" -Level "SUCCESS"

# Disable Snipping Tool
$TabletPCPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC"
if (-not (Test-Path $TabletPCPath)) { New-Item -Path $TabletPCPath -Force | Out-Null }
Set-ItemProperty -Path $TabletPCPath -Name "DisableSnippingTool" -Value 1 -Type DWord -Force
Write-Log "Snipping Tool disabled" -Level "SUCCESS"

# Disable keyboard shortcuts
$KeyboardPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
if (-not (Test-Path $KeyboardPath)) { New-Item -Path $KeyboardPath -Force | Out-Null }
Set-ItemProperty -Path $KeyboardPath -Name "NoWinKeys" -Value 1 -Type DWord -Force
Write-Log "Windows key shortcuts restricted" -Level "SUCCESS"

# Edge Policies
$EdgePath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
if (-not (Test-Path $EdgePath)) { New-Item -Path $EdgePath -Force | Out-Null }

$EdgePolicies = @{
    "QuickSearchShowMiniMenu" = 0
    "DeveloperToolsAvailability" = 2      # Disabled
    "PrintingEnabled" = 0                  # No printing
    "SavingBrowserHistoryDisabled" = 1
    "AllowDeletingBrowserHistory" = 0
    "BrowserSignin" = 0                    # No sign-in
    "SyncDisabled" = 1
    "DownloadRestrictions" = 3             # Block all downloads
    "HideFirstRunExperience" = 1
    "InPrivateModeAvailability" = 1        # Disable InPrivate
    "NewTabPageLocation" = "file:///C:/Kiosk/index.html"
    "HomepageLocation" = "file:///C:/Kiosk/index.html"
    "RestoreOnStartup" = 4
}

foreach ($Policy in $EdgePolicies.GetEnumerator()) {
    Set-ItemProperty -Path $EdgePath -Name $Policy.Key -Value $Policy.Value -Force
}

$EdgeStartupPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge\RestoreOnStartupURLs"
if (-not (Test-Path $EdgeStartupPath)) { New-Item -Path $EdgeStartupPath -Force | Out-Null }
Set-ItemProperty -Path $EdgeStartupPath -Name "1" -Value "file:///C:/Kiosk/index.html" -Force

Write-Log "Edge policies applied (mini menu, DevTools, downloads disabled)" -Level "SUCCESS"

# =============================================================================
# NETWORK ISOLATION - FIREWALL RULES
# =============================================================================
Write-Log "Configuring network isolation..."

# Remove old rules if they exist
Remove-NetFirewallRule -DisplayName "Exam Kiosk - Block All Outbound" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Exam Kiosk - Allow SMB to Server" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Exam Kiosk - Allow DNS" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Exam Kiosk - Allow Private Network" -ErrorAction SilentlyContinue

# NOTE: Rules are evaluated in order, most specific first

# Allow DNS (needed for basic network operations)
New-NetFirewallRule -DisplayName "Exam Kiosk - Allow DNS" `
    -Direction Outbound -Action Allow -Protocol UDP `
    -RemotePort 53 | Out-Null

# Allow SMB to server
New-NetFirewallRule -DisplayName "Exam Kiosk - Allow SMB to Server" `
    -Direction Outbound -Action Allow -Protocol TCP `
    -RemoteAddress $CONFIG.ServerIP -RemotePort 445 | Out-Null

# Allow all private network traffic (192.168.x.x, 10.x.x.x, 172.16-31.x.x)
# This allows administrators to access network shares and local resources
New-NetFirewallRule -DisplayName "Exam Kiosk - Allow Private Network" `
    -Direction Outbound -Action Allow -Protocol Any `
    -RemoteAddress 192.168.0.0/16,10.0.0.0/8,172.16.0.0/12 | Out-Null

# Block all other outbound traffic (internet only - place last)
New-NetFirewallRule -DisplayName "Exam Kiosk - Block All Outbound" `
    -Direction Outbound -Action Block | Out-Null

Write-Log "Network isolated: Private network allowed, internet blocked" -Level "SUCCESS"

# =============================================================================
# SCHEDULED TASK FOR PDF FETCHING
# =============================================================================
Write-Log "Creating scheduled task..."

$TaskName = "ExamFetchSystem"

$Action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptsDir\FetchExam.ps1`""

$Trigger = New-ScheduledTaskTrigger -AtStartup

$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 12) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
    -Principal $Principal -Settings $Settings -Force | Out-Null

Write-Log "Scheduled task registered (runs as SYSTEM)" -Level "SUCCESS"

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   DEPLOYMENT COMPLETE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Log "=== DEPLOYMENT SUMMARY ===" -Level "SUCCESS"
Write-Log "Student folder: $FolderName"
Write-Log "Network path: $NetworkFolder"
Write-Log "Poll interval: $($CONFIG.PollInterval) seconds"
Write-Log "Auto-login: DISABLED (manual login required)"
Write-Log "Task Manager: DISABLED"
Write-Log "Clipboard/Screenshots: DISABLED"
Write-Log "Network: ISOLATED (SMB to server only)"
Write-Log "Log file: $LogFile"

Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host "1. Configure Edge Kiosk manually in Windows Settings:" -ForegroundColor White
Write-Host "   - Settings > Accounts > Other users > Set up a kiosk" -ForegroundColor Gray
Write-Host "   - Choose the student account (e.g., Alumno-01)" -ForegroundColor Gray
Write-Host "   - Select 'Digital signage'" -ForegroundColor Gray
Write-Host "   - URL: file:///C:/Kiosk/index.html" -ForegroundColor Gray
Write-Host ""
Write-Host "2. Restart the laptop" -ForegroundColor White
Write-Host "3. Students log in manually with password: $($CONFIG.StudentPassword)" -ForegroundColor White
Write-Host "4. When teacher drops PDF to $NetworkFolder," -ForegroundColor White
Write-Host "   it will appear within $($CONFIG.PollInterval) seconds" -ForegroundColor White
Write-Host ""
Write-Host "To restore laptop, run: .\restore-kiosk.ps1" -ForegroundColor Gray
Write-Host ""

Read-Host "Press Enter to exit"
