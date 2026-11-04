#!/bin/sh
set -u

if [ "${PI_SYNC_MODELS:-1}" = "1" ]; then
    gen="${CORTEX_GENERATE_MODELS:-/opt/cortex-scripts/generate-models-pi.sh}"
    retries="${PI_SYNC_RETRIES:-10}"
    delay="${PI_SYNC_DELAY:-3}"

    if [ -f "$gen" ]; then
        i=1
        while [ "$i" -le "$retries" ]; do
            if CORTEX_URL="${CORTEX_URL:-http://openresty:8080}" \
               OLLAMA_URL="${OLLAMA_URL:-http://openresty:11434}" \
               PI_MODELS_FILE="${PI_MODELS_FILE:-/root/.pi/agent/models.json}" \
               "$gen"; then
                break
            fi
            echo "pi-entrypoint: model sync failed ($i/$retries), retrying in ${delay}s" >&2
            sleep "$delay"
            i=$((i + 1))
        done
    else
        echo "pi-entrypoint: $gen not found; skipping model sync" >&2
    fi
fi

exec "$@"
