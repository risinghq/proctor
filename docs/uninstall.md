# Uninstall

```powershell
.\uninstall.ps1 -UserName Alumno-01 -Force
```

or with the install parameters (`-Config`, `-UserPrefix`, `-DeviceNumber`).
Without `-Force` it asks for confirmation. It works after an incomplete
install.

## What it removes

- The sync task and the kiosk server task.
- The loopback URL reservation — only when Proctor created it, recorded in
  `install.json` (see [Architecture](architecture.md)).
- The firewall block rule.
- The Edge policies and registry restrictions.
- Assigned Access and auto-logon.
- `C:\Kiosk` and `C:\ProgramData\proctor`, including the share credential
  and cached exam versions.
- The student account and its profile.

## Failed steps

Uninstall runs each removal as a step and reports the outcome per step.
When a step throws, uninstall continues with the remaining steps, prints
the failed steps at the end and exits nonzero — fix the cause and run it
again.
