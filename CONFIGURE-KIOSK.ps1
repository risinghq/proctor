<#
.SYNOPSIS
    Configure Assigned Access for existing Alumno - 01 user
    
.DESCRIPTION
    Focuses only on the Assigned Access configuration step
    Shows detailed error messages
#>

#Requires -RunAsAdministrator

$TestUser = "Alumno - 01"
$LogFile = "f:\projects\totem\secure\KIOSK-CONFIG-LOG.txt"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Entry = "$(Get-Date -Format 'HH:mm:ss') [$Level] $Message"
    Add-Content -Path $LogFile -Value $Entry
    Write-Host $Entry -ForegroundColor $(if($Level -eq "ERROR"){"Red"}elseif($Level -eq "SUCCESS"){"Green"}else{"White"})
}

if (Test-Path $LogFile) { Remove-Item $LogFile -Force }

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   CONFIGURE KIOSK MODE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Verify user exists
Write-Log "Checking if user exists..."
try {
    $User = Get-LocalUser -Name $TestUser -ErrorAction Stop
    Write-Log "User found: $TestUser" -Level "SUCCESS"
} catch {
    Write-Log "User NOT found: $TestUser" -Level "ERROR"
    exit 1
}

# Check if user is logged in
Write-Log "Checking if user is currently logged in..."
$LoggedInUsers = quser 2>$null | Select-Object -Skip 1
if ($LoggedInUsers -match $TestUser) {
    Write-Log "WARNING: User '$TestUser' appears to be logged in!" -Level "ERROR"
    Write-Log "You must log out that user before configuring Assigned Access" -Level "ERROR"
    Write-Host ""
    Write-Host "Please:" -ForegroundColor Yellow
    Write-Host "1. Log out of '$TestUser' if logged in" -ForegroundColor White
    Write-Host "2. Run this script again" -ForegroundColor White
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}
Write-Log "User not currently logged in" -Level "SUCCESS"

# Get Edge AUMID
Write-Log "Finding Edge application..."
$EdgeAUMID = "Microsoft.MicrosoftEdge_8wekyb3d8bbwe!MicrosoftEdge"

# Try to find newer Edge
$EdgePackage = Get-AppxPackage -Name "*MicrosoftEdge.Stable*" -AllUsers | Select-Object -First 1
if ($EdgePackage) {
    $EdgeAUMID = "$($EdgePackage.PackageFamilyName)!MicrosoftEdge"
    Write-Log "Using Edge Stable: $EdgeAUMID" -Level "SUCCESS"
} else {
    Write-Log "Using legacy Edge: $EdgeAUMID" -Level "SUCCESS"
}

# Clear any existing Assigned Access
Write-Log "Clearing any existing Assigned Access configuration..."
try {
    Clear-AssignedAccess -ErrorAction SilentlyContinue
    Write-Log "Cleared existing config (if any)" -Level "SUCCESS"
} catch {
    Write-Log "No existing config to clear"
}

# Configure Assigned Access
Write-Log "Configuring Assigned Access for $TestUser..."
Write-Log "Edge AUMID: $EdgeAUMID"

try {
    Set-AssignedAccess -UserName $TestUser -AppUserModelId $EdgeAUMID -ErrorAction Stop
    Write-Log "Assigned Access configured successfully!" -Level "SUCCESS"
    
    # Verify it worked
    $Config = Get-AssignedAccess -ErrorAction Stop
    if ($Config) {
        Write-Log "Verification: Assigned Access IS active" -Level "SUCCESS"
        Write-Log "  User: $($Config.UserName)"
        Write-Log "  App: $($Config.AppUserModelId)"
    }
}
catch {
    Write-Log "FAILED to configure Assigned Access!" -Level "ERROR"
    Write-Log "Error: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "Full error details:" -Level "ERROR"
    Write-Log "$($_ | Out-String)" -Level "ERROR"
    
    Write-Host ""
    Write-Host "Common causes:" -ForegroundColor Yellow
    Write-Host "1. User is logged in somewhere" -ForegroundColor White
    Write-Host "2. Edge AUMID is incorrect" -ForegroundColor White
    Write-Host "3. Windows version issue" -ForegroundColor White
    Write-Host ""
    
    Read-Host "Press Enter to exit"
    exit 1
}

# Configure Edge policies
Write-Log "Configuring Edge policies..."
$EdgePath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
if (-not (Test-Path $EdgePath)) { New-Item -Path $EdgePath -Force | Out-Null }

$EdgePolicies = @{
    "DeveloperToolsAvailability" = 2
    "PrintingEnabled" = 0
    "DownloadRestrictions" = 3
    "HideFirstRunExperience" = 1
    "HomepageLocation" = "file:///C:/ExamKiosk/index.html"
    "RestoreOnStartup" = 4
}

foreach ($Policy in $EdgePolicies.GetEnumerator()) {
    Set-ItemProperty -Path $EdgePath -Name $Policy.Key -Value $Policy.Value -Force
}

$EdgeStartupPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge\RestoreOnStartupURLs"
if (-not (Test-Path $EdgeStartupPath)) { New-Item -Path $EdgeStartupPath -Force | Out-Null }
Set-ItemProperty -Path $EdgeStartupPath -Name "1" -Value "file:///C:/ExamKiosk/index.html" -Force

Write-Log "Edge policies configured" -Level "SUCCESS"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   CONFIGURATION COMPLETE!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "TO TEST:" -ForegroundColor Yellow
Write-Host "1. Press Win+L to lock screen" -ForegroundColor White
Write-Host "2. Click 'Other user'" -ForegroundColor White
Write-Host "3. Login as: $TestUser" -ForegroundColor White
Write-Host "4. Password: alumno" -ForegroundColor White
Write-Host "5. Edge should launch in kiosk mode" -ForegroundColor White
Write-Host ""
Write-Host "Log saved to: $LogFile" -ForegroundColor Green
Write-Host ""

Read-Host "Press Enter to exit"
