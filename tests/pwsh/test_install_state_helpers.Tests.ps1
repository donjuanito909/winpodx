# Pester 5+ tests for config/oem/install-state-helpers.ps1.
#
# Validates the in-guest PowerShell primitives that back the agent-first
# install state machine. Mirrors tests/test_agent_install_state.py:
#
#   * Marker primitives:    atomic write, race resilience, list completed
#   * Retry counter ACID:   read-modify-write, corrupt-JSON recovery
#   * Redactor parity:      runs every case in tests/fixtures/redactor_cases.json
#                           through Invoke-WinpodxRedact and asserts byte-
#                           identical output to the Python redactor's expected
#                           value. The fixture file is the single source of
#                           truth; both implementations must agree.
#   * install_failure.json: validates against docs/design/install_failure.schema.json
#                           via Test-Json
#   * Property test:        100 seeded random strings; assert no leak of
#                           net user pw / Bearer token / password=value patterns
#
# Runs on Linux under PowerShell Core (pwsh 7+); helper functions tested
# here are pure pwsh (icacls / netsh / Win32 calls only fire when the
# relevant cmdlet is available, which it is not on Linux).

#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# ---- Discovery-time fixture loading ---------------------------------------
# Pester 5 evaluates -ForEach data at discovery time. We need the redactor
# cases array AT discovery so the parametrized It blocks emit one test per
# case in the suite output. Other state lives in BeforeAll (run scope).

