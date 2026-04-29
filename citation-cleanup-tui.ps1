#requires -Version 7.0
<#
.SYNOPSIS
    Markdown artifact cleanup TUI.

.DESCRIPTION
    Interactive terminal UI for finding and stripping unwanted regex artifacts
    (e.g. :contentReference[oaicite:N]{index=N}) from Markdown files.
    Supports scan, preview, dry-run, clean (with .bak backups), restore, and
    backup deletion. Configuration persists to citation-cleanup-tui.config.json
    next to the script.

    Architecture (top-to-bottom):
      1. Constants & default config
      2. ANSI colour helpers (no external deps)
      3. Config persistence (Load-Config / Save-Config)
      4. File enumeration (Get-TargetFiles, Get-Backups)
      5. Pure logic (Scan-Files, Build-LeadingPattern, Clean-One, Show-Preview)
      6. Menu helpers (Print-Header, Pause-Any, Pick-FromList)
      7. Action-* wrappers — one per menu item, all I/O lives here
      8. Main loop (labeled :menu so 'q' can break out of switch + while)

    Design notes:
      - All file I/O is UTF-8 with -NoNewline writes, so we never
        accidentally append a trailing newline to a file that did not
        already have one.
      - Cleaning is done in two passes: replace pattern (optionally
        with leading whitespace), then trim trailing whitespace on
        touched lines. After write, we re-read and re-count to
        produce a CLEAN/FAILED status — never trust the in-memory
        result alone.
      - Backups are sibling .bak files (Path + '.bak'). They are NOT
        cleaned up automatically; the user must use menu option 7
        (Restore) or 8 (Delete .bak).
      - Pattern can be ANY .NET regex; the default targets ChatGPT-
        style :contentReference[oaicite:N]{index=N} citation leftovers.

.EXAMPLE
    pwsh -File .\citation-cleanup-tui.ps1

    Launches the interactive menu using the saved config (or defaults
    if no config file exists yet).

.NOTES
    Run:    pwsh -File .\citation-cleanup-tui.ps1
    Or:     .\citation-cleanup-tui.ps1

    Config: <script-dir>\citation-cleanup-tui.config.json

    Changelog:
      - Initial: scan/preview/dry-run/clean/restore/delete + persistent config.
      - Fix: replaced bare 'break' in quit branch with labeled 'break menu'
        because 'break' inside a switch only exits the switch, not the
        surrounding while ($true) loop.
#>

# CmdletBinding gives us -Verbose / -Debug / -ErrorAction for free.
[CmdletBinding()]
param()

# ---------- Constants ----------
# Resolve the script's own directory so the config file can sit next to the
# script regardless of the caller's current working directory.
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath  = Join-Path $ScriptDir 'citation-cleanup-tui.config.json'

# Default configuration. Each property is also a key in the persisted JSON;
# Load-Config merges saved values onto this template so adding a new property
# here is automatically backward-compatible with older config files.
$DefaultConfig = [pscustomobject]@{
    Root          = 'C:\Users\Admin\Documents'                                    # recursion root
    Include       = '*.md'                                                          # Get-ChildItem -Filter glob
    Pattern       = ':contentReference\[oaicite:\d+\]\{index=\d+\}'                # .NET regex
    StripLeading  = $true   # also remove preceding spaces/tabs before each match
    TrimEol       = $true   # strip trailing whitespace on lines we touched
    ExcludeDirs   = @('AppData','node_modules','.git','.venv','venv','.npm','.cache') # path-segment names to skip
}

# ---------- ANSI helpers ----------
# Minimal SGR-based colouring. PowerShell 7 + Windows Terminal / pwsh.exe
# both render these by default. We avoid Write-Host -ForegroundColor so the
# output composes nicely inside Write-Host "$(Good 'ok')" expressions.
$ESC = [char]27
function Color {
    # Wrap $Text in an SGR sequence with the given $Code (e.g. '1;32' = bold green).
    param([string]$Text, [string]$Code)
    "$ESC[${Code}m$Text$ESC[0m"
}
function Title  ($t) { Color $t '1;36' }      # bold cyan   - banner text
function Dim    ($t) { Color $t '2;37' }      # dim grey    - notes/hints
function Good   ($t) { Color $t '1;32' }      # green       - success
function Warn   ($t) { Color $t '1;33' }      # yellow      - warning / cancelled
function Bad    ($t) { Color $t '1;31' }      # red         - error / failure
function Hdr    ($t) { Color $t '1;35' }      # magenta     - section headers

