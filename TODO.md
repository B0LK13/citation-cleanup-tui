# TODO

Post-v1.0 backlog for `citation-cleanup-tui`. Items are roughly ordered
by value and effort. Pick them up as GitHub issues when you start work.

---

## Testing

### 1. Automated Pester tests for `Action-*` functions

The 13 tests in `tests/Cleanup.Tests.ps1` cover every pure-logic
function. The six `Action-*` wrappers (`Action-Configure`,
`Action-Scan`, `Action-Clean`, `Action-ListBackups`, `Action-Restore`,
`Action-DeleteBackups`) have no unit coverage yet.

They need `Read-Host` / `Write-Host` to be mockable in isolation — the
cleanest approach is to extract the I/O calls into thin helpers that can
be swapped out in tests, then add a new `Describe 'Action-Clean'` etc.
in the existing test file.

---

## CLI / Automation

### 2. `-WhatIf` / dry-run CLI flag

Allow the script to be invoked non-interactively from pipelines or cron
jobs:

```powershell
pwsh -File .\citation-cleanup-tui.ps1 -WhatIf
```

When `-WhatIf` is set the script should scan, print a summary, and exit
without touching files — equivalent to menu option **4** run silently.

### 3. Non-interactive batch-clean mode

Accept explicit parameters on the command line so no menu is shown:

```powershell
pwsh -File .\citation-cleanup-tui.ps1 -Root C:\Notes -Pattern '...' -Apply
```

Suggested parameters: `-Root`, `-Include`, `-Pattern`, `-Apply`
(switch). Falls back to interactive menu when none are given.

---

## Features

### 4. Support multiple patterns (array input)

Currently `Pattern` accepts a single .NET regex. Extend it to accept an
array so multiple artifact types are stripped in one pass:

```json
"Pattern": [
  ":contentReference\\[oaicite:\\d+\\]\\{index=\\d+\\}",
  "\\[\\^\\d+\\]:\\s*.+"
]
```

### 5. Progress indicator during long scans

For large vaults (thousands of files) the scan step is silent for up to
60 s. Add a `Write-Progress` call inside `Scan-Files` that updates with
the current file index and folder depth so users know work is happening.

### 6. Configurable backup extension / backup directory

Today backups land as `<file>.bak` next to the original. Add two
optional config keys:

- `BackupExtension` (default `.bak`)
- `BackupRoot` (default empty = sibling; if set, mirror directory
  structure under this path)

### 7. Summary report / log output to file

After **Apply**, optionally write a timestamped record of every file
touched:

- Format: CSV or JSON (config key `LogPath`, default empty = no log)
- Columns: `Timestamp`, `Path`, `Removed`, `Status`

Useful for auditing changes across repeated runs.

---

## CI

### 8. Cross-platform test matrix (Linux + macOS)

The GitHub Actions workflow currently runs only on `windows-latest`.
Extend it with a matrix strategy to catch path-separator and
line-ending differences:

```yaml
strategy:
  matrix:
    os: [windows-latest, ubuntu-latest, macos-latest]
runs-on: ${{ matrix.os }}
```

---

## Distribution

### 9. PowerShell Gallery / winget publication

Package the script as a PSGallery module so it can be installed with:

```powershell
Install-Module citation-cleanup-tui -Scope CurrentUser
```

Steps: create a `citation-cleanup-tui.psd1` module manifest, add a
`Publish-Module` step to a release workflow, register a NuGet API key
as a GitHub secret.

Optionally also add a `winget` manifest for GUI-friendly installation.

### 10. Proper GitHub Release for v1.0 (and future tags)

The `v1.0` tag exists on GitHub but has no associated Release page,
release notes, or downloadable asset.

- Create the Release via `gh release create v1.0 --generate-notes`.
- Attach `citation-cleanup-tui-v1.0.zip` as a release asset.
- Add a `CHANGELOG.md` entry summarising v1.0.
- Add a GitHub Actions workflow step that auto-publishes a Release on
  every `v*` tag push.
