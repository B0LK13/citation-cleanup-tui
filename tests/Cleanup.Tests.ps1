#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
Pester 5 suite for citation-cleanup-tui.

Run from the repo root:

    Invoke-Pester ./tests

The suite dot-sources citation-cleanup-tui.ps1 with $env:CCTUI_TEST set so
only function/constant definitions are evaluated (the interactive menu is
guarded out). All filesystem fixtures live in unique temp directories and
are torn down in AfterAll/AfterEach.
#>

BeforeAll {
    # Skip the interactive menu when the script is dot-sourced.
    $env:CCTUI_TEST = '1'

    # Path to the script under test, relative to this test file.
    $script:ScriptUnderTest = Join-Path $PSScriptRoot '..\citation-cleanup-tui.ps1'

    # Dot-source so we get all function definitions in the test scope.
    . $script:ScriptUnderTest
}

AfterAll {
    Remove-Item Env:\CCTUI_TEST -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
Describe 'Build-LeadingPattern' {
    It 'prefixes pattern with "[ \t]*" when StripLeading is true' {
        $cfg = [pscustomobject]@{ Pattern = 'X'; StripLeading = $true }
        Build-LeadingPattern $cfg | Should -Be '[ \t]*X'
    }
    It 'returns the bare pattern when StripLeading is false' {
        $cfg = [pscustomobject]@{ Pattern = 'X'; StripLeading = $false }
        Build-LeadingPattern $cfg | Should -Be 'X'
    }
}

# ---------------------------------------------------------------------------
Describe 'Clean-One' {
    BeforeAll {
        $script:CleanCfg = [pscustomobject]@{
            Pattern      = ':contentReference\[oaicite:\d+\]\{index=\d+\}'
            StripLeading = $true
            TrimEol      = $true
        }
    }
    BeforeEach {
        $script:TmpDir  = Join-Path ([System.IO.Path]::GetTempPath()) ('cctui-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
        $script:TmpFile = Join-Path $script:TmpDir 'sample.md'
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:TmpDir) {
            Remove-Item -LiteralPath $script:TmpDir -Recurse -Force
        }
    }

    It 'removes every match, writes a backup, and reports CLEAN' {
        $content = "hi :contentReference[oaicite:0]{index=0}`r`n" +
                   "two :contentReference[oaicite:1]{index=1} :contentReference[oaicite:2]{index=2}`r`n"
        Set-Content -LiteralPath $script:TmpFile -Value $content -Encoding UTF8 -NoNewline

        $result = Clean-One -Path $script:TmpFile -cfg $script:CleanCfg

        $result.Status                              | Should -Be 'CLEAN'
        $result.Removed                             | Should -Be 3
        Test-Path -LiteralPath "$($script:TmpFile).bak"   | Should -BeTrue
        $remaining = ([regex]$script:CleanCfg.Pattern).Matches((Get-Content -LiteralPath $script:TmpFile -Raw)).Count
        $remaining                                  | Should -Be 0
    }

    It 'reports SKIP and does not create a backup when there are no matches' {
        Set-Content -LiteralPath $script:TmpFile -Value 'no artifacts here' -Encoding UTF8 -NoNewline

        $result = Clean-One -Path $script:TmpFile -cfg $script:CleanCfg

        $result.Status   | Should -Be 'SKIP'
        $result.Removed  | Should -Be 0
        Test-Path -LiteralPath "$($script:TmpFile).bak" | Should -BeFalse
    }

    It 'does not write the file or create .bak in dry-run' {
        $original = 'x :contentReference[oaicite:0]{index=0} y'
        Set-Content -LiteralPath $script:TmpFile -Value $original -Encoding UTF8 -NoNewline

        $result = Clean-One -Path $script:TmpFile -cfg $script:CleanCfg -DryRun

        $result.Status   | Should -Be 'DRY'
        $result.Removed  | Should -Be 1
        Test-Path -LiteralPath "$($script:TmpFile).bak"   | Should -BeFalse
        (Get-Content -LiteralPath $script:TmpFile -Raw) | Should -Be $original
    }

    It 'consumes preceding whitespace when StripLeading is true' {
        Set-Content -LiteralPath $script:TmpFile -Value 'before    :contentReference[oaicite:0]{index=0}' -Encoding UTF8 -NoNewline

        Clean-One -Path $script:TmpFile -cfg $script:CleanCfg | Out-Null

        (Get-Content -LiteralPath $script:TmpFile -Raw) | Should -Be 'before'
    }

    It 'trims trailing whitespace on touched lines when TrimEol is true' {
        # Two lines: first ends with several spaces after the artifact; second is clean.
        # After Pass 1 (StripLeading), the artifact + leading space are removed but
        # any trailing whitespace already on the line is also gone in this case.
        # Use a case where ONLY pass 2 matters: artifact in middle, trailing spaces after.
        $content = "alpha :contentReference[oaicite:0]{index=0}   trailing   `r`nbeta`r`n"
        Set-Content -LiteralPath $script:TmpFile -Value $content -Encoding UTF8 -NoNewline

        Clean-One -Path $script:TmpFile -cfg $script:CleanCfg | Out-Null

        $disk = Get-Content -LiteralPath $script:TmpFile -Raw
        # No line should end with whitespace before its newline.
        ($disk -match '[ \t]+\r?\n') | Should -BeFalse
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-TargetFiles' {
    BeforeAll {
        $script:TfRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cctui-tf-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:TfRoot 'good')                | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:TfRoot 'node_modules\nested') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:TfRoot 'good\a.md')              -Value 'a' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:TfRoot 'node_modules\nested\b.md') -Value 'b' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:TfRoot 'good\c.txt')             -Value 'c' -Encoding UTF8
        $script:TfCfg = [pscustomobject]@{
            Root        = $script:TfRoot
            Include     = '*.md'
            ExcludeDirs = @('node_modules')
        }
    }
    AfterAll {
        if ($script:TfRoot -and (Test-Path -LiteralPath $script:TfRoot)) {
            Remove-Item -LiteralPath $script:TfRoot -Recurse -Force
        }
    }

    It 'matches the Include glob and skips files inside ExcludeDirs' {
        $names = Get-TargetFiles $script:TfCfg | ForEach-Object Name
        $names | Should -Contain 'a.md'
        $names | Should -Not -Contain 'b.md'  # under node_modules
        $names | Should -Not -Contain 'c.txt' # not *.md
    }

    It 'returns an empty array when Root does not exist' {
        $bad = [pscustomobject]@{ Root = (Join-Path ([System.IO.Path]::GetTempPath()) ('cctui-nope-' + [guid]::NewGuid().ToString('N'))); Include = '*.md'; ExcludeDirs = @() }
        @(Get-TargetFiles $bad).Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
Describe 'Scan-Files' {
    BeforeAll {
        $script:SfRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cctui-sf-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:SfRoot | Out-Null
        $hitContent = "one :contentReference[oaicite:0]{index=0}`r`n" +
                      "two :contentReference[oaicite:1]{index=1} :contentReference[oaicite:2]{index=2}`r`n"
        Set-Content -LiteralPath (Join-Path $script:SfRoot 'a.md')     -Value $hitContent -Encoding UTF8 -NoNewline
        Set-Content -LiteralPath (Join-Path $script:SfRoot 'clean.md') -Value 'no matches' -Encoding UTF8 -NoNewline
        $script:SfCfg = [pscustomobject]@{
            Root        = $script:SfRoot
            Include     = '*.md'
            Pattern     = ':contentReference\[oaicite:\d+\]\{index=\d+\}'
            ExcludeDirs = @()
        }
    }
    AfterAll {
        if ($script:SfRoot -and (Test-Path -LiteralPath $script:SfRoot)) {
            Remove-Item -LiteralPath $script:SfRoot -Recurse -Force
        }
    }

    It 'returns one entry per file with matches and skips clean files' {
        $hits = Scan-Files $script:SfCfg
        @($hits).Count       | Should -Be 1
        $hits[0].Path        | Should -BeLike '*a.md'
        $hits[0].Matches     | Should -Be 3
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-Backups' {
    BeforeAll {
        $script:GbRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cctui-gb-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:GbRoot 'sub')  | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:GbRoot '.git') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:GbRoot 'sub\a.md.bak')  -Value 'old' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:GbRoot '.git\b.md.bak') -Value 'old' -Encoding UTF8
        $script:GbCfg = [pscustomobject]@{
            Root        = $script:GbRoot
            ExcludeDirs = @('.git')
        }
    }
    AfterAll {
        if ($script:GbRoot -and (Test-Path -LiteralPath $script:GbRoot)) {
            Remove-Item -LiteralPath $script:GbRoot -Recurse -Force
        }
    }

    It 'finds .bak files under Root and respects ExcludeDirs' {
        $baks = Get-Backups $script:GbCfg
        @($baks).Count | Should -Be 1
        $baks[0].Name  | Should -Be 'a.md.bak'
    }
}

