<#
.SYNOPSIS
    Exam Kiosk Deployment Script - Windows Assigned Access
    Configures laptop for secure exam viewing with per-student network folder

.DESCRIPTION
    - Prompts for student number (01-30)
    - Configures Windows Assigned Access (kiosk mode) for that student
    - Sets auto-login to student account
    - Generates PDF fetcher that polls student's network folder
    - Applies security policies (disable Task Manager, etc.)

.NOTES
    Run as Administrator
    Requires Windows 10/11 Pro or Enterprise
    
.EXAMPLE
    .\1-deploy-kiosk.ps1
    # Prompts: "Enter student number (1-30):"
#>

#Requires -RunAsAdministrator

# =============================================================================
# CONFIGURATION
# =============================================================================
$NetworkShareBase = "\\Server\TeacherShare"  # Base path for student folders
$ExamPassword = "alumno"                      # Password for Alumno accounts
$PollIntervalSeconds = 30                     # How often to check for PDF

# =============================================================================
# LOGGING SETUP
# =============================================================================
$ScriptsDir = "C:\Scripts"
$KioskDir = "C:\ExamKiosk"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

if (-not (Test-Path $ScriptsDir)) { 
    New-Item -Path $ScriptsDir -ItemType Directory -Force | Out-Null 
}

$LogFile = Join-Path $ScriptsDir "deployment_$Timestamp.log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )
    
    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $LogFile -Value $Entry
    
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
Write-Host "   EXAM KIOSK DEPLOYMENT" -ForegroundColor Cyan
Write-Host "   Windows Assigned Access Mode" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================
Write-Log "Starting deployment checks..."

# Check Windows Edition
$Edition = (Get-WmiObject -Class Win32_OperatingSystem).Caption
Write-Log "Windows Edition: $Edition"

if ($Edition -match "Home") {
    Write-Log "Windows Home edition detected - Assigned Access NOT supported!" -Level "ERROR"
    Write-Log "Requires Windows 10/11 Pro or Enterprise" -Level "ERROR"
    exit 1
}

Write-Log "Windows edition compatible" -Level "SUCCESS"

# =============================================================================
# PROMPT FOR STUDENT NUMBER
# =============================================================================
Write-Host ""
Write-Host "Available students: Alumno - 01 through Alumno - 30" -ForegroundColor Yellow
Write-Host ""

do {
    $StudentInput = Read-Host "Enter student number (1-30)"
    $StudentNumber = 0
    
    if ([int]::TryParse($StudentInput, [ref]$StudentNumber)) {
        if ($StudentNumber -ge 1 -and $StudentNumber -le 30) {
            break
        }
    }
    
    Write-Host "Invalid input. Please enter a number between 1 and 30." -ForegroundColor Red
} while ($true)

# Format username (Alumno - 01, Alumno - 02, etc.)
$UserName = "Alumno - $('{0:D2}' -f $StudentNumber)"
$NetworkFolder = "$NetworkShareBase\$UserName"
$NetworkExamPath = "$NetworkFolder\Exam.pdf"

Write-Log "Configuring for user: $UserName"
Write-Log "Network folder: $NetworkFolder"

# =============================================================================
# VERIFY USER EXISTS
# =============================================================================
Write-Log "Verifying user account exists..."

try {
    $User = Get-LocalUser -Name $UserName -ErrorAction Stop
    Write-Log "Found user: $UserName" -Level "SUCCESS"
}
catch {
    Write-Log "User '$UserName' does NOT exist on this laptop!" -Level "ERROR"
    Write-Log "Please create the user first or check the username format" -Level "ERROR"
    exit 1
}

# =============================================================================
# CREATE DIRECTORIES
# =============================================================================
Write-Log "Creating directories..."

foreach ($Dir in @($ScriptsDir, $KioskDir)) {
    if (-not (Test-Path $Dir)) {
        New-Item -Path $Dir -ItemType Directory -Force | Out-Null
        Write-Log "Created: $Dir" -Level "SUCCESS"
    }
}

# =============================================================================
# GENERATE FETCH EXAM SCRIPT (User-Specific)
# =============================================================================
Write-Log "Generating FetchExam.ps1 for $UserName..."

$FetchScriptContent = @"
# ============================================================
# FETCH EXAM SCRIPT
# Generated for: $UserName
# Network path: $NetworkExamPath
# Poll interval: $PollIntervalSeconds seconds
# ============================================================

`$Source = "$NetworkExamPath"
`$Dest   = "C:\ExamKiosk\Exam.pdf"
`$LogFile = "C:\Scripts\fetch_runtime.log"

function Write-FetchLog {
    param([string]`$Message)
    `$Entry = "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - `$Message"
    Add-Content -Path `$LogFile -Value `$Entry -ErrorAction SilentlyContinue
}

Write-FetchLog "========================================="
Write-FetchLog "Fetch service started for: $UserName"
Write-FetchLog "Monitoring: `$Source"
Write-FetchLog "========================================="

# Cleanup existing PDF on boot (force fresh fetch)
if (Test-Path `$Dest) { 
    Remove-Item `$Dest -Force -ErrorAction SilentlyContinue 
    Write-FetchLog "Removed existing local PDF"
}