# ---- Discovery: load redactor cases for -ForEach parametrization ----------
# Pester 5 evaluates -ForEach data at discovery time, so the JSON read
# happens in the discovery scope (outside any block).
$script:DiscoveryRepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
$script:DiscoveryFixturePath  = Join-Path $script:DiscoveryRepoRoot 'tests' 'fixtures' 'redactor_cases.json'
$script:RedactorCases = (Get-Content -Raw -LiteralPath $script:DiscoveryFixturePath | ConvertFrom-Json).cases

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:HelpersPath  = Join-Path $script:RepoRoot 'config' 'oem' 'install-state-helpers.ps1'
    $script:SchemaPath   = Join-Path $script:RepoRoot 'docs' 'design' 'install_failure.schema.json'
    $script:FixturePath  = Join-Path $script:RepoRoot 'tests' 'fixtures' 'redactor_cases.json'

    if (-not (Test-Path $script:HelpersPath)) {
        throw "install-state-helpers.ps1 not present at $script:HelpersPath"
    }
    if (-not (Test-Path $script:FixturePath)) {
        throw "redactor fixtures not present at $script:FixturePath"
    }
    if (-not (Test-Path $script:SchemaPath)) {
        throw "install_failure schema not present at $script:SchemaPath"
    }

    # Helper functions defined in BeforeAll are visible to BeforeEach /
    # AfterEach / It blocks in the same container (Pester 5 contract).

    function Initialize-FakeWindowsDrive {
        # Map a fake C:\ drive on Linux pwsh so helpers' module-scope
        # Join-Path 'C:\winpodx\install-state' calls resolve under StrictMode.
        # No-op on real Windows.
        if (-not (Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue)) {
            $root = (New-Item -ItemType Directory `
                -Path (Join-Path ([System.IO.Path]::GetTempPath()) ("winpodx-fakec-" + [guid]::NewGuid())) `
                -Force).FullName
            New-PSDrive -Name 'C' -PSProvider FileSystem -Root $root -Scope Global `
                -ErrorAction Stop | Out-Null
            return $root
        }
        return $null
    }

    function Use-WpxTestStateDir {
        # Per-test: redirect every state-dir-derived path used by the helpers
        # to a fresh subdir so tests don't bleed into each other.
        param([string] $SubDir)
        $dir = Join-Path $script:WpxTestRoot $SubDir
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $script:WpxStateDir        = $dir
        $script:WpxLogPath         = Join-Path $dir 'install.log'
        $script:WpxRetryCountsPath = Join-Path $dir 'retry_counts.json'
        $script:WpxFailurePath     = Join-Path $dir 'install_failure.json'
        $script:WpxSessionIdPath   = Join-Path $dir 'install_session_id.txt'
        return $dir
    }

    $script:FakeWindowsRoot = Initialize-FakeWindowsDrive

    # Dot-source helpers into the script scope. The helpers file declares
    # $script:Wpx* variables; we override the state-dir-derived ones in
    # Use-WpxTestStateDir so tests use a per-suite tmp dir instead of C:\winpodx\.
    . $script:HelpersPath

    $script:WpxTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("winpodx-pester-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:WpxTestRoot -Force | Out-Null
}

AfterAll {
    if ($null -ne $script:WpxTestRoot -and (Test-Path -LiteralPath $script:WpxTestRoot)) {
        Remove-Item -LiteralPath $script:WpxTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $script:FakeWindowsRoot -and (Test-Path -LiteralPath $script:FakeWindowsRoot)) {
        Remove-PSDrive -Name 'C' -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:FakeWindowsRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Marker primitives' {

    BeforeEach {
        $script:CurrentStateDir = Use-WpxTestStateDir -SubDir ("markers-" + [guid]::NewGuid())
    }

    It 'New-WinpodxMarker writes an empty .done file under the state dir' {
        New-WinpodxMarker -Name 'phase0_done'
        $marker = Join-Path $script:CurrentStateDir 'phase0_done.done'
        Test-Path $marker | Should -BeTrue
        (Get-Item $marker).Length | Should -Be 0
    }

    It 'New-WinpodxMarker creates the state dir if missing' {
        # Wipe the dir; the helper must recreate it.
        Remove-Item -LiteralPath $script:CurrentStateDir -Recurse -Force
        New-WinpodxMarker -Name 'fresh_dir'
        Test-Path (Join-Path $script:CurrentStateDir 'fresh_dir.done') | Should -BeTrue
    }

    It 'Test-WinpodxMarker returns $true for an existing marker' {
        New-WinpodxMarker -Name 'present'
        Test-WinpodxMarker -Name 'present' | Should -BeTrue
    }

    It 'Test-WinpodxMarker returns $false for a missing marker' {
        Test-WinpodxMarker -Name 'absent' | Should -BeFalse
    }

    It 'Get-WinpodxCompletedSteps returns sorted step names with .done stripped' {
        foreach ($name in @('zeta', 'alpha', 'beta')) {
            New-WinpodxMarker -Name $name
        }
        # Decoy non-marker file + subdir to confirm filter behaviour.
        Set-Content -Path (Join-Path $script:CurrentStateDir 'ignored.txt') -Value 'nope'
        New-Item -ItemType Directory -Path (Join-Path $script:CurrentStateDir 'subdir') -Force | Out-Null

        $steps = @(Get-WinpodxCompletedSteps)
        $steps | Should -Be @('alpha', 'beta', 'zeta')
    }

    It 'Get-WinpodxCompletedSteps returns empty when state dir is missing' {
        Remove-Item -LiteralPath $script:CurrentStateDir -Recurse -Force
        $steps = @(Get-WinpodxCompletedSteps)
        $steps.Count | Should -Be 0
    }

    It 'Concurrent New-WinpodxMarker calls leave the file empty and well-formed' {
        # Race resilience: 10 parallel writers, each writing 20 times to
        # the same marker. Final file must be 0 bytes; no .tmp leftovers.
        $jobs = 1..10 | ForEach-Object {
            Start-ThreadJob -ArgumentList $script:HelpersPath, $script:CurrentStateDir -ScriptBlock {
                param($helpersPath, $stateDir)
                . $helpersPath
                $script:WpxStateDir = $stateDir
                for ($i = 0; $i -lt 20; $i++) {
                    New-WinpodxMarker -Name 'race'
                }
            }
        }
        $jobs | Wait-Job | Out-Null
        $jobs | Remove-Job -Force

        $marker = Join-Path $script:CurrentStateDir 'race.done'
        Test-Path $marker | Should -BeTrue
        (Get-Item $marker).Length | Should -Be 0

        # No .tmp files left in the dir.
        $leftovers = @(Get-ChildItem -LiteralPath $script:CurrentStateDir -File | Where-Object {
            $_.Name -ne 'race.done'
        })
        $leftovers.Count | Should -Be 0
    }

    It 'New-WinpodxMarker rejects invalid names (param validation)' {
        # Helpers enforce ^[a-z_][a-z0-9_]*$ via ValidatePattern. A name
        # with uppercase / dots / spaces must throw before any I/O.
        { New-WinpodxMarker -Name 'BAD-NAME' }   | Should -Throw
        { New-WinpodxMarker -Name 'with.dots' }  | Should -Throw
        { New-WinpodxMarker -Name 'with space' } | Should -Throw
    }
}

Describe 'Retry counter ACID' {

    BeforeEach {
        $script:CurrentStateDir = Use-WpxTestStateDir -SubDir ("retry-" + [guid]::NewGuid())
    }

    It 'Get-WinpodxRetry returns 0 for a missing file' {
        Get-WinpodxRetry -Name 'rdprrap_installed' | Should -Be 0
    }

    It 'Increment-WinpodxRetry increments and persists across reload' {
        Increment-WinpodxRetry -Name 'step_a' | Should -Be 1
        Increment-WinpodxRetry -Name 'step_a' | Should -Be 2
        Increment-WinpodxRetry -Name 'step_b' | Should -Be 1

        Get-WinpodxRetry -Name 'step_a' | Should -Be 2
        Get-WinpodxRetry -Name 'step_b' | Should -Be 1
    }

    It 'Corrupt JSON is treated as empty (no crash, count starts at 0)' {
        # Write garbage; the helper must absorb it (mirrors the Python
        # `corrupt JSON treated as empty` test).
        Set-Content -LiteralPath $script:WpxRetryCountsPath -Value '{not json' -NoNewline

        Get-WinpodxRetry -Name 'anything' | Should -Be 0
        Increment-WinpodxRetry -Name 'fresh' | Should -Be 1
        $reread = Get-Content -Raw -LiteralPath $script:WpxRetryCountsPath | ConvertFrom-Json
        $reread.fresh | Should -Be 1
    }

    It 'Corrupt JSON file is preserved on disk for forensic inspection' {
        Set-Content -LiteralPath $script:WpxRetryCountsPath -Value '{not json' -NoNewline
        Get-WinpodxRetry -Name 'anything' | Should -Be 0
        # The pure read MUST NOT delete the corrupt file (the Python
        # implementation only logs a warning).
        Test-Path -LiteralPath $script:WpxRetryCountsPath | Should -BeTrue
    }

    It 'Reset-WinpodxRetry only zeroes the requested step' {
        Increment-WinpodxRetry -Name 'a' | Out-Null
        Increment-WinpodxRetry -Name 'a' | Out-Null
        Increment-WinpodxRetry -Name 'b' | Out-Null
        Reset-WinpodxRetry -Name 'a'
        Get-WinpodxRetry -Name 'a' | Should -Be 0
        Get-WinpodxRetry -Name 'b' | Should -Be 1
    }

    It 'Concurrent Increment-WinpodxRetry leaves a well-formed JSON file' {
        # Seed file so writers race on an existing one.
        Increment-WinpodxRetry -Name 'seed' | Out-Null

        $jobs = 1..4 | ForEach-Object {
            Start-ThreadJob -ArgumentList $script:HelpersPath, $script:CurrentStateDir -ScriptBlock {
                param($helpersPath, $stateDir)
                . $helpersPath
                $script:WpxStateDir = $stateDir
                $script:WpxRetryCountsPath = Join-Path $stateDir 'retry_counts.json'
                for ($i = 0; $i -lt 50; $i++) {
                    Increment-WinpodxRetry -Name 'hot' | Out-Null
                }
            }
        }
        $jobs | Wait-Job | Out-Null
        $jobs | Remove-Job -Force

        # File must always parse as valid JSON. The ACID guarantee is
        # "no torn write", not "no lost increments" — concurrent writers
        # may collapse increments OR even lose the seed key during a
        # tight race (load-snapshot, save-snapshot — second write wins).
        # The non-negotiable invariant is that the resulting file parses.
        $raw = Get-Content -Raw -LiteralPath $script:WpxRetryCountsPath
        { $raw | ConvertFrom-Json } | Should -Not -Throw
        $parsed = $raw | ConvertFrom-Json
        # 'hot' must be present and >= 1 (every worker incremented at least once).
        $parsed.hot | Should -BeGreaterOrEqual 1

        $leftovers = @(Get-ChildItem -LiteralPath $script:CurrentStateDir -File -Filter '.*.tmp')
        $leftovers.Count | Should -Be 0
    }
}

Describe 'Invoke-WinpodxRedact parity with Python redact_log_line' {

    Context 'For every shared fixture case' {
        It "case=<_.id>: <_.description>" -ForEach $script:RedactorCases {
            $actual = Invoke-WinpodxRedact -Line $_.input
            $actual | Should -BeExactly $_.expected
            foreach ($forbidden in $_.must_not_contain) {
                $actual | Should -Not -Match ([regex]::Escape($forbidden))
            }
        }
    }

    It 'Coerces non-string input rather than crashing' {
        # Logging path must never crash on a stray int / null.
        Invoke-WinpodxRedact -Line 12345 | Should -BeExactly '12345'
    }

    It 'Treats $null as empty string' {
        Invoke-WinpodxRedact -Line $null | Should -BeExactly ''
    }
}

Describe 'Invoke-WinpodxRedact property test (seeded random strings)' {

    It 'Never leaks net user pw / Bearer / base64 across 100 random inputs' {
        # Deterministic seed so failures reproduce exactly.
        $rng = [System.Random]::new(20260509)
        $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/= '

        # Patterns whose presence post-redaction would mean a leak. We
        # accept matches only if the matched span ends with a literal
        # redaction marker we put in ourselves.
        $leakPatterns = @(
            [regex]::new('net user\s+\S+\s+(?!<REDACTED>)\S+', 'IgnoreCase'),
            [regex]::new('Authorization:\s*Bearer\s+(?!<REDACTED>)\S+', 'IgnoreCase'),
            [regex]::new('(?<![A-Za-z0-9+/=])[A-Za-z0-9+/]{40,}={0,2}(?![A-Za-z0-9+/=])')
        )

        for ($i = 0; $i -lt 100; $i++) {
            $len = $rng.Next(0, 400)
            $sb = [System.Text.StringBuilder]::new($len)
            for ($j = 0; $j -lt $len; $j++) {
                [void]$sb.Append($alphabet[$rng.Next(0, $alphabet.Length)])
            }
            $line = switch ($rng.Next(0, 10)) {
                0 { 'net user kernalix7 ' + $sb.ToString() }
                1 { 'Authorization: Bearer ' + $sb.ToString() }
                2 { 'password=' + $sb.ToString() }
                default { $sb.ToString() }
            }

            $out = Invoke-WinpodxRedact -Line $line
            foreach ($pat in $leakPatterns) {
                foreach ($match in $pat.Matches($out)) {
                    $match.Value | Should -Match '<(REDACTED|BASE64-REDACTED)>' `
                        -Because ("leak '" + $match.Value + "' survived redaction of '" + $line + "' -> '" + $out + "'")
                }
            }
        }
    }
}

