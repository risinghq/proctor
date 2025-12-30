<#
.SYNOPSIS
    Verify exam kiosk deployment on a laptop

.DESCRIPTION
    Checks that all components are properly configured

.EXAMPLE
    .\4-verify-deployment.ps1
#>

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   DEPLOYMENT VERIFICATION" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$Passed = 0
$Failed = 0

function Test-Check {
    param([string]$Name, [bool]$Result, [string]$Details = "")
    
    if ($Result) {
        Write-Host "  [OK] $Name" -ForegroundColor Green
        if ($Details) { Write-Host "       $Details" -ForegroundColor Gray }
        $script:Passed++
    } else {
        Write-Host "  [X]  $Name" -ForegroundColor Red
        if ($Details) { Write-Host "       $Details" -ForegroundColor Gray }
        $script:Failed++
    }
}

# Check 1: Assigned Access configured
$Config = Get-AssignedAccess -ErrorAction SilentlyContinue
Test-Check "Assigned Access configured" ($null -ne $Config) $(if ($Config) { "User: $($Config.UserName)" } else { "Not configured" })

# Check 2: Auto-login enabled
$AutoLogin = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -ErrorAction SilentlyContinue
$AutoLoginEnabled = $AutoLogin.AutoAdminLogon -eq "1"
Test-Check "Auto-login enabled" $AutoLoginEnabled $(if ($AutoLoginEnabled) { "User: $($AutoLogin.DefaultUserName)" } else { "Disabled" })

# Check 3: Scheduled task exists
$Task = Get-ScheduledTask -TaskName "ExamFetchSystem" -ErrorAction SilentlyContinue
Test-Check "Scheduled task registered" ($null -ne $Task) $(if ($Task) { "State: $($Task.State)" } else { "Not found" })

# Check 4: FetchExam.ps1 exists
$FetchExists = Test-Path "C:\Scripts\FetchExam.ps1"
Test-Check "FetchExam.ps1 exists" $FetchExists

# Check 5: index.html exists
$HtmlExists = Test-Path "C:\ExamKiosk\index.html"
Test-Check "index.html exists" $HtmlExists

# Check 6: Task Manager disabled
$TaskMgr = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableTaskMgr" -ErrorAction SilentlyContinue
Test-Check "Task Manager disabled" ($TaskMgr.DisableTaskMgr -eq 1)

# Check 7: Edge policies applied
$EdgePolicies = Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
Test-Check "Edge policies applied" $EdgePolicies

# Check 8: FetchExam.ps1 has student-specific path
if ($FetchExists) {
    $FetchContent = Get-Content "C:\Scripts\FetchExam.ps1" -Raw
    $HasAlumnoPath = $FetchContent -match "Alumno - \d{2}"
    Test-Check "FetchExam.ps1 has student-specific path" $HasAlumnoPath
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan

if ($Failed -eq 0) {
    Write-Host "   ALL CHECKS PASSED ($Passed/$($Passed + $Failed))" -ForegroundColor Green
} else {
    Write-Host "   SOME CHECKS FAILED ($Passed passed, $Failed failed)" -ForegroundColor Red
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($Config) {
    Write-Host "Configured for: $($Config.UserName)" -ForegroundColor Yellow
    
    # Show network path from FetchExam.ps1
    if ($FetchExists) {
        $Match = [regex]::Match($FetchContent, '\$Source = "([^"]+)"')
        if ($Match.Success) {
            Write-Host "Network path: $($Match.Groups[1].Value)" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Read-Host "Press Enter to exit"
