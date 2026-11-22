#!/bin/bash
# hf_fetch.sh — download files of a Hugging Face repo into cortex's HF cache
# with the official `hf` client, in a throwaway container (no host install).
#
#   ./tools/hf_fetch.sh <repo> <file> [<file>...]
#   ./tools/hf_fetch.sh unsloth/Inkling-2-Mini-GGUF Inkling-2-Mini-UD-IQ4_XS.gguf
#
# Ctrl+C stops it and changes nothing else; run it again to resume. Unlike
# `bench.sh fetch` it does not touch models.ini, restart a router or load a
# model. Faster than the routers' own downloader (one connection).
#
# It pins the download to the commit already cached for the repo (refs/main),
# so fetching one quant never moves refs/main and strands the files cached
# before (see bench.sh strand_guard). A repo with nothing cached takes main.
# Gated repos: HF_TOKEN in the environment is passed through.
set -euo pipefail
[ $# -ge 2 ] || { sed -n '2,8p' "$0"; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.local/llama-cpp_data"
REPO=$1; shift
REF_FILE="$CACHE/hub/models--${REPO/\//--}/refs/main"
REV=""
if [ -f "$REF_FILE" ]; then
  REV=$(cat "$REF_FILE")
  echo "pinning to the cached commit $REV"
fi
TTY=""; [ -t 0 ] && [ -t 1 ] && TTY="-t"
exec docker run --rm -i $TTY --init \
  -v "$CACHE:/hf" -e HF_HOME=/hf ${HF_TOKEN:+-e HF_TOKEN} \
  python:3.12-slim sh -c '
    pip install -q --root-user-action=ignore huggingface_hub hf_xet >/dev/null 2>&1
    repo=$1; rev=$2; shift 2
    exec hf download "$repo" "$@" ${rev:+--revision "$rev"}
  ' sh "$REPO" "$REV" "$@"
