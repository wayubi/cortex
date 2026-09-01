#!/bin/bash
# bench.sh — Unified benchmarking pipeline: MTP capability check, batch bisect,
# MTP tuning, and full benchmark record. Single script, single scope.
#
# Usage:
#   ./tools/bench.sh                            # interactive: pick models, full suite, confirm
#   ./tools/bench.sh all <models...>            # non-interactive full suite per model
#   ./tools/bench.sh mtpcheck <models...>       # MTP capability check only (writes spec-type)
#   ./tools/bench.sh bisect <model> [test-batch|resume <lo> <hi>|resume <batch>]
#   ./tools/bench.sh mtp <models...>            # n_max/p_min tuning (requires mtpcheck first)
#   ./tools/bench.sh bench <models...>          # full benchmark JSON record
#
# Full suite order per model (fixed): mtpcheck -> bisect -> mtp -> bench.
# mtpcheck empirically determines MTP capability and sets/clears spec-type in
# models.ini BEFORE the bisect, so the bisect runs against the true MTP state.
# Failures are logged and skipped; a verdict table is printed at the end.
#
# Reads/writes llama-cpp/models.ini. Logs to logs/bench_<timestamp>.log.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INI="$ROOT/llama-cpp/models.ini"
MODELS_DIR="$ROOT/llama-cpp/models"
LOG_DIR="$ROOT/logs"
mkdir -p "$LOG_DIR" "$MODELS_DIR"
LOG_FILE="$LOG_DIR/bench_$(date +%Y%m%d-%H%M).log"
DOCKER_LOG="cortex-llama-cpp-1"
OMG_GREP="cudaMalloc failed|failed to allocate compute pp buffers|terminate called after throwing|failed to create MTP context|exiting due to model loading error|CUDA error: out of memory|cuMemCreate"
ESSAY="Write a detailed 1000-word essay explaining transformers and MoE"
POLL_MIN_SAMPLES=3
POLL_MAX_SAMPLES=80

# Shared per-model state (set before each engine call)
MODEL=""

log() { echo "$1" | tee -a "$LOG_FILE"; }
lshow() { echo "$1"; echo "$1" >> "$LOG_FILE"; }

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

model_name()  { echo "${MODEL_NAMES[$1]}"; }
model_batch() { echo "${MODEL_HAS_BATCH[$1]}"; }
model_mtp()   { echo "${MODEL_IS_MTP[$1]}"; }

# Resolve model names against the inventory, echo matching indices.
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

# ── Interactive helpers ─────────────────────────────────────
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

# ── Shared models.ini section helpers ──────────────────────
read_section() {
  python3 -c "
import re, sys
with open('$INI') as f: content = f.read()
m = re.search(r'\['+re.escape('$MODEL')+r'\](.*?)(?=\n\[|\Z)', content, re.DOTALL)
sys.stdout.write(m.group(1) if m else '')
"
}

read_ctx() {
  python3 -c "
import re
with open('$INI') as f: content = f.read()
m = re.search(r'\['+re.escape('$MODEL')+r'\](.*?)(?=\n\[|\Z)', content, re.DOTALL)
sec = m.group(1) if m else ''
mm = re.search(r'^\s*ctx-size\s*=\s*(\d+)', sec, re.MULTILINE)
print(mm.group(1) if mm else '')
"
}

