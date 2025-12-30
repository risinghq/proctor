# Exam Kiosk Deployment - Verification Checklist

## Pre-Deployment Checklist

### Hardware & Network
- [ ] Laptop has Windows 10/11 Pro or Enterprise (not Home)
- [ ] Laptop is connected to network with access to `192.168.5.30`
- [ ] Network share `\\192.168.5.30\sidera\Examenes\Dispositivo XX` is accessible
- [ ] Student account exists (e.g., `Alumno-01`, `Alumno-02`, etc.)
- [ ] Student password is set to `alumno`

### Software Prerequisites
- [ ] Microsoft Edge is installed
- [ ] PowerShell execution policy allows script execution
- [ ] Administrator access is available

---

## Deployment Steps

### 1. Run Deployment Script
```powershell
cd c:\dev\ps1\kiosk-v2
.\deploy-kiosk.ps1
```

**Expected prompts**:
- Enter student number (1-30)
- Script should complete without errors
- Press Enter to exit

### 2. Configure Edge Kiosk (Manual)
- [ ] Open Settings > Accounts > Other users
- [ ] Click "Set up a kiosk"
- [ ] Choose "Get started"
- [ ] Create new account or select existing student account
- [ ] Select "Digital signage" (not "Public browser")
- [ ] Enter URL: `file:///C:/Kiosk/index.html`
- [ ] Click "Close" when done

### 3. Restart Laptop
- [ ] Restart the laptop
- [ ] Wait for login screen

---

## Post-Deployment Verification

### Security Tests

#### Test 1: Task Manager Disabled
- [ ] Log in as student (password: `alumno`)
- [ ] Press `Ctrl+Shift+Esc` → Should NOT open Task Manager
- [ ] Press `Ctrl+Alt+Del` → Task Manager option should be missing or disabled

#### Test 2: Clipboard History Disabled
- [ ] Copy some text
- [ ] Press `Win+V` → Should NOT open clipboard history

#### Test 3: Screenshot Tools Disabled
- [ ] Press `Win+Shift+S` → Snipping Tool should NOT open
- [ ] Press `PrtScr` → Screenshot should NOT be captured

#### Test 4: Edge Security
- [ ] Right-click on page → Context menu should be disabled
- [ ] Press `F12` → DevTools should NOT open
- [ ] Press `Ctrl+Shift+I` → DevTools should NOT open
- [ ] Select text and right-click → Mini menu should NOT appear

#### Test 5: Network Isolation
Open PowerShell (if accessible) or use Command Prompt from another admin account:
```powershell
# This should FAIL (internet blocked)
Test-Connection google.com

# This should SUCCEED (server allowed)
Test-Connection 192.168.5.30
```

### Functional Tests

