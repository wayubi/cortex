#!/bin/sh
# Installed as /usr/local/sbin/opencode, ahead of the real binary (/usr/local/bin/opencode) on PATH.
# `opencode pair` with neither --url nor --remote gets --url "$OPENCODE_PAIR_URL" when that is set
# (the address clients reach the server at, e.g. a reverse proxy's https:// URL); without it,
# OpenCode puts the container's own addresses in the links, which other devices cannot reach.
# Every other command passes through unchanged.
real=/usr/local/bin/opencode
if [ "${1:-}" = "pair" ] && [ -n "${OPENCODE_PAIR_URL:-}" ]; then
    for arg in "$@"; do
        case "$arg" in --url|--url=*|--remote) exec "$real" "$@" ;; esac
    done
    shift
    exec "$real" pair --url "$OPENCODE_PAIR_URL" "$@"
fi
exec "$real" "$@"
