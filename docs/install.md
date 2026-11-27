# Install

```powershell
.\install.ps1 -Config .\config.json
```

Run as administrator on each laptop. Running it twice produces the same
result. `install.ps1` is in the repository root.

## Requirements

- Windows 10 or 11, or Windows Server. PowerShell 5.1, included in Windows.
- Microsoft Edge installed.
- An SMB share on the local network, with one read-only account for the
  laptops (for example `proctor-lectura`). The account must be
  authenticated: Windows 11 24H2 refuses guest and anonymous SMB
  connections by default.
- Administrator rights for the install.

## Options

Every option can come from the JSON file or a parameter; a parameter wins
over the file. See [config.example.json](../config.example.json).

| Config key | Parameter | Description | Default |
| --- | --- | --- | --- |
| `server` | `-Server` | Name or IP of the server holding the share. | (required) |
| `share` | `-Share` | Share path under the server. A full UNC path also works: `\\192.168.5.30\sidera\Examenes`. | (required) |
| `userPrefix` | `-UserPrefix` | Prefix for the student account. The account is `<prefix>-<NN>`. | `Alumno` |
| `deviceNumber` | `-DeviceNumber` | Device number, two digits. It picks the share folder `Dispositivo <NN>` (`Device <NN>` in English). | (required) |
| `examTitle` | `-ExamTitle` | Title shown on screen. | (required) |
| `language` | `-Language` | Page language: `es` or `en`. | `es` |
| `shareUser` | `-ShareUser` | Share account with read access. The installer asks for the password on screen. | (no credential) |
| — | `-ShareCredential` | A ready-made credential, for scripted runs. Replaces `-ShareUser`. | |
| `port` | `-Port` | Loopback port for the kiosk server. | `8471` |
| — | `-Config` | Path to the JSON file. | |

With `-ShareUser` the installer asks for the password on screen; it never
goes in the file or the command line. The password is stored
DPAPI-encrypted in `C:\ProgramData\proctor\share.cred`, readable only by
SYSTEM and Administrators. Without a share user the sync connects to the
share anonymously — see [Send an exam](send-an-exam.md).

The install creates the passwordless student account, builds its profile
without anyone signing in, and points auto-logon at it. It registers the
sync task and the kiosk server task, reserves the loopback URL, applies the
lockdown for the edition found, and writes `install.json` for
[uninstall](uninstall.md). Reinstalling on a different port is refused;
uninstall first.
