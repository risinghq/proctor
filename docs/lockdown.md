# Lockdown

The student sees a full-screen Edge window on `http://127.0.0.1:<port>/`.
Everything else is locked.

## Per edition

- **Pro, Education, Enterprise** — Assigned Access runs the account as a
  single-app kiosk: Edge opens the kiosk URL full screen at sign-in.
- **Home, Server** — no Assigned Access, so registry restrictions apply:
  no Run dialog, no command prompt, no Task Manager. Edge starts in kiosk
  mode at logon.

Edge policies disable downloads, printing, the context menu and sign-in,
and block `file://` pages.

## The account

The student account signs in automatically at boot and has no password.
It cannot reach the internet: a firewall rule blocks all its outbound
traffic. Loopback is never filtered, so the page still reaches the kiosk
server on 127.0.0.1. The account cannot change the clock, read
`C:\ProgramData\proctor` (only SYSTEM and Administrators may), or reach
other devices' folders on the share — the sync runs as SYSTEM, not as the
student.

## The kiosk server

A `HttpListener` bound to `http://127.0.0.1:<port>/` serves the page as
SYSTEM. It is not reachable from the network. `/exam.pdf` answers only
while the exam is open or unscheduled, so the PDF is not reachable before
`opensAt` or after `closesAt`.

The installer prints the edition it found and the lockdown it applied.
