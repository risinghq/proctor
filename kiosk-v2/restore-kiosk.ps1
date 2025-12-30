<#
.SYNOPSIS
    Restore Laptop to Normal State - Undo Kiosk Configuration
    
.DESCRIPTION
    Reverses all changes made by deploy-kiosk.ps1:
    - Removes scheduled tasks
    - Re-enables Task Manager, Command Prompt
    - Removes firewall rules
    - Clears Edge policies
    - Deletes kiosk files
    
.NOTES
    Run as Administrator
    
.EXAMPLE
    .\restore-kiosk.ps1
#>

#Requires -RunAsAdministrator

# =============================================================================
# CONFIGURATION
# =============================================================================
$KioskDir   = "C:\Kiosk"
$ScriptsDir = "C:\Scripts"
$Timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile    = "$ScriptsDir\restore_$Timestamp.log"

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
    
    if (Test-Path $ScriptsDir) {
        Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    }
    
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
Write-Host "   KIOSK RESTORATION SCRIPT" -ForegroundColor Cyan
Write-Host "   Reverting to Normal Laptop State" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Log "=== RESTORATION START ==="

# =============================================================================
# CONFIRMATION
# =============================================================================
Write-Host "This will REMOVE all kiosk configurations and restore the laptop." -ForegroundColor Yellow
Write-Host ""
$Confirm = Read-Host "Continue? (yes/no)"

if ($Confirm -ne "yes") {
    Write-Log "Restoration cancelled by user"
    exit 0
}

# =============================================================================
# REMOVE SCHEDULED TASKS
# =============================================================================
Write-Log "Removing scheduled tasks..."

$TasksToRemove = @("ExamFetchSystem", "ExamFetch")
foreach ($TaskName in $TasksToRemove) {
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($Task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Log "Removed task: $TaskName" -Level "SUCCESS"
    }
}

# =============================================================================
# RE-ENABLE SYSTEM FEATURES
# =============================================================================
Write-Log "Re-enabling system features..."

# Re-enable Task Manager
$SysPolPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
if (Test-Path $SysPolPath) {
    Remove-ItemProperty -Path $SysPolPath -Name "DisableTaskMgr" -ErrorAction SilentlyContinue
    Write-Log "Task Manager re-enabled" -Level "SUCCESS"
}

# Re-enable Command Prompt
$CmdPolPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
if (Test-Path $CmdPolPath) {
    Remove-ItemProperty -Path $CmdPolPath -Name "DisableCMD" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $CmdPolPath -Name "AllowClipboardHistory" -ErrorAction SilentlyContinue
    Write-Log "Command Prompt and Clipboard re-enabled" -Level "SUCCESS"
}

# Re-enable Snipping Tool
$TabletPCPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC"
if (Test-Path $TabletPCPath) {
    Remove-ItemProperty -Path $TabletPCPath -Name "DisableSnippingTool" -ErrorAction SilentlyContinue
    Write-Log "Snipping Tool re-enabled" -Level "SUCCESS"
}

# Re-enable Windows key
$KeyboardPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
if (Test-Path $KeyboardPath) {
    Remove-ItemProperty -Path $KeyboardPath -Name "NoWinKeys" -ErrorAction SilentlyContinue
    Write-Log "Windows key shortcuts re-enabled" -Level "SUCCESS"
}

# =============================================================================
# REMOVE EDGE POLICIES
# =============================================================================
Write-Log "Removing Edge policies..."

$EdgePath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
if (Test-Path $EdgePath) {
    Remove-Item -Path $EdgePath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Edge policies removed" -Level "SUCCESS"
}

# =============================================================================
# REMOVE AUTO-LOGIN (if configured)
# =============================================================================
Write-Log "Removing auto-login configuration..."

$WinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
if (Test-Path $WinlogonPath) {
    Set-ItemProperty -Path $WinlogonPath -Name "AutoAdminLogon" -Value "0" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $WinlogonPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
    Write-Log "Auto-login disabled" -Level "SUCCESS"
}

# =============================================================================
# REMOVE FIREWALL RULES
# =============================================================================
Write-Log "Removing firewall rules..."

$RulesToRemove = @(
    "Exam Kiosk - Block All Outbound",
    "Exam Kiosk - Allow SMB to Server",
    "Exam Kiosk - Allow DNS",
    "Exam Kiosk - Allow Private Network"
)

foreach ($RuleName in $RulesToRemove) {
    $Rule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    if ($Rule) {
        Remove-NetFirewallRule -DisplayName $RuleName
        Write-Log "Removed firewall rule: $RuleName" -Level "SUCCESS"
    }
}

# =============================================================================
# CLEAR ASSIGNED ACCESS (if configured)
# =============================================================================
Write-Log "Clearing Assigned Access configuration..."

try {
    Clear-AssignedAccess -ErrorAction SilentlyContinue
    Write-Log "Assigned Access cleared" -Level "SUCCESS"
}
catch {
    Write-Log "No Assigned Access to clear" -Level "INFO"
}

# =============================================================================
# DELETE KIOSK FILES
# =============================================================================
Write-Log "Deleting kiosk files..."

if (Test-Path $KioskDir) {
    Remove-Item -Path $KioskDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Deleted: $KioskDir" -Level "SUCCESS"
}

# Delete fetch script (keep logs for reference)
$FetchScript = "$ScriptsDir\FetchExam.ps1"
if (Test-Path $FetchScript) {
    Remove-Item -Path $FetchScript -Force -ErrorAction SilentlyContinue
    Write-Log "Deleted: $FetchScript" -Level "SUCCESS"
}

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   RESTORATION COMPLETE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Log "=== RESTORATION SUMMARY ===" -Level "SUCCESS"
Write-Log "Scheduled tasks: REMOVED"
Write-Log "Task Manager: RE-ENABLED"
Write-Log "Command Prompt: RE-ENABLED"
Write-Log "Clipboard/Snipping: RE-ENABLED"
Write-Log "Edge policies: REMOVED"
Write-Log "Firewall rules: REMOVED"
Write-Log "Kiosk files: DELETED"
Write-Log "Log file: $LogFile"

Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host "1. Restart the laptop to ensure all changes take effect" -ForegroundColor White
Write-Host "2. Verify normal functionality (Task Manager, internet, etc.)" -ForegroundColor White
Write-Host "3. If Edge still opens in kiosk mode, manually disable it in:" -ForegroundColor White
Write-Host "   Settings > Accounts > Other users > Remove kiosk" -ForegroundColor Gray
Write-Host ""

Read-Host "Press Enter to exit"