#### Test 6: PDF Fetching
**Teacher side**:
- [ ] Copy a test PDF to `\\192.168.5.30\sidera\Examenes\Dispositivo XX\`
- [ ] Rename it to something like `Test-Exam.pdf`

**Student side**:
- [ ] Wait up to 10 seconds
- [ ] Check if PDF appears in browser
- [ ] Verify PDF content is readable

#### Test 7: PDF Update
**Teacher side**:
- [ ] Copy a DIFFERENT PDF to the same folder
- [ ] Make sure it has a newer timestamp

**Student side**:
- [ ] Wait up to 40 seconds (10s polling + 30s iframe refresh)
- [ ] Verify new PDF appears
- [ ] Content should match the new PDF

#### Test 8: Multiple PDFs
**Teacher side**:
- [ ] Place 3 different PDFs in the folder with different timestamps
- [ ] Latest modified should be `Newest-Exam.pdf`

**Student side**:
- [ ] Wait for update
- [ ] Verify that `Newest-Exam.pdf` is displayed (not the oldest)

#### Test 9: Waiting State
**Teacher side**:
- [ ] Delete all PDFs from student folder

**Student side**:
- [ ] Restart laptop and log in
- [ ] Should see "Esperando examen..." with animated loader
- [ ] Should NOT see any error messages

---

## Edge Case Testing

### Escape Attempt Tests
- [ ] Press `Alt+Tab` → Should NOT switch apps (kiosk mode)
- [ ] Press `Alt+F4` → Should NOT close browser
- [ ] Press `Windows key` → Should NOT open Start menu
- [ ] Try to access Settings via keyboard → Should fail
- [ ] Try to download a file from PDF → Should be blocked

### Network Failure Scenario
- [ ] Disconnect network cable or disable WiFi
- [ ] Verify browser stays in kiosk mode (doesn't crash)
- [ ] Reconnect network
- [ ] Verify PDF fetching resumes automatically

### File Locking Test
**Teacher side**:
- [ ] Open the PDF in Adobe Reader on server (locking the file)
- [ ] Try to update timestamp or copy new PDF

**Student side**:
- [ ] Verify student can still VIEW the PDF
- [ ] Check logs in `C:\Scripts\fetch_runtime.log` for errors

---

## Restoration Test

### After Testing is Complete
```powershell
cd c:\dev\ps1\kiosk-v2
.\restore-kiosk.ps1
```

- [ ] Type `yes` to confirm restoration
- [ ] Script should complete without errors
- [ ] Restart laptop
- [ ] Verify normal functionality:
  - [ ] Task Manager works (`Ctrl+Shift+Esc`)
  - [ ] Internet access works (browse to google.com)
  - [ ] Screenshots work (`Win+Shift+S`)
  - [ ] Clipboard history works (`Win+V`)
  - [ ] No kiosk mode on login

---

## Troubleshooting

### Issue: PDF Not Appearing
**Check**:
1. Verify network path: `\\192.168.5.30\sidera\Examenes\Dispositivo XX`
2. Check scheduled task is running: `Get-ScheduledTask -TaskName "ExamFetchSystem"`
3. Check fetch logs: `C:\Scripts\fetch_runtime.log`
4. Verify PDF exists in network folder
5. Check file permissions (student should have read access)

### Issue: Kiosk Not Launching
**Check**:
1. Verify Edge kiosk is configured in Settings
2. Check URL is correct: `file:///C:/Kiosk/index.html`
3. Verify `C:\Kiosk\index.html` exists
4. Try opening URL manually in Edge

### Issue: Security Features Not Working
**Check**:
1. Verify registry keys were created (run as admin):
   ```powershell
   Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
   Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
   ```
2. Restart laptop to apply policies
3. Check Windows Update hasn't reverted policies

### Issue: Network Still Works (Internet Accessible)
**Check**:
1. Verify firewall rules exist:
   ```powershell
   Get-NetFirewallRule -DisplayName "Exam Kiosk*"
   ```
2. Check firewall service is running
3. Test from student account (not admin)

---

## Production Deployment Notes

### Before Exam Day
1. Deploy to all laptops 1-2 days before exam
2. Run full verification on at least 3 sample laptops
3. Prepare spare laptop with same configuration
4. Test network share with all student folders
5. Document any issues and resolutions

### Exam Day Procedure
1. Students turn on laptops
2. Teacher provides password: `alumno`
3. Students log in (Edge kiosk auto-launches)
4. Teacher confirms all students see "Esperando examen..."
5. Teacher gives instructions
6. Teacher drops exam PDF to all student folders simultaneously
7. Students see exam within 10 seconds

### After Exam
1. Collect all laptops
2. Run `restore-kiosk.ps1` on each
3. Verify restoration successful
4. Return laptops to normal use

---

## Quick Reference

**Student login**: `Alumno-XX` / `alumno`  
**Network share**: `\\192.168.5.30\sidera\Examenes\Dispositivo XX`  
**Kiosk URL**: `file:///C:/Kiosk/index.html`  
**Poll interval**: 10 seconds  
**Logs**: `C:\Scripts\deployment_*.log`, `C:\Scripts\fetch_runtime.log`  
**Deploy script**: `c:\dev\ps1\kiosk-v2\deploy-kiosk.ps1`  
**Restore script**: `c:\dev\ps1\kiosk-v2\restore-kiosk.ps1`
