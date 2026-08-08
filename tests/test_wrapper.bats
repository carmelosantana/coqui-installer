#!/usr/bin/env bats

# Drives coqui.wrapper.sh with a fake `docker` on PATH that records its args.
setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WRAPPER="$ROOT/coqui.wrapper.sh"
    STUB="$(mktemp -d)"
    export COQUI_HOME="$(mktemp -d)"
    echo "services: {coqui: {image: x}}" > "$COQUI_HOME/compose.yaml"
    cat > "$STUB/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$RECORD"
exit 0
EOF
    chmod +x "$STUB/docker"
    export RECORD="$STUB/record.txt"
    export PATH="$STUB:$PATH"
}
teardown() { rm -rf "$STUB" "$COQUI_HOME"; }

@test "coqui up runs compose up -d" {
    run bash "$WRAPPER" up
    [ "$status" -eq 0 ]
    grep -q 'compose .* up -d' "$RECORD"
}

@test "coqui stop runs compose stop" {
    run bash "$WRAPPER" stop
    grep -q 'compose .* stop' "$RECORD"
}

@test "coqui status runs compose ps" {
    run bash "$WRAPPER" status
    grep -q 'compose .* ps' "$RECORD"
}

@test "coqui update pulls then ups" {
    run bash "$WRAPPER" update
    grep -q 'compose .* pull' "$RECORD"
    grep -q 'compose .* up -d' "$RECORD"
}

@test "coqui logs runs compose logs" {
    run bash "$WRAPPER" logs
    grep -q 'compose .* logs' "$RECORD"
}
