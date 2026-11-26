# proctor

proctor prepares a Windows laptop for an exam. It creates a passwordless
student account, limits what that account can do, and shows the exam on
screen: a full-screen page in Microsoft Edge that displays the PDF arriving
over the network. A small HTTP server on the laptop decides what the page
shows — a waiting screen before the exam opens, the PDF with a countdown
while it is open, and a "time is up" screen after it closes. Answers are
written on paper; proctor collects and grades nothing.

## Requirements

- Windows 10 or 11, or Windows Server. PowerShell 5.1, included in Windows.
- Microsoft Edge installed.
- An SMB share on the local network.
- Run the install as administrator.

## Installation

Run as administrator on each laptop:

```powershell
.\install.ps1 -Config .\config.json
```

or with parameters directly:

```powershell
.\install.ps1 -Server 192.168.5.30 -Share "sidera\Examenes" -DeviceNumber 01 -ExamTitle "Math midterm" -ShareUser proctor-lectura
```

With `-ShareUser` the installer asks for the password on screen (it appears
in no file and no command). In scripts pass
`-ShareCredential (Get-Credential)`; then `-ShareUser` is not needed.

| Parameter | Description | Default |
| --- | --- | --- |
| `-Server` | Name or IP of the server holding the share. | (required) |
| `-Share` | Share path under the server. Also accepts the full UNC path, for example `\\192.168.5.30\sidera\Examenes`. | (required) |
| `-UserPrefix` | Prefix for the student account. The final account is `<prefix>-<NN>`. | `Alumno` |
| `-DeviceNumber` | Device number, two digits. | (required) |
| `-ExamTitle` | Title shown on screen. | (required) |
| `-Language` | Page language: `es` or `en`. | `es` |
| `-ShareUser` | Server account with read access to the share. The password is asked on screen. | (no credential) |
| `-ShareCredential` | A ready-made credential, for scripted runs. | |
| `-Port` | Loopback port for the kiosk server. | `8471` |
| `-Config` | JSON file with the same values (includes `shareUser`). The password never goes in the file. Parameters win. | |

Example `config.json` (see `config.example.json`):

```json
{
  "server": "192.168.5.30",
  "share": "sidera/Examenes",
  "userPrefix": "Alumno",
  "deviceNumber": "01",
  "examTitle": "Math midterm",
  "language": "es"
}
```

The install creates the passwordless student account, builds its profile
without anyone signing in, and points auto-logon at that account. Running it
twice produces the same result.

## How the exam arrives

The sync task copies the newest PDF every minute from
`\\<server>\<share>\Dispositivo NN` (or `Device NN` in English) into a
versioned folder under `C:\ProgramData\proctor\exam`, then repoints
`current.txt` at it. `C:\ProgramData\proctor` allows only SYSTEM and
Administrators, so the student cannot open the PDF directly. To publish an
exam, drop the PDF in the device folder; to withdraw it, delete the file
there.

The task runs as SYSTEM and connects to the share with its own account. The
server needs a read-only account on the share (for example
`proctor-lectura`), given with `-ShareUser` or `shareUser` in the config.
The password is stored DPAPI-encrypted in
`C:\ProgramData\proctor\share.cred`, readable only by SYSTEM and
Administrators. Without a stored credential the connection is anonymous.

A share open to guests does not work: Windows 11 24H2 refuses guest and
anonymous SMB connections by default, so the server must not rely on an
unauthenticated share.

## The exam window

An optional `exam.json` next to the PDF in the device folder schedules the
exam. The sync task mirrors it into the same version folder as the PDF, so
the server always reads a consistent pair.

```json
{
  "title": "Math midterm",
  "opensAt": "2026-03-10T09:00:00+01:00",
  "closesAt": "2026-03-10T11:00:00+01:00"
}
```

`opensAt` and `closesAt` are ISO-8601 timestamps with an offset. The laptop
clock decides the phase; the student account cannot change the clock.

- Before `opensAt` the page shows a waiting screen with a countdown.
- Between `opensAt` and `closesAt` it shows the PDF and the time left.
- After `closesAt` it shows a "time is up" screen and hides the PDF.
- With no `exam.json` the exam is unscheduled: the PDF shows whenever it is
  present, with no countdown.
- A malformed `exam.json` (unparseable, a bad or offset-less timestamp, or a
  `closesAt` at or before `opensAt`) blocks the exam: the page shows a
  schedule-error screen telling students to notify the proctor, the PDF is
  not served, and an error lands in `C:\Kiosk\Logs\server_*.log`.

## The kiosk server

A PowerShell `HttpListener` bound to `http://127.0.0.1:<port>/` serves the
kiosk page. It runs as SYSTEM from its own scheduled task, started at boot
and restarted on failure. The page polls `/state` every few seconds and
renders the phase the server computes. `/exam.pdf` answers only while the
exam is open or unscheduled, so the PDF is never reachable before `opensAt`
or after `closesAt`.

## Lockdown

The student account has no internet access: the firewall blocks all outbound
traffic for that account. Loopback is never filtered, so the page still
reaches the kiosk server. The sync task runs as SYSTEM, so the student
account neither needs to reach the share nor can read other devices' exam
folders. Edge policies disable downloads, printing, the context menu and
sign-in, and block `file://` pages.

On Windows Pro, Education and Enterprise the account works as a single-app
kiosk through Assigned Access: Edge opens `http://127.0.0.1:<port>/` full
screen.

On Windows Home, which has no Assigned Access, registry restrictions apply
(no Run dialog, no command prompt, no Task Manager) and Edge starts in kiosk
mode at logon.

The installer prints the edition it found and the path it applied.

## Uninstall

```powershell
.\uninstall.ps1 -UserName Alumno-01 -Force
```

or with the same parameters as the install (`-Config`, `-UserPrefix`,
`-DeviceNumber`). The install records its port and whether it created the
URL reservation in `C:\ProgramData\proctor\install.json`, so uninstall
removes only a reservation Proctor made, even when it runs with only
`-UserName`. It removes both scheduled
tasks, the URL reservation, the
firewall rules, the policies, Assigned Access, auto-logon, `C:\Kiosk`,
`C:\ProgramData\proctor` (including the credential), the student account and
its profile. Without `-Force` it asks for confirmation. It also works after
an incomplete install.

## Development

Checks run with mise:

```
mise run check
```

`check` runs `lint` (PSScriptAnalyzer) and `test` (Pester). They need `pwsh`
on the PATH; the tasks install missing modules for the current user.