# ---------------------------------------------------------------------------
Describe 'Config persistence (Save-Config / Load-Config)' {
    BeforeAll {
        # Use the explicit -Path parameter on Save-Config / Load-Config so the
        # user's real config (next to the production script) is never touched.
        $script:TmpCfgPath = Join-Path ([System.IO.Path]::GetTempPath()) ('cctui-cfg-' + [guid]::NewGuid().ToString('N') + '.json')
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:TmpCfgPath) {
            Remove-Item -LiteralPath $script:TmpCfgPath -Force
        }
    }
    AfterEach {
        # Reset between Its so a stale file from one test doesn't leak into the next.
        if (Test-Path -LiteralPath $script:TmpCfgPath) {
            Remove-Item -LiteralPath $script:TmpCfgPath -Force
        }
    }

    It 'roundtrips: Save-Config followed by Load-Config preserves values' {
        $cfg = [pscustomobject]@{
            Root         = 'C:\X'
            Include      = '*.md'
            Pattern      = 'foo'
            StripLeading = $false
            TrimEol      = $true
            ExcludeDirs  = @('a','b')
        }
        Save-Config -cfg $cfg -Path $script:TmpCfgPath | Out-Null
        $back = Load-Config -Path $script:TmpCfgPath

        $back.Root            | Should -Be 'C:\X'
        $back.Include         | Should -Be '*.md'
        $back.Pattern         | Should -Be 'foo'
        $back.StripLeading    | Should -Be $false
        $back.TrimEol         | Should -Be $true
        $back.ExcludeDirs.Count | Should -Be 2
        $back.ExcludeDirs[0]  | Should -Be 'a'
        $back.ExcludeDirs[1]  | Should -Be 'b'
    }

    It 'falls back to script defaults for keys missing from the saved JSON' {
        '{ "Root": "C:\\Y" }' | Set-Content -LiteralPath $script:TmpCfgPath -Encoding UTF8

        $back = Load-Config -Path $script:TmpCfgPath

        $back.Root         | Should -Be 'C:\Y'
        $back.Include      | Should -Be '*.md'   # default
        $back.StripLeading | Should -Be $true    # default
        $back.TrimEol      | Should -Be $true    # default
    }
}
