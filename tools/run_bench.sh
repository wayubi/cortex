#!/bin/bash
# run_bench.sh — Batch benchmarking: select models, select pipeline steps, run them
#
# Usage:
#   ./tools/run_bench.sh                            # interactive: pick models, pick steps, confirm, run
#   ./tools/run_bench.sh <steps> <models...>        # non-interactive, e.g.:
#                                                   #   ./tools/run_bench.sh all glm-4.7-30b-a3b-flash-q4-64k
#                                                   #   ./tools/run_bench.sh bench,mtp qwen-3.5-9b-q4-mtp-16k qwen-3.5-9b-q4-mtp-16k-think
#
# <steps>  = comma list from {bisect,mtp,bench} or 'all'
# <models> = exact models.ini section names (comma/space separated)
#
# Per model, steps run in fixed dependency order: bisect -> mtp -> bench.
# Failures are logged and skipped; a verdict table is printed at the end.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INI="$ROOT/llama-cpp/models.ini"
MODELS_DIR="$ROOT/llama-cpp/models"
LOG_DIR="$ROOT/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/run_bench_$(date +%Y%m%d-%H%M).log"

# ── Model inventory from models.ini ─────────────────────────
declare -a MODEL_NAMES=()
declare -a MODEL_HAS_BATCH=()
declare -a MODEL_IS_MTP=()

load_models() {
  MODEL_NAMES=(); MODEL_HAS_BATCH=(); MODEL_IS_MTP=()
  while IFS='|' read -r name batch mtp; do
    MODEL_NAMES+=("$name")
    MODEL_HAS_BATCH+=("$batch")
    MODEL_IS_MTP+=("$mtp")
  done < <(python3 -c "
import re, json
with open('$INI') as f: c = f.read()
sections = re.split(r'(?m)^\[', c)
out = []
for s in sections[1:]:
    name = s.split(']')[0].strip()
    if name == '*' or not name: continue
    out.append({
        'name': name,
        'batch': bool(re.search(r'^\s*batch-size\s*=', s, re.M)),
        'mtp': 'draft-mtp' in s,
    })
print(json.dumps(out))
" | python3 -c "
import json, sys
for m in json.load(sys.stdin):
    print(m['name'] + '|' + str(1 if m['batch'] else 0) + '|' + str(1 if m['mtp'] else 0))
")
}

# Shell functions can't return arrays, so re-read into a global string set per index
model_name()  { echo "${MODEL_NAMES[$1]}"; }
model_batch() { echo "${MODEL_HAS_BATCH[$1]}"; }
model_mtp()   { echo "${MODEL_IS_MTP[$1]}"; }

# ── Helpers ─────────────────────────────────────────────────
log() { echo "$1" >> "$LOG_FILE"; }
# Log to file AND show live on stdout
lshow() { echo "$1"; echo "$1" >> "$LOG_FILE"; }

confirm() {
  while true; do
    read -r -p "$1 [y/N] " REPLY
    case "$REPLY" in
      [yY]|[yY][eE][sS]) return 0 ;;
      "") return 1 ;;
      *) return 1 ;;
    esac
  done
}

expand_selection() {
  # $1 = user input like "1,3,5-8" or "all"; $2 = count
  local INPUT=$1 COUNT=$2
  local -a OUT=()
  if [ "$INPUT" = "all" ]; then
    for i in $(seq 0 $((COUNT - 1))); do OUT+=("$i"); done
    echo "${OUT[*]}"
    return
  fi
  local part
  IFS=',' read -r -a parts <<< "$INPUT"
  for part in "${parts[@]}"; do
    part=$(echo "$part" | tr -d ' ')
    if [[ "$part" =~ ^[0-9]+$ ]]; then
      [ "$part" -ge 0 ] && [ "$part" -lt "$COUNT" ] && OUT+=("$part")
    elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      local LO=${BASH_REMATCH[1]} HI=${BASH_REMATCH[2]}
      [ "$LO" -gt "$HI" ] && { local t=$LO; LO=$HI; HI=$t; }
      for i in $(seq "$LO" "$HI"); do
        [ "$i" -ge 0 ] && [ "$i" -lt "$COUNT" ] && OUT+=("$i")
      done
    fi
  done
  echo "${OUT[*]}"
}

