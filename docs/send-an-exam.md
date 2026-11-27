# Send an exam

Drop the PDF on the share:

```
\\<server>\<share>\Dispositivo 01\Exam.pdf
```

(`Device 01` when the laptop is installed with `-Language en`.)

## The share layout

One folder per device, named `Dispositivo <NN>` or `Device <NN>` from the
device number. The folder holds:

- One or more PDFs. The sync picks the newest by modification time and
  stores it as `Exam.pdf`. Keep a single PDF to avoid ambiguity.
- An optional `exam.json` that schedules the window — see
  [The exam window](exam-window.md).

To publish an exam, drop the PDF in the folder. To withdraw it, delete the
file there.

## How the sync runs

A scheduled task runs `src/sync-exam.ps1` as SYSTEM every minute. It
connects to the share with the stored credential (see
[Install](install.md)) and copies the newest PDF and `exam.json` into a
versioned folder under `C:\ProgramData\proctor\exam`, then repoints
`current.txt` at it atomically. When the files did not change, no new
version is created. Old versions are pruned; the current one and the one
before it stay.

`C:\ProgramData\proctor` allows only SYSTEM and Administrators, so the
student cannot open the PDF directly.

An unreachable share or a read error creates no new version and changes
nothing: the laptop keeps the last good copy and the task exits nonzero. A
file absent from a reachable share is absent in the new version.