# ---------- Config persistence ----------
function Load-Config {
    <#
    .SYNOPSIS
        Load configuration from $ConfigPath, merging into $DefaultConfig.
    .DESCRIPTION
        Returns a PSCustomObject with the full set of properties from
        $DefaultConfig. Any property present in the saved JSON overrides the
        default; properties missing from the JSON keep the default value.
        On any read/parse error, falls back to defaults and warns the user.
    .OUTPUTS
        [pscustomobject] with the same shape as $DefaultConfig.
    #>
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $loaded = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            $merged = [pscustomobject]@{}
            # Iterate over DEFAULT keys (not loaded keys) so unknown keys in the
            # JSON are silently ignored and new defaults appear automatically.
            foreach ($p in $DefaultConfig.PSObject.Properties.Name) {
                $val = if ($loaded.PSObject.Properties.Name -contains $p) { $loaded.$p } else { $DefaultConfig.$p }
                $merged | Add-Member -NotePropertyName $p -NotePropertyValue $val
            }
            return $merged
        } catch {
            Write-Host (Bad "Failed to read config: $($_.Exception.Message). Using defaults.")
            return $DefaultConfig.PSObject.Copy()
        }
    }
    return $DefaultConfig.PSObject.Copy()
}
function Save-Config([object]$cfg) {
    <#
    .SYNOPSIS
        Persist $cfg to $ConfigPath as pretty-printed UTF-8 JSON.
    #>
    $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-Host (Good "Saved config -> $ConfigPath")
}

