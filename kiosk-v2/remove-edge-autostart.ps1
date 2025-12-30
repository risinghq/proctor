<#
.SYNOPSIS
    Remove Edge Auto-Start Configuration from Old Deployment
    
.DESCRIPTION
    Removes the Edge kiosk registry entry that was added by previous
    deployment scripts (1-deploy-kiosk.ps1) which causes Edge to open
    on every login for all users.
    
.NOTES
    Run as Administrator
    
.EXAMPLE
    .\remove-edge-autostart.ps1
#>

#Requires -RunAsAdministrator

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   REMOVE EDGE AUTO-START" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$RunKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$EdgeStartupPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge\RestoreOnStartupURLs"

Write-Host "Checking for Edge auto-start configurations..." -ForegroundColor Yellow
Write-Host ""

# Check Run registry key
$EdgeRunEntry = Get-ItemProperty -Path $RunKey -Name "ExamKiosk" -ErrorAction SilentlyContinue
if ($EdgeRunEntry) {
    Write-Host "[FOUND] ExamKiosk entry in Run registry" -ForegroundColor Red
    Remove-ItemProperty -Path $RunKey -Name "ExamKiosk" -ErrorAction Stop
    Write-Host "[REMOVED] ExamKiosk from startup" -ForegroundColor Green
} else {
    Write-Host "[OK] No ExamKiosk entry in Run registry" -ForegroundColor Gray
}

# Check Edge startup URLs policy
if (Test-Path $EdgeStartupPath) {
    $StartupURLs = Get-ItemProperty -Path $EdgeStartupPath -ErrorAction SilentlyContinue
    if ($StartupURLs) {
        Write-Host "[FOUND] Edge startup URL policy" -ForegroundColor Red
        Remove-Item -Path $EdgeStartupPath -Recurse -Force -ErrorAction Stop
        Write-Host "[REMOVED] Edge startup URL policy" -ForegroundColor Green
    }
} else {
    Write-Host "[OK] No Edge startup URL policy" -ForegroundColor Gray
}

# Also check HKCU (current user) in case it was set there
$HKCURunKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$HKCUEdgeEntry = Get-ItemProperty -Path $HKCURunKey -Name "ExamKiosk" -ErrorAction SilentlyContinue
if ($HKCUEdgeEntry) {
    Write-Host "[FOUND] ExamKiosk entry in current user Run registry" -ForegroundColor Red
    Remove-ItemProperty -Path $HKCURunKey -Name "ExamKiosk" -ErrorAction Stop
    Write-Host "[REMOVED] ExamKiosk from current user startup" -ForegroundColor Green
} else {
    Write-Host "[OK] No ExamKiosk entry in current user Run registry" -ForegroundColor Gray
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   CLEANUP COMPLETE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host "1. Close all Edge windows" -ForegroundColor White
Write-Host "2. Log out and log back in to verify Edge doesn't auto-start" -ForegroundColor White
Write-Host "3. If Edge still opens, manually check:" -ForegroundColor White
Write-Host "   - Task Scheduler for any Edge-related tasks" -ForegroundColor Gray
Write-Host "   - Startup folder: shell:startup" -ForegroundColor Gray
Write-Host ""

Read-Host "Press Enter to exit"