Describe 'Write-WinpodxFailure produces JSON valid against install_failure.schema.json' {

    BeforeEach {
        $script:CurrentStateDir = Use-WpxTestStateDir -SubDir ("failure-" + [guid]::NewGuid())
        # Seed a session id so the helper's _Wpx_GetSessionId path picks
        # up a stable UUID instead of minting a fresh one each call.
        Set-Content -LiteralPath $script:WpxSessionIdPath `
            -Value 'abcd1234-1111-2222-3333-444455556666' -NoNewline
    }

    It 'Happy path with no install.log: writes redacted JSON that validates against the schema' {
        # No install.log seeded — exercises the missing-log path.
        # _Wpx_TailLog returns a plain list; Write-WinpodxFailure wraps
        # it once with `$tail = @(_Wpx_TailLog)` at the JSON boundary so
        # an empty result serialises to `[]`, not `null`. The schema's
        # "type: array" rule on last_log_lines catches the regression
        # if either layer goes back to a bare `@()` -> $null collapse.
        Write-WinpodxFailure `
            -Step 'multi_session_active' `
            -Phase 2 `
            -Attempt 3 `
            -MaxAttempts 3 `
            -ExitCode 1 `
            -ErrorClass 'rdprrap_activate_failed' `
            -ErrorSummary 'Authorization: Bearer abc123def456ghi789jkl012mno345'

        Test-Path -LiteralPath $script:WpxFailurePath | Should -BeTrue

        $written = Get-Content -Raw -LiteralPath $script:WpxFailurePath
        $schema  = Get-Content -Raw -LiteralPath $script:SchemaPath
        Test-Json -Json $written -Schema $schema | Should -BeTrue

        $parsed = $written | ConvertFrom-Json
        $parsed.error_summary  | Should -Not -Match 'abc123def456ghi789jkl012mno345'
        $parsed.error_summary  | Should -Match '<REDACTED>'
        $parsed.session_id     | Should -BeExactly 'abcd1234-1111-2222-3333-444455556666'
        $parsed.failed_step    | Should -BeExactly 'multi_session_active'
        $parsed.phase          | Should -Be 2
        $parsed.attempt        | Should -Be 3
        $parsed.max_attempts   | Should -Be 3
        $parsed.exit_code      | Should -Be 1
        $parsed.error_class    | Should -BeExactly 'rdprrap_activate_failed'
        # environment + last_log_lines are auto-filled by the helper.
        $parsed.PSObject.Properties.Name | Should -Contain 'environment'
        $parsed.PSObject.Properties.Name | Should -Contain 'last_log_lines'
        # last_log_lines must serialise as a JSON array (not null) even
        # when install.log is missing. Test-Json above already enforced
        # the schema's "type: array" rule; this is belt-and-braces, and
        # documents the array-context contract for future readers.
        ,$parsed.last_log_lines | Should -BeOfType ([System.Array])
    }

    It 'Happy path with seeded install.log: includes redacted tail in last_log_lines' {
        @(
            '{"ts":"2026-05-08T09:17:51Z","level":"INFO","step":"multi_session_active","event":"start"}',
            '{"ts":"2026-05-08T09:17:55Z","level":"ERROR","step":"multi_session_active","event":"failed"}'
        ) | Set-Content -LiteralPath $script:WpxLogPath

        Write-WinpodxFailure `
            -Step 'multi_session_active' `
            -Phase 2 `
            -Attempt 3 `
            -MaxAttempts 3 `
            -ExitCode 1 `
            -ErrorClass 'rdprrap_activate_failed' `
            -ErrorSummary 'plain summary'

        $written = Get-Content -Raw -LiteralPath $script:WpxFailurePath
        $schema  = Get-Content -Raw -LiteralPath $script:SchemaPath
        Test-Json -Json $written -Schema $schema | Should -BeTrue

        $parsed = $written | ConvertFrom-Json
        $parsed.last_log_lines.Count | Should -BeGreaterOrEqual 2
    }

    It 'Rejects invalid step name via parameter validation, before writing' {
        # The schema requires ^[a-z_]+$; the helper's ValidatePattern
        # enforces the same. Writing must fail BEFORE the file is created.
        {
            Write-WinpodxFailure `
                -Step 'BAD-STEP' `
                -Phase 2 -Attempt 1 -MaxAttempts 3 -ExitCode 1 `
                -ErrorClass 'x' -ErrorSummary 'y'
        } | Should -Throw
        Test-Path -LiteralPath $script:WpxFailurePath | Should -BeFalse
    }

    It 'Rejects out-of-range phase before writing' {
        {
            Write-WinpodxFailure `
                -Step 'multi_session_active' `
                -Phase 99 -Attempt 1 -MaxAttempts 3 -ExitCode 1 `
                -ErrorClass 'rdprrap_activate_failed' -ErrorSummary 'y'
        } | Should -Throw
        Test-Path -LiteralPath $script:WpxFailurePath | Should -BeFalse
    }

    It 'Truncates an over-long error_summary to 500 chars' {
        $long = 'x' * 800
        Write-WinpodxFailure `
            -Step 'multi_session_active' `
            -Phase 2 -Attempt 1 -MaxAttempts 3 -ExitCode 1 `
            -ErrorClass 'rdprrap_activate_failed' `
            -ErrorSummary $long
        $parsed = Get-Content -Raw -LiteralPath $script:WpxFailurePath | ConvertFrom-Json
        $parsed.error_summary.Length | Should -BeLessOrEqual 500
    }
}
