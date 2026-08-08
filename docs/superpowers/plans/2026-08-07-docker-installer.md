# Coqui Docker Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a single Docker container (`ghcr.io/carmelosantana/coqui`) the primary install path — coqui CAP API + Flutter web UI in one image behind a single-origin reverse proxy — with the native `install.sh` demoted to a Linux/macOS fallback and all PowerShell/Windows-native code removed.

**Architecture:** The image is *assembled from prebuilt releases* (no source build): it fetches the coqui server release tarball (`coqui-v<ver>.tar.gz` + `.sha256`, fail-closed verify) and the coqui-app web bundle (`Coqui-<ver>-web.tar.gz`, added by dependency D1), then runs the CAP API (bound to `127.0.0.1:3300`) and a **Caddy** reverse proxy under **supervisord**. Caddy serves the web UI at `/` with cross-origin-isolation headers (COOP/COEP) required by the `--wasm` build and proxies `/api/*` to the API on localhost — single origin, so no CORS and no API key are needed. The app restarts the server via `POST /api/v1/server/restart`, which exits the process with code 10; supervisord (configured `autorestart=unexpected`, `exitcodes=0,130`) relaunches it while the container and Caddy stay up.

**Tech Stack:** Docker, `php:8.4-cli` (Debian slim) + `docker-php-ext-install`, Caddy 2, supervisord, docker compose v2, Bash, bats-core, GitHub Actions.

## Global Constraints

- **Commit identity:** use the global `Carmelo Santana <me@carmelosantana.com>` — never override it.
- **No-legacy / clean cut:** NO migration shims, deprecation stubs, or compat branches. Deleted files stay deleted.
- **Do NOT modify Coqui core** (`Core/coqui`) — it is read-only reference. Do not weaken `CatastrophicBlacklist` or any safety gate. (Core was only *read* to verify facts; this plan changes no core file.)
- **Two repos, two PRs, isolated worktrees only:**
  - `coqui-installer` worktree: `/home/carmelo/Projects/CoquiBot/Core/coqui-installer/.worktrees/docker-installer` (branch `feat/docker-installer`). ALL installer work here.
  - `coqui-app` worktree: `/home/carmelo/Projects/CoquiBot/Apps/coqui-app/.worktrees/web-release-asset` (branch `feat/web-release-asset`). ONLY Task 1 (D1) here.
  - NEVER touch coqui-app branches `fix/apple-build` or `feat/discord-redesign`.
- **PHP floor:** 8.4. **Extension parity (D3):** required `dom mbstring pdo_sqlite xml`; recommended `curl readline`; optional `gd pcntl posix`.
- **Verified server facts (do not re-derive):** API base path `/api/v1`; default bind `127.0.0.1:3300`; public health `GET /api/v1/health`; restart `POST /api/v1/server/restart` needs env `COQUI_LAUNCHER_MANAGED=1`, exits 10 on restart (0/130 clean, other crash); start via `bin/coqui-console api --host <h> --port <p> [--config <f>] [--workspace <d>]`; config file `openclaw.json`, sole required field `agents.defaults.model.primary`; SQLite at `<workspace>/data/coqui.db`; version reported by `AppVersion` via `COQUI_VERSION` env or `config/version.txt`.
- **Release URL pattern (mirror install.sh):** `https://github.com/carmelosantana/coqui/releases/download/v<ver>/coqui-v<ver>.tar.gz` (+ `.sha256` sidecar). Archive has a single top-level `coqui/` directory.
- **Default published port:** host `8080` → container Caddy port.

---

## File Structure

**`coqui-app` (Task 1 only — separate PR):**
- Modify `.github/workflows/release.yml` — in the `release` job, tar the `web-build` artifact into `Coqui-<version>-web.tar.gz` and attach it (below line 354, clear of the `fix/apple-build` hunks).

**`coqui-installer` (Tasks 2–11):**
- Create `Dockerfile` — assemble-from-release image (base, extensions, server tarball fetch+verify, web bundle, Caddy, supervisor).
- Create `docker/fetch-coqui.sh` — server release download + fail-closed checksum verify + extract (mirrors install.sh).
- Create `docker/fetch-web.sh` — web bundle fetch (real URL or `WEB_TARBALL_URL` override; `COQUI_WEB_STUB=1` writes a placeholder for CI).
- Create `docker/Caddyfile` — `/` static (COOP/COEP/CORP headers, SPA fallback) + `/api/*` → `127.0.0.1:3300`.
- Create `docker/supervisord.conf` — `coqui-api` (autorestart=unexpected, exitcodes=0,130) + `caddy` (autorestart=true).
- Create `docker/entrypoint.sh` — first-run `openclaw.json` scaffold, workspace/data dirs, exec supervisord.
- Create `docker/openclaw.default.json` — minimal first-run config (BYO Ollama pointer).
- Create `compose.yaml` — one `coqui` service, port 8080, config/data mounts, `restart: unless-stopped`, `extra_hosts` note.
- Create `coqui.wrapper.sh` — the `coqui` CLI wrapper template (`up`/`status`/`stop`/`restart`/`logs`/`update`) installed by install.sh.
- Modify `install.sh` — Docker-first: detect Docker + compose → scaffold + pull + up + install wrapper; native fallback on `--native` or Docker absent; keep `--dev`.
- Modify `uninstall.sh` — tear down Docker stack + native removal.
- Modify `.github/workflows/test-installer.yml` — drop `lint-powershell` + `test-windows`; keep shell lint + bats; wire the new docker job in the summary gate.
- Create `.github/workflows/docker-image.yml` — build image + boot container + smoke-assert `/` (COOP/COEP) and `/api/v1/health` via proxy.
- Modify `tests/test_install.bats`, `tests/test_uninstall.bats` — cover Docker-detect + native-fallback branching and wrapper generation.
- Modify `README.md` — Docker primary, native fallback secondary, purge all Windows/PowerShell references.
- **Delete:** `install.ps1`, `install-native.ps1`, `uninstall.ps1`, `uninstall-native.ps1`, `tests/test_install.ps1`, `tests/test_install_native.ps1`, `tests/test_uninstall.ps1`, `tests/test_uninstall_native.ps1`, `tests/WINDOWS-SMOKE-CHECKLIST.md`, `docs/NATIVE-WINDOWS-DEPRECATED.md`, `.github/PSScriptAnalyzerSettings.psd1`.

**Task dependency notes:** Task 1 (D1) is independent and unblocks the *production* image but not CI (CI uses the `COQUI_WEB_STUB` path). Tasks 3→4→5 build the image incrementally. Task 6 (compose) depends on the image contract. Tasks 7–8 rewrite install.sh (detection before scaffolding). Task 10 (CI) depends on the image + compose. Task 11 (README) is last.

---

### Task 1: D1 — publish the web bundle as a release asset (coqui-app)

**Repo/worktree:** `/home/carmelo/Projects/CoquiBot/Apps/coqui-app/.worktrees/web-release-asset` (branch `feat/web-release-asset`). This is the ONLY task in coqui-app. Stay below line 354 of `release.yml` (the `build-web` and `release` jobs) — the `fix/apple-build` branch edits `build-macos`/`build-ios` above line ~266, so there is no overlap.

**Files:**
- Modify: `.github/workflows/release.yml` (the `release` job — `Collect release assets` step and the `softprops/action-gh-release` `files:` list)

**Context (verified):** The `release` job already declares `needs: [build-android, build-linux, build-windows, build-web]`, so the `web-build` artifact (the raw `build/web/` dir) is already downloaded into `artifacts/web-build/` by the existing `Download all artifacts` step (`uses: actions/download-artifact@v4` with `path: artifacts/`). Asset version is `${{ steps.version.outputs.version }}` (tag ref minus leading `v`). No `needs:` change is required.

- [ ] **Step 1: Confirm the current release job shape**

Run: `cd /home/carmelo/Projects/CoquiBot/Apps/coqui-app/.worktrees/web-release-asset && grep -n 'Collect release assets\|Generate checksums\|action-gh-release\|files:\|web-build\|download-artifact' .github/workflows/release.yml`
Expected: shows the `Collect release assets` step, the `Generate checksums` step (`working-directory: release`), and the `files:` block listing `release/Coqui-...` assets. Confirm `artifacts/web-build/` is where the web bundle lands.

- [ ] **Step 2: Add the tar step to `Collect release assets`**

In the `Collect release assets` `run:` block (the one with the `cp -v artifacts/... release/` lines), append a line that tars the web bundle into the flat `release/` dir so it is checksummed alongside the others. The `web-build` artifact contains the contents of `build/web/`, downloaded to `artifacts/web-build/`:

```yaml
          tar -czf "release/Coqui-${{ steps.version.outputs.version }}-web.tar.gz" -C artifacts/web-build . || echo "Web build not found"
```

Place it after the existing `cp -v` lines, before the step ends. (The `Generate checksums` step runs `sha256sum *` in `release/`, so the new tarball is automatically added to `SHA256SUMS.txt`.)

- [ ] **Step 3: Add the web tarball to the `files:` list**

In the `Create GitHub Release` step (`uses: softprops/action-gh-release@v2`), add one line to the `files:` block so the asset is actually attached (files not listed here are checksummed but NOT uploaded):