# ---------- File enumeration ----------
function Get-TargetFiles {
    <#
    .SYNOPSIS
        Recursively list files under $cfg.Root matching $cfg.Include,
        excluding any path that contains a segment in $cfg.ExcludeDirs.
    .NOTES
        ExcludeDirs entries are matched as full path segments (delimited by
        '\' or '/') so 'venv' won't accidentally exclude '.\my-venv-app\'.
        Each entry is regex-escaped before being joined with '|'.
    #>
    param([object]$cfg)
    if (-not (Test-Path -LiteralPath $cfg.Root)) {
        Write-Host (Bad "Root does not exist: $($cfg.Root)")
        return @()
    }
    # Escape user-supplied dir names so '.git' doesn't behave like a regex.
    $excludePattern = ($cfg.ExcludeDirs | ForEach-Object { [regex]::Escape($_) }) -join '|'
    Get-ChildItem -LiteralPath $cfg.Root -Recurse -File -Filter $cfg.Include -ErrorAction SilentlyContinue |
        Where-Object {
            if (-not $excludePattern) { return $true }
            # Must be a full path segment, hence the [\\/] delimiters on each side.
            $_.FullName -notmatch "[\\/]($excludePattern)[\\/]"
        }
}

# ---------- Scan ----------
function Scan-Files {
    <#
    .SYNOPSIS
        Count regex matches per file. Returns objects only for files with > 0
        matches.
    .OUTPUTS
        [pscustomobject[]] with { Path; Matches; SizeKB }.
        Always returned as an array (the leading-comma in `return ,$hits`
        prevents PowerShell from unwrapping a single-element collection).
    #>
    param([object]$cfg)
    $rx = [regex]$cfg.Pattern
    $files = Get-TargetFiles $cfg
    $hits = foreach ($f in $files) {
        # Read whole file once. -ErrorAction SilentlyContinue avoids dying on
        # files we can't read (locked, permissions, etc.) — we just skip them.
        $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($null -eq $raw) { continue }
        $count = $rx.Matches($raw).Count
        if ($count -gt 0) {
            [pscustomobject]@{ Path = $f.FullName; Matches = $count; SizeKB = [math]::Round($f.Length/1KB,1) }
        }
    }
    # Force array return even for 0/1 hits.
    return ,$hits
}

# ---------- Cleaning ----------
function Build-LeadingPattern {
    <#
    .SYNOPSIS
        Return the cleanup regex, optionally prefixed with '[ \t]*' so
        trailing-on-line artifacts also consume the spaces/tabs in front of
        them (avoiding lines that end with stray whitespace after removal).
    #>
    param([object]$cfg)
    if ($cfg.StripLeading) { return ('[ \t]*' + $cfg.Pattern) }
    return $cfg.Pattern
}
function Clean-One {
    <#
    .SYNOPSIS
        Clean a single file in place, with backup, and verify by re-reading.
    .PARAMETER Path
        Absolute path to the file. A '<Path>.bak' is written next to it.
    .PARAMETER cfg
        Config object (Pattern, StripLeading, TrimEol).
    .PARAMETER DryRun
        If set, no .bak is written and no file is modified; only a count
        is reported.
    .OUTPUTS
        [pscustomobject] with { Path; Removed; Status } where Status is one
        of: SKIP (no matches), DRY (dry-run), CLEAN (apply succeeded),
        FAILED (apply ran but post-write count > 0).
    #>
    param([string]$Path, [object]$cfg, [switch]$DryRun)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $rxFull = [regex](Build-LeadingPattern $cfg)
    $before = $rxFull.Matches($raw).Count
    if ($before -eq 0) { return [pscustomobject]@{ Path=$Path; Removed=0; Status='SKIP' } }

    # Pass 1: remove every match (and its preceding whitespace if StripLeading).
    $cleaned = $rxFull.Replace($raw, '')
    # Pass 2: collapse trailing whitespace on any line that now ends with it.
    if ($cfg.TrimEol) { $cleaned = [regex]::Replace($cleaned, '[ \t]+(\r?\n)', '$1') }

    if ($DryRun) {
        return [pscustomobject]@{ Path=$Path; Removed=$before; Status='DRY' }
    }

    # Backup BEFORE writing so a write failure can't lose data.
    Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force
    # -NoNewline avoids appending an extra \n that wasn't in the original.
    Set-Content -LiteralPath $Path -Value $cleaned -Encoding UTF8 -NoNewline

    # Verify: re-read disk content, count matches against the *bare* pattern
    # (not the leading-whitespace variant) so we measure what really matters.
    $after = ([regex]$cfg.Pattern).Matches((Get-Content -LiteralPath $Path -Raw -Encoding UTF8)).Count
    $status = if ($after -eq 0) { 'CLEAN' } else { 'FAILED' }
    return [pscustomobject]@{ Path=$Path; Removed=$before; Status=$status }
}

# ---------- Preview ----------
function Show-Preview {
    <#
    .SYNOPSIS
        Print up to $MaxLines lines from $Path that contain a regex match,
        with the matched substring highlighted red. Long lines are truncated.
    #>
    param([string]$Path, [object]$cfg, [int]$MaxLines = 8)
    if (-not (Test-Path -LiteralPath $Path)) { Write-Host (Bad "Not found: $Path"); return }
    $rx = [regex]$cfg.Pattern
    $i = 0
    Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object {
        $i++
        if ($rx.IsMatch($_)) {
            # Inline replacement with a callback wraps each match in red SGR.
            $line = $rx.Replace($_, { param($m) "$ESC[1;31m$($m.Value)$ESC[0m" })
            $shown = if ($line.Length -gt 200) { $line.Substring(0,200) + (Dim '...') } else { $line }
            Write-Host ("{0,5}: {1}" -f $i, $shown)
        }
    } | Select-Object -First $MaxLines | Out-Null
}

# ---------- Backups ----------
function Get-Backups {
    <#
    .SYNOPSIS
        Recursively list every *.bak file under $cfg.Root, honouring the
        same ExcludeDirs rules as Get-TargetFiles.
    .NOTES
        We don't restrict to <Include>.bak so legacy backups from earlier
        runs are also found.
    #>
    param([object]$cfg)
    if (-not (Test-Path -LiteralPath $cfg.Root)) { return @() }
    $excludePattern = ($cfg.ExcludeDirs | ForEach-Object { [regex]::Escape($_) }) -join '|'
    Get-ChildItem -LiteralPath $cfg.Root -Recurse -File -Filter '*.bak' -ErrorAction SilentlyContinue |
        Where-Object {
            if (-not $excludePattern) { return $true }
            $_.FullName -notmatch "[\\/]($excludePattern)[\\/]"
        }
}

# ---------- Menu helpers ----------
function Print-Header {
    <#
    .SYNOPSIS
        Clear the screen and render the banner + current configuration
        snapshot. Called at the top of every menu iteration so the user
        always sees the active settings.
    #>
    param([object]$cfg)
    Clear-Host
    Write-Host (Title '╔══════════════════════════════════════════════════════════════════╗')
    Write-Host (Title '║          Markdown Artifact Cleanup TUI (PowerShell 7)            ║')
    Write-Host (Title '╚══════════════════════════════════════════════════════════════════╝')
    Write-Host ''
    Write-Host (Hdr 'Current configuration:')
    Write-Host ("  Root         : " + $cfg.Root)
    Write-Host ("  Include      : " + $cfg.Include)
    Write-Host ("  Pattern      : " + $cfg.Pattern)
    Write-Host ("  StripLeading : " + $cfg.StripLeading)
    Write-Host ("  TrimEol      : " + $cfg.TrimEol)
    Write-Host ("  ExcludeDirs  : " + ($cfg.ExcludeDirs -join ', '))
    Write-Host ''
}
# Block-and-wait helper between an action's output and the next menu paint.
function Pause-Any { Write-Host ''; Read-Host (Dim 'Press Enter to continue') | Out-Null }

function Pick-FromList {
    <#
    .SYNOPSIS
        Print a 1-indexed numbered list of $Items and prompt the user to
        pick one. Returns the chosen item, or $null on empty list / invalid
        / out-of-range input.
    #>
    param([object[]]$Items, [string]$Prompt = 'Pick #')
    if (-not $Items -or $Items.Count -eq 0) { Write-Host (Warn 'No items.'); return $null }
    for ($i=0; $i -lt $Items.Count; $i++) {
        Write-Host ("  [{0,2}] {1}" -f ($i+1), $Items[$i])
    }
    $sel = Read-Host $Prompt
    if ($sel -match '^\d+$') {
        $idx = [int]$sel - 1
        if ($idx -ge 0 -and $idx -lt $Items.Count) { return $Items[$idx] }
    }
    return $null
}

# ---------- Actions ----------
# Each Action-* function corresponds to a menu item. Actions own their own
# Read-Host prompts and Write-Host output; the main loop only routes to them.
function Action-Configure {
    <#
    .SYNOPSIS
        Interactively edit configuration in place. Pass a [ref] so the
        caller's $cfg is updated on return. Optionally persists to disk.
    #>
    param([ref]$cfgRef)
    $cfg = $cfgRef.Value
    Write-Host (Hdr 'Edit configuration (blank = keep current):')
    $r = Read-Host "Root [$($cfg.Root)]"
    if ($r) { $cfg.Root = $r }
    $r = Read-Host "Include [$($cfg.Include)]"
    if ($r) { $cfg.Include = $r }
    $r = Read-Host "Pattern (regex) [$($cfg.Pattern)]"
    if ($r) { $cfg.Pattern = $r }
    $r = Read-Host "StripLeading (true/false) [$($cfg.StripLeading)]"
    if ($r) { $cfg.StripLeading = ($r -match '^(?i:true|1|y|yes)$') }
    $r = Read-Host "TrimEol (true/false) [$($cfg.TrimEol)]"
    if ($r) { $cfg.TrimEol = ($r -match '^(?i:true|1|y|yes)$') }
    $r = Read-Host "ExcludeDirs (comma-separated) [$($cfg.ExcludeDirs -join ',')]"
    if ($r) { $cfg.ExcludeDirs = ($r -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
    $cfgRef.Value = $cfg
    if ((Read-Host 'Save to disk? (y/N)') -match '^(?i:y|yes)$') { Save-Config $cfg }
}

function Action-Scan {
    <#
    .SYNOPSIS
        Run a scan, print a summary + sorted table, and return the hit list
        for the caller to cache (used by Preview / Clean).
    #>
    param([object]$cfg)
    Write-Host (Dim "Scanning $($cfg.Root) for $($cfg.Include) ...")
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $hits = Scan-Files $cfg
    $sw.Stop()
    if (-not $hits -or $hits.Count -eq 0) {
        Write-Host (Good "No matches found. ($([int]$sw.Elapsed.TotalSeconds)s)")
        return @()
    }
    $total = ($hits | Measure-Object -Property Matches -Sum).Sum
    Write-Host (Good ("Found {0} matches across {1} files in {2}s." -f $total, $hits.Count, [int]$sw.Elapsed.TotalSeconds))
    Write-Host ''
    $hits | Sort-Object -Property Matches -Descending | Format-Table -AutoSize Matches, SizeKB, Path | Out-Host
    return $hits
}

function Action-Preview {
    <#
    .SYNOPSIS
        Let the user pick one file from the last scan and show its matching
        lines with the matched substring highlighted.
    #>
    param([object]$cfg, [object[]]$hits)
    if (-not $hits -or $hits.Count -eq 0) { Write-Host (Warn 'Run a scan first.'); return }
    $paths = $hits | ForEach-Object { $_.Path }
    $picked = Pick-FromList $paths 'Preview which file? #'
    if (-not $picked) { return }
    Write-Host ''
    Write-Host (Hdr "Matches in: $picked")
    Show-Preview -Path $picked -cfg $cfg -MaxLines 20
}

function Action-Clean {
    <#
    .SYNOPSIS
        Apply (or dry-run) the cleanup across every file in $hits.
    .NOTES
        On apply, returns @() so the caller's cached $hits is invalidated
        (the files no longer have matches and a stale cache would mislead
        Preview / subsequent Clean calls). On dry-run, $hits is returned
        unchanged so a follow-up real apply still has its targets.
    #>
    param([object]$cfg, [bool]$DryRun, [object[]]$hits)
    if (-not $hits -or $hits.Count -eq 0) { Write-Host (Warn 'Run a scan first.'); return $hits }
    $label = if ($DryRun) { 'DRY-RUN' } else { 'APPLY' }
    if (-not $DryRun) {
        $confirm = Read-Host (Warn "Apply cleanup to $($hits.Count) files? Backups will be written as *.bak. (y/N)")
        if ($confirm -notmatch '^(?i:y|yes)$') { Write-Host (Dim 'Cancelled.'); return $hits }
    }
    $results = foreach ($h in $hits) {
        if ($DryRun) { Clean-One -Path $h.Path -cfg $cfg -DryRun }
        else        { Clean-One -Path $h.Path -cfg $cfg }
    }
    $results | Format-Table -AutoSize Removed, Status, Path | Out-Host
    $sum = ($results | Measure-Object -Property Removed -Sum).Sum
    $failed = ($results | Where-Object Status -eq 'FAILED').Count
    Write-Host (Good "$label complete. Total artifacts: $sum. Failed: $failed.")
    if ($DryRun) { return $hits } else { return @() }   # after apply, hits are stale
}

function Action-ListBackups {
    <#
    .SYNOPSIS
        Print a table of every .bak file under Root.
    #>
    param([object]$cfg)
    $baks = Get-Backups $cfg
    if (-not $baks -or $baks.Count -eq 0) { Write-Host (Good 'No .bak files.'); return @() }
    Write-Host (Hdr "Found $($baks.Count) .bak file(s):")
    $baks | Format-Table -AutoSize Length, LastWriteTime, FullName | Out-Host
    return $baks
}

function Action-Restore {
    <#
    .SYNOPSIS
        Copy every .bak file back over its original. Backups are NOT deleted
        afterwards — use Action-DeleteBackups (menu 8) to remove them.
    #>
    param([object]$cfg)
    $baks = Get-Backups $cfg
    if (-not $baks -or $baks.Count -eq 0) { Write-Host (Warn 'No backups to restore.'); return }
    $confirm = Read-Host (Warn "Restore $($baks.Count) file(s) from .bak (overwrites current)? (y/N)")
    if ($confirm -notmatch '^(?i:y|yes)$') { Write-Host (Dim 'Cancelled.'); return }
    $restored = 0
    foreach ($b in $baks) {
        $orig = $b.FullName -replace '\.bak$',''
        try {
            Copy-Item -LiteralPath $b.FullName -Destination $orig -Force
            $restored++
        } catch {
            Write-Host (Bad "Failed: $($b.FullName) -> $($_.Exception.Message)")
        }
    }
    Write-Host (Good "Restored $restored / $($baks.Count) file(s). (.bak kept; use option 8 to delete.)")
}

function Action-DeleteBackups {
    <#
    .SYNOPSIS
        Permanently remove every .bak file under Root. Destructive — there
        is no second-stage trash; the caller must confirm at the prompt.
    #>
    param([object]$cfg)
    $baks = Get-Backups $cfg
    if (-not $baks -or $baks.Count -eq 0) { Write-Host (Good 'No .bak files to delete.'); return }
    $confirm = Read-Host (Warn "Delete $($baks.Count) .bak file(s) permanently? (y/N)")
    if ($confirm -notmatch '^(?i:y|yes)$') { Write-Host (Dim 'Cancelled.'); return }
    $deleted = 0
    foreach ($b in $baks) {
        try { Remove-Item -LiteralPath $b.FullName -Force; $deleted++ }
        catch { Write-Host (Bad "Failed: $($b.FullName) -> $($_.Exception.Message)") }
    }
    Write-Host (Good "Deleted $deleted / $($baks.Count) .bak file(s).")
}

function Action-Help {
    <#
    .SYNOPSIS
        Print a short explanation of every action. Mirrors the menu order.
    #>
    Write-Host (Hdr 'How it works')
    Write-Host (@'
  Scan       : recursively walks Root, opens every Include-matching file,
               counts regex Pattern occurrences. Excludes ExcludeDirs.
  Preview    : shows up to 20 matching lines from one selected file with
               the matched substring highlighted.
  Dry-run    : reports what would be removed; does not write.
  Clean      : creates *.bak next to each modified file, removes matches
               (and leading whitespace if StripLeading is on), trims
               trailing whitespace on touched lines if TrimEol is on,
               then re-counts to confirm. UTF-8, no added trailing newline.
  Restore    : copies every *.bak under Root back over its original.
  Delete .bak: permanently removes every *.bak found under Root.

  Config persists to: 
'@)
    Write-Host ('  ' + $ConfigPath)
}

# ---------- Main loop ----------
# State:
#   $cfg  - the active config (loaded from disk or defaults)
#   $hits - cached scan result; populated by menu 2, consumed by 3/4/5
#           and invalidated to @() after a successful apply.
$cfg = Load-Config
$hits = @()

# IMPORTANT: 'break' inside a switch only exits the switch. The :menu label
# lets the 'q' branch use 'break menu' to actually exit the while loop.
:menu while ($true) {
    Print-Header $cfg
    Write-Host (Hdr 'Menu:')
    Write-Host '  [1] Configure'
    Write-Host '  [2] Scan'
    Write-Host '  [3] Preview a file (after scan)'
    Write-Host '  [4] Dry-run clean (after scan)'
    Write-Host '  [5] Apply clean (writes .bak)'
    Write-Host '  [6] List .bak backups'
    Write-Host '  [7] Restore from .bak'
    Write-Host '  [8] Delete .bak backups'
    Write-Host '  [9] Save config'
    Write-Host '  [h] Help'
    Write-Host '  [q] Quit'
    Write-Host ''
    if ($hits.Count -gt 0) {
        Write-Host (Dim "(scan cache: $($hits.Count) files with matches)")
    }
    $choice = Read-Host 'Choose'
    switch -Regex ($choice) {
        '^1$' { Action-Configure ([ref]$cfg); Pause-Any }
        '^2$' { $hits = Action-Scan $cfg;     Pause-Any }
        '^3$' { Action-Preview $cfg $hits;     Pause-Any }
        '^4$' { $hits = Action-Clean $cfg $true  $hits; Pause-Any }
        '^5$' { $hits = Action-Clean $cfg $false $hits; Pause-Any }
        '^6$' { Action-ListBackups $cfg | Out-Null; Pause-Any }
        '^7$' { Action-Restore $cfg;           Pause-Any }
        '^8$' { Action-DeleteBackups $cfg;     Pause-Any }
        '^9$' { Save-Config $cfg;              Pause-Any }
        '^(?i:h)$' { Action-Help;              Pause-Any }
        '^(?i:q)$' { Write-Host (Good 'Bye.'); break menu }
        default { Write-Host (Warn 'Unknown choice.'); Start-Sleep -Milliseconds 500 }
    }
}