# ── Parse steps arg ─────────────────────────────────────────
parse_steps() {
  local IN=$1
  # 'all' as any comma-token expands to all three steps
  local token
  IFS=',' read -r -a arr <<< "$IN"
  for token in "${arr[@]}"; do
    token=$(echo "$token" | tr -d ' ')
    if [ "$token" = "all" ]; then
      echo "bisect mtp bench"
      return
    fi
  done
  local result=""
  for s in "${arr[@]}"; do
    s=$(echo "$s" | tr -d ' ')
    case "$s" in
      bisect|mtp|bench) result="$result $s" ;;
    esac
  done
  echo "$result" | xargs
}

# ── Non-interactive model resolution ────────────────────────
# $@ = model names. Resolves each against the inventory, echoes resolved indices.
resolve_models() {
  local idx name
  for name in "$@"; do
    for idx in "${!MODEL_NAMES[@]}"; do
      if [ "${MODEL_NAMES[$idx]}" = "$name" ]; then
        echo "$idx"
      fi
    done
  done
}

# ── Run one step for one model ──────────────────────────────
# Sets the global STATUS var; the sub-script's stdout flows through live.
# mtp_tune.sh exits 1 when it detects MTP is NOT supported (config restored) —
# mapped to NOT_MTP so run_bench can record it as a skip, not a failure.
run_step() {
  local STEP=$1 IDX=$2 NAME=$3
  local RC=0
  STATUS=""
  lshow ""
  lshow "=== [$NAME] STEP: $STEP ==="
  lshow "  $(date +%H:%M:%S) starting $STEP for $NAME"
  case "$STEP" in
    bisect) (cd "$ROOT" && ./tools/batch_bisect.sh "$NAME") || RC=$? ;;
    mtp)    (cd "$ROOT" && ./tools/mtp_tune.sh "$NAME") || RC=$? ;;
    bench)  (cd "$ROOT" && ./tools/bench_model.sh "$NAME") || RC=$? ;;
  esac
  lshow "  $(date +%H:%M:%S) finished $STEP for $NAME (exit $RC)"
  if [ "$RC" -eq 0 ]; then
    STATUS="OK"
  elif [ "$STEP" = "mtp" ] && [ "$RC" -eq 1 ]; then
    STATUS="NOT_MTP"
  else
    STATUS="FAIL"
  fi
  echo "$STATUS" > /tmp/run_bench_status.$$
}