```yaml
          files: |
            release/Coqui-${{ steps.version.outputs.version }}-android.apk
            release/Coqui-${{ steps.version.outputs.version }}-linux-x64.tar.gz
            release/Coqui-${{ steps.version.outputs.version }}-windows-x64.zip
            release/Coqui-${{ steps.version.outputs.version }}-web.tar.gz
            release/SHA256SUMS.txt
```

- [ ] **Step 4: Validate the workflow YAML + lint**

Run: `cd /home/carmelo/Projects/CoquiBot/Apps/coqui-app/.worktrees/web-release-asset && python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"`
Expected: `YAML OK`
Then, if `actionlint` is available: `actionlint .github/workflows/release.yml` → Expected: no errors. (If `actionlint` is not installed, skip — the YAML check is the gate.)

- [ ] **Step 5: Assert the two edits are present (guard against regressions)**

Run: `cd /home/carmelo/Projects/CoquiBot/Apps/coqui-app/.worktrees/web-release-asset && grep -c 'Coqui-${{ steps.version.outputs.version }}-web.tar.gz' .github/workflows/release.yml`
Expected: `2` (one in the tar step, one in the `files:` list).

- [ ] **Step 6: Confirm no collision with fix/apple-build**

Run: `cd /home/carmelo/Projects/CoquiBot/Apps/coqui-app && git diff --stat main fix/apple-build -- .github/workflows/release.yml && git diff feat/web-release-asset main -- .github/workflows/release.yml | grep '^@@'`
Expected: the `feat/web-release-asset` hunks are all in the `release` job region (line numbers ≥ ~382), while `fix/apple-build` touches only `build-macos`/`build-ios` (≤ ~266). Confirm the changed line ranges do not overlap.

- [ ] **Step 7: Commit**

```bash
cd /home/carmelo/Projects/CoquiBot/Apps/coqui-app/.worktrees/web-release-asset
git add .github/workflows/release.yml
git commit -m "ci(release): attach Coqui-<version>-web.tar.gz as a release asset

Tars the web-build artifact (build/web/) into the flat release/ dir so it is
checksummed and uploaded by the softprops release action, letting the Docker
installer fetch the web bundle by release tag like the server tarball (D1)."
```

---

### Task 2: Remove all PowerShell / Windows-native code

**Files:**
- Delete: `install.ps1`, `install-native.ps1`, `uninstall.ps1`, `uninstall-native.ps1`, `tests/test_install.ps1`, `tests/test_install_native.ps1`, `tests/test_uninstall.ps1`, `tests/test_uninstall_native.ps1`, `tests/WINDOWS-SMOKE-CHECKLIST.md`, `docs/NATIVE-WINDOWS-DEPRECATED.md`, `.github/PSScriptAnalyzerSettings.psd1`
- Modify: `.github/workflows/test-installer.yml` — remove the `lint-powershell` and `test-windows` jobs, drop their references in the `all-tests-passed` gate and the `paths:` filters.

**Interfaces:**
- Produces: a CI workflow with jobs `lint-shell`, `test-linux`, `test-macos`, `all-tests-passed` (no PowerShell). The docker job is added in Task 10; this task leaves the gate correct for the current job set.

- [ ] **Step 1: Write the failing test (repo cleanliness guard)**

Create `tests/test_no_powershell.bats`:

```bash
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
    run grep -iE 'powershell|pwsh|pester|psscriptanalyzer|test-windows' "$REPO_ROOT/.github/workflows/test-installer.yml"
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd .worktrees/docker-installer && bats tests/test_no_powershell.bats`
Expected: FAIL — `.ps1` files exist, `test-windows` job present, etc.

- [ ] **Step 3: Delete the PowerShell + Windows-native files**

```bash
cd .worktrees/docker-installer
git rm install.ps1 install-native.ps1 uninstall.ps1 uninstall-native.ps1 \
  tests/test_install.ps1 tests/test_install_native.ps1 \
  tests/test_uninstall.ps1 tests/test_uninstall_native.ps1 \
  tests/WINDOWS-SMOKE-CHECKLIST.md docs/NATIVE-WINDOWS-DEPRECATED.md \
  .github/PSScriptAnalyzerSettings.psd1
```

- [ ] **Step 4: Strip PowerShell from the CI workflow**

Edit `.github/workflows/test-installer.yml`:
- In BOTH `paths:` filters (push + pull_request), delete the four lines `- "install.ps1"`, `- "install-native.ps1"`, `- "uninstall.ps1"`, `- "uninstall-native.ps1"`.
- Delete the entire `lint-powershell:` job (name `PSScriptAnalyzer`).
- Delete the entire `test-windows:` job (name `PowerShell tests (Windows)`).
- In `test-linux:` and `test-macos:`, change `needs: [lint-shell]` — leave as-is (still valid).
- In the `all-tests-passed:` job, change `needs:` to `[lint-shell, test-linux, test-macos]` and rewrite the `Check results` script to only check those three:

```yaml
  all-tests-passed:
    name: All tests passed
    runs-on: ubuntu-latest
    needs: [lint-shell, test-linux, test-macos]
    if: always()
    steps:
      - name: Check results
        run: |
          if [[ "${{ needs.lint-shell.result }}" != "success" ]] || \
             [[ "${{ needs.test-linux.result }}" != "success" ]] || \
             [[ "${{ needs.test-macos.result }}" != "success" ]]; then
            echo "One or more jobs failed."
            exit 1
          fi
          echo "All jobs passed."
```

- [ ] **Step 5: Run the guard test to verify it passes**

Run: `cd .worktrees/docker-installer && bats tests/test_no_powershell.bats`
Expected: PASS (all 4 tests).

- [ ] **Step 6: Validate the workflow YAML still parses**

Run: `cd .worktrees/docker-installer && python3 -c "import yaml; yaml.safe_load(open('.github/workflows/test-installer.yml')); print('YAML OK')"`
Expected: `YAML OK`

- [ ] **Step 7: Commit**

```bash
cd .worktrees/docker-installer
git add -A
git commit -m "chore: remove all PowerShell and Windows-native install code

Clean cut per the Docker-first design: Windows is Docker-only. Deletes the
native/WSL PowerShell installers, their Pester tests, the smoke checklist, the
deprecation doc, and the PSScriptAnalyzer settings + CI jobs. Adds a bats guard
so no PowerShell artifact can creep back in."
```

---

### Task 3: Dockerfile — base image, PHP extensions, and fail-closed server fetch

**Files:**
- Create: `docker/fetch-coqui.sh`
- Create: `Dockerfile`
- Test: `docker/fetch-coqui.sh` is unit-tested via `tests/test_fetch_coqui.bats`; the image layer is smoke-tested by building.

**Interfaces:**
- Produces: an image stage with the coqui server extracted at `/srv/coqui` (so `/srv/coqui/bin/coqui-console` exists), PHP 8.4 with extensions `dom xml pdo_sqlite mbstring gd pcntl posix`, and `curl`/`ca-certificates`/`coreutils` present. Build args `COQUI_VERSION` (server release, e.g. `0.0.1`) drive the fetch. Later tasks add web (Task 4) and supervisor/entrypoint (Task 5).

**Context:** `fetch-coqui.sh` mirrors install.sh's `install_release`/`verify_checksum` but is **hardened fail-closed**: unlike install.sh (which *skips* verification if no `sha256sum`), this script requires `sha256sum` and aborts if absent — `coreutils` is installed in the image so this never triggers, but the guard is explicit.

- [ ] **Step 1: Write the failing test for `fetch-coqui.sh`**

Create `tests/test_fetch_coqui.bats`:

```bash
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
    # Shadow sha256sum with a non-executable placeholder so `command -v` fails.
    run env PATH="$STUB_DIR" bash "$SCRIPT" 9.9.9 "$DEST_DIR"
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd .worktrees/docker-installer && bats tests/test_fetch_coqui.bats`
Expected: FAIL — `docker/fetch-coqui.sh` does not exist.

- [ ] **Step 3: Write `docker/fetch-coqui.sh`**

