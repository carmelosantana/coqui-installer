#!/usr/bin/env bats
#
# Tests for uninstall.sh
# Requires bats-core: https://github.com/bats-core/bats-core

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
UNINSTALL_SCRIPT="$SCRIPT_DIR/uninstall.sh"

# ─── Argument parsing ─────────────────────────────────────────────────────────

@test "uninstall.sh --help exits 0" {
    run bash "$UNINSTALL_SCRIPT" --help
    [ "$status" -eq 0 ]
}

@test "uninstall.sh -h exits 0" {
    run bash "$UNINSTALL_SCRIPT" -h
    [ "$status" -eq 0 ]
}

@test "uninstall.sh --help outputs usage info" {
    run bash "$UNINSTALL_SCRIPT" --help
    echo "$output" | grep -q "Usage:"
}

@test "uninstall.sh --help shows all flags" {
    run bash "$UNINSTALL_SCRIPT" --help
    echo "$output" | grep -q -- "--remove-workspace"
    echo "$output" | grep -q -- "--force"
    echo "$output" | grep -q -- "--all"
}

@test "uninstall.sh unknown argument exits 1" {
    run bash "$UNINSTALL_SCRIPT" --unknown-flag-xyz
    [ "$status" -eq 1 ]
}

# ─── Not-installed guard ──────────────────────────────────────────────────────

@test "uninstall.sh exits 0 when Coqui is not installed" {
    COQUI_INSTALL_DIR="/tmp/coqui-not-installed-$$" run bash "$UNINSTALL_SCRIPT" --force
    [ "$status" -eq 0 ]
}

@test "uninstall.sh warns when Coqui is not installed" {
    COQUI_INSTALL_DIR="/tmp/coqui-not-installed-$$" run bash "$UNINSTALL_SCRIPT" --force
    echo "$output" | grep -qi "not installed"
}

# ─── Release install removal ──────────────────────────────────────────────────

@test "uninstall.sh --force removes release install directory" {
    local test_dir
    test_dir="$(mktemp -d)"
    echo "1.0.0" > "$test_dir/.coqui-version"
    touch "$test_dir/bin"

    COQUI_INSTALL_DIR="$test_dir" run bash "$UNINSTALL_SCRIPT" --force
    [ "$status" -eq 0 ]
    [ ! -d "$test_dir" ]
}

@test "uninstall.sh --force removes dev install directory" {
    local test_dir
    test_dir="$(mktemp -d)"
    mkdir -p "$test_dir/.git"

    COQUI_INSTALL_DIR="$test_dir" run bash "$UNINSTALL_SCRIPT" --force
    [ "$status" -eq 0 ]
    [ ! -d "$test_dir" ]
}

@test "uninstall.sh --force exits 0 on success" {
    local test_dir
    test_dir="$(mktemp -d)"
    echo "1.0.0" > "$test_dir/.coqui-version"

    COQUI_INSTALL_DIR="$test_dir" run bash "$UNINSTALL_SCRIPT" --force
    [ "$status" -eq 0 ]
}

# ─── Workspace preservation ───────────────────────────────────────────────────

@test "uninstall.sh preserves workspace by default" {
    local test_dir
    test_dir="$(mktemp -d)"
    echo "1.0.0" > "$test_dir/.coqui-version"
    mkdir -p "$test_dir/.workspace"
    echo "important-data" > "$test_dir/.workspace/session.json"

    COQUI_INSTALL_DIR="$test_dir" run bash "$UNINSTALL_SCRIPT" --force
    [ "$status" -eq 0 ]
    [ -f "$test_dir/.workspace/session.json" ]
    [ "$(cat "$test_dir/.workspace/session.json")" = "important-data" ]

    rm -rf "$test_dir"
}

@test "uninstall.sh --remove-workspace deletes workspace" {
    local test_dir
    test_dir="$(mktemp -d)"
    echo "1.0.0" > "$test_dir/.coqui-version"
    mkdir -p "$test_dir/.workspace"
    echo "data" > "$test_dir/.workspace/session.json"

    COQUI_INSTALL_DIR="$test_dir" run bash "$UNINSTALL_SCRIPT" --force --remove-workspace
    [ "$status" -eq 0 ]
    [ ! -d "$test_dir" ]
}

@test "uninstall.sh removes install dir files but keeps workspace dir intact" {
    local test_dir
    test_dir="$(mktemp -d)"
    echo "1.0.0" > "$test_dir/.coqui-version"
    mkdir -p "$test_dir/bin" "$test_dir/src" "$test_dir/.workspace"
    echo "coqui-binary" > "$test_dir/bin/coqui"
    echo "source-file" > "$test_dir/src/main.php"
    echo "workspace-data" > "$test_dir/.workspace/data.txt"

    COQUI_INSTALL_DIR="$test_dir" run bash "$UNINSTALL_SCRIPT" --force
    [ "$status" -eq 0 ]

    # bin and src should be gone
    [ ! -d "$test_dir/bin" ]
    [ ! -d "$test_dir/src" ]
    [ ! -f "$test_dir/.coqui-version" ]

    # workspace should remain
    [ -d "$test_dir/.workspace" ]
    [ -f "$test_dir/.workspace/data.txt" ]

    rm -rf "$test_dir"
}

# ─── Symlink removal ─────────────────────────────────────────────────────────