# ── Main ────────────────────────────────────────────────────
load_models
N_MODELS=${#MODEL_NAMES[@]}

if [ "$N_MODELS" -eq 0 ]; then
  echo "ERROR: no models found in $INI"
  exit 1
fi

STEPS=""
MODEL_IDXS=""
NONINTERACTIVE=0

if [ "$#" -ge 2 ]; then
  NONINTERACTIVE=1
  # Non-interactive: $1 = steps, rest = model names
  STEPS=$(parse_steps "$1")
  shift
  MODEL_IDXS=$(resolve_models "$@")
  if [ -z "$STEPS" ]; then
    echo "ERROR: no valid steps. Use bisect,mtp,bench or all"
    exit 1
  fi
  if [ -z "$MODEL_IDXS" ]; then
    echo "ERROR: no valid model names matched models.ini"
    exit 1
  fi
else
  # Interactive
  echo ""
  echo "=== MODELS ($N_MODELS) ==="
  for i in $(seq 0 $((N_MODELS - 1))); do
    NAME=$(model_name "$i")
    B=$(model_batch "$i")
    M=$(model_mtp "$i")
    S=$([ -f "$MODELS_DIR/$NAME.json" ] && echo "S" || echo "-")
    BFLAG=$([ "$B" = "1" ] && echo "B" || echo "-")
    MFLAG=$([ "$M" = "1" ] && echo "M" || echo "-")
    printf "  %3d) [%s%s%s] %s\n" "$i" "$S" "$BFLAG" "$MFLAG" "$NAME"
  done
  echo ""
  echo "  S = stats JSON exists | - = not benched"
  echo "  B = batch-size set | - = needs bisect"
  echo "  M = MTP model | - = not MTP"
  echo ""
  read -r -p "Select models (numbers, ranges like 1,3,5-8, or 'all'): " MODEL_INPUT
  MODEL_IDXS=$(expand_selection "$MODEL_INPUT" "$N_MODELS")
  if [ -z "$MODEL_IDXS" ]; then
    echo "No models selected."; exit 1
  fi
  echo ""
  echo "Selected:"
  for i in $MODEL_IDXS; do echo "  $i) $(model_name "$i")"; done

  echo ""
  read -r -p "Select steps (comma list of bisect,mtp,bench, or 'all'): " STEP_INPUT
  STEPS=$(parse_steps "$STEP_INPUT")
  if [ -z "$STEPS" ]; then
    echo "No valid steps selected."; exit 1
  fi
fi

# ── Build + confirm plan ────────────────────────────────────
lshow "=== MASTER PLAN ==="
lshow "  models: $(for i in $MODEL_IDXS; do echo -n "$(model_name "$i") "; done)"
lshow "  steps: $STEPS"
lshow "  log: $LOG_FILE"

echo ""
echo "=== PLAN ==="
for i in $MODEL_IDXS; do
  NAME=$(model_name "$i")
  echo "  $NAME:"
  for s in $STEPS; do
    case "$s" in
      mtp)
        echo "    $s (auto-detect)" ;;
      bench)
        if [ "$(model_batch "$i")" != "1" ] && ! [[ " $STEPS " == *" bisect "* ]]; then
          echo "    $s -> SKIPPED (no batch-size and bisect not selected)"
        else echo "    $s"; fi ;;
      *) echo "    $s" ;;
    esac
  done
done

echo ""
if [ "$NONINTERACTIVE" -eq 1 ]; then
  echo "Non-interactive mode — running."
else
  confirm "Proceed with this plan?" || { echo "Aborted."; exit 1; }
fi

# ── Execute ─────────────────────────────────────────────────
declare -A VERDICTS
for i in $MODEL_IDXS; do
  NAME=$(model_name "$i")
  lshow ""
  lshow "=============== MODEL: $NAME ==============="
  for s in $STEPS; do
    case "$s" in
      mtp)
        # No static pre-judgment — mtp_tune.sh empirically detects MTP support.
        run_step "$s" "$i" "$NAME"
        if [ "$(cat /tmp/run_bench_status.$$)" = "NOT_MTP" ]; then
          VERDICTS["$NAME|$s"]="SKIPPED (not MTP)"
        else
          VERDICTS["$NAME|$s"]=$(cat /tmp/run_bench_status.$$)
        fi
        rm -f /tmp/run_bench_status.$$
        continue ;;
      bench)
        if [ "$(model_batch "$i")" != "1" ] && ! [[ " $STEPS " == *" bisect "* ]]; then
          log "  bench: SKIPPED (no batch-size and bisect not selected)"
          VERDICTS["$NAME|$s"]="SKIPPED"
          continue
        fi ;;
    esac
    run_step "$s" "$i" "$NAME"
    VERDICTS["$NAME|$s"]=$(cat /tmp/run_bench_status.$$)
    rm -f /tmp/run_bench_status.$$
  done
done

# ── Verdict summary ─────────────────────────────────────────
lshow ""
lshow "=== VERDICT SUMMARY ==="
lshow "$(printf '%-45s %-8s %-8s %-8s' MODEL bisect mtp bench)"
for i in $MODEL_IDXS; do
  NAME=$(model_name "$i")
  ROW=$(printf "%-45s" "$NAME")
  for s in bisect mtp bench; do
    ROW="$ROW  $(printf '%-8s' "${VERDICTS["$NAME|$s"]:-—}")"
  done
  lshow "$ROW"
done
lshow ""
lshow "Full log: $LOG_FILE"
