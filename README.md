# citation-cleanup-tui

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

A run-local config is persisted next to the script as
`citation-cleanup-tui.config.json` (gitignored). Defaults are in the
script itself; new defaults are auto-merged on top of older saved configs.