```bash
#!/usr/bin/env sh
# Fetch, verify (fail-closed), and extract a coqui server release.
# Usage: fetch-coqui.sh <version> <dest_dir>
#   <version>  release version without leading v, e.g. 0.0.1
#   <dest_dir> directory to place the extracted server (gets bin/, vendor/, ...)
set -eu

VERSION="${1:?version required}"
DEST="${2:?dest dir required}"

OWNER="carmelosantana"
REPO="coqui"
BASE="https://github.com/${OWNER}/${REPO}/releases/download"
ARCHIVE="coqui-v${VERSION}.tar.gz"
URL="${BASE}/v${VERSION}/${ARCHIVE}"
CHECKSUM_URL="${URL}.sha256"

# Fail closed: the integrity control must be available.
if ! command -v sha256sum >/dev/null 2>&1; then
    echo "fetch-coqui: sha256sum not found — refusing to install unverified release" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "fetch-coqui: downloading ${URL}"
curl -fsSL "$URL" -o "${TMP}/${ARCHIVE}" \
    || { echo "fetch-coqui: download failed: ${URL}" >&2; exit 1; }

echo "fetch-coqui: verifying checksum"
EXPECTED="$(curl -fsSL "$CHECKSUM_URL" 2>/dev/null | awk '{print $1}')" \
    || { echo "fetch-coqui: could not fetch checksum ${CHECKSUM_URL} — refusing unverified install" >&2; exit 1; }
[ -n "$EXPECTED" ] || { echo "fetch-coqui: empty checksum — refusing unverified install" >&2; exit 1; }
ACTUAL="$(sha256sum "${TMP}/${ARCHIVE}" | awk '{print $1}')"
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "fetch-coqui: Checksum mismatch. Expected ${EXPECTED}, got ${ACTUAL}" >&2
    exit 1
fi

echo "fetch-coqui: extracting to ${DEST}"
tar -xzf "${TMP}/${ARCHIVE}" -C "$TMP"
[ -d "${TMP}/coqui" ] || { echo "fetch-coqui: archive missing top-level coqui/ dir" >&2; exit 1; }
mkdir -p "$DEST"
cp -a "${TMP}/coqui/." "$DEST/"
echo "$VERSION" > "${DEST}/.coqui-version"
chmod +x "${DEST}/bin/coqui" "${DEST}/bin/coqui-console" 2>/dev/null || true
echo "fetch-coqui: done"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd .worktrees/docker-installer && bats tests/test_fetch_coqui.bats`
Expected: PASS (3 tests). If the third test does not fail as written, adjust: the "sha256sum unavailable" case relies on running with a PATH that omits system dirs; if the sandbox still resolves `sha256sum`, replace the stub-dir PATH approach with a `PATH` that points only at `$STUB_DIR` plus a `sha256sum` shim that `exit 127`. The behavior under test is: no `sha256sum` ⇒ non-zero exit.

- [ ] **Step 5: Write the initial `Dockerfile` (base + extensions + server fetch)**

```dockerfile
# syntax=docker/dockerfile:1

# ── Runtime base: PHP 8.4 CLI + coqui extension set (parity with install.sh) ──
FROM php:8.4-cli-bookworm

ARG COQUI_VERSION
LABEL org.opencontainers.image.title="coqui" \
      org.opencontainers.image.source="https://github.com/carmelosantana/coqui-installer" \
      org.opencontainers.image.description="Coqui CAP API + Flutter web UI (single container)"

# System deps: build headers for the PHP extensions + tools for fetch/verify.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl coreutils \
        libpng-dev libjpeg62-turbo-dev libfreetype6-dev \
        libxml2-dev libsqlite3-dev libonig-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" dom xml pdo_sqlite mbstring gd pcntl posix; \
    rm -rf /var/lib/apt/lists/*

# Assemble the coqui server from its prebuilt release (fail-closed checksum verify).
COPY docker/fetch-coqui.sh /usr/local/bin/fetch-coqui.sh
RUN chmod +x /usr/local/bin/fetch-coqui.sh \
    && /usr/local/bin/fetch-coqui.sh "${COQUI_VERSION}" /srv/coqui

# Record the server version so AppVersion reports it at runtime.
ENV COQUI_VERSION=${COQUI_VERSION}

WORKDIR /srv/coqui
```

- [ ] **Step 6: Build the image stage and verify extensions + binary**

Run (pick a real published server version — check `curl -fsSL https://api.github.com/repos/carmelosantana/coqui/releases/latest | grep tag_name`; use that version minus the `v`):

