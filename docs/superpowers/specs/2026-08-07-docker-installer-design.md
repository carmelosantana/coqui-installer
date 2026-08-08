# Coqui Docker Installer — Design

> **Status:** Design approved 2026-08-07. Next step: a `prompt-agent-task` hand-off brief for a fresh
> agent to execute (not inline implementation).
> **Scope:** `coqui-installer` repo (with a small dependency on `coqui-app`'s release workflow). Make a
> single Docker container the primary install path — coqui **server + web app in one image** — with the
> app controlling the server over the API. Demote native install to a Linux/macOS fallback; remove all
> PowerShell. Unblock end-to-end testing.

## Goal

Replace the native-per-OS install model with a **Docker-first** experience: one image runs the coqui
server (CAP API) and serves the Flutter **web** UI behind a single-origin reverse proxy; `docker compose up`
and open a browser. The native `install.sh` remains as a secondary Linux/macOS fallback. The container
also becomes the reproducible stack that unblocks e2e testing.

## Context: what exists today

`coqui-installer` (repo `carmelosantana/coqui-installer`, local `/home/carmelo/Projects/CoquiBot/Core/coqui-installer`):

- `install.sh` (~1,227 lines): detects OS + package manager (`apt|brew|dnf|yum|pacman|apk|nix|winget`),
  installs PHP 8.4+ and the coqui extension set, downloads the release asset
  `coqui-v<version>.tar.gz` (+ `.sha256` sidecar, fail-closed checksum verify) from
  `https://github.com/carmelosantana/coqui/releases/download/...`, wires the `coqui` command onto PATH.
  Flags: `--dev` (git clone instead of release), `--help`.
- `install.ps1`: Windows **WSL2 bootstrap** — checks/installs WSL2 + Ubuntu, then runs `install.sh` inside WSL.
- `install-native.ps1`: deprecated native Windows install.
- `uninstall.sh`, `uninstall.ps1`, `uninstall-native.ps1`.
- `tests/`: `test_install.bats`, `test_uninstall.bats`, `test_install.ps1`, `test_install_native.ps1`,
  `test_uninstall.ps1`, `test_uninstall_native.ps1`, `WINDOWS-SMOKE-CHECKLIST.md`.
- `docs/NATIVE-WINDOWS-DEPRECATED.md`.

After install, `coqui` runs the launcher-managed app: REPL foreground + CAP API background
(`coqui`, `coqui --api-only`, `coqui status`).

`coqui-app` (Flutter client, repo `carmelosantana/coqui-app`): its `release.yml` builds a web bundle with
`flutter build web --wasm --release --base-href /`, uploads it as the CI artifact **`web-build`**, and
deploys it to Vercel — but does **not** attach a web bundle to the GitHub **release** (the release-assets
step copies only apk/linux/windows/dmg/ipa).

## Decisions (locked during brainstorming, 2026-08-07)

1. **App delivery:** the single container serves the Flutter **web** build (browser UI), alongside the server.
2. **Control plane:** an **in-container supervisor** runs the server; the app restarts/reloads it over the
   **CAP API**. Config + workspace are Docker bind-mounts set at `compose up`; the app manages contents
   within them, not the mounts themselves. **No Docker socket exposed.**
3. **Entry point:** **both** — a wrapper-free `compose.yaml` + `docker compose up` is the canonical path
   (frontend access is the priority; sidesteps sudo-for-Docker friction), and `install.sh` layers an
   optional `coqui` CLI wrapper on top for those who want it. Both land on the same container.
4. **Image build:** **assemble prebuilt release artifacts** — Dockerfile fetches the coqui server release
   tarball + the coqui-app web build and lays them in. No source build; image tag tracks release versions.
5. **Model backend:** **BYO / external provider** — no model runtime in the image; default config points at
   a configured provider (host Ollama `host.docker.internal:11434` or a remote API via keys in the mounted config).
6. **Windows / native:** **Docker only on Windows.** Remove ALL PowerShell (`install-native.ps1`,
   `install.ps1`, `uninstall-native.ps1`, `uninstall.ps1`, `tests/*.ps1`, `docs/NATIVE-WINDOWS-DEPRECATED.md`,
   `tests/WINDOWS-SMOKE-CHECKLIST.md`). Keep `install.sh`/`uninstall.sh` as the native Linux/macOS fallback.

## Architecture

### 1. The image (`ghcr.io/carmelosantana/coqui`)

- Base `php:8.4` (Debian slim) + the coqui extension set (mirror what `install.sh` installs).
- **Assembled from prebuilt releases** at build time:
  - coqui server: fetch `coqui-v<version>.tar.gz` + `.sha256` from the coqui release, verify checksum
    (fail-closed, same as `install.sh`), extract into the app dir.
  - coqui-app web: fetch the **web build artifact** (see Dependency D1) and place it where the proxy serves it.
- **Reverse proxy (Caddy)** fronts everything on one port: serves the web UI at `/`, reverse-proxies
  `/api/*` to the coqui API on an internal port. **Single-origin ⇒ the web app needs no CORS config.**
  - The web bundle is built `--wasm`, which requires **cross-origin isolation headers**
    (`Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: require-corp` or
    `credentialless`) on the document response. The proxy MUST set these, or WASM threading breaks.
- **Supervisor** (s6-overlay or supervisord) runs (a) the coqui API process and (b) Caddy. Chosen so the
  server process can be restarted independently while the container stays up.
- Image tag tracks the coqui server release version (and records the bundled app version).

### 2. compose.yaml (canonical, wrapper-free)

- One service `coqui`, image `ghcr.io/carmelosantana/coqui:<tag>`.
- One published port (default host `8080` → container proxy port; configurable via env).
- Bind mounts set at `compose up`:
  - **config** → the coqui config dir (`openclaw.json`, credentials).
  - **workspace** → the coqui workspace.
  - **data** (named volume or bind) → the sessions SQLite + other persistent state, so it survives restarts.
- `restart: unless-stopped`.
- Model backend is BYO: config (in the mounted config dir) selects the provider; default points at
  `host.docker.internal:11434` (host Ollama) with remote-API config supported. On Linux, document the
  `extra_hosts: ["host.docker.internal:host-gateway"]` needed for host.docker.internal to resolve.
- `docker compose up` then open `http://localhost:8080`. This path is self-contained — no wrapper required.

### 3. install.sh (rewritten) + `coqui` wrapper (optional layer)

- **Docker path (primary):** detect Docker (and `docker compose`); pull the image; scaffold `compose.yaml`
  + `config/` + `workspace/` dirs in an install location; install a `coqui` shell wrapper that drives
  `docker compose`; `docker compose up -d`; print the URL. Handle the case where Docker needs `sudo`
  (detect, message clearly, don't silently fail).
- **`coqui` wrapper commands (optional):** `coqui` (up + report URL), `coqui status` (compose ps/health),
  `coqui stop`, `coqui restart`, `coqui logs`, `coqui update` (pull newer image + recreate). This preserves
  the `coqui` CLI ergonomics against the container.
- **Native fallback:** if Docker is absent (or `--native` is passed), run the existing native Linux/macOS
  flow. `--dev` stays as-is for the native path.
- README rewritten: Docker primary (compose + optional `install.sh`), native fallback documented as secondary.

### 4. Removals (no-legacy clean cut)

Delete: `install-native.ps1`, `install.ps1`, `uninstall-native.ps1`, `uninstall.ps1`, `tests/test_install.ps1`,
`tests/test_install_native.ps1`, `tests/test_uninstall.ps1`, `tests/test_uninstall_native.ps1`,
`tests/WINDOWS-SMOKE-CHECKLIST.md`, `docs/NATIVE-WINDOWS-DEPRECATED.md`, and the
`.github/PSScriptAnalyzerSettings.psd1` + any PowerShell CI. Purge Windows-native references from README.

### 5. e2e payoff

A CI compose (or the shipped `compose.yaml` with a test override) brings the container up with a stub/mock
provider (no real model calls); the Flutter web UI + CAP API are reachable at `localhost`, giving a
reproducible stack e2e tests run against. (Prior CAP e2e work stood up an ad-hoc ollama + coqui-api:3300 +
Flutter-web stack; this image is the durable replacement.)

## Data flow

1. `docker compose up` → supervisor starts coqui API (internal) + Caddy (published port).
2. Browser → Caddy `/` → Flutter web UI (COOP/COEP headers set); UI calls `/api/*` → Caddy proxies to the
   coqui API (same origin, no CORS).
3. App "restart server" → CAP API endpoint → supervisor restarts the API process; container stays up; Caddy
   keeps serving the UI.
4. Config/workspace/data live on host bind-mounts, so edits and sessions persist across restarts and image updates.

## Dependencies & prerequisites

- **D1 (blocking the image build): coqui-app must publish a fetchable web build.** Today the web bundle is
  only a CI artifact (`web-build`) + Vercel deploy; it is not a release asset. The task must make the web
  build fetchable for the Dockerfile — **preferred:** add `Coqui-<version>-web.tar.gz` (tar of `build/web/`)
  to coqui-app's `release.yml` release-assets step, so the Dockerfile pulls it by release tag exactly like
  the server tarball. (Alternative: pin a commit and download the CI artifact — messier; avoid.)
- **D2: a server "restart" control the supervisor can honor.** Confirm/define how the app triggers a server
  process restart in-container: either an existing CAP restart endpoint the supervisor observes (process
  exits → supervisor restarts), or a documented mechanism. Verify against coqui core before wiring; do not
  invent an endpoint the server doesn't serve.
- **D3: extension parity.** The image's PHP extensions must match what `install.sh` installs for coqui to run.

## Open unknowns (resolve during planning, don't assume away)

- **U1 — server-side static serving vs. proxy:** confirmed approach is a Caddy front + API behind. Verify the
  coqui API's base path/port and that it does NOT itself need to serve the web assets. If the API already has
  a static-serving mode, reconsider whether Caddy is still the simplest single-origin answer.
- **U2 — config bootstrapping:** what minimal `openclaw.json` must be scaffolded on first `compose up` so the
  container boots without a pre-existing config (default provider pointer, workspace path). Define the
  first-run default.
- **U3 — restart mechanism (see D2):** exact wiring is unverified until checked against coqui core.
- **U4 — image versioning:** tag scheme when server and app versions differ (server release drives the tag;
  bundled app version recorded in an image label / `/version`).

## Testing & validation

- `install.sh` bash tests (`tests/test_install.bats`, `tests/test_uninstall.bats`) updated for the
  Docker-detection + native-fallback branching; PowerShell tests removed.
- Image build validated in CI (GitHub Action in `coqui-installer`): builds the image, boots the container,
  asserts the web UI responds at `/` (with COOP/COEP headers) and `/api/*` proxies to a healthy API.
- `compose.yaml` smoke: `docker compose up` → HTTP 200 on `/` and an API health endpoint.
- e2e stack (D-payoff) runs against the container with a stub provider.

## Where the pieces live

- `Dockerfile`, `compose.yaml`, rewritten `install.sh`/`uninstall.sh`, `coqui` wrapper, and the image-build +
  container-smoke GitHub Action all live in **`coqui-installer`**. Image published to
  `ghcr.io/carmelosantana/coqui`.
- The single cross-repo change is **D1** in **`coqui-app`** (`release.yml` web asset).

## Out of scope / deferred

- No bundled model runtime (BYO only); the optional-Ollama-service idea is explicitly not built now.
- No Docker-socket / container-lifecycle control from the app (process-level restart only).
- No Windows native or WSL bootstrap (removed).
- The Discord-UI redesign is unrelated and remains separately deferred.
