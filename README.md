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
