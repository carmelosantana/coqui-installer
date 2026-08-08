#!/usr/bin/env bats

# Guards the clean-cut removal of all PowerShell / Windows-native artifacts.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "no PowerShell scripts remain anywhere in the repo" {
    run bash -c "find '$REPO_ROOT' -name '*.ps1' -not -path '*/.git/*' | head -20"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "no PSScriptAnalyzer settings remain" {
    [ ! -f "$REPO_ROOT/.github/PSScriptAnalyzerSettings.psd1" ]
}

@test "Windows-native deprecation docs are gone" {
    [ ! -f "$REPO_ROOT/docs/NATIVE-WINDOWS-DEPRECATED.md" ]
    [ ! -f "$REPO_ROOT/tests/WINDOWS-SMOKE-CHECKLIST.md" ]
}

@test "CI workflow has no PowerShell jobs" {
    # Match only genuine PowerShell indicators. A plain 'powershell' grep would
    # match the CI line that runs tests/test_no_powershell.bats (the filename
    # contains "power"+"shell"), so key off real PS tooling/step markers instead.
    run grep -iE 'pwsh|pester|psscriptanalyzer|lint-powershell|test-windows|shell: *pwsh|Invoke-Pester' "$REPO_ROOT/.github/workflows/test-installer.yml"
    [ "$status" -ne 0 ]
}