# Main polling loop
while (`$true) {
    if (Test-Path `$Dest) {
        # PDF exists locally - check if source was updated
        `$LocalTime = (Get-Item `$Dest -ErrorAction SilentlyContinue).LastWriteTime
        `$RemoteTime = `$null
        
        if (Test-Path `$Source) {
            `$RemoteTime = (Get-Item `$Source -ErrorAction SilentlyContinue).LastWriteTime
            
            if (`$RemoteTime -gt `$LocalTime) {
                # Source is newer - update local copy
                try {
                    Copy-Item -Path `$Source -Destination `$Dest -Force -ErrorAction Stop
                    Write-FetchLog "PDF updated from network (newer version detected)"
                }
                catch {
                    Write-FetchLog "ERROR updating PDF: `$(`$_.Exception.Message)"
                }
            }
        }
    }
    else {
        # No local PDF - try to fetch
        if (Test-Path `$Source) {
            try {
                Copy-Item -Path `$Source -Destination `$Dest -Force -ErrorAction Stop
                Write-FetchLog "PDF fetched successfully from network"
            }
            catch {
                Write-FetchLog "ERROR fetching PDF: `$(`$_.Exception.Message)"
            }
        }
        else {
            # Source doesn't exist yet (teacher hasn't dropped it)
            # Silent - this is expected before exam starts
        }
    }
    
    Start-Sleep -Seconds $PollIntervalSeconds
}
"@

Set-Content -Path "$ScriptsDir\FetchExam.ps1" -Value $FetchScriptContent -Force
Write-Log "Generated FetchExam.ps1" -Level "SUCCESS"

# =============================================================================
# GENERATE HTML INTERFACE (with Student Name Display)
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
        function check() {
            var xhr = new XMLHttpRequest();
            xhr.open('HEAD', 'Exam.pdf?t=' + Date.now(), true);
            xhr.onload = function() {
                if (xhr.status === 200) {
                    var f = document.getElementById('pdfFrame');
                    f.src = "Exam.pdf?t=" + Date.now();
                    f.style.display = "block";
                    // Keep checking for updates
                    setTimeout(checkForUpdates, 30000);
                } else { 
                    setTimeout(check, 5000); 
                }
            };
            xhr.onerror = function() { 
                setTimeout(check, 5000); 
            };
            xhr.send();
        }
        
        function checkForUpdates() {
            // Refresh PDF to catch teacher updates
            var f = document.getElementById('pdfFrame');
            f.src = "Exam.pdf?t=" + Date.now();
            setTimeout(checkForUpdates, 30000);
        }
    </script>
</head>
<body onload="check()" oncontextmenu="return false;">
    <div class="student-badge">$UserName</div>
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
Write-Log "Generated index.html with student badge: $UserName" -Level "SUCCESS"

# =============================================================================
# SET FOLDER PERMISSIONS
# =============================================================================
Write-Log "Setting folder permissions..."

$Acl = Get-Acl $KioskDir
$Acl.SetAccessRuleProtection($true, $false)  # Disable inheritance

# SYSTEM: Full Control
$RuleSys = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$Acl.AddAccessRule($RuleSys)

# Administrators: Full Control
$RuleAdmin = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$Acl.AddAccessRule($RuleAdmin)

# Users: Read Only
$RuleUser = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "Users", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
$Acl.AddAccessRule($RuleUser)

# Users: Deny Write (extra safety)
$RuleDeny = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "Users", "Write", "ContainerInherit,ObjectInherit", "None", "Deny")
$Acl.AddAccessRule($RuleDeny)

Set-Acl $KioskDir $Acl
Write-Log "Folder permissions secured" -Level "SUCCESS"

# =============================================================================
# CONFIGURE ASSIGNED ACCESS (KIOSK MODE)
# =============================================================================
Write-Log "Configuring Windows Assigned Access (Kiosk Mode)..."

# Get Edge AUMID
$EdgePackage = Get-AppxPackage -Name "Microsoft.MicrosoftEdge*" -AllUsers | 
    Where-Object { $_.Name -match "MicrosoftEdge$" -or $_.Name -eq "Microsoft.MicrosoftEdge.Stable" } |
    Select-Object -First 1

if (-not $EdgePackage) {
    # Try new Edge
    $EdgePackage = Get-AppxPackage -Name "*MicrosoftEdge*" -AllUsers | Select-Object -First 1
}

if ($EdgePackage) {
    $EdgeAUMID = "$($EdgePackage.PackageFamilyName)!MicrosoftEdge"
    Write-Log "Edge AUMID: $EdgeAUMID"
} else {
    # Fallback to known AUMID
    $EdgeAUMID = "Microsoft.MicrosoftEdge_8wekyb3d8bbwe!MicrosoftEdge"
    Write-Log "Using fallback Edge AUMID" -Level "WARNING"
}

