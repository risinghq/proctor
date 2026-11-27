# Development

```
mise run check
```

`check` runs `lint` (PSScriptAnalyzer) and `test` (Pester), defined in
[mise.toml](../mise.toml). Both need `pwsh` on the PATH; the tasks install
missing modules for the current user.

## Unit tests

[tests/Proctor.Tests.ps1](../tests/Proctor.Tests.ps1) is a Pester suite
against the pure logic in [proctor.psm1](../proctor.psm1): config parsing,
the exam-state machine, the version-folder helpers and the URL ACL
decisions.

## Round trip

CI runs [tests/RoundTrip.ps1](../tests/RoundTrip.ps1) on a Windows runner
(see [.github/workflows/ci.yml](../.github/workflows/ci.yml)): a real
install against a local SMB share, sync, server, probe of the student
lockdown, then uninstall and a clean-state check. Run it locally on a
Windows machine as administrator:

```powershell
.\tests\RoundTrip.ps1
```