read_batch() {
  python3 -c "
import re
with open('$INI') as f: content = f.read()
m = re.search(r'\['+re.escape('$MODEL')+r'\](.*?)(?=\n\[|\Z)', content, re.DOTALL)
sec = m.group(1) if m else ''
mm = re.search(r'^\s*batch-size\s*=\s*(\d+)', sec, re.MULTILINE)
print(mm.group(1) if mm else '')
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

# Dynamic alignment: set batch/ubatch aligned to the section's existing '=' column.
# Inserts the lines if the section has none (a batch-less model gets them added).
set_batch() {
  local BATCH=$1
  python3 -c "
import re, sys
model='$MODEL'; batch=$BATCH; ini='$INI'
with open(ini) as f: content = f.read()
m = re.search(r'(\['+re.escape(model)+r'\])(.*?)(?=\n\[|\Z)', content, re.DOTALL)
if not m: print('ERROR'); sys.exit(1)
section = m.group(2)
# Find the existing '=' column from the section's non-batch key lines
target = None
for line in section.split('\n'):
    if '=' in line and not line.strip().startswith(('#', ';')):
        if not re.match(r'\s*(batch|ubatch)-size\s*=', line):
            target = max(target, line.index('=')) if target is not None else line.index('=')
if target is None:
    target = 17  # default: col 18
new_lines = []
found = False
for line in section.split('\n'):
    if re.match(r'\s*batch-size\s*=', line) and 'ubatch' not in line:
        pad = target - len('batch-size')
        new_lines.append('batch-size' + ' ' * pad + '= ' + str(batch))
        found = True
    elif re.match(r'\s*ubatch-size\s*=', line):
        pad = target - len('ubatch-size')
        new_lines.append('ubatch-size' + ' ' * pad + '= ' + str(batch))
    else:
        new_lines.append(line)
if not found:
    # No batch/ubatch lines in the section — insert them after the section header's
    # first key line (aligned to the section's '=' column).
    pad_b = target - len('batch-size')
    pad_u = target - len('ubatch-size')
    insert_at = 1
    # find first non-comment key line index
    for idx, line in enumerate(new_lines):
        if '=' in line and not line.strip().startswith(('#', ';')):
            insert_at = idx + 1
            break
    new_lines.insert(insert_at, 'batch-size' + ' ' * pad_b + '= ' + str(batch))
    new_lines.insert(insert_at + 1, 'ubatch-size' + ' ' * pad_u + '= ' + str(batch))
with open(ini, 'w') as f:
    f.write(content[:m.start(2)] + '\n'.join(new_lines) + content[m.end(2):])
print(f'  batch={batch} ubatch={batch} (= at col {target+1})')
"
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

# ── Shared infra: restart + log-marked OOM detection ───────
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

LOG_MARK=0
logmark() { LOG_MARK=$(docker logs $DOCKER_LOG 2>&1 | wc -l); }
oom_since_mark() {
  docker logs $DOCKER_LOG 2>&1 | tail -n +$((LOG_MARK + 1)) | grep -iE "$OMG_GREP" || true
}
oom_count_since_mark() { oom_since_mark | wc -l | tr -d ' '; }

# ── Probe primitives ────────────────────────────────────────
tiny_probe() {
  logmark
  log "  Probe started $(date +%H:%M:%S)..."
  curl -s --max-time 300 -X POST http://localhost:8080/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"max_tokens\":8}" \
    > /tmp/probe.json 2>&1
  local OOM=$(oom_count_since_mark)
  if [ "$OOM" -gt 0 ]; then
    log "  OOM: $(oom_since_mark | head -1)"
    return 1
  fi
  python3 -c "import json; d=json.load(open('/tmp/probe.json')); exit(0 if 'choices' in d else 1)" 2>/dev/null
  return $?
}

# Measure chars-per-token ratio for this model (also warms the model up).
# Cached after the first successful measurement — reused across all phases/candidates.
CHARS_PER_TOK=0
measure_ratio() {
  # skip the probe if we already have a cached ratio
  if python3 -c "exit(0 if float($CHARS_PER_TOK) > 0 else 1)" 2>/dev/null; then
    return 0
  fi
  local MEASURE_CHARS=2000
  python3 -c "
import json
payload = {'model':'$MODEL','messages':[{'role':'user','content':('The history of computing is long and complex. '*30000)[:$MEASURE_CHARS]}],'max_tokens':1}
with open('/tmp/ratio_payload.json','w') as f: json.dump(payload, f)
"
  logmark
  curl -s --max-time 300 -X POST http://localhost:8080/v1/chat/completions \
    -H 'Content-Type: application/json' -d @/tmp/ratio_payload.json \
    > /tmp/ratio_response.json 2>&1
  local TOK=$(python3 -c "
import json
try:
    d = json.load(open('/tmp/ratio_response.json'))
    print(d.get('usage',{}).get('prompt_tokens',0))
except: print(0)
" 2>/dev/null || echo 0)
  if [ "$TOK" -gt 0 ] 2>/dev/null; then
    CHARS_PER_TOK=$(python3 -c "print('%.1f' % ($MEASURE_CHARS / $TOK))" 2>/dev/null || echo 0)
    log "  Measured ratio: $MEASURE_CHARS chars = $TOK tokens → ${CHARS_PER_TOK} chars/tok"
    return 0
  fi
  log "  Measure probe failed — using fallback heuristic"
  CHARS_PER_TOK=0
  return 1
}

saturation_test() {
  local CTX=$1
  local MAX_TOK=$(python3 -c "print(int($CTX * 0.2))")
  local TARGET_TOK=$(python3 -c "print(int($CTX * 0.85))")
  local SAT_SIZE=0
  local ATTEMPT=1

  measure_ratio || true
  if python3 -c "exit(0 if float($CHARS_PER_TOK) > 0 else 1)" 2>/dev/null; then
    SAT_SIZE=$(python3 -c "print(int($TARGET_TOK * $CHARS_PER_TOK))")
    log "  Saturation: target ~${TARGET_TOK} tokens (85% of ctx), prompt ~${SAT_SIZE} chars, max_tokens=$MAX_TOK"
  else
    SAT_SIZE=$(python3 -c "print(int($CTX * 2.5))")
    log "  Saturation: fallback prompt ~${SAT_SIZE} chars, max_tokens=$MAX_TOK"
  fi

  while [ "$ATTEMPT" -le 3 ]; do
    python3 -c "
import json
payload = {'model':'$MODEL','messages':[{'role':'user','content':('The history of computing is long and complex. '*30000)[:$SAT_SIZE]}],'max_tokens':$MAX_TOK,'ignore_eos':True}
with open('/tmp/sat_payload.json','w') as f: json.dump(payload, f)
print(f'  Payload: {len(json.dumps(payload))} bytes')
"
    logmark
    # Background curl + OOM watchdog: kill early if the log shows an OOM marker
    # (dead-child/router cleanup can otherwise stall the request for ~10s+)
    curl -s --max-time 600 -X POST http://localhost:8080/v1/chat/completions \
      -H 'Content-Type: application/json' -d @/tmp/sat_payload.json \
      > /tmp/sat_response.json 2>&1 &
    local SAT_PID=$!
    local WATCH=0
    while kill -0 $SAT_PID 2>/dev/null; do
      if [ "$(oom_count_since_mark)" -gt 0 ]; then
        log "  Saturation: OOM detected — killing curl"
        kill $SAT_PID 2>/dev/null
        break
      fi
      WATCH=$((WATCH + 1))
      [ $((WATCH % 30)) -eq 0 ] && log "    ...watchdog ${WATCH}x2s (request still running)"
      sleep 2
    done
    wait $SAT_PID 2>/dev/null || true

    if grep -q "exceeds the available context" /tmp/sat_response.json 2>/dev/null; then
      log "  Prompt too large — shrinking 10% (attempt $ATTEMPT)"
      SAT_SIZE=$(python3 -c "print(int($SAT_SIZE * 0.9))")
      ATTEMPT=$((ATTEMPT + 1))
      continue
    fi
    break
  done

  local OOM=$(oom_count_since_mark)
  if [ "$OOM" -gt 0 ]; then
    log "  Saturation: OOM"
    oom_since_mark | tail -2 | tee -a "$LOG_FILE"
    return 1
  fi
  python3 -c "
import json; d=json.load(open('/tmp/sat_response.json'))
if 'choices' in d:
    t=d.get('timings',{}); u=d.get('usage',{})
    print(f'  Saturation: PASS (prompt_tokens={u.get(\"prompt_tokens\",\"?\")}, completion_tokens={u.get(\"completion_tokens\",\"?\")})')
else: print(f'  Saturation: FAIL'); exit(1)
" 2>/dev/null; return $?
}

long_decode_check() {
  log "  Long-decode: essay prompt, max_tokens=6000..."
  python3 -c "
import json
with open('/tmp/longdec_payload.json','w') as f:
    json.dump({'model':'$MODEL','messages':[{'role':'user','content':'Write a detailed essay explaining the history of computing.'}],'max_tokens':6000,'ignore_eos':True}, f)
"
  logmark
  curl -s --max-time 600 -X POST http://localhost:8080/v1/chat/completions \
    -H 'Content-Type: application/json' -d @/tmp/longdec_payload.json \
    > /tmp/longdec_response.json 2>&1
  local OOM=$(oom_count_since_mark)
  if [ "$OOM" -gt 0 ]; then log "  Long-decode: OOM"; return 1; fi
  python3 -c "
import json; d=json.load(open('/tmp/longdec_response.json'))
if 'choices' in d:
    t=d.get('timings',{}); u=d.get('usage',{})
    print(f'  Long-decode: PASS (completion_tokens={u.get(\"completion_tokens\",\"?\")}, decode={t.get(\"predicted_per_second\",0):.1f} t/s)')
else: print('  Long-decode: FAIL'); exit(1)
" 2>/dev/null; return $?
}

# Measure prefill + decode speed at the CURRENT batch (75%-ctx prefill probe,
# then a full 4000-token decode window). Echoes "prefill_t_s|decode_t_s|cpu".
measure_speed() {
  local CTX=$1
  measure_ratio >&2 || true   # progress → stderr; stdout reserved for the result
  local PREFILL_CHARS=0
  if python3 -c "exit(0 if float($CHARS_PER_TOK) > 0 else 1)" 2>/dev/null; then
    PREFILL_CHARS=$(python3 -c "print(int($CTX * 0.75 * $CHARS_PER_TOK))")
  else
    PREFILL_CHARS=$(python3 -c "print(int($CTX * 0.75 * 4))")
  fi

  # Prefill probe (75% ctx, max_tokens=1)
  python3 -c "
import json
payload = {'model':'$MODEL','messages':[{'role':'user','content':('The history of computing is long and complex. '*30000)[:$PREFILL_CHARS]}],'max_tokens':1,'ignore_eos':True}
with open('/tmp/perf_prefill_payload.json','w') as f: json.dump(payload, f)
"
  curl -s --max-time 600 -X POST http://localhost:8080/v1/chat/completions \
    -H 'Content-Type: application/json' -d @/tmp/perf_prefill_payload.json \
    > /tmp/perf_prefill.json 2>&1

  # Decode probe (short prompt, full 4000-token window) — poll CPU during it
  # for GPU-residency classification
  python3 -c "
import json
payload = {'model':'$MODEL','messages':[{'role':'user','content':'Explain the history of computing in detail.'}],'max_tokens':4000,'ignore_eos':True}
with open('/tmp/perf_decode_payload.json','w') as f: json.dump(payload, f)
"
  curl -s --max-time 600 -X POST http://localhost:8080/v1/chat/completions \
    -H 'Content-Type: application/json' -d @/tmp/perf_decode_payload.json \
    > /tmp/perf_decode.json 2>&1 &
  local DEC_PID=$!
  local CPU_SAMPLES=()
  for i in $(seq 1 40); do
    local TOP CPU
    TOP=$(top -bn1 2>/dev/null | grep llama-s | head -n1)
    CPU=$(echo "$TOP" | awk '{print $9}' 2>/dev/null || echo "0")
    [ -n "$CPU" ] && [ "$CPU" != "0.0" ] && CPU_SAMPLES+=("$CPU")
    if ! kill -0 $DEC_PID 2>/dev/null; then break; fi
    sleep 2
  done
  wait $DEC_PID 2>/dev/null || true

  # Avg CPU (skip first sample = warmup), min 2 samples
  local CPU_SUM=0 CPU_CNT=0 AVG_CPU=0
  for idx in $(seq 1 $((${#CPU_SAMPLES[@]} - 1))); do
    [ -z "${CPU_SAMPLES[$idx]:-}" ] && continue
    CPU_SUM=$(echo "$CPU_SUM + ${CPU_SAMPLES[$idx]}" | bc 2>/dev/null || echo 0)
    CPU_CNT=$((CPU_CNT + 1))
  done
  [ "$CPU_CNT" -gt 0 ] && AVG_CPU=$(echo "scale=1; $CPU_SUM / $CPU_CNT" | bc)

  python3 -c "
import json
def ts(path, key):
    try:
        d = json.load(open(path))
        if 'choices' in d:
            return d.get('timings', {}).get(key, 0)
    except Exception: pass
    return 0
p = ts('/tmp/perf_prefill.json', 'prompt_per_second')
d = ts('/tmp/perf_decode.json', 'predicted_per_second')
print(f'{p:.1f}|{d:.1f}|${AVG_CPU:-0}')
"
}

# ── MTP capability detection (try-it-and-see) ──────────────
# Snapshots the model's section to a temp file, sets MTP config, restarts, probes.
# MTP supported = probe succeeds AND log shows MTP engagement.
# On failure, restores the original section and exits 1 (caller decides).
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

# ── MTP tuning decode test (essay + placement polling) ──────
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

# ── SUBCOMMAND: mtpcheck ────────────────────────────────────
# Empirically determine MTP capability, write spec-type to models.ini.
# Exit 0 = MTP-capable (spec-type left set), 1 = not MTP (config restored).
cmd_mtpcheck() {
  local IS_MTP=1
  detect_mtp || IS_MTP=0
  if [ "$IS_MTP" -eq 0 ]; then
    return 1
  fi
  return 0
}

# ── SUBCOMMAND: mtp (tuning only; capability pre-settled) ───
cmd_mtp() {
  if ! grep -q "spec-type.*draft-mtp" <(read_section); then
    echo "  ERROR: $MODEL has no spec-type=draft-mtp — run 'bench.sh mtpcheck $MODEL' first"
    exit 1
  fi
  local CTX=$(read_ctx)
  log ""; log "Model: $MODEL | ctx: $CTX"

  # ── Phase B: n_max sweep {1,2,3,4,5} at p_min=0.7 ──
  local NMAX_VALUES="1 2 3 4 5"
  local WIN_NMAX=0
  declare -A NMAX_RESULTS
  log ""; log "=== PHASE B: n_max SWEEP (p_min=0.7) ==="
  for N in $NMAX_VALUES; do
    set_key spec-draft-n-max "$N"
    set_key spec-draft-p-min 0.7
    restart
    local RESULT SPEED ACC PLACEMENT AVGCPU QUALITY OOM
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
  log ""; log "  WINNING n_max: $WIN_NMAX"

  # ── Phase C: p_min sweep {0.5,0.6,0.7,0.8,0.9} at winning n_max ──
  local PMIN_VALUES="0.5 0.6 0.7 0.8 0.9"
  local WIN_PMIN=0.7
  declare -A PMIN_RESULTS
  log ""; log "=== PHASE C: p_min SWEEP (n_max=$WIN_NMAX) ==="
  for P in $PMIN_VALUES; do
    set_key spec-draft-n-max "$WIN_NMAX"
    set_key spec-draft-p-min "$P"
    restart
    local RESULT SPEED ACC PLACEMENT AVGCPU QUALITY OOM
    RESULT=$(run_decode_test "n_max=$WIN_NMAX, p_min=$P")
    IFS='|' read -r SPEED ACC PLACEMENT AVGCPU QUALITY OOM <<< "$RESULT"
    PMIN_RESULTS[$P]="$SPEED|$ACC|$PLACEMENT|$QUALITY|$OOM"
    if [ "$OOM" -eq 0 ] && [ "$PLACEMENT" != "CPU" ] && [ "${QUALITY:-0}" -lt 2 ] 2>/dev/null; then
      WIN_PMIN=$P
    fi
  done

  log ""; log "=== APPLYING WINNERS ==="
  set_key spec-draft-n-max "$WIN_NMAX"
  set_key spec-draft-p-min "$WIN_PMIN"

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
}

# ── SUBCOMMAND: bisect (batch ceiling + Phase 4 sweep) ──────
# Args: MODEL, then optional TEST_BATCH | resume <lo> <hi> | resume <batch>
cmd_bisect() {
  local TEST_BATCH=0 RESUME=0 RESUME_LO=0 RESUME_HI=0 RESUME_BATCH=0
  if [ $# -ge 2 ]; then
    if [ "$2" = "resume" ]; then
      if [[ "${3:-}" =~ ^[0-9]+$ ]] && [[ "${4:-}" =~ ^[0-9]+$ ]]; then
        RESUME=1; RESUME_LO=$3; RESUME_HI=$4
        if ! [ "$RESUME_LO" -gt 0 ] 2>/dev/null || ! [ "$RESUME_HI" -gt "$RESUME_LO" ] 2>/dev/null; then
          echo "Usage: bench.sh bisect <model> resume <lo> <hi>"; exit 1
        fi
      elif [[ "${3:-}" =~ ^[0-9]+$ ]]; then
        RESUME_BATCH=1; TEST_BATCH=$3
      else
        echo "Usage: bench.sh bisect <model> resume <lo> <hi> | resume <batch>"; exit 1
      fi
    elif [[ "$2" =~ ^[0-9]+$ ]]; then
      TEST_BATCH=$2
    fi
  fi

  local CTX=$(read_ctx)
  [ -z "$CTX" ] && { log "ERROR: ctx-size not found for [$MODEL]"; exit 1; }

  # Snapshot the model's original batch so a failed run can restore it
  # (a mid-sweep crash must not leave a partial candidate in models.ini).
  local ORIG_BATCH=$(read_batch)
  local RESTORED=0
  restore_batch() {
    [ "$RESTORED" -eq 1 ] && return
    if [ -n "$ORIG_BATCH" ]; then
      log "  Restoring original batch=$ORIG_BATCH (run did not complete)"
      set_batch "$ORIG_BATCH" >/dev/null 2>&1
    fi
    RESTORED=1
  }
  # Restore on failure only; the success path sets the winner before exiting 0.
  trap 'RC=$?; if [ "$RC" -ne 0 ]; then restore_batch; fi; exit $RC' EXIT

  log "Model: $MODEL | ctx: $CTX | test-batch: $TEST_BATCH"

  if [ "$TEST_BATCH" -gt 0 ] 2>/dev/null; then
    if [ "$RESUME_BATCH" -eq 1 ]; then
      log ""; log "=== RESUMING VALIDATION OF BATCH $TEST_BATCH ==="
    else
      log ""; log "=== TESTING BATCH $TEST_BATCH ==="
    fi
    set_batch "$TEST_BATCH"; restart
    log ""; log "=== PHASE 1: TINY PROBE ==="
    tiny_probe && log "  PASS" || { log "  FAIL"; exit 1; }
    log ""; log "=== PHASE 2: SATURATION ==="
    saturation_test "$CTX" || { log "  FAILED"; exit 1; }
    log ""; log "=== PHASE 3: LONG-DECODE ==="
    long_decode_check || true
    log ""; log "=== RESULT: batch=$TEST_BATCH ubatch=$TEST_BATCH ==="
    log "=== DONE ==="
    exit 0
  fi

  local LO HI VALIDATED PASS CANDIDATES
  if [ "$RESUME" -eq 1 ]; then
    LO=$RESUME_LO; HI=$RESUME_HI
    log ""; log "=== RESUMING BISECT (lo=$LO, hi=$HI, gap=$((HI-LO))) — skipping coarse sweep ==="
  else
    # ── PHASE 1: CEILING SEARCH (ctx first, then 2048+doubling ladder) ──
    # The max useful batch can never exceed ctx. Test ctx first: PASS → the value
    # is ctx. If ctx OOMs, the real ceiling is almost always ≤ 16384 (fleet data:
    # every batch != ctx model is 448–8640), so jump straight to 2048 and ladder
    # UP by doubling (2048 → 4096 → 8192 → 16384 → 32768…) — never halve down from
    # a 64K/128K ctx. A failing rung becomes HI; Phase 2 bisects [LO, HI].
    ceiling_probe() {
      local B=$1
      set_batch "$B"; restart
      log "  Tiny probe @ batch=$B..."
      if tiny_probe; then
        log "  Probe PASS at $B — saturation-validating..."
        if saturation_test "$CTX"; then
          log "  PASS at $B (probe + saturation)"
          return 0
        fi
      fi
      log "  OOM at $B"
      return 1
    }

    log ""; log "=== PHASE 1: CEILING SEARCH (ctx=$CTX, ladder 2048→up) ==="
    LO=0; HI=0; VALIDATED=0

    # Probe 1: ctx itself
    if ceiling_probe "$CTX"; then
      LO=$CTX; HI=$((CTX + 64)); VALIDATED=$CTX
      log "  Bracket: lo=$LO (PASS), hi=$HI (assumed OOM above)"
    else
      HI=$CTX
      if [ "$CTX" -gt 2048 ]; then
        # Jump to the realistic region and ladder UP by doubling
        if ceiling_probe 2048; then
          LO=2048
          RUNG=2048
          while [ $((RUNG * 2)) -lt "$HI" ]; do
            RUNG=$((RUNG * 2))
            if ceiling_probe "$RUNG"; then
              LO=$RUNG
            else
              HI=$RUNG
              break
            fi
          done
        else
          # 2048 OOMs — halve DOWN from 2048 (cheap: few probes to sub-2048 values)
          HI=2048
          B=1024
          while [ "$B" -ge 64 ]; do
            if ceiling_probe "$B"; then LO=$B; break
            else HI=$B; B=$((B / 2 / 64 * 64)); fi
          done
        fi
      else
        # ctx <= 2048 and failed — halve down from ctx
        B=$((CTX / 2 / 64 * 64))
        while [ "$B" -ge 64 ]; do
          if ceiling_probe "$B"; then LO=$B; break
          else HI=$B; B=$((B / 2 / 64 * 64)); fi
        done
      fi
      if [ "$LO" -eq 0 ]; then
        log "  ERROR: no PASS found at any batch down to 64. Lower ctx or free VRAM (override-tensor=exps=CPU)."
        exit 1
      fi
      log "  Bracket: lo=$LO (PASS), hi=$HI (OOM bound)"
    fi
  fi

  # ── PHASE 2: REFINE BISECT (PASS = tiny probe AND saturation, until gap <= 64) ──
  log ""; log "=== PHASE 2: BISECT (lo=$LO, hi=$HI) — saturation-gated ==="
  CANDIDATES=0
  while [ $((HI - LO)) -gt 64 ]; do
    MID=$(((LO + HI) / 2)); REM=$((MID % 64))
    [ "$REM" -lt 32 ] && MID=$((MID - REM)) || MID=$((MID + 64 - REM))
    [ "$MID" -le "$LO" ] && MID=$((LO + 64))
    [ "$MID" -ge "$HI" ] && MID=$((HI - 64))
    [ "$MID" -le "$LO" ] && break; [ "$MID" -ge "$HI" ] && break
    CANDIDATES=$((CANDIDATES + 1))
    log ""; log "  Testing batch=$MID (lo=$LO, hi=$HI, gap=$((HI-LO)))..."
    set_batch "$MID"; restart; log "  Tiny probe..."
    if tiny_probe; then
      log "  Probe PASS — running saturation..."
      if saturation_test "$CTX"; then
        log "  PASS (probe + saturation)"; LO=$MID
      else
        log "  FAIL (saturation)"; HI=$MID
      fi
    else
      log "  OOM (probe)"; HI=$MID
    fi
  done
  VALIDATED=$LO
  log "  Refined lo=$LO — max batch passing tiny probe AND saturation"

  # ── FINAL CONFIRM (winner already passed saturation in the gated bisect;
  #    this fresh-restart run is the single re-confirm) ──
  log ""; log "=== FINAL CONFIRM (batch=$VALIDATED) ==="
  set_batch "$VALIDATED"; restart
  PASS=0
  if saturation_test "$CTX"; then
    PASS=1
    log "  *** VALIDATED batch=$VALIDATED ***"
  else
    # Bracketed halve-down + bisect (O(log) — replaces the -64 grind)
    log "  Final confirm FAIL — bracketed halve-down search"
    HI=$VALIDATED; LO=0
    local BATCH=$((VALIDATED / 2))
    while [ "$BATCH" -ge 64 ]; do
      set_batch "$BATCH"; restart
      if saturation_test "$CTX"; then LO=$BATCH; break
      else HI=$BATCH; BATCH=$((BATCH / 2)); fi
    done
    while [ $((HI - LO)) -gt 64 ]; do
      MID=$(((LO + HI) / 2)); MID=$((MID / 64 * 64))
      [ "$MID" -le "$LO" ] && MID=$((LO + 64))
      set_batch "$MID"; restart
      if saturation_test "$CTX"; then LO=$MID; else HI=$MID; fi
    done
    VALIDATED=$LO
    PASS=1
    log "  *** Saturation-validated batch=$VALIDATED (bracketed search) ***"
  fi

  log ""; log "=== LONG-DECODE CHECK ==="
  set_batch "$VALIDATED"; restart
  long_decode_check || true

  # ── RESIDENCY-GATED PHASE 4 SKIP ──
  # Only when the ceiling IS ctx (small-ctx model that fits at ctx on the first
  # probe) is a single residency check enough to decide whether the sweep is
  # worth running. GPU-resident ctx → ctx is the value, skip Phase 4 entirely.
  # CPU-spilled ctx → Phase 4 sweeps below and its residency filter finds the
  # largest GPU-resident batch (e.g. a 128K ctx that passes OOM but decodes on
  # CPU while 32K is 100% GPU — Phase 4 picks 32K).
  if [ "$VALIDATED" -eq "$CTX" ]; then
    log ""; log "=== RESIDENCY CHECK (batch=$VALIDATED == ctx) ==="
    local SCORE_OF AVG_CPU
    SCORE_OF=$(measure_speed "$CTX")
    AVG_CPU=$(echo "$SCORE_OF" | cut -d'|' -f3)
    if [ -n "$AVG_CPU" ] && [ "$(echo "$AVG_CPU > 200" | bc -l)" = "1" ]; then
      log "  ctx spilled to CPU (avg ${AVG_CPU}%) — running Phase 4 to find the GPU-resident ceiling"
    else
      log "  ctx is GPU-resident (avg ${AVG_CPU:-?}%) — batch value is ctx, skipping Phase 4"
      set_batch "$VALIDATED"
      log ""; log "  *** PERFORMANCE-OPTIMIZED batch=$VALIDATED (ctx, GPU-resident) ***"
      log ""; log "=== RESULT ==="
      log "  batch=$VALIDATED ubatch=$VALIDATED ctx=$CTX"
      log "  candidates=0 saturation-confirm=$PASS/1"
      log "  residency: ctx passes + GPU-resident — no sweep needed"
      log ""; log "  Next: run bench.sh bench $MODEL"
      log "=== DONE ==="
      exit 0
    fi
  fi

  # ── PHASE 4: PERFORMANCE SWEEP (find fastest batch below the ceiling) ──
  log ""; log "=== PHASE 4: PERFORMANCE SWEEP (ceiling=$VALIDATED) ==="
  # Candidate batches: ceiling, /2, /4, /8, /16, floor 2048
  local CAND_LIST
  CAND_LIST=$(python3 -c "
ceiling=$VALIDATED
vals = set()
for d in (1, 2, 4, 8, 16):
    v = (ceiling // d) // 64 * 64
    if v >= 2048: vals.add(v)
vals.add(2048)
print(' '.join(str(v) for v in sorted(vals)))
")
  local BEST_BATCH=$VALIDATED BEST_SCORE=0
  declare -A SWEEP_RESULTS
  declare -A FINALIST_SCORES
  local SCORE_OF=""
  for B in $CAND_LIST; do
    log ""; log "  Bench candidate batch=$B..."
    set_batch "$B"; restart
    SCORE_OF=$(measure_speed "$CTX")
    local PRE=$(echo "$SCORE_OF" | cut -d'|' -f1)
    local DEC=$(echo "$SCORE_OF" | cut -d'|' -f2)
    local AVG_CPU=$(echo "$SCORE_OF" | cut -d'|' -f3)
    # GPU-residency filter: a candidate that spills compute to CPU (avg CPU > 200%)
    # is inherently slower (documented rationale) — exclude it from winning.
    if [ -n "$AVG_CPU" ] && [ "$(echo "$AVG_CPU > 200" | bc -l)" = "1" ]; then
      log "  batch=$B: SPILL to CPU (avg ${AVG_CPU}%) — EXCLUDED"
      SWEEP_RESULTS[$B]="SPILL"
      continue
    fi
    # combined throughput: total tokens / total time over a representative workload
    # (75%-ctx prompt + 4000-token decode), self-weighted by phase duration
    local SCORE
    SCORE=$(python3 -c "
p=$PRE; d=$DEC; pt=$((CTX * 3 / 4)); dt=4000
if p <= 0 or d <= 0:
    print('0')
else:
    print('%.1f' % ((pt + dt) / (pt/p + dt/d)))
")
    SWEEP_RESULTS[$B]="$PRE|$DEC|$SCORE|$AVG_CPU"
    log "  batch=$B: prefill=${PRE} t/s, decode=${DEC} t/s, cpu=${AVG_CPU}% → score=$SCORE"
    if [ "$(echo "$SCORE > $BEST_SCORE" | bc -l)" = "1" ]; then
      BEST_SCORE=$SCORE; BEST_BATCH=$B
    fi
  done

  # ── Flat-field gate: if every GPU-resident candidate scores within the
  # noise floor (spread ≤ 3% of max), the sweep is selecting noise — batch
  # has no meaningful throughput effect at this ctx (small-ctx workloads are
  # decode-dominated; decode does not move with batch). Skip the finalists
  # and take the LARGEST GPU-resident candidate (the ceiling) for headroom.
  local MAX_SCORE MIN_SCORE
  MAX_SCORE=$(for B in $CAND_LIST; do
    V="${SWEEP_RESULTS[$B]}"; [ "$V" = "SPILL" ] && continue
    echo "$V" | cut -d'|' -f3
  done | python3 -c "
import sys
scores = [float(l) for l in sys.stdin if l.strip()]
print('%.1f' % max(scores)) if scores else print('0')
")
  MIN_SCORE=$(for B in $CAND_LIST; do
    V="${SWEEP_RESULTS[$B]}"; [ "$V" = "SPILL" ] && continue
    echo "$V" | cut -d'|' -f3
  done | python3 -c "
import sys
scores = [float(l) for l in sys.stdin if l.strip()]
print('%.1f' % min(scores)) if scores else print('0')
")
  if [ "$(echo "$MAX_SCORE > 0" | bc -l)" = "1" ] && [ "$(echo "($MAX_SCORE - $MIN_SCORE) / $MAX_SCORE <= 0.03" | bc -l)" = "1" ]; then
    # largest GPU-resident candidate (CAND_LIST is ascending → scan from the end)
    local LARGEST_RESIDENT=""
    for B in $(echo "$CAND_LIST" | tr ' ' '\n' | sort -rn); do
      V="${SWEEP_RESULTS[$B]}"; [ "$V" = "SPILL" ] && continue
      LARGEST_RESIDENT=$B; break
    done
    if [ -n "$LARGEST_RESIDENT" ]; then
      VALIDATED=$LARGEST_RESIDENT
      V="${SWEEP_RESULTS[$VALIDATED]}"
      BEST_SCORE=$(echo "$V" | cut -d'|' -f3)
      log ""; log "  Flat field: scores tied within 3% (max=${MAX_SCORE}, min=${MIN_SCORE}, spread=$(python3 -c "print('%.1f' % (($MAX_SCORE - $MIN_SCORE) / $MAX_SCORE * 100))")%)"
      log "  → skipping finalists, taking largest GPU-resident batch=$VALIDATED (headroom at zero throughput cost)"
      set_batch "$VALIDATED"
      log ""; log "  *** PERFORMANCE-OPTIMIZED batch=$VALIDATED (score=$BEST_SCORE, flat field — noise floor) ***"
      log ""; log "=== RESULT ==="
      log "  batch=$VALIDATED ubatch=$VALIDATED ctx=$CTX"
      log "  candidates=$CANDIDATES saturation-confirm=$PASS/1"
      log "  flat-field: scores tied (noise floor) — largest GPU-resident batch kept"
      log ""; log "  Next: run bench.sh bench $MODEL"
      log "=== DONE ==="
      exit 0
    fi
  fi

  # ── Re-verify top-2 finalists with 3x repeats (average score) ──
  log ""; log "  Finalists: re-verifying top candidates 3x..."
  # Rank candidates by sweep score, skipping SPILL entries (feed "batch score" via stdin)
  local TOP2
  TOP2=$(for B in $CAND_LIST; do
    V="${SWEEP_RESULTS[$B]}"
    [ "$V" = "SPILL" ] && continue
    SC=$(echo "$V" | cut -d'|' -f3)
    echo "$B $SC"
  done | python3 -c "
import sys
results = {}
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    b, score = line.split()
    results[b] = float(score)
order = sorted(results, key=results.get, reverse=True)
print(' '.join(order[:2]))
")
  for B in $TOP2; do
    local SUM_SCORE=0 RUNS=0 SPILL_COUNT=0
    for r in 1 2 3; do
      log "    Finalist batch=$B run $r..."
      set_batch "$B"; restart
      SCORE_OF=$(measure_speed "$CTX")
      local PRE=$(echo "$SCORE_OF" | cut -d'|' -f1)
      local DEC=$(echo "$SCORE_OF" | cut -d'|' -f2)
      local AVG_CPU=$(echo "$SCORE_OF" | cut -d'|' -f3)
      # reject a finalist if a repeat run spills to CPU
      if [ -n "$AVG_CPU" ] && [ "$(echo "$AVG_CPU > 200" | bc -l)" = "1" ]; then
        log "      run $r: SPILL (avg ${AVG_CPU}%) — penalizing"
        SPILL_COUNT=$((SPILL_COUNT + 1))
        continue
      fi
      SUM_SCORE=$(python3 -c "
p=$PRE; d=$DEC; pt=$((CTX * 3 / 4)); dt=4000
s = (pt + dt) / (pt/p + dt/d) if p > 0 and d > 0 else 0
print('%.1f' % ($SUM_SCORE + s))
")
      RUNS=$((RUNS + 1))
    done
    if [ "$RUNS" -eq 0 ]; then
      log "    Finalist batch=$B: all runs spilled — EXCLUDED"
      continue
    fi
    local AVG
    AVG=$(python3 -c "print('%.1f' % ($SUM_SCORE / $RUNS))")
    log "    Finalist batch=$B avg score=$AVG ($RUNS clean runs, $SPILL_COUNT spilled)"
    FINALIST_SCORES[$B]="$AVG"
  done

  # Winner = the finalist with the highest AVERAGED re-run score (direct
  # comparison — not vs the single-run sweep score). On an equal average, the
  # LARGER batch wins (headroom at zero throughput cost). Fall back to the
  # sweep best only if every finalist spilled.
  VALIDATED=$BEST_BATCH
  if [ ${#FINALIST_SCORES[@]} -gt 0 ]; then
    BEST_SCORE=0
    for B in $TOP2; do
      AVG="${FINALIST_SCORES[$B]:-}"
      [ -z "$AVG" ] && continue
      if [ "$(echo "$AVG > $BEST_SCORE" | bc -l)" = "1" ]; then
        BEST_SCORE=$AVG; VALIDATED=$B
      elif [ "$(echo "$AVG == $BEST_SCORE" | bc -l)" = "1" ] && [ "$B" -gt "$VALIDATED" ]; then
        VALIDATED=$B
      fi
    done
  fi
  set_batch "$VALIDATED"
  log ""; log "  *** PERFORMANCE-OPTIMIZED batch=$VALIDATED (score=$BEST_SCORE) ***"

  log ""; log "=== RESULT ==="
  log "  batch=$VALIDATED ubatch=$VALIDATED ctx=$CTX"
  log "  candidates=$CANDIDATES saturation-confirm=$PASS/1"
  log "  perf-sweep: fastest batch below ceiling (combined prefill+decode score)"
  log ""; log "  Next: run bench.sh bench $MODEL"
  log "=== DONE ==="
}

# ── SUBCOMMAND: bench (full benchmark record) ───────────────
cmd_bench() {
  local PROMPT_TOKENS=${2:-0}
  local JSON_FILE="${MODELS_DIR}/${MODEL}.json"

  # ── Environment fingerprint (host-level, captured once) ─────
  local ENV_JSON
  ENV_JSON=$(python3 - << PYEOF
import json, subprocess, platform

env = {}

# GPU
try:
    out = subprocess.run(
        ["nvidia-smi", "--query-gpu=name,driver_version,memory.total,power.limit,clocks.max.sm,clocks.max.mem,compute_cap,count",
         "--format=csv,noheader,nounits"],
        capture_output=True, text=True, timeout=15).stdout.strip()
    parts = [p.strip() for p in out.split(",")] if out else []
    env["gpu"] = {
        "name": parts[0] if len(parts) > 0 else None,
        "driver_version": parts[1] if len(parts) > 1 else None,
        "memory_total_mib": int(float(parts[2])) if len(parts) > 2 and parts[2] else None,
        "power_limit_w": float(parts[3]) if len(parts) > 3 and parts[3] else None,
        "clocks_max_sm_mhz": int(float(parts[4])) if len(parts) > 4 and parts[4] else None,
        "clocks_max_mem_mhz": int(float(parts[5])) if len(parts) > 5 and parts[5] else None,
        "compute_cap": parts[6] if len(parts) > 6 else None,
        "count": int(parts[7]) if len(parts) > 7 and parts[7] else None,
    }
except Exception:
    env["gpu"] = None

# CPU
cpu = {}
try:
    out = subprocess.run(["lscpu"], capture_output=True, text=True, timeout=15).stdout
    def g(key):
        for line in out.splitlines():
            if line.startswith(key):
                return line.split(":", 1)[1].strip()
        return None
    cpu = {
        "model": g("Model name"),
        "sockets": int(g("Socket(s)")) if g("Socket(s)") else None,
        "cores": int(g("Core(s) per socket")) if g("Core(s) per socket") else None,
        "threads": int(g("CPU(s)")) if g("CPU(s)") else None,
        "max_mhz": g("CPU max MHz"),
        "min_mhz": g("CPU min MHz"),
    }
except Exception:
    cpu = {}
env["cpu"] = cpu

# RAM total (MiB)
try:
    out = subprocess.run(["free", "-m"], capture_output=True, text=True, timeout=10).stdout
    env["ram_total_mib"] = int(out.splitlines()[1].split()[1])
except Exception:
    env["ram_total_mib"] = None

# Kernel + hostname
try:
    env["kernel"] = platform.release()
    env["hostname"] = platform.node()
    env["arch"] = platform.machine()
except Exception:
    pass

print(json.dumps(env))
PYEOF
)

  # llama.cpp build info via the running server
  local BUILD_INFO
  BUILD_INFO=$(curl -s --max-time 5 http://localhost:8080/props 2>/dev/null | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get('build_info', ''))
except: print('')
" 2>/dev/null || echo "")

  # Read ctx-size (scoped to the model's own section)
  local CTX=$(read_ctx)
  [ -z "$CTX" ] && { log "ERROR: ctx-size not found"; exit 1; }

  # Read batch-size (scoped to the model's own section)
  local BATCH=$(read_batch)
  [ -z "$BATCH" ] && { log "ERROR: batch-size not found — run 'bench.sh bisect $MODEL' first"; exit 1; }

  # Read full config: model section + [*] defaults
  local META
  META=$(python3 -c "
import re, json
with open('$INI') as f: content = f.read()
def get_section(name):
    m = re.search(r'\['+re.escape(name)+r'\](.*?)(?=\n\[|\Z)', content, re.DOTALL)
    return m.group(1) if m else ''
def kv(sec, key, default=None):
    m = re.search(r'^\s*'+re.escape(key)+r'\s*=\s*(\S+)', sec, re.MULTILINE)
    return m.group(1) if m else default

sec = get_section('$MODEL')
star = get_section('*')
spec_type = kv(sec, 'spec-type')
n_max = kv(sec, 'spec-draft-n-max')
p_min = kv(sec, 'spec-draft-p-min')
hf = kv(sec, 'hf')
print(json.dumps({
    'config': {
        'temp': kv(sec, 'temp', kv(star, 'temp')),
        'top_k': kv(sec, 'top-k', kv(star, 'top-k')),
        'top_p': kv(sec, 'top-p', kv(star, 'top-p')),
        'min_p': kv(sec, 'min-p', kv(star, 'min-p')),
        'repeat_penalty': kv(sec, 'repeat-penalty', kv(star, 'repeat-penalty')),
        'threads': kv(sec, 'threads', kv(star, 'threads')),
        'threads_batch': kv(sec, 'threads-batch', kv(star, 'threads-batch')),
        'cache_type_k': kv(sec, 'cache-type-k', kv(star, 'cache-type-k')),
        'cache_type_v': kv(sec, 'cache-type-v', kv(star, 'cache-type-v')),
        'ngl': kv(sec, 'ngl', kv(star, 'ngl')),
        'hf': hf,
        'quant': hf.split(':')[-1] if hf and ':' in hf else None,
        'reasoning': kv(sec, 'reasoning', 'off'),
        'ctx': '$CTX',
        'batch': '$BATCH',
    },
    'mtp': {
        'is_mtp': bool(spec_type) and 'draft-mtp' in spec_type,
        'n_max': int(n_max) if n_max and n_max.isdigit() else None,
        'p_min': float(p_min) if p_min else None,
        'drafter': 'in-model' if spec_type and 'draft-mtp' in spec_type else 'none',
    },
}))
")

  # Model file size (resolve hf repo → hub cache gguf blob)
  local MODEL_FILE_SIZE
  MODEL_FILE_SIZE=$(python3 -c "
import os, glob
import re
with open('$INI') as f: c = f.read()
m = re.search(r'\['+re.escape('$MODEL')+r'\].*?hf\s*=\s*(\S+)', c, re.DOTALL)
if not m:
    print(''); exit()
repo = m.group(1).split(':')[0]
hub = os.path.join('$ROOT', '.local', 'llama-cpp_data', 'hub', 'models--' + repo.replace('/', '--'))
paths = []
for snap in sorted(glob.glob(os.path.join(hub, 'snapshots', '*'))):
    for gguf in glob.glob(os.path.join(snap, '*.gguf')):
        base = os.path.basename(gguf)
        if 'mmproj' in base or base.startswith('mtp-'):
            continue
        paths.append(gguf)
if not paths:
    print(''); exit()
p = paths[0]
size = os.path.getsize(p) if os.path.exists(p) else os.path.getsize(os.path.realpath(p))
print(f'{size/1024/1024/1024:.2f}')
" 2>/dev/null || echo "")

  # Prompt size: if not specified, use 75% of ctx
  if [ "$PROMPT_TOKENS" -eq 0 ]; then
    PROMPT_TOKENS=$((CTX * 3 / 4))
  fi

  log "Model: $MODEL | ctx: $CTX | batch: $BATCH | prompt: ${PROMPT_TOKENS} tokens"

  # ── Prefill + decode bench ──
  log ""
  log "=== PREFILL + DECODE BENCH ==="
  restart

  # Measure chars/token ratio (also warms the model so polling captures clean prefill+decode)
  log "  Measuring tokenizer ratio..."
  python3 -c "
import json
payload = {'model':'$MODEL','messages':[{'role':'user','content':('The history of computing is long and complex. '*1000)[:2000]}],'max_tokens':1}
with open('/tmp/ratio_payload.json','w') as f: json.dump(payload, f)
"
  curl -s --max-time 300 -X POST http://localhost:8080/v1/chat/completions \
    -H 'Content-Type: application/json' -d @/tmp/ratio_payload.json \
    > /tmp/ratio_response.json 2>&1 || true
  local MEASURED_TOK
  MEASURED_TOK=$(python3 -c "
import json
try:
    d = json.load(open('/tmp/ratio_response.json'))
    print(d.get('usage',{}).get('prompt_tokens',0))
except: print(0)
" 2>/dev/null || echo 0)
  local CHARS_PER_TOK_RATIO PROMPT_CHARS
  if [ "$MEASURED_TOK" -gt 0 ] 2>/dev/null; then
    CHARS_PER_TOK_RATIO=$(python3 -c "print('%.1f' % (2000 / $MEASURED_TOK))" 2>/dev/null || echo 0)
    log "  Measured: 2000 chars = $MEASURED_TOK tokens → ${CHARS_PER_TOK_RATIO} chars/tok"
    PROMPT_CHARS=$(python3 -c "print(int($PROMPT_TOKENS * $CHARS_PER_TOK_RATIO))" 2>/dev/null || echo $((PROMPT_TOKENS * 4)))
  else
    log "  Measure probe failed — fallback to $((PROMPT_TOKENS * 4)) chars"
    PROMPT_CHARS=$((PROMPT_TOKENS * 4))
  fi

  # ── Phase A: PREFILL (75%-ctx prompt, max_tokens=1) ─────────
  # Decouple decode sizing: decode uses a short 150-token prompt so the full
  # decode window fits even on small-ctx models (4k → ~3946 decode tokens).
  local DECODE_PROMPT_TOKENS=150
  local DECODE_MAX_TOKENS=$((CTX - DECODE_PROMPT_TOKENS))
  [ "$DECODE_MAX_TOKENS" -gt 4000 ] && DECODE_MAX_TOKENS=4000
  local DECODE_PROMPT_CHARS
  DECODE_PROMPT_CHARS=$(python3 -c "print(int($DECODE_PROMPT_TOKENS * $CHARS_PER_TOK_RATIO))" 2>/dev/null || echo $((DECODE_PROMPT_TOKENS * 4)))

  python3 -c "
import json
filler = 'The history of computing is long and complex. '
target_chars = $PROMPT_CHARS
prompt = ''
while len(prompt) < target_chars: prompt += filler
prompt = prompt[:target_chars]
payload = {'model':'$MODEL','messages':[{'role':'user','content':prompt}],'max_tokens':1,'ignore_eos':True}
with open('/tmp/bench_prefill_payload.json','w') as f: json.dump(payload, f)
print(f'  Prefill payload: {len(prompt)} chars, ~{$PROMPT_TOKENS} tokens (max_tokens=1)')
"

  log "  Phase A: prefill request ($PROMPT_TOKENS tokens)..."
  curl -s --max-time 300 -X POST http://localhost:8080/v1/chat/completions \
    -H 'Content-Type: application/json' -d @/tmp/bench_prefill_payload.json \
    > /tmp/bench_prefill.json 2>&1 || true

  # ── Phase B: DECODE (short prompt, placement polling) ───────
  python3 -c "
import json
filler = 'The history of computing is long and complex. '
target_chars = $DECODE_PROMPT_CHARS
prompt = ''
while len(prompt) < target_chars: prompt += filler
prompt = prompt[:target_chars]
payload = {'model':'$MODEL','messages':[{'role':'user','content':prompt}],'max_tokens':$DECODE_MAX_TOKENS,'ignore_eos':True}
with open('/tmp/bench_payload.json','w') as f: json.dump(payload, f)
print(f'  Decode payload: {len(prompt)} chars, ~$DECODE_PROMPT_TOKENS tokens (max_tokens=$DECODE_MAX_TOKENS)')
"

  # Mark log position for MTP + OOM capture of the decode request
  LOG_MARK=$(docker logs $DOCKER_LOG 2>&1 | wc -l)
  local REQUEST_START=$(date +%s)

  log "  Phase B: firing decode request..."
  curl -s --max-time 600 -X POST http://localhost:8080/v1/chat/completions \
    -H 'Content-Type: application/json' -d @/tmp/bench_payload.json \
    > /tmp/bench_output.json 2>&1 &
  local PID=$!

  # Poll CPU/GPU until the request completes (min 3 samples, capped at 160s)
  log "  Polling CPU/GPU until request completes (max $((POLL_MAX_SAMPLES * 2))s)..."
  local CPU_SAMPLES=() GPU_SAMPLES=() MEM_SAMPLES=() TEMP_SAMPLES=()
  local POWER_SAMPLES=() VRAM_SAMPLES=() CLOCK_SM_SAMPLES=() CLOCK_MEM_SAMPLES=()
  local i
  for i in $(seq 1 $POLL_MAX_SAMPLES); do
    local TOP CPU GPUSTATS GPU MEM TEMP POWER VRAM CLOCK_SM CLOCK_MEM
    TOP=$(top -bn1 2>/dev/null | grep llama-s | head -n1)
    CPU=$(echo "$TOP" | awk '{print $9}' 2>/dev/null || echo "0")
    GPUSTATS=$(nvidia-smi --query-gpu=utilization.gpu,utilization.memory,temperature.gpu,power.draw,memory.used,clocks.sm,clocks.mem --format=csv,noheader,nounits 2>/dev/null)
    GPU=$(echo "$GPUSTATS" | cut -d',' -f1 | tr -d ' ')
    MEM=$(echo "$GPUSTATS" | cut -d',' -f2 | tr -d ' ')
    TEMP=$(echo "$GPUSTATS" | cut -d',' -f3 | tr -d ' ')
    POWER=$(echo "$GPUSTATS" | cut -d',' -f4 | tr -d ' ')
    VRAM=$(echo "$GPUSTATS" | cut -d',' -f5 | tr -d ' ')
    CLOCK_SM=$(echo "$GPUSTATS" | cut -d',' -f6 | tr -d ' ')
    CLOCK_MEM=$(echo "$GPUSTATS" | cut -d',' -f7 | tr -d ' ')
    log "  $(date +%H:%M:%S) CPU: ${CPU:-0}% | GPU: ${GPU:-0}% | mem: ${MEM:-?}% | ${TEMP:-?}C | ${POWER:-?}W | VRAM: ${VRAM:-0}MiB | sm:${CLOCK_SM:-?}MHz"
    [ -n "$CPU" ] && [ "$CPU" != "0.0" ] && CPU_SAMPLES+=("$CPU")
    [ -n "$GPU" ] && GPU_SAMPLES+=("$GPU")
    [ -n "$MEM" ] && MEM_SAMPLES+=("$MEM")
    [ -n "$TEMP" ] && TEMP_SAMPLES+=("$TEMP")
    [ -n "$POWER" ] && POWER_SAMPLES+=("$POWER")
    [ -n "$VRAM" ] && VRAM_SAMPLES+=("$VRAM")
    [ -n "$CLOCK_SM" ] && CLOCK_SM_SAMPLES+=("$CLOCK_SM")
    [ -n "$CLOCK_MEM" ] && CLOCK_MEM_SAMPLES+=("$CLOCK_MEM")
    sleep 2
    if [ "$i" -ge "$POLL_MIN_SAMPLES" ] && ! kill -0 $PID 2>/dev/null; then
      log "  Request complete after ~$((i*2))s — stopping poll"
      break
    fi
  done
  wait $PID 2>/dev/null || true
  local REQUEST_END=$(date +%s)
  local WALL_TIME_S=$((REQUEST_END - REQUEST_START))

  # Log-window capture for THIS request (MTP acceptance)
  local REQ_LOGS
  REQ_LOGS=$(docker logs $DOCKER_LOG 2>&1 | tail -n +$((LOG_MARK + 1)))
  # Load-confirmation lines appear when the model first loads (during the ratio warm-up,
  # BEFORE LOG_MARK). Capture them from the whole log since the container started.
  docker logs $DOCKER_LOG > /tmp/load_logs.txt 2>&1 || true

  # Compute averages (bc-based)
  local CPU_SUM=0 CPU_CNT=0 GPU_SUM=0 GPU_CNT=0 MEM_SUM=0 MEM_CNT=0
  local c g m
  for c in "${CPU_SAMPLES[@]}"; do CPU_SUM=$(echo "$CPU_SUM + $c" | bc); CPU_CNT=$((CPU_CNT+1)); done
  for g in "${GPU_SAMPLES[@]}"; do GPU_SUM=$(echo "$GPU_SUM + $g" | bc); GPU_CNT=$((GPU_CNT+1)); done
  for m in "${MEM_SAMPLES[@]}"; do MEM_SUM=$(echo "$MEM_SUM + $m" | bc); MEM_CNT=$((MEM_CNT+1)); done
  local AVG_CPU=$(echo "scale=1; $CPU_SUM / $CPU_CNT" | bc 2>/dev/null || echo "0")
  local AVG_GPU=$(echo "scale=1; $GPU_SUM / $GPU_CNT" | bc 2>/dev/null || echo "0")
  local AVG_MEM=$(echo "scale=1; $MEM_SUM / $MEM_CNT" | bc 2>/dev/null || echo "0")

  # Peaks (shell max)
  local PEAK_VRAM=0 PEAK_POWER=0 PEAK_TEMP=0 PEAK_CLOCK_SM=0 PEAK_CLOCK_MEM=0
  local v p t cc
  for v in "${VRAM_SAMPLES[@]}"; do [ "${v:-0}" -gt "$PEAK_VRAM" ] 2>/dev/null && PEAK_VRAM=$v; done
  for p in "${POWER_SAMPLES[@]}"; do
    [ -n "$p" ] && [ "$(echo "$p > $PEAK_POWER" | bc)" = "1" ] 2>/dev/null && PEAK_POWER=$p
  done
  for t in "${TEMP_SAMPLES[@]}"; do [ "${t:-0}" -gt "$PEAK_TEMP" ] 2>/dev/null && PEAK_TEMP=$t; done
  for c in "${CLOCK_SM_SAMPLES[@]}"; do [ "${c:-0}" -gt "$PEAK_CLOCK_SM" ] 2>/dev/null && PEAK_CLOCK_SM=$c; done
  for c in "${CLOCK_MEM_SAMPLES[@]}"; do [ "${c:-0}" -gt "$PEAK_CLOCK_MEM" ] 2>/dev/null && PEAK_CLOCK_MEM=$c; done

  # CPU stddev (placement confidence)
  local CPU_STDDEV=0
  if [ "$CPU_CNT" -gt 1 ]; then
    local CPU_VALS_STR
    CPU_VALS_STR=$(printf '%s\n' "${CPU_SAMPLES[@]}")
    CPU_STDDEV=$(printf '%s\n' "$CPU_VALS_STR" | python3 -c "
import sys, statistics
vals = [float(x) for x in sys.stdin.read().split()]
print(f'{statistics.stdev(vals):.1f}')
" 2>/dev/null || echo "0")
  fi

  # Final hardware snapshot
  local HW GPU_TEMP GPU_POWER VRAM RAM RSS
  HW=$(nvidia-smi --query-gpu=temperature.gpu,power.draw,memory.used --format=csv,noheader,nounits 2>/dev/null)
  GPU_TEMP=$(echo "$HW" | cut -d',' -f1 | tr -d ' ')
  GPU_POWER=$(echo "$HW" | cut -d',' -f2 | tr -d ' ')
  VRAM=$(echo "$HW" | cut -d',' -f3 | tr -d ' ')
  RAM=$(free -m | awk '/Mem:/ {print $3}')
  RSS=$(ps aux 2>/dev/null | grep llama-server | grep -v grep | grep -v models-preset | awk '{print int($6/1024)}' | head -1)

  # Classify placement
  local PLACEMENT
  if (( $(echo "$AVG_CPU < 100" | bc -l) )); then PLACEMENT="GPU"
  elif (( $(echo "$AVG_CPU > 200" | bc -l) )); then PLACEMENT="CPU"
  else PLACEMENT="AMBIGUOUS"; fi

  # Extract speed + request signals (prefill from phase A, decode from phase B)
  local SPEED
  SPEED=$(python3 -c "
import json

def load(path):
    try:
        d = json.load(open(path))
        if 'choices' in d: return d
    except Exception: pass
    return None

pd = load('/tmp/bench_prefill.json')   # Phase A prefill
dd = load('/tmp/bench_output.json')    # Phase B decode
out = {'speed': {}, 'request': {}}

if pd:
    t = pd.get('timings', {}); u = pd.get('usage', {})
    out['speed'].update({
        'prefill_t_s': round(t.get('prompt_per_second', 0), 2),
        'prefill_ms': round(t.get('prompt_ms', 0), 2),
        'prefill_ms_per_tok': round(t.get('prompt_per_token_ms', 0), 4),
    })
    out['request']['prefill_prompt_tokens'] = u.get('prompt_tokens', 0)

if dd:
    t = dd.get('timings', {}); u = dd.get('usage', {})
    out['speed'].update({
        'decode_t_s': round(t.get('predicted_per_second', 0), 2),
        'decode_ms': round(t.get('predicted_ms', 0), 2),
        'decode_ms_per_tok': round(t.get('predicted_per_token_ms', 0), 4),
    })
    out['request'].update({
        'decode_prompt_tokens': u.get('prompt_tokens', 0),
        'max_tokens': $DECODE_MAX_TOKENS,
        'completion_tokens': u.get('completion_tokens', 0),
        'total_tokens': u.get('total_tokens', 0),
        'cached_tokens': (u.get('prompt_tokens_details') or {}).get('cached_tokens', 0),
        'cache_n': t.get('cache_n', 0),
        'predicted_n': t.get('predicted_n', 0),
        'finish_reason': dd['choices'][0].get('finish_reason'),
        'truncated': bool(dd['choices'][0].get('finish_reason') == 'length'),
    })

print(json.dumps(out))
")

  # MTP runtime capture (only if model is MTP)
  local MTP
  MTP=$(python3 -c "
import json, re
meta = json.loads('''$META''')
if not meta['mtp']['is_mtp']:
    print(json.dumps({
        'acceptance': None, 'draft_accepted': None, 'draft_generated': None,
        'draft_mean_len': None, 'n_max_confirmed': None, 'p_min_confirmed': None,
    }))
    exit()
logs = '''$REQ_LOGS'''
# acceptance from the bench request's decode
acc = re.search(r'draft acceptance = ([0-9.]+)\s*\(\s*(\d+)\s+accepted\s*/\s*(\d+)\s+generated\), mean len =\s*([0-9.]+)', logs)
# confirmed params from load log — scoped to THIS model's load block via its --alias
load_logs = open('/tmp/load_logs.txt').read()
def load_val(flag):
    # find the --alias <MODEL> line, then look backward within ~50 lines for the flag/value pair
    m = re.search(r'--alias\s*\n[^\n]*' + re.escape('$MODEL'), load_logs)
    if not m:
        return None
    block = load_logs[max(0, m.start() - 2000):m.start()]
    m2 = re.search(re.escape(flag) + r'\s*\n[^\n]*load:\s*(\S+)', block)
    return m2.group(1) if m2 else None
print(json.dumps({
    'acceptance': float(acc.group(1)) if acc else None,
    'draft_accepted': int(acc.group(2)) if acc else None,
    'draft_generated': int(acc.group(3)) if acc else None,
    'draft_mean_len': float(acc.group(4)) if acc else None,
    'n_max_confirmed': load_val(r'--spec-draft-n-max'),
    'p_min_confirmed': load_val(r'--draft-p-min'),
}))
")

  log ""
  log "=== RESULTS ==="
  python3 -c "
import json; d=json.loads('''$SPEED''')
for k,v in d.items(): print(f'  {k}: {v}')
"
  log "  placement: $PLACEMENT (avg_cpu: ${AVG_CPU}%, avg_gpu: ${AVG_GPU}%)"

  local SAMPLE_COUNT=${#CPU_SAMPLES[@]}

  # Write JSON
  python3 - << PYEOF
import json, datetime
speed = json.loads('''$SPEED''')
meta = json.loads('''$META''')
mtp = json.loads('''$MTP''')
env = json.loads('''$ENV_JSON''')

data = {
    'model': '$MODEL',
    'ctx': $CTX,
    'batch': $BATCH,
    'ubatch': $BATCH,
    'placement': '$PLACEMENT',
    'bench_date': datetime.datetime.now().isoformat(),
    'bench_method': 'bench_model.sh v2',
    'config': meta['config'],
    'bench': {
        'max_tokens': $DECODE_MAX_TOKENS,
        'prefill_prompt_tokens': $PROMPT_TOKENS,
        'decode_prompt_tokens': $DECODE_PROMPT_TOKENS,
        'model_file_size_gb': ${MODEL_FILE_SIZE:-null},
        'build_info': '${BUILD_INFO}',
        'wall_time_s': $WALL_TIME_S,
    },
    'speed': speed.get('speed', {}),
    'request': speed.get('request', {}),
    'mtp': {
        **mtp,
        'configured_n_max': meta['mtp']['n_max'],
        'configured_p_min': meta['mtp']['p_min'],
        'drafter': meta['mtp']['drafter'],
    },
    'hardware': {
        **env,
        'run': {
            'avg_cpu_pct': ${AVG_CPU:-0},
            'avg_gpu_util_pct': ${AVG_GPU:-0},
            'avg_gpu_mem_util_pct': ${AVG_MEM:-0},
            'cpu_stddev_pct': ${CPU_STDDEV:-0},
            'peak_vram_mib': ${PEAK_VRAM:-0},
            'peak_power_w': ${PEAK_POWER:-0},
            'peak_temp_c': ${PEAK_TEMP:-0},
            'peak_clocks_sm_mhz': ${PEAK_CLOCK_SM:-0},
            'peak_clocks_mem_mhz': ${PEAK_CLOCK_MEM:-0},
            'final_vram_mib': ${VRAM:-0},
            'final_temp_c': ${GPU_TEMP:-0},
            'final_power_w': ${GPU_POWER:-0},
            'ram_used_mib': ${RAM:-0},
            'rss_mib': ${RSS:-0},
            'sample_count': $SAMPLE_COUNT,
        },
    },
}

with open('$JSON_FILE', 'w') as f:
    json.dump(data, f, indent=2)
print("JSON written to $JSON_FILE")
PYEOF

  log "=== DONE: $MODEL ==="
}

# ── Full-suite orchestrator (mtpcheck → bisect → mtp → bench) ──
run_full_suite() {
  declare -A VERDICTS
  local i NAME s
  for i in $MODEL_IDXS; do
    NAME=$(model_name "$i")
    MODEL=$NAME
    lshow ""
    lshow "=============== MODEL: $NAME ==============="
    local IS_MTP=0 BISECT_FAILED=0

    # step 1: mtpcheck
    lshow "  $(date +%H:%M:%S) starting mtpcheck for $NAME"
    if ( cmd_mtpcheck ); then
      IS_MTP=1
      VERDICTS["$NAME|mtpcheck"]="OK"
    else
      IS_MTP=0
      VERDICTS["$NAME|mtpcheck"]="SKIPPED (not MTP)"
    fi
    lshow "  $(date +%H:%M:%S) finished mtpcheck for $NAME"

    # step 2: bisect (runs against the true MTP state set by mtpcheck)
    lshow "  $(date +%H:%M:%S) starting bisect for $NAME"
    if ( cmd_bisect ); then
      VERDICTS["$NAME|bisect"]="OK"
    else
      BISECT_FAILED=1
      VERDICTS["$NAME|bisect"]="FAIL"
      lshow "  bisect FAILED — will skip bench for this model (stale batch risk)"
    fi
    lshow "  $(date +%H:%M:%S) finished bisect for $NAME"

    # step 3: mtp tuning (only if MTP-capable and bisect succeeded)
    if [ "$BISECT_FAILED" -eq 1 ]; then
      VERDICTS["$NAME|mtp"]="SKIPPED (bisect failed)"
    elif [ "$IS_MTP" -eq 0 ]; then
      VERDICTS["$NAME|mtp"]="SKIPPED (not MTP)"
    else
      lshow "  $(date +%H:%M:%S) starting mtp for $NAME"
      if ( cmd_mtp ); then
        VERDICTS["$NAME|mtp"]="OK"
      else
        VERDICTS["$NAME|mtp"]="FAIL"
      fi
      lshow "  $(date +%H:%M:%S) finished mtp for $NAME"
    fi

    # step 4: bench
    if [ "$BISECT_FAILED" -eq 1 ]; then
      lshow "  bench: SKIPPED (bisect failed — models.ini batch unreliable)"
      VERDICTS["$NAME|bench"]="SKIPPED (bisect failed)"
    elif [ "$(model_batch "$i")" != "1" ]; then
      lshow "  bench: SKIPPED (no batch-size — run bisect first)"
      VERDICTS["$NAME|bench"]="SKIPPED"
    else
      lshow "  $(date +%H:%M:%S) starting bench for $NAME"
      if ( cmd_bench ); then
        VERDICTS["$NAME|bench"]="OK"
      else
        VERDICTS["$NAME|bench"]="FAIL"
      fi
      lshow "  $(date +%H:%M:%S) finished bench for $NAME"
    fi
  done

  # ── Verdict summary ─────────────────────────────────────────
  lshow ""
  lshow "=== VERDICT SUMMARY ==="
  lshow "$(printf '%-45s %-9s %-8s %-8s %-8s' MODEL mtpcheck bisect mtp bench)"
  for i in $MODEL_IDXS; do
    NAME=$(model_name "$i")
    ROW=$(printf "%-45s" "$NAME")
    for s in mtpcheck bisect mtp bench; do
      ROW="$ROW  $(printf '%-8s' "${VERDICTS["$NAME|$s"]:-—}")"
    done
    lshow "$ROW"
  done
  lshow ""
  lshow "Full log: $LOG_FILE"
}

# ── MAIN ────────────────────────────────────────────────────
load_models
N_MODELS=${#MODEL_NAMES[@]}
if [ "$N_MODELS" -eq 0 ]; then
  echo "ERROR: no models found in $INI"
  exit 1
fi

if [ "$#" -eq 0 ]; then
  # ── Interactive: pick models → full suite → confirm ──
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

  lshow "=== MASTER PLAN ==="
  lshow "  models: $(for i in $MODEL_IDXS; do echo -n "$(model_name "$i") "; done)"
  lshow "  steps: mtpcheck bisect mtp bench (full suite)"
  lshow "  log: $LOG_FILE"

  echo ""
  echo "=== PLAN ==="
  for i in $MODEL_IDXS; do
    echo "  $(model_name "$i"): mtpcheck → bisect → mtp → bench"
  done
  echo ""
  confirm "Proceed with this plan?" || { echo "Aborted."; exit 1; }
  run_full_suite
  exit 0
fi

# ── Subcommand dispatch ─────────────────────────────────────
CMD=$1; shift
case "$CMD" in
  all)
    MODEL_IDXS=$(resolve_models "$@")
    [ -z "$MODEL_IDXS" ] && { echo "ERROR: no valid model names matched models.ini"; exit 1; }
    run_full_suite
    ;;
  mtpcheck)
    for m in "$@"; do
      MODEL=$m
      if ( cmd_mtpcheck ); then
        echo "  $m: MTP-capable (spec-type=draft-mtp set)"
      else
        echo "  $m: NOT MTP (config restored)"
      fi
    done
    ;;
  bisect)
    MODEL=$1
    shift
    cmd_bisect "$MODEL" "$@"
    ;;
  mtp)
    for m in "$@"; do
      MODEL=$m
      ( cmd_mtp ) || { echo "  $m: mtp tuning FAILED"; continue; }
    done
    ;;
  bench)
    for m in "$@"; do
      MODEL=$m
      ( cmd_bench ) || { echo "  $m: bench FAILED"; continue; }
    done
    ;;
  *)
    echo "Usage: bench.sh [all|mtpcheck|bisect|mtp|bench] <models...>"
    echo "       bench.sh                                    # interactive full suite"
    echo "       bench.sh all <models...>                    # non-interactive full suite"
    echo "       bench.sh mtpcheck <models...>               # MTP capability check"
    echo "       bench.sh bisect <model> [test-batch|resume <lo> <hi>|resume <batch>]"
    echo "       bench.sh mtp <models...>                    # n_max/p_min tuning"
    echo "       bench.sh bench <models...>                  # benchmark JSON record"
    exit 1
    ;;
esac
