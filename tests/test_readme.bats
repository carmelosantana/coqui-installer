#!/usr/bin/env bats

setup() { README="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/README.md"; }

@test "README has no Windows/PowerShell/WSL references" {
    run grep -iE 'powershell|\.ps1|wsl|winget|irm .*iex' "$README"
    [ "$status" -ne 0 ]
}

@test "README documents the docker compose primary path" {
    grep -q 'docker compose up' "$README"
    grep -q 'ghcr.io/carmelosantana/coqui' "$README"
    grep -q 'localhost:8080' "$README"
}

@test "README documents the native fallback and --native" {
    grep -qi 'fallback' "$README"
    grep -q -- '--native' "$README"
}
