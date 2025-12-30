<#
.SYNOPSIS
    Restore laptop to normal operation after exam

.DESCRIPTION
    - Removes Windows Assigned Access configuration
    - Disables auto-login
    - Removes scheduled tasks
    - Cleans up exam files
    - Re-enables Task Manager and other policies
    - Preserves user accounts for future exams

.NOTES
    Run as Administrator
    
.EXAMPLE
    .\3-restore-laptop.ps1
#>

#Requires -RunAsAdministrator

# =============================================================================
# LOGGING
# =============================================================================
$LogFile = "C:\Scripts\restore_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )
    
    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    
    # Try to log to file (might fail if C:\Scripts doesn't exist)
    try {
        Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
    } catch {}
    
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
Write-Host "   LAPTOP RESTORE" -ForegroundColor Cyan
Write-Host "   Removing Exam Kiosk Configuration" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# CONFIRMATION
# =============================================================================
Write-Host "This will:" -ForegroundColor Yellow
Write-Host "  - Remove kiosk mode" -ForegroundColor White
Write-Host "  - Disable auto-login" -ForegroundColor White
Write-Host "  - Delete exam files (C:\ExamKiosk, C:\Scripts)" -ForegroundColor White
Write-Host "  - Re-enable Task Manager" -ForegroundColor White
Write-Host "  - Preserve user accounts (Alumno - XX)" -ForegroundColor White
Write-Host ""

$Confirm = Read-Host "Continue? (Y/N)"
if ($Confirm -notmatch "^[Yy]") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Log "Starting restoration..."

# =============================================================================
# 1. REMOVE ASSIGNED ACCESS
# =============================================================================
Write-Log "Removing Assigned Access configuration..."

try {
    $Config = Get-AssignedAccess -ErrorAction SilentlyContinue
    if ($Config) {
        $KioskUser = $Config.UserName
        Write-Log "Found kiosk configuration for: $KioskUser"
        
        Clear-AssignedAccess -ErrorAction Stop
        Write-Log "Assigned Access removed" -Level "SUCCESS"
    } else {
        Write-Log "No Assigned Access configuration found" -Level "WARNING"
    }
}
catch {
    Write-Log "Error removing Assigned Access: $($_.Exception.Message)" -Level "WARNING"
}

# =============================================================================
# 2. DISABLE AUTO-LOGIN
# =============================================================================
Write-Log "Disabling auto-login..."

$AutoLoginPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

try {
    Set-ItemProperty -Path $AutoLoginPath -Name "AutoAdminLogon" -Value "0" -Force
    Remove-ItemProperty -Path $AutoLoginPath -Name "DefaultUserName" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $AutoLoginPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $AutoLoginPath -Name "DefaultDomainName" -ErrorAction SilentlyContinue
    Write-Log "Auto-login disabled" -Level "SUCCESS"
}
catch {
    Write-Log "Error disabling auto-login: $($_.Exception.Message)" -Level "WARNING"
}

# =============================================================================
# 3. REMOVE SCHEDULED TASK
# =============================================================================
Write-Log "Removing scheduled task..."

try {
    Unregister-ScheduledTask -TaskName "ExamFetchSystem" -Confirm:$false -ErrorAction Stop
    Write-Log "Scheduled task removed" -Level "SUCCESS"
}
catch {
    Write-Log "Scheduled task not found or already removed" -Level "WARNING"
}

# =============================================================================
# 4. RE-ENABLE TASK MANAGER
# =============================================================================
Write-Log "Re-enabling Task Manager..."

$SysPolPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
try {
    Remove-ItemProperty -Path $SysPolPath -Name "DisableTaskMgr" -ErrorAction Stop
    Write-Log "Task Manager re-enabled" -Level "SUCCESS"
}
catch {
    Write-Log "DisableTaskMgr not set or already removed" -Level "WARNING"
}

# =============================================================================
# 5. RE-ENABLE COMMAND PROMPT
# =============================================================================
Write-Log "Re-enabling Command Prompt..."

$CmdPolPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
try {
    Remove-ItemProperty -Path $CmdPolPath -Name "DisableCMD" -ErrorAction SilentlyContinue
    Write-Log "Command Prompt re-enabled" -Level "SUCCESS"
}
catch {
    Write-Log "DisableCMD not set" -Level "WARNING"
}

# =============================================================================
# 6. REMOVE EDGE POLICIES
# =============================================================================
Write-Log "Removing Edge policies..."

$EdgePath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
try {
    if (Test-Path $EdgePath) {
        Remove-Item $EdgePath -Recurse -Force -ErrorAction Stop
        Write-Log "Edge policies removed" -Level "SUCCESS"
    } else {
        Write-Log "No Edge policies found" -Level "WARNING"
    }
}
catch {
    Write-Log "Error removing Edge policies: $($_.Exception.Message)" -Level "WARNING"
}

# =============================================================================
# 7. CLEAN UP EXAM FILES
# =============================================================================
Write-Log "Cleaning up exam files..."

foreach ($Dir in @("C:\ExamKiosk", "C:\Scripts")) {
    try {
        if (Test-Path $Dir) {
            Remove-Item $Dir -Recurse -Force -ErrorAction Stop
            Write-Log "Removed: $Dir" -Level "SUCCESS"
        }
    }
    catch {
        Write-Log "Could not remove ${Dir}: $($_.Exception.Message)" -Level "WARNING"
    }
}

# =============================================================================
# 8. RESTORE BOOT MENU (Allow Safe Mode)
# =============================================================================
Write-Log "Restoring boot menu options..."

try {
    $null = & bcdedit /set "{current}" bootmenupolicy legacy 2>&1
    Write-Log "Boot menu restored to legacy mode" -Level "SUCCESS"
}
catch {
    Write-Log "Could not restore boot menu" -Level "WARNING"
}

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   RESTORATION COMPLETE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Log "Laptop restored to normal operation" -Level "SUCCESS"
Write-Log "User accounts preserved (Alumno - XX)" -Level "INFO"

Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host "1. Restart the laptop" -ForegroundColor White
Write-Host "2. Normal Windows login screen should appear" -ForegroundColor White
Write-Host "3. Task Manager should work (Ctrl+Shift+Esc)" -ForegroundColor White
Write-Host ""

Read-Host "Press Enter to exit"
