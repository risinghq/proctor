# proctor

proctor locks a Windows laptop down for an exam. The institution drops a
PDF on its SMB share; the laptop shows it full screen during the scheduled
window and nothing else. Students answer on paper. Uninstalling restores
the laptop.

```powershell
.\install.ps1 -Config .\config.json
```

Minimal `config.json` (see [docs/install.md](docs/install.md) for every
option):

```json
{
  "server": "192.168.5.30",
  "share": "sidera/Examenes",
  "deviceNumber": "01",
  "examTitle": "Math midterm"
}
```

To publish an exam, drop the PDF in `\\<server>\<share>\Dispositivo 01`
on the share. See [docs/send-an-exam.md](docs/send-an-exam.md).

- Single-app kiosk on Pro, Education and Enterprise; registry lockdown on
  Home and Server.
- Scheduled exam window from `exam.json`, with a countdown on screen.
- The PDF is served only while the exam is open.
- The student account has no internet access: a firewall rule blocks all
  its outbound traffic.
- The share credential is stored DPAPI-encrypted, readable only by SYSTEM
  and Administrators.
- The exam PDF lands in a folder only SYSTEM and Administrators can read.
- Auto-logon signs the student in at boot; no password is needed.
- Uninstall removes what install added: tasks, firewall rule, kiosk
  settings, account, profile and files.

See the [manual](docs/readme.md) and
[development](docs/development.md).
