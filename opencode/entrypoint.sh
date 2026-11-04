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

exec "$@"
