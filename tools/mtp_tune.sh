#!/bin/bash
# mtp_tune.sh — MTP detection + spec-draft-n-max / spec-draft-p-min tuning sweep
#
# Usage:
#   ./tools/mtp_tune.sh <model-name>                      # detect MTP + full sweep
#   ./tools/mtp_tune.sh <model-name> resume nmax <start>  # resume n_max sweep from <start>
#   ./tools/mtp_tune.sh <model-name> resume pmin <start>  # skip to p_min sweep (uses current models.ini n_max)
#
# Detection: tries MTP empirically — sets spec-type=draft-mtp (+ draft keys), restarts,
# and probes. If the model loads and MTP engages, it's supported. If load fails or MTP
# never engages, the original config is restored and the script exits.
#
# Sweep order (AGENTS.md): n_max over {1,2,3,4,5} at p_min=0.7, then p_min over
# {0.5,0.6,0.7,0.8,0.9} at the winning n_max. Each candidate runs a real essay
# decode with 160s CPU/GPU placement polling, extracting decode t/s, draft
# acceptance, quality, and OOM status. Winners are applied to models.ini.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL=${1:-}
ARG2=${2:-}
INI="$ROOT/llama-cpp/models.ini"
LOG_FILE="$ROOT/logs/mtp_tune_${MODEL}.log"
DOCKER_LOG="cortex-llama-cpp-1"
OMG_GREP="cudaMalloc failed|failed to allocate compute pp buffers|terminate called after throwing|failed to create MTP context|exiting due to model loading error|CUDA error: out of memory|cuMemCreate"
ESSAY="Write a detailed 1000-word essay explaining transformers and MoE"

RESUME_NMAX=0
RESUME_PMIN=0
NMAX_START=1
PMIN_START=0.5

mkdir -p "$ROOT/logs"

log() { echo "$1" | tee -a "$LOG_FILE"; }

if [ -z "$MODEL" ]; then
  echo "Usage: $0 <model-name> [resume nmax <start>|resume pmin <start>]"
  exit 1
fi

if [ "$ARG2" = "resume" ]; then
  case "${3:-}" in
    nmax) RESUME_NMAX=1; NMAX_START=${4:-1}
          if ! [[ "$NMAX_START" =~ ^[0-9]+$ ]]; then
            echo "Usage: $0 <model> resume nmax <start>"; exit 1
          fi ;;
    pmin) RESUME_PMIN=1; PMIN_START=${4:-0.5}
          if ! [[ "$PMIN_START" =~ ^[0-9.]+$ ]]; then
            echo "Usage: $0 <model> resume pmin <start>"; exit 1
          fi ;;
    *)    echo "Usage: $0 <model> resume nmax <start> | resume pmin <start>"; exit 1 ;;
  esac
fi

# ── Section helpers ──────────────────────────────────────────
read_section() {
  python3 -c "
import re, sys
with open('$INI') as f: content = f.read()
m = re.search(r'\['+re.escape('$MODEL')+r'\](.*?)(?=\n\[|\Z)', content, re.DOTALL)
sys.stdout.write(m.group(1) if m else '')
"
}

# Set a key value, preserving the existing line's key+padding prefix
set_key() {
  local KEY=$1 VALUE=$2
  python3 -c "
import re, sys
key='$KEY'; value='$VALUE'; model='$MODEL'; ini='$INI'
with open(ini) as f: content = f.read()
m = re.search(r'(\['+re.escape(model)+r'\])(.*?)(?=\n\[|\Z)', content, re.DOTALL)
if not m: print('ERROR: section not found'); sys.exit(1)
section = m.group(2)
new_lines = []
found = False
for line in section.split('\n'):
    if re.match(r'\s*'+re.escape(key)+r'\s*=', line):
        prefix = line.split('=')[0] + '='
        new_lines.append(prefix + ' ' + value)
        found = True
    else:
        new_lines.append(line)
if not found:
    keys = [l.split('=')[0].strip() for l in section.split('\n') if '=' in l and not l.strip().startswith(('#',';'))]
    max_len = max((len(k) for k in keys), default=len(key))
    pad = max_len - len(key) + 1
    new_lines.insert(1, key + ' ' * pad + '= ' + value)
with open(ini, 'w') as f:
    f.write(content[:m.start(2)] + '\n'.join(new_lines) + content[m.end(2):])
print(f'  {key} = {value}')
"
}

