#!/usr/bin/env bats

# Unit tests for the server-release fetch+verify helper. Network calls are
# stubbed by putting a fake `curl` and `sha256sum` on PATH.

setup() {
    SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/docker/fetch-coqui.sh"
    STUB_DIR="$(mktemp -d)"
    DEST_DIR="$(mktemp -d)"
    export PATH="$STUB_DIR:$PATH"
    # Build a fake release tarball with the required top-level coqui/ dir.
    FIXTURE_DIR="$(mktemp -d)"
    mkdir -p "$FIXTURE_DIR/coqui/bin"
    echo '#!/bin/sh' > "$FIXTURE_DIR/coqui/bin/coqui-console"
    ( cd "$FIXTURE_DIR" && tar -czf "$STUB_DIR/coqui.tar.gz" coqui )
    REAL_HASH="$(sha256sum "$STUB_DIR/coqui.tar.gz" | awk '{print $1}')"
    export REAL_HASH
}

teardown() {
    rm -rf "$STUB_DIR" "$DEST_DIR" "$FIXTURE_DIR"
}

# Stub curl: first call (tarball) copies the fixture; second call (.sha256) echoes the hash.
_write_curl_stub() {
    cat > "$STUB_DIR/curl" <<EOF
#!/bin/sh
# args end with -o <file> for the tarball, or plain URL for the checksum
for a in "\$@"; do :; done
case "\$*" in
  *.sha256*) echo "$1  coqui-v9.9.9.tar.gz" ;;
  *-o*)
    out=""
    while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && { out="\$2"; }; shift; done
    cp "$STUB_DIR/coqui.tar.gz" "\$out" ;;
esac
EOF
    chmod +x "$STUB_DIR/curl"
}

@test "extracts server release into dest when checksum matches" {
    _write_curl_stub "$REAL_HASH"
    run bash "$SCRIPT" 9.9.9 "$DEST_DIR"
    [ "$status" -eq 0 ]
    [ -f "$DEST_DIR/bin/coqui-console" ]
}

@test "fails closed when checksum does not match" {
    _write_curl_stub "deadbeefdeadbeef"
    run bash "$SCRIPT" 9.9.9 "$DEST_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Checksum"* ]]
}

@test "fails closed when sha256sum is unavailable" {
    _write_curl_stub "$REAL_HASH"
    # Run with a PATH that contains ONLY the stub dir so `command -v sha256sum`
    # cannot resolve the system binary. `bash` is symlinked in so the script
    # itself is still reachable and its fail-closed guard actually executes
    # (otherwise a bare stub-only PATH fails with 127 "bash not found" and the
    # guard is never reached). The behaviour under test: no sha256sum ⇒ the
    # script refuses to install and exits non-zero.
    ln -s "$(command -v bash)" "$STUB_DIR/bash"
    run env PATH="$STUB_DIR" bash "$SCRIPT" 9.9.9 "$DEST_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"sha256sum not found"* ]]
}
