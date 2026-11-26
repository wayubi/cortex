#!/bin/sh
# Entrypoint for the llama.cpp routers: prune the slot-cache folder in the
# background, then run llama-server with the service's arguments.
#
# The coordinator saves a model's slot (KV cache + context checkpoints) to
# /slot-cache/<entry>.bin before unloading it and restores it after the next
# load (md/plan-slot-cache-across-swaps.md). llama.cpp has no API to delete
# those files, and the folder is a tmpfs private to this container, so the
# pruning runs here. Model weights are never kept here; only slot files.
#
#   SLOT_CACHE_DIR          folder (default /slot-cache); no folder, no pruning
#   SLOT_CACHE_TTL_MIN      delete files not written for this many minutes (120)
#   SLOT_CACHE_PRUNE_EVERY  seconds between passes (300)
#   SLOT_CACHE_KEEP_GB      then delete oldest-first while above this size (3)

DIR=${SLOT_CACHE_DIR:-/slot-cache}
TTL=${SLOT_CACHE_TTL_MIN:-120}
EVERY=${SLOT_CACHE_PRUNE_EVERY:-300}
KEEP_KB=$(( ${SLOT_CACHE_KEEP_GB:-3} * 1024 * 1024 ))

prune() {
    find "$DIR" -maxdepth 1 -type f -mmin +"$TTL" -delete 2>/dev/null
    used=$(du -sk "$DIR" 2>/dev/null | cut -f1)
    while [ "${used:-0}" -gt "$KEEP_KB" ]; do
        oldest=$(find "$DIR" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null \
                 | sort -n | head -n 1 | cut -d' ' -f2-)
        [ -n "$oldest" ] || break
        rm -f "$oldest"
        used=$(du -sk "$DIR" 2>/dev/null | cut -f1)
    done
}

if [ -d "$DIR" ]; then
    ( while sleep "$EVERY"; do prune; done ) &
fi

exec llama-server "$@"
