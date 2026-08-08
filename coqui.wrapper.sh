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
    logs)   shift; compose logs "$@" ;;
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
