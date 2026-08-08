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
