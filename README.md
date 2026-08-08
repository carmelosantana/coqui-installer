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

> **Security — host-only by default.** The stack binds to `127.0.0.1` (loopback), so it is reachable only from this machine. The API is **unauthenticated**: to expose it on your LAN/server set `COQUI_BIND=0.0.0.0` (e.g. `COQUI_BIND=0.0.0.0 docker compose up -d`) and put it behind your own auth/reverse proxy — anyone who can reach the port can use the API.

### Model backend (bring your own)

No model runtime ships in the image. The default config points at host Ollama (`host.docker.internal:11434`). Edit `./config/openclaw.json` to point at a remote API provider instead. On Linux, the bundled `compose.yaml` already maps `host.docker.internal` via `host-gateway`.

## Install script (optional wrapper)

`install.sh` sets up the same Docker stack and adds a `coqui` command:

```bash
curl -fsSL https://raw.githubusercontent.com/carmelosantana/coqui-installer/main/install.sh | bash
```

`coqui` commands:

| Command         | Description                          |
| --------------- | ------------------------------------ |
| `coqui`         | Start the stack and print the URL    |
| `coqui status`  | Show container status                |
| `coqui stop`    | Stop the stack                       |
| `coqui restart` | Restart the stack                    |
| `coqui logs`    | Follow container logs                |
| `coqui update`  | Pull the latest image and restart    |

## Native install (Linux/macOS fallback)

If Docker is not available, `install.sh` falls back to a native install (PHP 8.4 + the coqui extension set, release download with checksum verification). Force it with `--native`:

```bash
./install.sh --native
```

`--dev` clones the git repo instead of downloading a release (needs Git + Composer). Native requirements: PHP 8.4+, extensions `dom mbstring pdo_sqlite xml` (plus `curl readline gd pcntl posix`).

### Install flags (native path)

| Flag                 | Description                                       |
| -------------------- | ------------------------------------------------- |
| `--native`           | Skip the Docker path; install natively on this host |
| `--dev`              | Use git clone instead of release download         |
| `--install-php`      | Install/check PHP 8.4+ and required extensions    |
| `--install-composer` | Install/check Composer                            |
| `--install-coqui`    | Install/update Coqui and create the `coqui` symlink |
| `--non-interactive`  | Skip all confirmation prompts (assume yes)        |
| `--help`, `-h`       | Show usage                                        |

### Configuration (native path)

Override defaults with environment variables:

| Variable            | Default         | Description                                  |
| ------------------- | --------------- | -------------------------------------------- |
| `COQUI_INSTALL_DIR` | `~/.coqui`      | Where Coqui is installed                     |
| `COQUI_REPO`        | GitHub repo URL | Git repository to clone from (dev mode only) |
| `COQUI_VERSION`     | latest          | Release version or git branch/tag to install |

```bash
# Specific release version
COQUI_VERSION=0.0.1 ./install.sh --native

# Custom install directory
COQUI_INSTALL_DIR=/opt/coqui ./install.sh --native
```

## Update

- Docker: `coqui update` (or `docker compose pull && docker compose up -d`).
- Native: re-run `./install.sh --native`.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/carmelosantana/coqui-installer/main/uninstall.sh | bash
```

Preserves persistent data by default; pass `--remove-workspace` to delete it. On the Docker path that deletes the persistent `coqui-data` volume; on the native path it removes `~/.coqui/.workspace`.

| Flag                 | Description                                       |
| -------------------- | ------------------------------------------------- |
| `--remove-workspace` | Delete persistent data (Docker: the `coqui-data` volume; native: `~/.coqui/.workspace`) |
| `--force`            | Skip all confirmation prompts                     |
| `--all`              | Also remove PHP and Composer installed by Coqui   |
| `--quiet`, `-q`      | Minimal output                                    |
| `--help`, `-h`       | Show usage                                        |

## License

MIT
