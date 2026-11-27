# Architecture

Follow one exam from the share to the screen.

[install.ps1](../install.ps1) resolves the config, applies the edition's
lockdown, registers two scheduled tasks and writes the install record —
all through [proctor.psm1](../proctor.psm1), which holds every function
that touches the system.

## Core data

- `C:\ProgramData\proctor\install.json` — port, and whether Proctor
  created the URL reservation plus its SDDL. Uninstall reads it.
- `C:\ProgramData\proctor\share.cred` — the share credential,
  DPAPI-encrypted (LocalMachine scope).
- `C:\ProgramData\proctor\exam\<yyyyMMddHHmmssfff>` — one folder per exam
  version, holding `Exam.pdf` and `exam.json`.
- `C:\ProgramData\proctor\exam\current.txt` — points to the current
  version folder; swapped atomically after a version is complete.

## The sync

The sync task runs [src/sync-exam.ps1](../src/sync-exam.ps1) as SYSTEM
every minute. It mounts the share root with `share.cred`, copies the
newest PDF and `exam.json` from the device folder into a fresh version
folder, then repoints `current.txt`. A failure before the swap changes
nothing; it prunes all but the current version and the one before it.

## The server

The server task runs [src/server.ps1](../src/server.ps1) as SYSTEM,
started at boot and restarted on failure. It binds a `HttpListener` to
`http://127.0.0.1:<port>/`. Each request resolves `current.txt` once and
reads `exam.json` and `Exam.pdf` from that one version folder, so the
state and the PDF always come from the same version. `/state` returns the
phase; `/exam.pdf` answers only in the `open` and `none` phases. Logs go
to `C:\Kiosk\Logs\server_*.log`.

## The page

[C:\Kiosk\index.html](../src/index.html) polls `/state` every three
seconds and renders the phase — waiting countdown, the PDF with time
left, or the closed screen. Edge opens it full screen from the kiosk
configuration [src/assigned-access.ps1](../src/assigned-access.ps1)
produces on Pro, Education and Enterprise, or as a kiosk-mode shortcut on
Home and Server.