@test "uninstall.sh removes symlink pointing into install dir" {
    local test_dir bin_dir
    test_dir="$(mktemp -d)"
    bin_dir="$(mktemp -d)"
    echo "1.0.0" > "$test_dir/.coqui-version"
    mkdir -p "$test_dir/bin"
    touch "$test_dir/bin/coqui"

    # Create a symlink pointing into the install dir
    ln -sf "$test_dir/bin/coqui" "$bin_dir/coqui"

    # Run uninstall with the custom bin dir in PATH
    COQUI_INSTALL_DIR="$test_dir" PATH="$bin_dir:$PATH" run bash "$UNINSTALL_SCRIPT" --force

    [ "$status" -eq 0 ]

    rm -f "$bin_dir/coqui"
    rm -rf "$bin_dir" "$test_dir"
}

# ─── Quiet mode ───────────────────────────────────────────────────────────────

@test "uninstall.sh --quiet --force suppresses status output" {
    local test_dir
    test_dir="$(mktemp -d)"
    echo "1.0.0" > "$test_dir/.coqui-version"

    COQUI_INSTALL_DIR="$test_dir" run bash "$UNINSTALL_SCRIPT" --force --quiet
    [ "$status" -eq 0 ]
    # Quiet mode should only print the milestone line
    [ "$(echo "$output" | wc -l)" -le 3 ]
}

# ─── Docker stack teardown ────────────────────────────────────────────────────

@test "uninstall_docker_stack runs compose down and removes the wrapper" {
    STUB="$(mktemp -d)"
    export COQUI_INSTALL_DIR="$(mktemp -d)/home"
    mkdir -p "$COQUI_INSTALL_DIR"
    echo "services: {}" > "$COQUI_INSTALL_DIR/compose.yaml"
    export BIN_DIR="$(mktemp -d)/bin"; mkdir -p "$BIN_DIR"; touch "$BIN_DIR/coqui"; chmod +x "$BIN_DIR/coqui"
    cat > "$STUB/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$RECORD"; exit 0
EOF
    chmod +x "$STUB/docker"; export RECORD="$STUB/record.txt"
    run env PATH="$STUB:$PATH" bash -c '
      source <(awk "NR>1 { print prev } { prev=\$0 }" uninstall.sh)
      BIN_DIR="'"$BIN_DIR"'"
      FORCE_MODE=true; REMOVE_WORKSPACE=false
      uninstall_docker_stack
    '
    [ "$status" -eq 0 ]
    grep -q 'compose .* down' "$RECORD"
    [ ! -e "$BIN_DIR/coqui" ]
    rm -rf "$STUB"
}

@test "uninstall_docker_stack passes -v only with --remove-workspace" {
    STUB="$(mktemp -d)"
    export COQUI_INSTALL_DIR="$(mktemp -d)/home"; mkdir -p "$COQUI_INSTALL_DIR"
    echo "services: {}" > "$COQUI_INSTALL_DIR/compose.yaml"
    export BIN_DIR="$(mktemp -d)/bin"; mkdir -p "$BIN_DIR"
    cat > "$STUB/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$RECORD"; exit 0
EOF
    chmod +x "$STUB/docker"; export RECORD="$STUB/record.txt"
    run env PATH="$STUB:$PATH" bash -c '
      source <(awk "NR>1 { print prev } { prev=\$0 }" uninstall.sh)
      BIN_DIR="'"$BIN_DIR"'"
      FORCE_MODE=true; REMOVE_WORKSPACE=true
      uninstall_docker_stack
    '
    grep -qE 'compose .* down .*-v|compose .* down.* --volumes' "$RECORD"
    rm -rf "$STUB"
}

# ─── Installation detection ───────────────────────────────────────────────────

@test "uninstall.sh is_dev_installed detects .git directory" {
    local test_dir
    test_dir="$(mktemp -d)"
    mkdir -p "$test_dir/.git"

    run bash -c "
        COQUI_INSTALL_DIR='$test_dir'
        is_dev_installed() {
            [ -d \"\$COQUI_INSTALL_DIR\" ] && [ -d \"\$COQUI_INSTALL_DIR/.git\" ]
        }
        is_dev_installed && echo 'dev' || echo 'not-dev'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "dev" ]

    rm -rf "$test_dir"
}

@test "uninstall.sh is_release_installed detects .coqui-version file" {
    local test_dir
    test_dir="$(mktemp -d)"
    echo "0.5.0" > "$test_dir/.coqui-version"

    run bash -c "
        COQUI_INSTALL_DIR='$test_dir'
        is_release_installed() {
            [ -d \"\$COQUI_INSTALL_DIR\" ] && [ -f \"\$COQUI_INSTALL_DIR/.coqui-version\" ]
        }
        is_release_installed && echo 'release' || echo 'not-release'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "release" ]

    rm -rf "$test_dir"
}

@test "uninstall.sh get_installed_version returns version string" {
    local test_dir
    test_dir="$(mktemp -d)"
    echo "3.1.0" > "$test_dir/.coqui-version"

    run bash -c "
        COQUI_INSTALL_DIR='$test_dir'
        get_installed_version() {
            if [ -f \"\$COQUI_INSTALL_DIR/.coqui-version\" ]; then
                cat \"\$COQUI_INSTALL_DIR/.coqui-version\"
            else
                echo ''
            fi
        }
        get_installed_version
    "
    [ "$status" -eq 0 ]
    [ "$output" = "3.1.0" ]

    rm -rf "$test_dir"
}
