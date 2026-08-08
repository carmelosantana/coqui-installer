#!/usr/bin/env bats

setup() {
    SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/docker/fetch-web.sh"
    DEST_DIR="$(mktemp -d)"
    STUB_DIR="$(mktemp -d)"
    export PATH="$STUB_DIR:$PATH"
}
teardown() { rm -rf "$DEST_DIR" "$STUB_DIR"; }

@test "stub mode writes a placeholder index.html" {
    run env COQUI_WEB_STUB=1 bash "$SCRIPT" 0.0.0 "$DEST_DIR"
    [ "$status" -eq 0 ]
    [ -f "$DEST_DIR/index.html" ]
    grep -qi "coqui" "$DEST_DIR/index.html"
}

@test "WEB_TARBALL_URL override is fetched and extracted" {
    # Build a fake web tarball and a curl stub that serves it.
    WEB_FIX="$(mktemp -d)"
    echo "<html>real</html>" > "$WEB_FIX/index.html"
    ( cd "$WEB_FIX" && tar -czf "$STUB_DIR/web.tar.gz" . )
    cat > "$STUB_DIR/curl" <<EOF
#!/bin/sh
out=""; while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && out="\$2"; shift; done
[ -n "\$out" ] && cp "$STUB_DIR/web.tar.gz" "\$out"
EOF
    chmod +x "$STUB_DIR/curl"
    run env WEB_TARBALL_URL="http://example/web.tar.gz" bash "$SCRIPT" 0.0.0 "$DEST_DIR"
    [ "$status" -eq 0 ]
    grep -q "real" "$DEST_DIR/index.html"
    rm -rf "$WEB_FIX"
}

# Build a fake web tarball + a curl stub that serves the tarball for the release
# asset URL and a SHA256SUMS.txt line for the SHA256SUMS.txt URL. $1 = the hash
# to advertise in SHA256SUMS.txt (use "GOOD" for the real hash, or a bad hash).
_make_release_stub() {
    WEB_FIX="$(mktemp -d)"
    echo "<html>real-release</html>" > "$WEB_FIX/index.html"
    ( cd "$WEB_FIX" && tar -czf "$STUB_DIR/web.tar.gz" . )
    local tarname="Coqui-9.9.9-web.tar.gz"
    local hash="$1"
    [ "$hash" = "GOOD" ] && hash="$(sha256sum "$STUB_DIR/web.tar.gz" | awk '{print $1}')"
    printf '%s  %s\n' "$hash" "$tarname" > "$STUB_DIR/SHA256SUMS.txt"
    cat > "$STUB_DIR/curl" <<EOF
#!/bin/sh
url=""; out=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        http*|https*) url="\$1"; shift ;;
        *) shift ;;
    esac
done
case "\$url" in
    *SHA256SUMS.txt) src="$STUB_DIR/SHA256SUMS.txt" ;;
    *web.tar.gz)     src="$STUB_DIR/web.tar.gz" ;;
    *) exit 22 ;;
esac
if [ -n "\$out" ]; then cp "\$src" "\$out"; else cat "\$src"; fi
EOF
    chmod +x "$STUB_DIR/curl"
}

@test "release path verifies the bundle against SHA256SUMS.txt (matching hash passes)" {
    _make_release_stub GOOD
    run bash "$SCRIPT" 9.9.9 "$DEST_DIR"
    [ "$status" -eq 0 ]
    grep -q "checksum verified" <<<"$output"
    grep -q "real-release" "$DEST_DIR/index.html"
    rm -rf "$WEB_FIX"
}

@test "release path fails closed on a checksum mismatch" {
    _make_release_stub "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    run bash "$SCRIPT" 9.9.9 "$DEST_DIR"
    [ "$status" -ne 0 ]
    grep -qi "checksum mismatch" <<<"$output"
    [ ! -f "$DEST_DIR/index.html" ]
    rm -rf "$WEB_FIX"
}
