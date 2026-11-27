#!/bin/sh
set -u

if [ "${OPENCODE_SYNC_MODELS:-1}" = "1" ]; then
    gen="${CORTEX_GENERATE_MODELS:-/opt/cortex-scripts/generate-models-opencode.sh}"
    retries="${OPENCODE_SYNC_RETRIES:-10}"
    delay="${OPENCODE_SYNC_DELAY:-3}"

    if [ -f "$gen" ]; then
        i=1
        while [ "$i" -le "$retries" ]; do
            if CORTEX_URL="${CORTEX_URL:-http://openresty:8080}" \
               OLLAMA_URL="${OLLAMA_URL:-http://openresty:11434}" \
               OPENCODE_CONFIG="${OPENCODE_CONFIG:-/root/.config/opencode/opencode.json}" \
               "$gen"; then
                break
            fi
            echo "opencode-entrypoint: model sync failed ($i/$retries), retrying in ${delay}s" >&2
            sleep "$delay"
            i=$((i + 1))
        done
    else
        echo "opencode-entrypoint: $gen not found; skipping model sync" >&2
    fi
fi

# Start OpenCode's background server (opencode serve --service) at container start, so
# `opencode pair` and browser/app clients can connect without a TUI having started it.
# Its settings (hostname, port, password, the --remote relay route) are in
# /root/.config/opencode/service.json; `opencode service set` changes them.
# OPENCODE_HOSTNAME, if set, is written there first: 0.0.0.0 makes the server reachable
# through a published port (the default, 127.0.0.1, serves only this container).
# A failure here is logged and does not stop the container.
if [ -n "${OPENCODE_HOSTNAME:-}" ]; then
    opencode service set hostname "$OPENCODE_HOSTNAME" >/dev/null \
        || echo "opencode-entrypoint: could not set hostname $OPENCODE_HOSTNAME" >&2
fi
if [ "${OPENCODE_SERVICE:-0}" = "1" ]; then
    opencode service start || echo "opencode-entrypoint: background server did not start" >&2
fi

exec "$@"