restart() {
  log "  Restarting llama-cpp..."
  cd "$ROOT" && docker compose restart llama-cpp || {
    log "  ERROR: docker compose restart failed"
    exit 1
  }
  local i
  for i in $(seq 1 30); do
    if curl -sf --max-time 3 http://localhost:8080/v1/models >/dev/null 2>&1; then
      log "  Model router ready (${i}x2s)"
      return 0
    fi
    sleep 2
  done
  log "  ERROR: llama-cpp did not become ready after restart"
  docker ps -a | grep llama-cpp || true
  docker logs --tail 20 $DOCKER_LOG 2>&1 || true
  exit 1
}

# Log-marking for precise OOM detection
LOG_MARK=0
logmark() { LOG_MARK=$(docker logs $DOCKER_LOG 2>&1 | wc -l); }
oom_since_mark() {
  docker logs $DOCKER_LOG 2>&1 | tail -n +$((LOG_MARK + 1)) | grep -iE "$OMG_GREP" || true
}
oom_count_since_mark() { oom_since_mark | wc -l | tr -d ' '; }

# ── MTP detection (try-it-and-see) ───────────────────────────
# Snapshots the model's section to a temp file, sets MTP config, restarts, probes.
# MTP supported = probe succeeds AND log shows MTP engagement.
# On failure, restores the original section and exits.
detect_mtp() {
  log ""; log "=== MTP DETECTION: $MODEL ==="
  local SNAP=/tmp/mtp_section_${MODEL}.snap
  read_section > "$SNAP"
  log "  Applying MTP config (spec-type=draft-mtp)..."
  set_key spec-type draft-mtp
  # only set draft params if absent — preserve prior winning values on resume
  if ! grep -q "spec-draft-n-max" "$SNAP"; then
    log "    (adding spec-draft-n-max=2)"
    set_key spec-draft-n-max 2
  fi
  if ! grep -q "spec-draft-p-min" "$SNAP"; then
    log "    (adding spec-draft-p-min=0.7)"
    set_key spec-draft-p-min 0.7
  fi

  local CUR_BATCH
  CUR_BATCH=$(read_batch)
  local ATTEMPT=0
  local PROBE_RETRY=0
  while true; do
    ATTEMPT=$((ATTEMPT + 1))
    log "  --- MTP load attempt $ATTEMPT (batch=$CUR_BATCH) ---"
    restart
    logmark
    curl -s --max-time 300 -X POST http://localhost:8080/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"max_tokens\":8}" \
      > /tmp/mtp_detect.json 2>&1

    local OOM LOGS
    OOM=$(oom_count_since_mark)
    LOGS=$(docker logs $DOCKER_LOG 2>&1 | tail -n +$((LOG_MARK + 1)))

    local PROBE_OK=0
    python3 -c "import json; d=json.load(open('/tmp/mtp_detect.json')); exit(0 if 'choices' in d else 1)" 2>/dev/null && PROBE_OK=1

    local MTP_ENGAGED=0
    if echo "$LOGS" | grep -q -- "--spec-type" && echo "$LOGS" | grep -qiE "draft-mtp|loading draft model|n_layer_nextn[^0-9]*[1-9]"; then
      MTP_ENGAGED=1
    fi

    # Distinguish the two 'failed to create MTP context' causes:
    #   (a) 'model doesn't contain MTP layers' → genuinely NOT an MTP model (no retry helps)
    #   (b) VRAM OOM at load (no such line) → MTP draft context couldn't fit — step batch down.
    if echo "$LOGS" | grep -q "model doesn't contain MTP layers"; then
      log "  ✗ NOT MTP-SUPPORTED: GGUF has no MTP layers"
      log "    $(echo "$LOGS" | grep "model doesn't contain MTP layers" | head -1)"
      log "  Restoring original config..."
      restore_section "$SNAP"
      log "  Exiting."
      exit 1
    fi

    if [ "$OOM" -gt 0 ]; then
      if [ "$CUR_BATCH" -gt 2048 ]; then
        local PREV=$CUR_BATCH
        CUR_BATCH=$((CUR_BATCH / 2))
        log "  MTP draft context OOM at batch=$PREV — stepping down to $CUR_BATCH"
        set_batch "$CUR_BATCH"
        PROBE_RETRY=0
        continue
      fi
      log "  ✗ MTP context OOM persists down to batch=$CUR_BATCH (2048 floor)"
      log "    OOM/load error: $(oom_since_mark | head -1)"
      log "  Restoring original config..."
      restore_section "$SNAP"
      log "  Exiting."
      exit 1
    fi

    # Probe failed with no OOM marker → transient (first request after a fresh
    # restart can take >20s and time out while the model loads fine). Retry the
    # SAME batch once before concluding anything.
    if [ "$PROBE_OK" -eq 0 ]; then
      if [ "$PROBE_RETRY" -lt 1 ]; then
        PROBE_RETRY=$((PROBE_RETRY + 1))
        log "  Probe failed (no OOM marker) — transient retry at batch=$CUR_BATCH"
        continue
      fi
      log "  ✗ NOT MTP-SUPPORTED: probe failed twice with no OOM marker"
      log "    probe request failed (no response)"
      log "  Restoring original config..."
      restore_section "$SNAP"
      log "  Exiting."
      exit 1
    fi

    if [ "$MTP_ENGAGED" -eq 0 ]; then
      log "  ✗ NOT MTP-SUPPORTED: model loaded but MTP did not engage"
      log "    no MTP engagement in load log (--spec-type draft-mtp / draft model / n_layer_nextn)"
      log "  Restoring original config..."
      restore_section "$SNAP"
      log "  Exiting."
      exit 1
    fi

    break
  done
  log "  ✓ MTP-SUPPORTED: model loaded and MTP engaged"
  rm -f "$SNAP"
}

