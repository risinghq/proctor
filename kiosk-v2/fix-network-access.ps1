<#
.SYNOPSIS
    Fix Network Access Issues - Enable SMB and Fix Firewall Rules
    
.DESCRIPTION
    - Enables SMB Client (required for network shares)
    - Removes the aggressive "Block All Outbound" rule
    - Adds targeted internet blocking (HTTP/HTTPS only)
    
.NOTES
    Run as Administrator
    
.EXAMPLE
    .\fix-network-access.ps1
#>

#Requires -RunAsAdministrator

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   NETWORK ACCESS FIX" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# FIX 1: ENABLE SMB CLIENT
# =============================================================================
Write-Host "[FIX 1] Enabling SMB Client..." -ForegroundColor Yellow

try {
    $smbConfig = Get-SmbClientConfiguration
    if (-not $smbConfig.EnableSMB2Protocol) {
        Set-SmbClientConfiguration -EnableSMB2Protocol $true -Force -Confirm:$false
        Write-Host "  SMB2/SMB3 Protocol: ENABLED" -ForegroundColor Green
    } else {
        Write-Host "  SMB2/SMB3 Protocol: Already enabled" -ForegroundColor Gray
    }
} catch {
    Write-Host "  Error enabling SMB: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# =============================================================================
# FIX 2: REMOVE AGGRESSIVE FIREWALL RULE
# =============================================================================
Write-Host "[FIX 2] Removing aggressive 'Block All Outbound' rule..." -ForegroundColor Yellow

$blockRule = Get-NetFirewallRule -DisplayName "Exam Kiosk - Block All Outbound" -ErrorAction SilentlyContinue
if ($blockRule) {
    Remove-NetFirewallRule -DisplayName "Exam Kiosk - Block All Outbound"
    Write-Host "  Removed: Block All Outbound rule" -ForegroundColor Green
} else {
    Write-Host "  Rule not found (already removed)" -ForegroundColor Gray
}

Write-Host ""

# =============================================================================
# FIX 3: ADD TARGETED INTERNET BLOCKING
# =============================================================================
Write-Host "[FIX 3] Adding targeted internet blocking (HTTP/HTTPS only)..." -ForegroundColor Yellow

# Remove old targeted rules if they exist
Remove-NetFirewallRule -DisplayName "Exam Kiosk - Block HTTP" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Exam Kiosk - Block HTTPS" -ErrorAction SilentlyContinue

# Block HTTP (port 80) to internet
New-NetFirewallRule -DisplayName "Exam Kiosk - Block HTTP" `
    -Direction Outbound -Action Block -Protocol TCP `
    -RemotePort 80 | Out-Null
Write-Host "  Added: Block HTTP (port 80)" -ForegroundColor Green

# Block HTTPS (port 443) to internet  
New-NetFirewallRule -DisplayName "Exam Kiosk - Block HTTPS" `
    -Direction Outbound -Action Block -Protocol TCP `
    -RemotePort 443 | Out-Null
Write-Host "  Added: Block HTTPS (port 443)" -ForegroundColor Green

Write-Host ""

# =============================================================================
# VERIFICATION
# =============================================================================
Write-Host "[VERIFICATION] Testing network access..." -ForegroundColor Yellow
Write-Host ""

$testShare = "\\192.168.5.30\sidera\Examenes"

Start-Sleep -Seconds 2  # Give firewall a moment to apply changes

if (Test-Path $testShare -ErrorAction SilentlyContinue) {
    Write-Host "SUCCESS! Network share is now accessible" -ForegroundColor Green
    Write-Host "Path: $testShare" -ForegroundColor Gray
} else {
    Write-Host "WARNING: Share still not accessible" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Additional steps to try:" -ForegroundColor White
    Write-Host "  1. Restart the laptop" -ForegroundColor Gray
    Write-Host "  2. Check share permissions on server" -ForegroundColor Gray
    Write-Host "  3. Verify share path is correct" -ForegroundColor Gray
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   FIX COMPLETE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "SUMMARY:" -ForegroundColor Yellow
Write-Host "  - SMB Client: Enabled" -ForegroundColor White
Write-Host "  - Aggressive firewall block: Removed" -ForegroundColor White
Write-Host "  - HTTP/HTTPS blocking: Added (students can't browse web)" -ForegroundColor White
Write-Host "  - Local network access: Allowed" -ForegroundColor White
Write-Host ""

Read-Host "Press Enter to exit"
