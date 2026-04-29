# citation-cleanup-tui

[![tests](https://github.com/B0LK13/citation-cleanup-tui/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/B0LK13/citation-cleanup-tui/actions/workflows/tests.yml)

Interactive PowerShell 7 TUI for finding and stripping unwanted regex
artifacts (e.g. `:contentReference[oaicite:N]{index=N}`) from Markdown
files in a directory tree.

## Run

```powershell
pwsh -File .\citation-cleanup-tui.ps1
```

Requires PowerShell 7+. No external dependencies.

## Menu

| Key | Action |
|----:|---|
| 1 | Configure (Root, Include glob, regex Pattern, StripLeading, TrimEol, ExcludeDirs) |
| 2 | Scan — count matches per file under Root |
| 3 | Preview — show matching lines from one chosen file with the match highlighted |
| 4 | Dry-run clean — report what would be removed; writes nothing |
| 5 | Apply clean — backs up each modified file as `*.bak`, removes matches, verifies |
| 6 | List `.bak` backups under Root |
| 7 | Restore from `.bak` (overwrites originals; backups are kept) |
| 8 | Delete `.bak` backups |
| 9 | Save current config |
| h | Help |
| q | Quit |

## Behaviour notes

- Files are read and written as **UTF-8**; writes use `-NoNewline` so the
  script never appends a trailing newline that wasn't already there.
- Cleaning runs in two passes: regex replacement (optionally consuming the
  spaces/tabs preceding each match), then trimming trailing whitespace on
  any line that now ends with it.
- After every apply, the file is **re-read and re-counted** to produce a
  `CLEAN` or `FAILED` status — never trust an in-memory result alone.
- Backups are sibling `*.bak` files. They are never deleted automatically;
  use menu **8** to remove them.

## Configuration

The script has six settings. You can change them three ways, in order of
increasing permanence:

1. **For one session** — open the menu, press **`1`** (Configure), edit any
   setting at the prompt (blank input keeps the current value), and answer
   `n` when asked to save.
2. **Persisted between runs** — same as above, but answer `y` to save. The
   values are written to `citation-cleanup-tui.config.json` next to the
   script (gitignored). Press **`9`** at the menu at any time to re-save
   the current in-memory settings.
3. **Change the script defaults** — edit the `$DefaultConfig` block near
   the top of `citation-cleanup-tui.ps1`. These values are used whenever no
   config file exists, and missing keys in an older config file fall back
   to them automatically.

### Settings reference

| Key | Type | Purpose |
|---|---|---|
| `Root` | string (path) | Directory to scan recursively. |
| `Include` | glob | `Get-ChildItem -Filter` pattern (e.g. `*.md`, `*.txt`). |
| `Pattern` | .NET regex | What to remove. Default targets `:contentReference[oaicite:N]{index=N}`. |
| `StripLeading` | bool | If `true`, also remove `[ \t]*` immediately before each match so cleanup doesn't leave trailing spaces. |
| `TrimEol` | bool | If `true`, after replacement collapse any leftover trailing whitespace at end-of-line. |
| `ExcludeDirs` | string[] | Path-segment names to skip during recursion (e.g. `node_modules`, `.git`). Each entry is regex-escaped automatically. |

### Config file example

`citation-cleanup-tui.config.json` (auto-created when you save from menu
**1** or **9**):

```json
{
  "Root":         "C:\\Users\\me\\Notes",
  "Include":      "*.md",
  "Pattern":      ":contentReference\\[oaicite:\\d+\\]\\{index=\\d+\\}",
  "StripLeading": true,
  "TrimEol":      true,
  "ExcludeDirs":  ["AppData", "node_modules", ".git"]
}
```

Notes:

- The file is loaded on startup; values present override the script's
  defaults, missing keys fall back to defaults. Unknown keys are ignored,
  so old config files keep working when new settings are added.
- The file path is `<script-dir>\citation-cleanup-tui.config.json`. Delete
  it to start fresh from defaults.
- It's listed in `.gitignore` so machine-specific paths and patterns never
  get committed.

## Verifying the script

A Pester 5 suite lives in [`tests/Cleanup.Tests.ps1`](tests/Cleanup.Tests.ps1)
and covers every pure-logic function (`Build-LeadingPattern`, `Clean-One`,
`Get-TargetFiles`, `Scan-Files`, `Get-Backups`, `Save-Config`,
`Load-Config`). The interactive menu is guarded behind `$env:CCTUI_TEST`
so dot-sourcing the script during tests is safe. The checks below are
what we run before each commit — from cheapest to most thorough.

### 1. Parse check (no execution)

Fastest sanity check — confirms the script has no syntax errors. Doesn't
run any code, doesn't touch any files.

```powershell
pwsh -NoProfile -Command @'
  $err = $null
  [System.Management.Automation.Language.Parser]::ParseInput(
    (Get-Content -Raw .\citation-cleanup-tui.ps1),
    [ref]$null, [ref]$err) | Out-Null
  if ($err -and $err.Count -gt 0) {
    $err | ForEach-Object { "L$($_.Extent.StartLineNumber):$($_.Extent.StartColumnNumber) $($_.Message)" }
    exit 1
  } else { "PARSE_OK" }
'@
```

Expected output: `PARSE_OK`. Any other output is a syntax error with a
file location.

### 2. Smoke test (end-to-end, on a disposable fixture)

This exercises every menu action against a throwaway file, so you can run
it without worrying about real notes. Run from the repo root.

```powershell
# Create a temp fixture with 3 known artifacts.
$tmp = Join-Path $env:TEMP ('cleanup-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
@"
# Sample
First paragraph. :contentReference[oaicite:0]{index=0}
Two on one line :contentReference[oaicite:1]{index=1} :contentReference[oaicite:2]{index=2}
Clean line.
"@ | Set-Content -LiteralPath (Join-Path $tmp 'sample.md') -Encoding UTF8

# Launch the TUI; in the menu:
#   1 -> Configure: set Root to $tmp, accept other defaults, don't save
#   2 -> Scan         (expect: 3 matches in 1 file)
#   4 -> Dry-run      (expect: Removed=3 Status=DRY)
#   5 -> Apply        (expect: Removed=3 Status=CLEAN)
#   6 -> List backups (expect: 1 .bak file)
#   7 -> Restore      (expect: Restored 1/1)
#   8 -> Delete .bak  (expect: Deleted 1/1)
#   q -> Quit         (expect: 'Bye.' and a clean exit)
pwsh -File .\citation-cleanup-tui.ps1

# Tear down.
Remove-Item -LiteralPath $tmp -Recurse -Force
```

If any step shows `Status=FAILED`, the wrong removed count, or the script
hangs at the `Choose:` prompt after `q`, that's a regression — please
open an issue with the output.

### 3. Repository integrity

Quick checks that the working tree matches what's committed:

```sh
git fsck --full       # object-level integrity
git status            # should be clean ("working tree clean")
git log --oneline -5  # most recent commits
```

### 4. Pester suite

The suite needs [Pester 5+](https://pester.dev). Install once if you
don't have it:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
```

Run from the repo root:

```powershell
Invoke-Pester ./tests -Output Detailed
```

The same suite runs on every push and pull request against `main` via
GitHub Actions — see [`.github/workflows/tests.yml`](.github/workflows/tests.yml).
Results are uploaded as a `pester-results` artifact (NUnit XML).

What it covers (13 tests, ~1.6 s):

- `Build-LeadingPattern` — prefix toggle.
- `Clean-One` — CLEAN / SKIP / DRY status, .bak creation, StripLeading
  consumes preceding whitespace, TrimEol strips trailing whitespace.
- `Get-TargetFiles` — Include glob + ExcludeDirs path-segment matching;
  empty result when Root is missing.
- `Scan-Files` — per-file match counts, clean files skipped.
- `Get-Backups` — finds `*.bak` under Root, respects ExcludeDirs.
- `Save-Config` / `Load-Config` — JSON roundtrip + default fallback for
  missing keys (uses the `-Path` parameter to avoid touching the user's
  real config).

### 5. Adding more tests (contributors)

The scaffold deliberately covers only pure-logic functions. Open
`tests/Cleanup.Tests.ps1` and append a `Describe` (or an `It` inside an
existing `Describe`). For filesystem fixtures, follow the existing
pattern: a unique temp dir under `[System.IO.Path]::GetTempPath()`,
cleaned up in `AfterAll` / `AfterEach`. For the config functions, pass
`-Path $tmp` instead of relying on the script-level `$ConfigPath` (it
lives in a different scope and can't be overridden cleanly from a test).

## Contributing

Contributions are welcome — bug fixes, new actions, regex presets, docs
improvements, cross-platform tweaks, etc.

### Quick start

1. **Fork** https://github.com/B0LK13/citation-cleanup-tui on GitHub.
2. **Clone** your fork and create a branch:
   ```sh
   git clone https://github.com/<your-user>/citation-cleanup-tui.git
   cd citation-cleanup-tui
   git checkout -b feat/short-description
   ```
3. Make your changes (see guidelines below).
4. **Verify** the script still parses and behaves:
   ```powershell
   pwsh -NoProfile -Command "$err=$null; [System.Management.Automation.Language.Parser]::ParseInput((Get-Content -Raw .\citation-cleanup-tui.ps1), [ref]$null, [ref]$err) | Out-Null; if ($err) { $err; exit 1 } else { 'PARSE_OK' }"
   pwsh -File .\citation-cleanup-tui.ps1   # smoke-test the menu manually
   ```
5. **Commit** with a Conventional-Commits-style subject and push:
   ```sh
   git add -A
   git commit -m "feat: add JSON-output mode"
   git push -u origin feat/short-description
   ```
6. **Open a Pull Request** against `main` with a short description of
   what changed and why, plus reproduction steps for any bug you fixed.

### Issues

Before opening an issue, please include:

- PowerShell version (`$PSVersionTable.PSVersion`).
- Operating system.
- The exact command you ran and the output (redact paths if needed).
- Your `Pattern` and `Include` settings if relevant.
- Whether the bug reproduces with the **default** config and an empty
  `citation-cleanup-tui.config.json` (delete it to start fresh).

### Coding guidelines

- **PowerShell 7+ only.** Don't add Windows PowerShell 5.x compat shims.
- **Keep it single-file.** No external modules or PSGallery dependencies.
  If a dependency really is needed, propose it in an issue first.
- **No destructive actions without confirmation.** Anything that writes,
  deletes, or overwrites files must prompt with `(y/N)` and default to no.
- **Backup before write.** Match the existing pattern in `Clean-One`:
  copy to `*.bak`, write, then re-read and verify.
- **UTF-8 + `-NoNewline`.** Don't append a trailing newline a file didn't
  have. Don't change file encoding.
- **Comment-based help on every function** (`<# .SYNOPSIS ... #>`).
  Inline comments for any non-obvious regex, array trick, or scope quirk.
- **Action-* functions own their own I/O.** The main loop is just a
  router; don't put `Read-Host` or `Write-Host` calls there.
- **Verify before claiming success.** If you add a new clean-style
  action, re-read from disk and count again, the way `Clean-One` does.
- Style: 4-space indent, `PascalCase` functions, `camelCase` locals,
  ANSI-colour helpers (`Good`/`Warn`/`Bad`/`Hdr`/`Dim`/`Title`) instead
  of `Write-Host -ForegroundColor`.

### Adding a new menu action

1. Write `Action-YourThing` next to the other `Action-*` functions, with
   comment-based help.
2. Add a `Write-Host` line for it inside the menu in the main loop.
3. Add a regex branch in the `switch -Regex ($choice)` block.
4. If the action mutates `$cfg` or `$hits`, return the new value so the
   main loop can rebind it (see `Action-Scan` and `Action-Clean`).
5. Update the **Menu** table in this README and the inline `Action-Help`
   text in the script.

### Commit messages

We loosely follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` user-visible new behaviour
- `fix:` bug fix
- `docs:` README / comment-based help only
- `refactor:` code change with no behaviour change
- `chore:` tooling, `.gitignore`, etc.

If an AI agent helped, add a co-author trailer on a final blank-line‐
separated paragraph of the commit message:

```
Co-Authored-By: Name <email@example.com>
```

### Code of conduct

Be kind, be specific, assume good faith. Reviews focus on the change,
not the contributor.