```bash
cd .worktrees/docker-installer
docker build --build-arg COQUI_VERSION=<real-version> -t coqui-base-test .
docker run --rm coqui-base-test php -m | tr '[:upper:]' '[:lower:]' | grep -E '^(dom|xml|pdo_sqlite|mbstring|gd|pcntl|posix)$' | sort -u
docker run --rm coqui-base-test sh -c 'test -x /srv/coqui/bin/coqui-console && echo console-ok'
```
Expected: the grep lists all seven extensions; prints `console-ok`. (If a build header is missing for an extension, the build fails at Step 5's `docker-php-ext-install` — add the corresponding `-dev` package.)

- [ ] **Step 7: Commit**

```bash
cd .worktrees/docker-installer
git add docker/fetch-coqui.sh Dockerfile tests/test_fetch_coqui.bats
git commit -m "feat(docker): base image with PHP 8.4 extensions and fail-closed server fetch

Assembles the coqui server from its release tarball (verified sha256, mirrors
install.sh but hardened to require sha256sum), on php:8.4 with the coqui
extension set (dom xml pdo_sqlite mbstring gd pcntl posix)."
```

---

### Task 4: Caddy reverse proxy — web at `/` (COOP/COEP) + `/api/*` proxy, with web-bundle fetch

**Files:**
- Create: `docker/fetch-web.sh`
- Create: `docker/Caddyfile`
- Modify: `Dockerfile` (add Caddy binary, run `fetch-web.sh`, copy Caddyfile)
- Test: `tests/test_fetch_web.bats` for the fetch script; header behavior smoke-tested in Task 10's CI.

**Interfaces:**
- Consumes: the server image stage from Task 3.
- Produces: web bundle at `/srv/web` (real fetch, `WEB_TARBALL_URL` override, or `COQUI_WEB_STUB=1` placeholder), the `caddy` binary at `/usr/bin/caddy`, and `/etc/caddy/Caddyfile`. Caddy listens on `${CADDY_PORT:-8080}`, serves `/srv/web` at `/` with `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp` + `Cross-Origin-Resource-Policy: same-origin`, SPA-falls-back to `/index.html`, and reverse-proxies `/api/*` to `127.0.0.1:3300`.

**Context (verified):** the API is pure JSON (no static serving) bound to `127.0.0.1:3300`; because Caddy and the API share the container's network namespace, proxying to localhost means the API never binds a non-localhost host and therefore needs **no API key** and **no CORS**. COEP `require-corp` demands same-origin subresources carry CORP — the Flutter assets are same-origin and we set CORP `same-origin` globally, satisfying it.

- [ ] **Step 1: Write the failing test for `fetch-web.sh`**

Create `tests/test_fetch_web.bats`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd .worktrees/docker-installer && bats tests/test_fetch_web.bats`
Expected: FAIL — `docker/fetch-web.sh` does not exist.

- [ ] **Step 3: Write `docker/fetch-web.sh`**

```bash
#!/usr/bin/env sh
# Fetch the coqui-app web bundle into <dest_dir>.
# Usage: fetch-web.sh <app_version> <dest_dir>
# Modes (in priority order):
#   COQUI_WEB_STUB=1     -> write a minimal placeholder index.html (CI plumbing tests)
#   WEB_TARBALL_URL=...  -> fetch that exact URL
#   else                 -> fetch the release asset for <app_version>
set -eu

APP_VERSION="${1:-}"
DEST="${2:?dest dir required}"
mkdir -p "$DEST"

if [ "${COQUI_WEB_STUB:-0}" = "1" ]; then
    cat > "${DEST}/index.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>Coqui (stub)</title></head>
<body><h1>Coqui web placeholder</h1><p>CI plumbing stub — not the real UI.</p></body></html>
HTML
    echo "fetch-web: wrote stub placeholder"
    exit 0
fi

if [ -n "${WEB_TARBALL_URL:-}" ]; then
    URL="$WEB_TARBALL_URL"
else
    [ -n "$APP_VERSION" ] || { echo "fetch-web: app version required when no WEB_TARBALL_URL/stub" >&2; exit 1; }
    URL="https://github.com/carmelosantana/coqui-app/releases/download/v${APP_VERSION}/Coqui-${APP_VERSION}-web.tar.gz"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "fetch-web: downloading ${URL}"
curl -fsSL "$URL" -o "${TMP}/web.tar.gz" || { echo "fetch-web: download failed: ${URL}" >&2; exit 1; }
tar -xzf "${TMP}/web.tar.gz" -C "$DEST"
[ -f "${DEST}/index.html" ] || { echo "fetch-web: bundle missing index.html" >&2; exit 1; }
echo "fetch-web: done"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd .worktrees/docker-installer && bats tests/test_fetch_web.bats`
Expected: PASS (2 tests).

- [ ] **Step 5: Write `docker/Caddyfile`**

```
{
	admin off
	auto_https off
}

:{$CADDY_PORT:8080} {
	encode gzip

	# JSON API — same-origin proxy to the localhost-bound CAP API. No CORS needed.
	handle /api/* {
		reverse_proxy 127.0.0.1:3300
	}

	# Flutter web (built --wasm) — requires cross-origin isolation.
	handle {
		root * /srv/web
		header {
			Cross-Origin-Opener-Policy "same-origin"
			Cross-Origin-Embedder-Policy "require-corp"
			Cross-Origin-Resource-Policy "same-origin"
			-Server
		}
		try_files {path} /index.html
		file_server
	}
}
```

- [ ] **Step 6: Extend the `Dockerfile` with Caddy + web bundle**

Add a Caddy binary copy near the top (after the `FROM` line, before or after the system deps block):

```dockerfile
# Caddy reverse proxy (single-origin front for web UI + /api proxy).
COPY --from=caddy:2 /usr/bin/caddy /usr/bin/caddy
```

Add web-bundle args + fetch after the server fetch block:

```dockerfile
ARG COQUI_APP_VERSION=""
ARG WEB_TARBALL_URL=""
ARG COQUI_WEB_STUB=""
LABEL org.opencontainers.image.app_version=${COQUI_APP_VERSION}

COPY docker/fetch-web.sh /usr/local/bin/fetch-web.sh
RUN chmod +x /usr/local/bin/fetch-web.sh \
    && COQUI_WEB_STUB="${COQUI_WEB_STUB}" WEB_TARBALL_URL="${WEB_TARBALL_URL}" \
       /usr/local/bin/fetch-web.sh "${COQUI_APP_VERSION}" /srv/web

COPY docker/Caddyfile /etc/caddy/Caddyfile
```

- [ ] **Step 7: Build with the stub and verify Caddy validates the config + web dir exists**

```bash
cd .worktrees/docker-installer
docker build --build-arg COQUI_VERSION=<real-version> --build-arg COQUI_WEB_STUB=1 -t coqui-web-test .
docker run --rm coqui-web-test sh -c 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && test -f /srv/web/index.html && echo web-ok'
```
Expected: Caddy prints "Valid configuration" and `web-ok`. (Full header assertions run against a booted container in Task 10; here we only prove the layer assembles and the Caddyfile is valid.)

- [ ] **Step 8: Commit**

```bash
cd .worktrees/docker-installer
git add docker/fetch-web.sh docker/Caddyfile Dockerfile tests/test_fetch_web.bats
git commit -m "feat(docker): Caddy single-origin front with COOP/COEP + web-bundle fetch

Serves the Flutter --wasm web UI at / with cross-origin isolation headers and
proxies /api/* to the localhost-bound CAP API (no CORS, no API key). Web bundle
is fetched by release tag, overridable via WEB_TARBALL_URL, or stubbed for CI."
```

---

### Task 5: supervisord, entrypoint, first-run config, and HEALTHCHECK

**Files:**
- Create: `docker/supervisord.conf`
- Create: `docker/entrypoint.sh`
- Create: `docker/openclaw.default.json`
- Modify: `Dockerfile` (install supervisor, copy the three files, `EXPOSE`, `HEALTHCHECK`, `ENTRYPOINT`)
- Test: `tests/test_entrypoint.bats` for the config-scaffold logic; full boot verified in Task 10.

**Interfaces:**
- Consumes: image from Task 4 (server at `/srv/coqui`, web at `/srv/web`, Caddy + Caddyfile).
- Produces: a runnable image whose `ENTRYPOINT` is `docker/entrypoint.sh` → scaffolds `/config/openclaw.json` (if absent) from `openclaw.default.json`, ensures `/data/workspace/data` exists, then `exec`s supervisord. supervisord runs `coqui-api` (`bin/coqui-console api --host 127.0.0.1 --port 3300 --config /config/openclaw.json --workspace /data/workspace`, env `COQUI_LAUNCHER_MANAGED=1`, `autorestart=unexpected`, `exitcodes=0,130`) and `caddy` (`caddy run --config /etc/caddy/Caddyfile --adapter caddyfile`, `autorestart=true`). Mounts: `/config` (config), `/data` (workspace + SQLite). `HEALTHCHECK` curls `http://127.0.0.1:3300/api/v1/health`.

**Context (verified):** `COQUI_LAUNCHER_MANAGED=1` makes `POST /api/v1/server/restart` return 200 and exit the API process with code 10; supervisord's `autorestart=unexpected` restarts on any exit code NOT in `exitcodes` — so 10 (restart) and crashes relaunch, while 0/130 (clean stop) do not. The API's sole required config field is `agents.defaults.model.primary`; `/api/v1/health` is public so the container is healthy even before a model provider is reachable.

⚠️ **Verify during implementation, do not assume:** the exact provider-config key for pointing at host Ollama. `agents.defaults.model.primary` is confirmed required; the Ollama `base_url` provider key is NOT yet verified. Before finalizing `openclaw.default.json`, read the provider/config schema in coqui core (`Core/coqui/src/Config/`, e.g. `ConfigValidator.php` and provider loading) and adjust the `models.providers` block to the real schema. If the schema is unclear, ship the minimal valid config (just `agents.defaults.model.primary`) plus a commented pointer, and note the follow-up — a wrong provider key must not break boot (boot tolerates unknown/absent provider config; `/health` still serves).

- [ ] **Step 1: Write `docker/openclaw.default.json`**

```json
{
  "agents": {
    "defaults": {
      "model": { "primary": "ollama/llama3.1" },
      "roles": { "orchestrator": "ollama/llama3.1" }
    }
  },
  "models": {
    "providers": {
      "ollama": { "base_url": "http://host.docker.internal:11434" }
    }
  }
}
```

(Adjust the `models.providers` block per the schema-verification note above. Keep `agents.defaults.model.primary` — it is the one strictly-required field.)

- [ ] **Step 2: Write the failing test for entrypoint config scaffolding**

Create `tests/test_entrypoint.bats`:

```bash
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
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd .worktrees/docker-installer && bats tests/test_entrypoint.bats`
Expected: FAIL — `docker/entrypoint.sh` does not exist.

- [ ] **Step 4: Write `docker/entrypoint.sh`**

```bash
#!/usr/bin/env sh
set -eu

CONFIG_DIR="${COQUI_CONFIG_DIR:-/config}"
DATA_DIR="${COQUI_DATA_DIR:-/data}"
DEFAULT_CONFIG="${COQUI_DEFAULT_CONFIG:-/srv/defaults/openclaw.default.json}"
WORKSPACE="${DATA_DIR}/workspace"

mkdir -p "$CONFIG_DIR" "$WORKSPACE/data"

# First-run config scaffold — never clobber an existing user config.
if [ ! -f "${CONFIG_DIR}/openclaw.json" ]; then
    cp "$DEFAULT_CONFIG" "${CONFIG_DIR}/openclaw.json"
    echo "entrypoint: scaffolded ${CONFIG_DIR}/openclaw.json"
fi

# Export workspace for the API (COQUI_WORKSPACE_PATH is honored by the server).
COQUI_WORKSPACE_PATH="$WORKSPACE"
export COQUI_WORKSPACE_PATH

# Test hook: skip the exec so the scaffold logic can be unit-tested.
if [ "${COQUI_ENTRYPOINT_NO_EXEC:-0}" = "1" ]; then
    exit 0
fi

exec supervisord -c /etc/supervisor/conf.d/supervisord.conf
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd .worktrees/docker-installer && bats tests/test_entrypoint.bats`
Expected: PASS (3 tests).

- [ ] **Step 6: Write `docker/supervisord.conf`**

```ini
[supervisord]
nodaemon=true
user=root
logfile=/dev/null
logfile_maxbytes=0
pidfile=/run/supervisord.pid

[program:coqui-api]
command=/srv/coqui/bin/coqui-console api --host 127.0.0.1 --port 3300 --config /config/openclaw.json --workspace /data/workspace
environment=COQUI_LAUNCHER_MANAGED="1",COQUI_WORKSPACE_PATH="/data/workspace"
autostart=true
autorestart=unexpected
exitcodes=0,130
startretries=1000000
stopsignal=TERM
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0

[program:caddy]
command=/usr/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
autostart=true
autorestart=true
stopsignal=TERM
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0
```

(Rationale: `autorestart=unexpected` + `exitcodes=0,130` relaunches the API on exit-10 restart requests and on crashes, but not on clean stops. `startretries` is set very high so repeated intentional restarts never exhaust the retry budget — see the verified restart contract.)

- [ ] **Step 7: Extend the `Dockerfile` (supervisor, defaults, expose, healthcheck, entrypoint)**

Add `supervisor` to the `apt-get install` list in Task 3's system-deps block (append `supervisor` to the package list). Then add near the end of the Dockerfile:

```dockerfile
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/openclaw.default.json /srv/defaults/openclaw.default.json
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV COQUI_CONFIG_DIR=/config \
    COQUI_DATA_DIR=/data \
    COQUI_DEFAULT_CONFIG=/srv/defaults/openclaw.default.json \
    CADDY_PORT=8080

EXPOSE 8080
VOLUME ["/config", "/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=25s --retries=3 \
    CMD curl -fsS http://127.0.0.1:3300/api/v1/health || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 8: Full-boot smoke test the image locally**

```bash
cd .worktrees/docker-installer
docker build --build-arg COQUI_VERSION=<real-version> --build-arg COQUI_WEB_STUB=1 -t coqui-full-test .
docker run -d --name coqui-smoke -p 8080:8080 coqui-full-test
# wait for health
for i in $(seq 1 30); do
  curl -fsS http://localhost:8080/api/v1/health >/dev/null 2>&1 && break; sleep 2;
done
echo "--- root headers ---"; curl -sD - -o /dev/null http://localhost:8080/
echo "--- api health ---"; curl -fsS http://localhost:8080/api/v1/health
docker rm -f coqui-smoke
```
Expected: `/` returns `200` with `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`; `/api/v1/health` returns JSON containing `"status":"ok"`. If health never comes up, inspect `docker logs coqui-smoke` (common cause: wrong `coqui-console` path or a config the server rejects — remember boot tolerates missing config, so a hard failure points at the invocation, not the config).

- [ ] **Step 9: Commit**

```bash
cd .worktrees/docker-installer
git add docker/supervisord.conf docker/entrypoint.sh docker/openclaw.default.json Dockerfile tests/test_entrypoint.bats
git commit -m "feat(docker): supervisord + entrypoint, first-run config, healthcheck

Runs the CAP API (COQUI_LAUNCHER_MANAGED=1, autorestart=unexpected/exitcodes=0,130
so the app's restart-exit-10 relaunches while the container stays up) and Caddy
under supervisord. Entrypoint scaffolds openclaw.json on first run and ensures the
persistent workspace/data dirs. HEALTHCHECK hits the public /api/v1/health."
```

---

### Task 6: compose.yaml — canonical, wrapper-free

**Files:**
- Create: `compose.yaml`
- Test: `tests/test_compose.bats` (static validation of the compose contract)

**Interfaces:**
- Consumes: the image contract from Tasks 3–5 (`ghcr.io/carmelosantana/coqui`, port 8080, mounts `/config` + `/data`).
- Produces: a wrapper-free compose file so `docker compose up` → `http://localhost:8080` works with no install script. One `coqui` service, published port `${COQUI_PORT:-8080}:8080`, bind mount `./config:/config`, named volume `coqui-data:/data`, `restart: unless-stopped`, `extra_hosts: host.docker.internal:host-gateway` (Linux) so the default Ollama pointer resolves.

- [ ] **Step 1: Write the failing test**

Create `tests/test_compose.bats`:

```bash
#!/usr/bin/env bats

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; COMPOSE="$ROOT/compose.yaml"; }

@test "compose.yaml exists and is valid YAML" {
    [ -f "$COMPOSE" ]
    python3 -c "import yaml; yaml.safe_load(open('$COMPOSE'))"
}

@test "declares a single coqui service on the ghcr image" {
    run python3 -c "import yaml; d=yaml.safe_load(open('$COMPOSE')); print(list(d['services']))"
    [[ "$output" == *"coqui"* ]]
    grep -q 'ghcr.io/carmelosantana/coqui' "$COMPOSE"
}

@test "publishes port 8080 and persists config + data" {
    grep -qE '8080:8080|:8080"' "$COMPOSE"
    grep -q '/config' "$COMPOSE"
    grep -q '/data' "$COMPOSE"
    grep -q 'restart: unless-stopped' "$COMPOSE"
}

@test "documents host.docker.internal for Linux" {
    grep -q 'host-gateway' "$COMPOSE"
}

@test "docker compose config parses (if docker is available)" {
    if ! command -v docker >/dev/null 2>&1; then skip "docker not installed"; fi
    run docker compose -f "$COMPOSE" config
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd .worktrees/docker-installer && bats tests/test_compose.bats`
Expected: FAIL — `compose.yaml` does not exist.

- [ ] **Step 3: Write `compose.yaml`**

```yaml
# Canonical, wrapper-free Coqui stack.
#   docker compose up   →   open http://localhost:8080
#
# Model backend is BYO. The default config (scaffolded on first run) points at
# host Ollama via host.docker.internal:11434; edit ./config/openclaw.json to use
# a remote API provider instead.
services:
  coqui:
    image: ghcr.io/carmelosantana/coqui:${COQUI_TAG:-latest}
    ports:
      - "${COQUI_PORT:-8080}:8080"
    volumes:
      - ./config:/config
      - coqui-data:/data
    environment:
      # Override the published proxy port inside the container if you remap it.
      CADDY_PORT: "8080"
    # Linux: make host.docker.internal resolve to the host so the default
    # Ollama pointer works. (Docker Desktop on macOS/Windows provides this.)
    extra_hosts:
      - "host.docker.internal:host-gateway"
    restart: unless-stopped

volumes:
  coqui-data:
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd .worktrees/docker-installer && bats tests/test_compose.bats`
Expected: PASS (5 tests; the `docker compose config` test runs if docker is present, else skips).

- [ ] **Step 5: End-to-end compose smoke (local, requires docker)**

```bash
cd .worktrees/docker-installer
# Point the tag at the locally built image for the smoke run.
docker tag coqui-full-test ghcr.io/carmelosantana/coqui:latest
mkdir -p config
docker compose up -d
for i in $(seq 1 30); do curl -fsS http://localhost:8080/api/v1/health >/dev/null 2>&1 && break; sleep 2; done
curl -sD - -o /dev/null http://localhost:8080/ | grep -i 'cross-origin'
curl -fsS http://localhost:8080/api/v1/health
docker compose down
```
Expected: COOP/COEP headers printed; health JSON `"status":"ok"`. Confirms the wrapper-free path works.

- [ ] **Step 6: Commit**

```bash
cd .worktrees/docker-installer
git add compose.yaml tests/test_compose.bats
git commit -m "feat(docker): canonical wrapper-free compose.yaml

One coqui service on port 8080 with config bind-mount + persistent data volume,
restart: unless-stopped, and the Linux host-gateway mapping for the default
BYO Ollama pointer. docker compose up is a self-contained install path."
```

---

### Task 7: install.sh — Docker detection, `--native` flag, and dispatch

**Files:**
- Modify: `install.sh` (add `detect_docker`, `docker_available`, extend `parse_args` for `--native`, add dispatch in `main`)
- Modify: `tests/test_install.bats` (cover the new detection + dispatch)

**Interfaces:**
- Consumes: existing install.sh helpers (`available`, `status`, `warn`, `fatal`, `setup_sudo`, `$SUDO`).
- Produces:
  - `detect_docker` — sets `DOCKER_OK=1` if `docker` + `docker compose` v2 both work (respecting sudo), else `DOCKER_OK=0`; sets `DOCKER_NEEDS_SUDO=1` when docker only works via sudo.
  - `docker_available` — returns 0 iff `DOCKER_OK=1`.
  - `parse_args` recognizes `--native` (sets `FORCE_NATIVE=1`) and keeps `--dev`, `--help`, the `--install-*` flags.
  - `main` chooses the Docker path unless `FORCE_NATIVE=1` or Docker is unavailable, in which case it runs the existing native flow.

**Context:** The native flow (`install_release`/`update_release`/`install_dev`, OS+package-manager detection, extension checks) already exists and is preserved. This task only adds the Docker branch decision; Task 8 implements the Docker branch body.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_install.bats` (follow the existing idiom that sources the real functions by stripping the trailing `main "$@"` line):

```bash
@test "parse_args accepts --native and sets FORCE_NATIVE" {
    run bash -c '
      source <(awk "NR>1 { print prev } { prev=\$0 }" install.sh)
      parse_args --native
      echo "FORCE_NATIVE=$FORCE_NATIVE"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"FORCE_NATIVE=1"* ]]
}

@test "docker_available reflects DOCKER_OK" {
    run bash -c '
      source <(awk "NR>1 { print prev } { prev=\$0 }" install.sh)
      DOCKER_OK=1; docker_available && echo yes || echo no
      DOCKER_OK=0; docker_available && echo yes || echo no
    '
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "yes" ]]
    [[ "${lines[1]}" == "no" ]]
}

@test "detect_docker sets DOCKER_OK=1 when docker+compose present" {
    STUB="$(mktemp -d)"
    cat > "$STUB/docker" <<'EOF'
#!/bin/sh
# `docker compose version` succeeds; `docker version` succeeds.
[ "$1" = "compose" ] && { echo "Docker Compose version v2.29.0"; exit 0; }
exit 0
EOF
    chmod +x "$STUB/docker"
    run bash -c '
      source <(awk "NR>1 { print prev } { prev=\$0 }" install.sh)
      detect_docker
      echo "DOCKER_OK=$DOCKER_OK"
    ' 
    # Prepend stub dir so the fake docker wins.
    PATH="$STUB:$PATH" run bash -c '
      source <(awk "NR>1 { print prev } { prev=\$0 }" install.sh)
      detect_docker
      echo "DOCKER_OK=$DOCKER_OK"
    '
    [[ "$output" == *"DOCKER_OK=1"* ]]
    rm -rf "$STUB"
}

@test "detect_docker sets DOCKER_OK=0 when docker missing" {
    # Empty PATH (plus coreutils dir) so `docker` is not found.
    run bash -c '
      source <(awk "NR>1 { print prev } { prev=\$0 }" install.sh)
      detect_docker
      echo "DOCKER_OK=$DOCKER_OK"
    '
    [[ "$output" == *"DOCKER_OK=0"* ]]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd .worktrees/docker-installer && bats tests/test_install.bats -f 'native|docker'`
Expected: FAIL — `detect_docker`/`docker_available`/`--native` not defined.

- [ ] **Step 3: Add the `--native` flag to `parse_args`**

In `parse_args` (install.sh ~line 57), add a case arm alongside the existing `--dev` arm:

```bash
        --native)
            FORCE_NATIVE=1
            ;;
```

And in the config block near the top (with the other defaults like `DEV_MODE`), add:

```bash
FORCE_NATIVE=0
DOCKER_OK=0
DOCKER_NEEDS_SUDO=0
```

- [ ] **Step 4: Add `detect_docker` and `docker_available`**

Add these functions (e.g. just after `detect_os`):

```bash
# Detect Docker Engine + Compose v2. Respects sudo: if docker only works under
# sudo, DOCKER_OK still becomes 1 but DOCKER_NEEDS_SUDO is set so callers can
# message the user (never silently sudo).
detect_docker() {
    DOCKER_OK=0
    DOCKER_NEEDS_SUDO=0

    if ! available docker; then
        return 0
    fi

    # Does `docker compose` (v2 plugin) exist and does the daemon respond?
    if docker compose version >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
        DOCKER_OK=1
        return 0
    fi

    # Daemon may require sudo (user not in docker group).
    if [ -n "${SUDO:-}" ] && $SUDO docker compose version >/dev/null 2>&1 && $SUDO docker version >/dev/null 2>&1; then
        DOCKER_OK=1
        DOCKER_NEEDS_SUDO=1
        return 0
    fi

    return 0
}

docker_available() {
    [ "${DOCKER_OK:-0}" = "1" ]
}
```

- [ ] **Step 5: Add the dispatch in `main`**

In `main` (install.sh ~line 1085), immediately after `parse_args "$@"`, `detect_os`, and `setup_sudo` have run (and before the native install sequence begins), insert the Docker-branch decision. The native path must remain reachable:

```bash
    # ── Install-path selection ─────────────────────────────────────────────
    # Docker is primary. Fall back to native only when forced or unavailable.
    if [ "${FORCE_NATIVE:-0}" != "1" ]; then
        detect_docker
        if docker_available; then
            install_docker_stack    # implemented in Task 8
            return 0
        fi
        warn "Docker (with 'docker compose') was not found — falling back to the native install."
        warn "Install Docker for the recommended experience, or pass --native to silence this."
    fi
    # ...existing native install flow continues below unchanged...
```

(If `main` uses `exit 0` rather than `return 0` at its end, match that convention — use `exit 0` after `install_docker_stack`.)

- [ ] **Step 6: Add a temporary stub so the file is sourceable/testable before Task 8**

So install.sh remains valid between tasks, add a minimal stub (Task 8 replaces its body):

```bash
install_docker_stack() {
    fatal "install_docker_stack not yet implemented"
}
```

- [ ] **Step 7: Run the tests + shellcheck**

Run: `cd .worktrees/docker-installer && bats tests/test_install.bats -f 'native|docker' && shellcheck --severity=warning install.sh`
Expected: the 4 new tests PASS; shellcheck clean.

- [ ] **Step 8: Commit**

```bash
cd .worktrees/docker-installer
git add install.sh tests/test_install.bats
git commit -m "feat(install): Docker detection + --native flag + dispatch

install.sh now prefers the Docker path when docker + compose v2 are available
(detecting the sudo-required case explicitly), and falls back to the existing
native Linux/macOS flow when Docker is absent or --native is passed."
```

---

### Task 8: install.sh — Docker stack scaffolding, pull, up, and the `coqui` wrapper

**Files:**
- Create: `coqui.wrapper.sh` (the installed `coqui` CLI wrapper template)
- Modify: `install.sh` (implement `install_docker_stack`, scaffold compose+config, install wrapper)
- Modify: `tests/test_install.bats` (cover scaffolding + wrapper install)

**Interfaces:**
- Consumes: `detect_docker`/`DOCKER_OK`/`DOCKER_NEEDS_SUDO` (Task 7), `$COQUI_INSTALL_DIR` (default `~/.coqui`), `detect_bin_dir`/`$BIN_DIR`, `status`/`success`/`warn`.
- Produces:
  - `install_docker_stack` — creates `$COQUI_INSTALL_DIR` with `compose.yaml` (copied from the repo or written inline), `config/`, pulls the image, runs `docker compose up -d`, installs the `coqui` wrapper into `$BIN_DIR`, prints the URL. Honors `DOCKER_NEEDS_SUDO` (passes sudo through the wrapper + messages the user).
  - `coqui.wrapper.sh` — a wrapper supporting: `coqui` / `coqui up` (up -d + print URL), `coqui status` (compose ps), `coqui stop`, `coqui restart`, `coqui logs`, `coqui update` (pull + up -d). It reads `COQUI_HOME` (the install dir with compose.yaml) and an optional `COQUI_SUDO` prefix.

**Context:** the wrapper drives `docker compose` against the scaffolded `compose.yaml`; it does NOT re-implement container logic. `coqui restart` restarts the whole compose service (distinct from the in-app `POST /server/restart`, which restarts just the API process inside the running container).

- [ ] **Step 1: Write the failing tests for the wrapper**

Create `tests/test_wrapper.bats`:

```bash
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd .worktrees/docker-installer && bats tests/test_wrapper.bats`
Expected: FAIL — `coqui.wrapper.sh` does not exist.

- [ ] **Step 3: Write `coqui.wrapper.sh`**

```bash
#!/usr/bin/env bash
# Coqui CLI wrapper — drives the Dockerized stack via docker compose.
# Installed to your PATH as `coqui` by install.sh. COQUI_HOME points at the
# install dir that holds compose.yaml; COQUI_SUDO is an optional prefix (e.g. "sudo").
set -euo pipefail

COQUI_HOME="${COQUI_HOME:-$HOME/.coqui}"
COQUI_SUDO="${COQUI_SUDO:-}"
COQUI_PORT="${COQUI_PORT:-8080}"

compose() {
    # shellcheck disable=SC2086
    $COQUI_SUDO docker compose -f "$COQUI_HOME/compose.yaml" "$@"
}

url() { echo "http://localhost:${COQUI_PORT}"; }

cmd="${1:-up}"
case "$cmd" in
    up|"")
        compose up -d
        echo "Coqui is up — open $(url)"
        ;;
    status) compose ps ;;
    stop)   compose stop ;;
    restart) compose restart ;;
    logs)   shift; compose logs "${@:-}" ;;
    update)
        compose pull
        compose up -d
        echo "Coqui updated — open $(url)"
        ;;
    -h|--help|help)
        cat <<EOF
Usage: coqui <command>
  up        Start the stack (default) and print the URL
  status    Show container status (docker compose ps)
  stop      Stop the stack
  restart   Restart the stack
  logs      Tail container logs
  update    Pull the newest image and recreate
EOF
        ;;
    *)
        echo "Unknown command: $cmd (try: coqui --help)" >&2
        exit 1
        ;;
esac
```

- [ ] **Step 4: Run the wrapper tests to verify they pass**

Run: `cd .worktrees/docker-installer && bats tests/test_wrapper.bats`
Expected: PASS (5 tests).

- [ ] **Step 5: Write the failing test for `install_docker_stack` scaffolding**

Add to `tests/test_install.bats`:

```bash
@test "install_docker_stack scaffolds compose + config + wrapper" {
    STUB="$(mktemp -d)"
    export COQUI_INSTALL_DIR="$(mktemp -d)/home"
    export BIN_DIR="$(mktemp -d)/bin"
    cat > "$STUB/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$STUB/docker"
    run env PATH="$STUB:$PATH" bash -c '
      source <(awk "NR>1 { print prev } { prev=\$0 }" install.sh)
      DOCKER_OK=1; DOCKER_NEEDS_SUDO=0
      BIN_DIR="'"$BIN_DIR"'"
      install_docker_stack
    '
    [ "$status" -eq 0 ]
    [ -f "$COQUI_INSTALL_DIR/compose.yaml" ]
    [ -d "$COQUI_INSTALL_DIR/config" ]
    [ -x "$BIN_DIR/coqui" ]
}
```

- [ ] **Step 6: Implement `install_docker_stack` (replace the Task 7 stub)**

Replace the stub body with the real implementation. It copies `compose.yaml` and `coqui.wrapper.sh` from the script's own directory when run locally, or writes them inline when piped via curl (so both `curl | bash` and `./install.sh` work):

```bash
install_docker_stack() {
    status "Setting up the Coqui Docker stack in ${COQUI_INSTALL_DIR}..."
    mkdir -p "$COQUI_INSTALL_DIR/config"

    local sudo_prefix=""
    if [ "${DOCKER_NEEDS_SUDO:-0}" = "1" ]; then
        sudo_prefix="sudo"
        warn "Docker requires sudo on this machine. The 'coqui' wrapper will run docker with sudo."
        warn "To avoid this, add your user to the 'docker' group and re-log in."
    fi

    # Resolve the directory this script lives in (empty when piped via stdin).
    local script_dir=""
    if [ -n "${BASH_SOURCE:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi

    # compose.yaml — copy from repo if present, else download the canonical file.
    if [ -n "$script_dir" ] && [ -f "$script_dir/compose.yaml" ]; then
        cp "$script_dir/compose.yaml" "$COQUI_INSTALL_DIR/compose.yaml"
    else
        curl -fsSL "https://raw.githubusercontent.com/carmelosantana/coqui-installer/main/compose.yaml" \
            -o "$COQUI_INSTALL_DIR/compose.yaml" \
            || fatal "Could not obtain compose.yaml"
    fi

    # coqui wrapper — same source resolution.
    detect_bin_dir
    mkdir -p "$BIN_DIR"
    local wrapper_src=""
    if [ -n "$script_dir" ] && [ -f "$script_dir/coqui.wrapper.sh" ]; then
        wrapper_src="$script_dir/coqui.wrapper.sh"
    fi
    if [ -n "$wrapper_src" ]; then
        cp "$wrapper_src" "$BIN_DIR/coqui"
    else
        curl -fsSL "https://raw.githubusercontent.com/carmelosantana/coqui-installer/main/coqui.wrapper.sh" \
            -o "$BIN_DIR/coqui" \
            || fatal "Could not obtain the coqui wrapper"
    fi
    chmod +x "$BIN_DIR/coqui"

    # Bake COQUI_HOME + optional sudo into the installed wrapper so it is self-contained.
    {
        echo "#!/usr/bin/env bash"
        echo "export COQUI_HOME=\"$COQUI_INSTALL_DIR\""
        [ -n "$sudo_prefix" ] && echo "export COQUI_SUDO=\"$sudo_prefix\""
        tail -n +2 "$BIN_DIR/coqui"
    } > "$BIN_DIR/coqui.tmp" && mv "$BIN_DIR/coqui.tmp" "$BIN_DIR/coqui"
    chmod +x "$BIN_DIR/coqui"

    # Pull + start (skipped cleanly if the fake docker in tests is a no-op).
    status "Pulling the Coqui image and starting the stack..."
    ${sudo_prefix} docker compose -f "$COQUI_INSTALL_DIR/compose.yaml" pull || true
    ${sudo_prefix} docker compose -f "$COQUI_INSTALL_DIR/compose.yaml" up -d \
        || fatal "docker compose up failed"

    success "Coqui is running — open http://localhost:8080"
    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
        warn "${BIN_DIR} is not in your PATH; add it to use the 'coqui' command."
    fi
}
```

- [ ] **Step 7: Run all install tests + shellcheck**

Run: `cd .worktrees/docker-installer && bats tests/test_install.bats && bats tests/test_wrapper.bats && shellcheck --severity=warning install.sh coqui.wrapper.sh`
Expected: all PASS; shellcheck clean. (If shellcheck flags the `${sudo_prefix} docker` word-splitting, add `# shellcheck disable=SC2086` above those lines — the split is intentional.)

- [ ] **Step 8: Commit**

```bash
cd .worktrees/docker-installer
git add install.sh coqui.wrapper.sh tests/test_install.bats tests/test_wrapper.bats
git commit -m "feat(install): Docker stack scaffolding + coqui wrapper

install_docker_stack scaffolds compose.yaml + config/, pulls the image, brings
the stack up, and installs a self-contained coqui wrapper (up/status/stop/
restart/logs/update) with COQUI_HOME baked in and sudo handled explicitly."
```

---

### Task 9: uninstall.sh — tear down the Docker stack, keep native removal

**Files:**
- Modify: `uninstall.sh`
- Modify: `tests/test_uninstall.bats`

**Interfaces:**
- Consumes: existing uninstall helpers + `$COQUI_INSTALL_DIR`, `--force`, `--remove-workspace`.
- Produces: `uninstall_docker_stack` — if `$COQUI_INSTALL_DIR/compose.yaml` exists, runs `docker compose down` (with `-v` only when `--remove-workspace`), removes the installed `coqui` wrapper, and (respecting the existing workspace-preservation contract) removes the scaffolded compose/config. `main` calls it before/instead of the native removal when the stack is present.

**Context:** The existing uninstaller preserves workspace data by default and only removes PHP/Composer with `--all`. The Docker path mirrors this: containers/images are removed, but the persistent `coqui-data` volume is kept unless `--remove-workspace` is passed.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_uninstall.bats`:

```bash
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
      FORCE=1; REMOVE_WORKSPACE=0
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
      FORCE=1; REMOVE_WORKSPACE=1
      uninstall_docker_stack
    '
    grep -qE 'compose .* down .*-v|compose .* down.* --volumes' "$RECORD"
    rm -rf "$STUB"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd .worktrees/docker-installer && bats tests/test_uninstall.bats -f 'docker'`
Expected: FAIL — `uninstall_docker_stack` not defined.

- [ ] **Step 3: Implement `uninstall_docker_stack`**

Add to `uninstall.sh` (match the existing variable names for `FORCE`/`REMOVE_WORKSPACE`/`BIN_DIR`; if the existing script uses different names, adapt):

```bash
uninstall_docker_stack() {
    local compose_file="${COQUI_INSTALL_DIR}/compose.yaml"
    [ -f "$compose_file" ] || return 1   # not a Docker install

    status "Stopping the Coqui Docker stack..."
    local down_args="down"
    if [ "${REMOVE_WORKSPACE:-0}" = "1" ]; then
        down_args="down -v"
        warn "Removing the persistent data volume (sessions will be lost)."
    fi
    # shellcheck disable=SC2086
    docker compose -f "$compose_file" $down_args || warn "docker compose down failed (continuing)."

    # Remove the installed wrapper.
    detect_bin_dir 2>/dev/null || true
    if [ -n "${BIN_DIR:-}" ] && [ -e "${BIN_DIR}/coqui" ]; then
        rm -f "${BIN_DIR}/coqui"
        success "Removed the coqui wrapper."
    fi

    # Remove scaffolded compose/config; keep workspace data unless requested.
    rm -f "$compose_file"
    if [ "${REMOVE_WORKSPACE:-0}" = "1" ]; then
        rm -rf "${COQUI_INSTALL_DIR}/config"
    fi
    success "Docker stack removed."
    return 0
}
```

- [ ] **Step 4: Wire it into `main`**

In uninstall.sh `main`, before the native removal path, attempt the Docker teardown and skip native removal if it handled things:

```bash
    if [ -f "${COQUI_INSTALL_DIR}/compose.yaml" ]; then
        uninstall_docker_stack && return 0
    fi
    # ...existing native uninstall flow continues...
```

- [ ] **Step 5: Run tests + shellcheck**

Run: `cd .worktrees/docker-installer && bats tests/test_uninstall.bats && shellcheck --severity=warning uninstall.sh`
Expected: all PASS; shellcheck clean.

- [ ] **Step 6: Commit**

```bash
cd .worktrees/docker-installer
git add uninstall.sh tests/test_uninstall.bats
git commit -m "feat(uninstall): tear down the Docker stack, preserve data by default

Detects a Docker install via compose.yaml, runs docker compose down (with -v only
when --remove-workspace), removes the coqui wrapper, and keeps the native removal
path for native installs."
```

---

### Task 10: CI — build the image, boot the container, smoke-assert the contract

**Files:**
- Create: `.github/workflows/docker-image.yml`
- Modify: `.github/workflows/test-installer.yml` (add the new bats files to the linux/macos runs)

**Interfaces:**
- Consumes: the Dockerfile + compose from Tasks 3–6.
- Produces: a CI job that builds the image with `COQUI_WEB_STUB=1` (CI does not depend on a published web release), boots it, and asserts `GET /` returns 200 with COOP/COEP headers and `GET /api/v1/health` (via the proxy) returns a healthy JSON body.

**Context:** CI uses the web stub so it is decoupled from the coqui-app release timing (D1). Once coqui-app publishes `Coqui-<ver>-web.tar.gz`, a follow-up can switch CI to fetch the real bundle. The server release version must be a real published tag — resolve it in the workflow via the GitHub API.

- [ ] **Step 1: Write `.github/workflows/docker-image.yml`**

```yaml
name: Docker Image

on:
  push:
    branches: ["main"]
    paths:
      - "Dockerfile"
      - "docker/**"
      - "compose.yaml"
      - ".github/workflows/docker-image.yml"
  pull_request:
    branches: ["main"]
    paths:
      - "Dockerfile"
      - "docker/**"
      - "compose.yaml"
      - ".github/workflows/docker-image.yml"

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-and-smoke:
    name: Build image + container smoke
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Resolve latest coqui server version
        id: ver
        run: |
          V="$(curl -fsSL https://api.github.com/repos/carmelosantana/coqui/releases/latest \
               | grep '"tag_name"' | head -1 | sed 's/.*"tag_name"[^"]*"\([^"]*\)".*/\1/')"
          V="${V#v}"
          echo "version=$V" >> "$GITHUB_OUTPUT"
          echo "Resolved server version: $V"

      - name: Build image (web stub)
        run: |
          docker build \
            --build-arg COQUI_VERSION="${{ steps.ver.outputs.version }}" \
            --build-arg COQUI_WEB_STUB=1 \
            -t coqui-ci:smoke .

      - name: Boot container
        run: docker run -d --name coqui-ci -p 8080:8080 coqui-ci:smoke

      - name: Wait for health
        run: |
          for i in $(seq 1 40); do
            if curl -fsS http://localhost:8080/api/v1/health >/dev/null 2>&1; then
              echo "healthy after ${i} tries"; exit 0
            fi
            sleep 3
          done
          echo "container did not become healthy"; docker logs coqui-ci; exit 1

      - name: Assert / serves with COOP/COEP
        run: |
          headers="$(curl -sD - -o /dev/null http://localhost:8080/)"
          echo "$headers"
          echo "$headers" | grep -iq '^HTTP/.* 200' || { echo "no 200 on /"; exit 1; }
          echo "$headers" | grep -iq 'Cross-Origin-Opener-Policy: *same-origin' || { echo "missing COOP"; exit 1; }
          echo "$headers" | grep -iq 'Cross-Origin-Embedder-Policy: *require-corp' || { echo "missing COEP"; exit 1; }

      - name: Assert /api/* proxies to a healthy API
        run: |
          body="$(curl -fsS http://localhost:8080/api/v1/health)"
          echo "$body"
          echo "$body" | grep -q '"status":"ok"' || { echo "api health not ok"; exit 1; }

      - name: Dump logs on failure
        if: failure()
        run: docker logs coqui-ci || true

      - name: Teardown
        if: always()
        run: docker rm -f coqui-ci || true
```

- [ ] **Step 2: Add the new bats files to the installer test workflow**

In `.github/workflows/test-installer.yml`, update the `Run install tests` / `Run uninstall tests` steps in BOTH `test-linux` and `test-macos` to also run the new suites. Replace the two run steps with:

```yaml
      - name: Run bats test suites
        run: |
          bats --tap tests/test_install.bats
          bats --tap tests/test_uninstall.bats
          bats --tap tests/test_wrapper.bats
          bats --tap tests/test_no_powershell.bats
          bats --tap tests/test_fetch_coqui.bats
          bats --tap tests/test_fetch_web.bats
          bats --tap tests/test_entrypoint.bats
          bats --tap tests/test_compose.bats
```

Also add `- "Dockerfile"`, `- "docker/**"`, `- "compose.yaml"` to the `paths:` filters is NOT needed here (that is the docker workflow's concern) — leave test-installer paths as the shell/test set.

- [ ] **Step 3: Validate both workflows parse**

Run: `cd .worktrees/docker-installer && for f in .github/workflows/docker-image.yml .github/workflows/test-installer.yml; do python3 -c "import yaml; yaml.safe_load(open('$f')); print('OK $f')"; done`
Expected: `OK` for both. If `actionlint` is available, run it on both.

- [ ] **Step 4: Local dry-run of the smoke assertions (optional but recommended)**

Run the exact build+boot+assert sequence from Step 1 locally (as in Task 5 Step 8) to confirm the header/health greps match real output.
Expected: all assertions pass against the locally built stub image.

- [ ] **Step 5: Commit**

```bash
cd .worktrees/docker-installer
git add .github/workflows/docker-image.yml .github/workflows/test-installer.yml
git commit -m "ci(docker): build image + container smoke (COOP/COEP + /api proxy)

New workflow builds the image (web stub, decoupled from the coqui-app web
release), boots the container, and asserts / serves 200 with COOP/COEP and
/api/v1/health proxies to a healthy API. Also runs the full bats suite set."
```

---

### Task 11: README — Docker-primary rewrite, native fallback secondary

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the final contract of Tasks 3–9 (image, compose, install.sh, wrapper).
- Produces: a README whose primary path is `docker compose up` (and the optional `install.sh` wrapper), with the native Linux/macOS install documented as a clearly-labeled fallback, and ALL Windows/PowerShell/WSL references removed.

- [ ] **Step 1: Write the failing doc-guard test**

Create `tests/test_readme.bats`:

```bash
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cd .worktrees/docker-installer && bats tests/test_readme.bats`
Expected: FAIL — current README still has Windows/WSL content and no Docker section.

- [ ] **Step 3: Rewrite `README.md`**

Replace the file with a Docker-first structure. Required sections and exact content anchors the guard test checks:

```markdown
# Coqui Installer

Run [Coqui](https://github.com/carmelosantana/coqui) — a terminal AI agent with multi-model orchestration — as a single Docker container: the CAP API and the Flutter web UI behind one port.

## Quick start (Docker — recommended)

```bash
mkdir coqui && cd coqui
curl -fsSL https://raw.githubusercontent.com/carmelosantana/coqui-installer/main/compose.yaml -o compose.yaml
docker compose up -d
```

Then open <http://localhost:8080>.

The image is `ghcr.io/carmelosantana/coqui`. Config lives in `./config/openclaw.json` (scaffolded on first run); sessions and workspace data persist in the `coqui-data` volume.

### Model backend (bring your own)

No model runtime ships in the image. The default config points at host Ollama (`host.docker.internal:11434`). Edit `./config/openclaw.json` to point at a remote API provider instead. On Linux, the bundled `compose.yaml` already maps `host.docker.internal` via `host-gateway`.

## Install script (optional wrapper)

`install.sh` sets up the same Docker stack and adds a `coqui` command:

```bash
curl -fsSL https://raw.githubusercontent.com/carmelosantana/coqui-installer/main/install.sh | bash
```

`coqui` commands: `coqui` (up + URL), `coqui status`, `coqui stop`, `coqui restart`, `coqui logs`, `coqui update`.

## Native install (Linux/macOS fallback)

If Docker is not available, `install.sh` falls back to a native install (PHP 8.4 + the coqui extension set, release download with checksum verification). Force it with `--native`:

```bash
./install.sh --native
```

`--dev` clones the git repo instead of downloading a release (needs Git + Composer). Native requirements: PHP 8.4+, extensions `dom mbstring pdo_sqlite xml` (plus `curl readline gd pcntl posix`).

## Update

- Docker: `coqui update` (or `docker compose pull && docker compose up -d`).
- Native: re-run `./install.sh --native`.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/carmelosantana/coqui-installer/main/uninstall.sh | bash
```

Preserves the data volume by default; pass `--remove-workspace` to delete it.

## License

MIT
```

(Preserve/merge any still-accurate env-var or flag tables from the old README, but drop every Windows/WSL/PowerShell row.)

- [ ] **Step 4: Run the doc-guard test to verify it passes**

Run: `cd .worktrees/docker-installer && bats tests/test_readme.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Full test sweep**

Run: `cd .worktrees/docker-installer && bats tests/ && shellcheck --severity=warning install.sh uninstall.sh coqui.wrapper.sh docker/*.sh`
Expected: all bats suites PASS; shellcheck clean.

- [ ] **Step 6: Commit**

```bash
cd .worktrees/docker-installer
git add README.md tests/test_readme.bats
git commit -m "docs: Docker-first README, native fallback, purge Windows/WSL

Primary path is docker compose up (open localhost:8080); optional install.sh
wrapper documented; native Linux/macOS install kept as a labeled fallback
(--native). All PowerShell/WSL/winget references removed."
```

---

## Self-Review

**Spec coverage (design §§ + brief §2):**
- Dockerfile assembled-from-releases, checksum fail-closed, php:8.4 + extension parity, Caddy COOP/COEP + `/api` proxy, supervisor → Tasks 3–5. ✅
- compose.yaml canonical wrapper-free, port 8080, mounts, restart, BYO Ollama + `extra_hosts` → Task 6. ✅
- install.sh Docker-first + native fallback + `--native` + `--dev` + sudo handling + `coqui` wrapper → Tasks 7–8. ✅
- uninstall.sh updated → Task 9. ✅
- Remove all PowerShell/Windows-native + purge README → Tasks 2 & 11. ✅
- D1 coqui-app release.yml web tarball → Task 1. ✅
- CI image build + container smoke (COOP/COEP + `/api` health) + bash tests updated → Task 10 (+ suites throughout). ✅
- README Docker-primary → Task 11. ✅
- Open unknowns: U1 (Caddy front confirmed, API 127.0.0.1:3300) Tasks 4–5; U2 (first-run openclaw.json) Task 5 (+ provider-schema verify note); U3/D2 (restart exit-10 + supervisord) Task 5; U4 (COQUI_VERSION env + image label, /health version) Tasks 3–5; D3 (extensions) Task 3. ✅

**Placeholder scan:** every code/config step contains complete content; no TODO/TBD. The one deliberate verify-before-finalize item (Ollama provider key in Task 5) is flagged with a fail-safe (minimal valid config still boots) rather than left blank. ✅

**Type/name consistency:** `install_docker_stack` (Tasks 7 stub → 8 impl), `detect_docker`/`DOCKER_OK`/`DOCKER_NEEDS_SUDO`, `uninstall_docker_stack`, `COQUI_HOME`/`COQUI_SUDO` (wrapper), `/config` + `/data` mounts, `COQUI_VERSION`/`COQUI_APP_VERSION`/`WEB_TARBALL_URL`/`COQUI_WEB_STUB` build args, Caddy port `8080`, API `127.0.0.1:3300`, health `/api/v1/health` — all consistent across tasks. ✅

## Post-implementation: open the PRs

After all tasks pass, use **superpowers:finishing-a-development-branch** to open two PRs:
1. `coqui-installer` `feat/docker-installer` → `main` (Tasks 2–11).
2. `coqui-app` `feat/web-release-asset` → `main` (Task 1, D1) — note in the PR body that it must be rebased/coordinated with `fix/apple-build` but does not conflict.
