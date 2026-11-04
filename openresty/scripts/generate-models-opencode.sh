#!/bin/sh
# Regenerate the OpenCode provider config from Cortex.
set -eu

CORTEX_URL="${CORTEX_URL:-http://openresty:8080}"
CORTEX_URL="${CORTEX_URL%/}"

# Only a script run from a file has a directory of its own. Piped in
# (`curl URL | sh`), $0 is the shell, and dirname would give the current
# directory, whose *-common.sh files must not be sourced.
SCRIPT_DIR=""
case "$0" in
    sh|bash|dash|ash|-*|*/sh|*/bash|*/dash|*/ash) ;;
    *) [ -f "$0" ] && SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd) || SCRIPT_DIR="" ;;
esac
COMMON="${CORTEX_MODELS_COMMON:-}"
if [ -z "$COMMON" ] || [ ! -f "$COMMON" ]; then
    for candidate in "${SCRIPT_DIR:+$SCRIPT_DIR/models-common.sh}" \
                     /opt/cortex-scripts/models-common.sh \
                     /usr/local/lib/cortex/models-common.sh; do
        if [ -f "$candidate" ]; then
            COMMON="$candidate"
            break
        fi
    done
fi
if [ -z "$COMMON" ] || [ ! -f "$COMMON" ]; then
    COMMON="${TMPDIR:-/tmp}/cortex-models-common.$$.sh"
    trap 'rm -f "$COMMON"' EXIT HUP INT TERM
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 30 "$CORTEX_URL/models-common.sh" -o "$COMMON"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$COMMON" "$CORTEX_URL/models-common.sh"
    else
        echo "error: curl or wget required to fetch $CORTEX_URL/models-common.sh" >&2
        exit 1
    fi
fi

. "$COMMON"
models_main opencode