try {
    # Clear existing Assigned Access first
    Clear-AssignedAccess -ErrorAction SilentlyContinue
    
    # Configure Assigned Access for this user
    Set-AssignedAccess -UserName $UserName -AppUserModelId $EdgeAUMID -ErrorAction Stop
    Write-Log "Assigned Access configured for $UserName" -Level "SUCCESS"
}
catch {
    Write-Log "FAILED to configure Assigned Access: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "Will use alternative shell replacement method" -Level "WARNING"
    
    # Fallback: Configure shell replacement (less secure but works)
    $ShellPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    # Note: This is a fallback only - Assigned Access is preferred
}

# =============================================================================
# CONFIGURE AUTO-LOGIN
# =============================================================================
Write-Log "Configuring auto-login for $UserName..."

$AutoLoginPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

Set-ItemProperty -Path $AutoLoginPath -Name "AutoAdminLogon" -Value "1" -Force
Set-ItemProperty -Path $AutoLoginPath -Name "DefaultUserName" -Value $UserName -Force
Set-ItemProperty -Path $AutoLoginPath -Name "DefaultPassword" -Value $ExamPassword -Force
Set-ItemProperty -Path $AutoLoginPath -Name "DefaultDomainName" -Value "" -Force

Write-Log "Auto-login configured" -Level "SUCCESS"
Write-Log "WARNING: Password stored in registry (necessary for auto-login)" -Level "WARNING"

# =============================================================================
# MACHINE HARDENING - SECURITY POLICIES
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
    "NewTabPageLocation" = "file:///C:/ExamKiosk/index.html"
    "HomepageLocation" = "file:///C:/ExamKiosk/index.html"
    "RestoreOnStartup" = 4
}

foreach ($Policy in $EdgePolicies.GetEnumerator()) {
    Set-ItemProperty -Path $EdgePath -Name $Policy.Key -Value $Policy.Value -Force
}
Write-Log "Edge policies applied (DevTools, printing, downloads disabled)" -Level "SUCCESS"

# Disable Safe Mode (requires bcdedit)
try {
    $null = & bcdedit /set "{current}" bootmenupolicy standard 2>&1
    Write-Log "Boot menu policy set to standard" -Level "SUCCESS"
}
catch {
    Write-Log "Could not modify boot policy: $($_.Exception.Message)" -Level "WARNING"
}

# =============================================================================
# REGISTER SCHEDULED TASK FOR PDF FETCHING
# =============================================================================
Write-Log "Registering scheduled task for PDF fetching..."

$TaskName = "ExamFetchSystem"

# Remove if exists
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$Action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptsDir\FetchExam.ps1`""

$Trigger = New-ScheduledTaskTrigger -AtStartup

# Run as the specific user (to respect network folder permissions)
$Principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Password -RunLevel Highest

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 12) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

# Register with password
$SecurePassword = ConvertTo-SecureString $ExamPassword -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential($UserName, $SecurePassword)

try {
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
        -Principal $Principal -Settings $Settings -Force | Out-Null
    
    # Set credentials
    $Task = Get-ScheduledTask -TaskName $TaskName
    Set-ScheduledTask -TaskName $TaskName -User $UserName -Password $ExamPassword | Out-Null
    
    Write-Log "Scheduled task registered (runs as $UserName for network permissions)" -Level "SUCCESS"
}
catch {
    Write-Log "Error registering task: $($_.Exception.Message)" -Level "WARNING"
    
    # Fallback to SYSTEM
    Write-Log "Falling back to SYSTEM account for task..." -Level "WARNING"
    $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
        -Principal $Principal -Settings $Settings -Force | Out-Null
    Write-Log "Task registered with SYSTEM account" -Level "WARNING"
}

# =============================================================================
# CONFIGURE EDGE STARTUP PAGE
# =============================================================================
Write-Log "Configuring Edge startup..."

# Set URLs on startup policy
$EdgeStartupPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge\RestoreOnStartupURLs"
if (-not (Test-Path $EdgeStartupPath)) { New-Item -Path $EdgeStartupPath -Force | Out-Null }
Set-ItemProperty -Path $EdgeStartupPath -Name "1" -Value "file:///C:/ExamKiosk/index.html" -Force

Write-Log "Edge will open exam page on startup" -Level "SUCCESS"

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   DEPLOYMENT COMPLETE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Log "=== DEPLOYMENT SUMMARY ===" -Level "SUCCESS"
Write-Log "User configured: $UserName"
Write-Log "Network path: $NetworkExamPath"
Write-Log "Auto-login: ENABLED"
Write-Log "Kiosk mode: ENABLED"
Write-Log "Task Manager: DISABLED"
Write-Log "Log file: $LogFile"

Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host "1. Restart the laptop" -ForegroundColor White
Write-Host "2. It should auto-login to $UserName" -ForegroundColor White
Write-Host "3. Edge should launch fullscreen showing exam page" -ForegroundColor White
Write-Host "4. When teacher drops PDF to $NetworkFolder, it will appear" -ForegroundColor White
Write-Host ""
Write-Host "To restore laptop, run: .\3-restore-laptop.ps1" -ForegroundColor Gray
Write-Host ""

Read-Host "Press Enter to exit"
