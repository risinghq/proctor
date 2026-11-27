# The exam window

Schedule the exam with an `exam.json` next to the PDF in the device folder
(see [Send an exam](send-an-exam.md)):

```json
{
  "title": "Math midterm",
  "opensAt": "2026-03-10T09:00:00+01:00",
  "closesAt": "2026-03-10T11:00:00+01:00"
}
```

## Fields

- `opensAt` — ISO-8601 timestamp with an offset, when the exam opens.
- `closesAt` — ISO-8601 timestamp with an offset, when it closes.
- `title` — replaces the installed exam title on screen when present.

The laptop clock decides the phase; the student account cannot change the
clock. The sync mirrors `exam.json` into the same version folder as the
PDF, so the server always reads a consistent pair.

## Phases

- **waiting** — before `opensAt`: a waiting screen with a countdown. The
  PDF is not served.
- **open** — between `opensAt` and `closesAt`: the PDF and the time left.
- **closed** — after `closesAt`: a "time is up" screen; the PDF is hidden.
- **error** — an invalid `exam.json`: a schedule-error screen telling
  students to notify the proctor. The PDF is not served, and an error
  lands in `C:\Kiosk\Logs\server_*.log`.
- **none** — no `exam.json`: the exam is unscheduled; the PDF shows
  whenever it is present, with no countdown.

`exam.json` is invalid when it does not parse, when a timestamp is not
ISO-8601 or carries no offset, or when `closesAt` is at or before
`opensAt`.
