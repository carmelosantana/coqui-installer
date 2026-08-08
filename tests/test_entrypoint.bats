#!/usr/bin/env bats

# Tests only the scaffold logic of entrypoint.sh (not the exec into supervisord).
# We drive it with COQUI_ENTRYPOINT_NO_EXEC=1 so it returns instead of exec'ing.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$ROOT/docker/entrypoint.sh"
    export COQUI_CONFIG_DIR="$(mktemp -d)/config"
    export COQUI_DATA_DIR="$(mktemp -d)/data"
    export COQUI_DEFAULT_CONFIG="$ROOT/docker/openclaw.default.json"
    export COQUI_ENTRYPOINT_NO_EXEC=1
}
teardown() { rm -rf "$COQUI_CONFIG_DIR" "$COQUI_DATA_DIR"; }

@test "scaffolds openclaw.json on first run" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$COQUI_CONFIG_DIR/openclaw.json" ]
    grep -q '"primary"' "$COQUI_CONFIG_DIR/openclaw.json"
}

@test "creates the workspace data dir" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -d "$COQUI_DATA_DIR/workspace/data" ]
}

@test "does not overwrite an existing config" {
    mkdir -p "$COQUI_CONFIG_DIR"
    echo '{"agents":{"defaults":{"model":{"primary":"custom/model"}}}}' > "$COQUI_CONFIG_DIR/openclaw.json"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q 'custom/model' "$COQUI_CONFIG_DIR/openclaw.json"
}
