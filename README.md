# Exam Kiosk Deployment System

## Overview

Secure exam laptop deployment using Windows Assigned Access (Kiosk Mode) for per-student exam viewing.

## Features

- 🔒 **Windows Kiosk Mode** - Students locked into Edge browser only
- 👤 **Per-Student Configuration** - Each laptop fetches from student's own network folder  
- 📄 **Live PDF Updates** - Teacher can update exam during session
- 🚫 **Attack Prevention** - Task Manager, keyboard shortcuts, DevTools all disabled
- 🔄 **Easy Cleanup** - Restore script returns laptop to normal

## Prerequisites

- Windows 10/11 **Pro or Enterprise** (Required for Assigned Access)
- Pre-created user accounts: `Alumno - 01`, `Alumno - 02`, etc.
- Password for all accounts: `alumno`
- Network share structure:
  ```
  \\Server\TeacherShare\
  ├── Alumno - 01\
  │   └── Exam.pdf
  ├── Alumno - 02\
  │   └── Exam.pdf
  └── ...
  ```

## Deployment Workflow

### 1. Prepare Network Folders

Ensure each student folder has correct permissions:
- `Alumno - 01` can only access `\\Server\TeacherShare\Alumno - 01\`
- `Alumno - 02` can only access `\\Server\TeacherShare\Alumno - 02\`
- etc.

### 2. Deploy to Each Laptop

On each laptop:

```powershell
# Run as Administrator
.\1-deploy-kiosk.ps1

# When prompted, enter the student number (1-30)
Enter student number (1-30): 1
```

### 3. Restart Laptop

After deployment:
1. Restart the laptop
2. It will auto-login to the configured student account
3. Edge will launch fullscreen showing the exam waiting page
4. Student badge shows which student this laptop is assigned to

### 4. Start the Exam

On teacher machine:
1. Copy `Exam.pdf` to each student folder
2. Within 30 seconds, the PDF will appear on student laptops
3. Different students can have different exam variants!

### 5. Update Exam (Optional)

If you need to update the PDF during the exam:
1. Replace `Exam.pdf` in the student's folder
2. The laptop will detect the change and refresh automatically

### 6. After Exam - Restore Laptops

On each laptop:

```powershell
# Run as Administrator (you'll need to break out of kiosk first)
# Press Ctrl+Alt+Del and select "Sign out" or restart
# Login as an Admin user
.\3-restore-laptop.ps1
```

## Files

| File | Purpose |
|------|---------|
| `1-deploy-kiosk.ps1` | Main deployment script |
| `3-restore-laptop.ps1` | Cleanup script |
| `README.md` | This file |

## Security Measures

| Measure | Status |
|---------|--------|
| Windows Assigned Access | ✅ Locks user into Edge only |
| Task Manager | ✅ Disabled |
| Command Prompt | ✅ Disabled |
| Win+R / Win+E shortcuts | ✅ Blocked by Assigned Access |
| Alt+F4 close browser | ✅ Blocked by Assigned Access |
| Alt+Tab switch apps | ✅ Blocked - only Edge running |
| F12 DevTools | ✅ Disabled via Edge policy |
| Right-click context menu | ✅ Disabled in HTML |
| Printing | ✅ Disabled via Edge policy |
| Downloads | ✅ Disabled via Edge policy |
| PDF file modification | ✅ Users have read-only access |

## Troubleshooting

### Laptop stuck on login screen
- Auto-login may have failed
- Check if password "alumno" is correct for that user
- Run `.\1-deploy-kiosk.ps1` again after fixing user password

### PDF not appearing
1. Check network connectivity
2. Verify `\\Server\TeacherShare\Alumno - XX\Exam.pdf` exists
3. Check `C:\Scripts\fetch_runtime.log` for errors
4. Ensure scheduled task is running (`Get-ScheduledTask -TaskName "ExamFetchSystem"`)

### Wrong student configured
1. Run `.\3-restore-laptop.ps1` to reset
2. Run `.\1-deploy-kiosk.ps1` with correct student number

### Need to access laptop as Admin during exam
1. Press Ctrl+Alt+Del
2. Select "Switch user" or "Sign out"
3. Login with Admin credentials
4. Run `.\3-restore-laptop.ps1` to exit kiosk mode

### Assigned Access failed to configure
- Check Windows edition (must be Pro or Enterprise)
- Ensure user is not currently logged in
- Try restarting and running script again

## Generated Files (on each laptop)

```
C:\Scripts\
├── FetchExam.ps1           # PDF fetching script (user-specific)
├── deployment_*.log        # Deployment log
└── fetch_runtime.log       # Runtime log for PDF fetching

C:\ExamKiosk\
├── index.html              # Exam interface (shows student name)
└── Exam.pdf                # Fetched from network (when available)
```

## Network Folder Permissions

**CRITICAL:** The scheduled task runs as the specific `Alumno - XX` user to respect network folder permissions. This means:

- `Alumno - 01`'s laptop can ONLY fetch from `\\Server\TeacherShare\Alumno - 01\`
- `Alumno - 02`'s laptop can ONLY fetch from `\\Server\TeacherShare\Alumno - 02\`

This enables **differentiated exams** - each student can have a different exam!

## Quick Reference

```powershell
# Deploy (run on each laptop as Admin)
.\1-deploy-kiosk.ps1

# Restore (run on each laptop as Admin after exam)
.\3-restore-laptop.ps1

# Check if kiosk is configured
Get-AssignedAccess

# Check scheduled task status
Get-ScheduledTask -TaskName "ExamFetchSystem"

# View fetch log
Get-Content C:\Scripts\fetch_runtime.log -Tail 20
```