# Restore a saved section snapshot into models.ini
restore_section() {
  local SNAP=$1
  python3 -c "
import re, sys
snap = open('$SNAP').read()
model='$MODEL'; ini='$INI'
with open(ini) as f: content = f.read()
m = re.search(r'(\['+re.escape(model)+r'\])(.*?)(?=\n\[|\Z)', content, re.DOTALL)
if not m: print('ERROR: section not found'); sys.exit(1)
with open(ini, 'w') as f:
    f.write(content[:m.start(2)] + snap + content[m.end(2):])
print('  section restored')
"
}

# Read the model's current batch-size from models.ini
read_batch() {
  python3 -c "
import re
with open('$INI') as f: c = f.read()
m = re.search(r'\['+re.escape('$MODEL')+r'\].*?batch-size\s*=\s*(\d+)', c, re.DOTALL)
print(m.group(1) if m else '0')
"
}

# Set batch-size + ubatch-size (keeps MTP draft fitting after a load OOM)
set_batch() {
  set_key batch-size "$1"
  set_key ubatch-size "$1"
}

# ── Decode test (essay + placement polling) ─────────────────
run_decode_test() {
  local LABEL=$1
  # progress to stderr (stdout is reserved for the pipe-delimited result)
  plog() { echo "$1" | tee -a "$LOG_FILE" >&2; }
  plog ""; plog "=== TEST: $LABEL ==="

  python3 -c "
import json
payload = {'model':'$MODEL','messages':[{'role':'user','content':'$ESSAY'}],'max_tokens':4000,'ignore_eos':True}
with open('/tmp/mtp_payload.json','w') as f: json.dump(payload, f)
"
  logmark
  curl -s --max-time 600 -X POST http://localhost:8080/v1/chat/completions \
    -H 'Content-Type: application/json' -d @/tmp/mtp_payload.json \
    > /tmp/mtp_out.json 2>&1 &
  local PID=$!

  # Placement poll: until request completes (min 3 samples), capped at 160s
  POLL_MIN_SAMPLES=3
  plog "  Polling CPU/GPU until request completes (max 160s)..."
  local CPU_SAMPLES=()
  for i in $(seq 1 80); do
    local TOP CPU GPU
    TOP=$(top -bn1 2>/dev/null | grep llama-s | head -n1)
    CPU=$(echo "$TOP" | awk '{print $9}' 2>/dev/null || echo "0")
    GPU=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
    [ -n "$CPU" ] && [ "$CPU" != "0.0" ] && CPU_SAMPLES+=("$CPU")
    [ $((i % 20)) -eq 0 ] && plog "    ...${i}x2s (CPU ${CPU}% GPU ${GPU}%)"
    sleep 2
    if [ "$i" -ge "$POLL_MIN_SAMPLES" ] && ! kill -0 $PID 2>/dev/null; then
      plog "    Request complete after ~$((i*2))s — stopping poll"
      break
    fi
  done
  wait $PID 2>/dev/null || true

  # Averages (skip first 10 samples as warmup if enough were collected)
  local CPU_SUM=0 CPU_CNT=0 AVG_CPU=0
  local AVG_START=0
  [ "${#CPU_SAMPLES[@]}" -gt 10 ] && AVG_START=10
  for idx in $(seq $AVG_START $((${#CPU_SAMPLES[@]} - 1))); do
    [ -z "${CPU_SAMPLES[$idx]:-}" ] && continue
    CPU_SUM=$(echo "$CPU_SUM + ${CPU_SAMPLES[$idx]}" | bc 2>/dev/null || echo 0)
    CPU_CNT=$((CPU_CNT + 1))
  done
  [ "$CPU_CNT" -gt 0 ] && AVG_CPU=$(echo "scale=1; $CPU_SUM / $CPU_CNT" | bc)

  # Classify
  local PLACEMENT
  if (( $(echo "$AVG_CPU < 100" | bc -l) )); then PLACEMENT="GPU"
  elif (( $(echo "$AVG_CPU > 200" | bc -l) )); then PLACEMENT="CPU"
  else PLACEMENT="AMBIGUOUS"; fi

  local OOM=$(oom_count_since_mark)

  local SPEED ACCEPT QUALITY
  SPEED=$(python3 -c "
import json
try:
    d = json.load(open('/tmp/mtp_out.json'))
    if 'choices' in d:
        t = d.get('timings',{})
        print(f\"{t.get('predicted_per_second',0):.1f}\")
    else: print('0')
except: print('0')
" 2>/dev/null)
  ACCEPT=$(docker logs $DOCKER_LOG 2>&1 | tail -n +$((LOG_MARK + 1)) | grep -oE "draft acceptance = [0-9.]+" | tail -1 | awk '{print $3}')
  QUALITY=$(python3 -c "
import json, re
try:
    d = json.load(open('/tmp/mtp_out.json'))
    text = d['choices'][0]['message']['content']
except:
    print('?'); exit()
sents = [s.strip() for s in re.split(r'[.!?]\s+', text) if len(s.strip()) > 30]
repeats = 0
for i in range(len(sents) - 1):
    if sents[i] == sents[i+1]:
        repeats += 1
# also flag repeated 8-word spans
words = text.split()
tri = [' '.join(words[i:i+8]) for i in range(len(words)-8)]
from collections import Counter
dup = sum(1 for v in Counter(tri).values() if v > 1)
print(max(repeats, dup if dup >= 3 else 0))
")

  plog "  Result: decode=${SPEED:-0} t/s | acc=${ACCEPT:-?} | placement=$PLACEMENT (cpu ${AVG_CPU}%) | quality-repeats=${QUALITY:-?} | OOM=$OOM"
  echo "$SPEED|$ACCEPT|$PLACEMENT|$AVG_CPU|$QUALITY|$OOM"
}

# ── Main ─────────────────────────────────────────────────────
detect_mtp

# Read current batch/ctx for reference
CTX=$(python3 -c "
import re
with open('$INI') as f: c = f.read()
m = re.search(r'\['+re.escape('$MODEL')+r'\].*?ctx-size\s*=\s*(\d+)', c, re.DOTALL)
print(m.group(1) if m else '?')
")
log ""; log "Model: $MODEL | ctx: $CTX"

# ── Phase B: n_max sweep {1,2,3,4,5} at p_min=0.7 ──
NMAX_VALUES="1 2 3 4 5"
WIN_NMAX=0
declare -A NMAX_RESULTS

if [ "$RESUME_PMIN" -eq 0 ]; then
  log ""; log "=== PHASE B: n_max SWEEP (p_min=0.7) ==="
  for N in $NMAX_VALUES; do
    [ "$N" -lt "$NMAX_START" ] && { log "  (resume) skipping n_max=$N"; continue; }
    set_key spec-draft-n-max "$N"
    set_key spec-draft-p-min 0.7
    restart
    RESULT=$(run_decode_test "n_max=$N, p_min=0.7")
    IFS='|' read -r SPEED ACC PLACEMENT AVGCPU QUALITY OOM <<< "$RESULT"
    NMAX_RESULTS[$N]="$SPEED|$ACC|$PLACEMENT|$QUALITY|$OOM"
    if [ "$OOM" -eq 0 ] && [ "$PLACEMENT" != "CPU" ] && [ "${QUALITY:-0}" -lt 2 ] 2>/dev/null; then
      WIN_NMAX=$N
    fi
  done
  if [ "$WIN_NMAX" -eq 0 ]; then
    log ""; log "  WARNING: no n_max passed all filters. Using default 2."
    WIN_NMAX=2
  fi
else
  # resume pmin: read n_max currently in models.ini
  WIN_NMAX=$(python3 -c "
import re
with open('$INI') as f: c = f.read()
m = re.search(r'\['+re.escape('$MODEL')+r'\].*?spec-draft-n-max\s*=\s*(\d+)', c, re.DOTALL)
print(m.group(1) if m else '2')
")
  log ""; log "=== RESUMING AT p_min SWEEP (n_max=$WIN_NMAX) ==="
fi

log ""; log "  WINNING n_max: $WIN_NMAX"

# ── Phase C: p_min sweep {0.5,0.6,0.7,0.8,0.9} at winning n_max ──
log ""; log "=== PHASE C: p_min SWEEP (n_max=$WIN_NMAX) ==="
PMIN_VALUES="0.5 0.6 0.7 0.8 0.9"
WIN_PMIN=0.7
declare -A PMIN_RESULTS

for P in $PMIN_VALUES; do
  # numeric compare for resume skip
  if ! python3 -c "exit(0 if float('$P') >= float('$PMIN_START') else 1)" 2>/dev/null; then
    log "  (resume) skipping p_min=$P"
    continue
  fi
  set_key spec-draft-n-max "$WIN_NMAX"
  set_key spec-draft-p-min "$P"
  restart
  RESULT=$(run_decode_test "n_max=$WIN_NMAX, p_min=$P")
  IFS='|' read -r SPEED ACC PLACEMENT AVGCPU QUALITY OOM <<< "$RESULT"
  PMIN_RESULTS[$P]="$SPEED|$ACC|$PLACEMENT|$QUALITY|$OOM"
  if [ "$OOM" -eq 0 ] && [ "$PLACEMENT" != "CPU" ] && [ "${QUALITY:-0}" -lt 2 ] 2>/dev/null; then
    WIN_PMIN=$P
  fi
done

log ""; log "  WINNING p_min: $WIN_PMIN"

# ── Apply winners ────────────────────────────────────────────
log ""; log "=== APPLYING WINNERS ==="
set_key spec-draft-n-max "$WIN_NMAX"
set_key spec-draft-p-min "$WIN_PMIN"

# ── Summary ──────────────────────────────────────────────────
log ""; log "=== SUMMARY: $MODEL ==="
log "  n_max sweep (p_min=0.7):"
for N in $NMAX_VALUES; do
  log "    n_max=$N: ${NMAX_RESULTS[$N]:-skipped}"
done
log "  p_min sweep (n_max=$WIN_NMAX):"
for P in $PMIN_VALUES; do
  log "    p_min=$P: ${PMIN_RESULTS[$P]:-skipped}"
done
log ""; log "  WINNERS: spec-draft-n-max=$WIN_NMAX spec-draft-p-min=$WIN_PMIN"
log "  (restart llama-cpp to apply)"
log "=== DONE ==="
