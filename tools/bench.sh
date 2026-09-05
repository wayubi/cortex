#!/bin/bash
# bench.sh — Unified benchmarking pipeline: MTP capability check, batch bisect,
# MTP tuning, and full benchmark record. Single script, single scope.
#
# Usage:
#   ./tools/bench.sh                            # interactive: pick models, full suite, confirm
#   ./tools/bench.sh all <models...>            # non-interactive full suite per model
#   ./tools/bench.sh mtpcheck <models...>       # MTP capability check only (writes spec-type)
#   ./tools/bench.sh bisect <model> [test-batch]
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
OMG_GREP="cudaMalloc failed|failed to allocate compute pp buffers|terminate called after throwing|failed to create MTP context|exiting due to model loading error|CUDA error: out of memory|cuMemCreate|GGML_ASSERT|nbytes_shared|smpbo"
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

# ── Parent/inheritance helpers ───────────────────────────────
# Find the parent model name (first models.ini section for given model's hf+ctx).
family_of() {
  local MODEL=$1
  python3 -c "
import re
with open('$INI') as f: c = f.read()
sections = re.split(r'(?m)^\[', c)
my_hf = my_ctx = None
for s in sections[1:]:
    name = s.split(']')[0].strip()
    if name == '*' or not name: continue
    if name == '$MODEL':
        hf = re.search(r'hf\s*=\s*(\S+)', s)
        ctx = re.search(r'ctx-size\s*=\s*(\S+)', s)
        if hf: my_hf = hf.group(1)
        if ctx: my_ctx = ctx.group(1)
        break
if my_hf is None: print('$MODEL'); exit()
for s in sections[1:]:
    name = s.split(']')[0].strip()
    if name == '*' or not name: continue
    hf = re.search(r'hf\s*=\s*(\S+)', s)
    ctx = re.search(r'ctx-size\s*=\s*(\S+)', s)
    if hf and ctx and hf.group(1) == my_hf and ctx.group(1) == my_ctx:
        print(name); break
"
}

# Check if a model's JSON stats file exists.
has_json() { [ -f "$MODELS_DIR/$1.json" ]; }

# Like set_batch but writes batch/ubatch to a specific section name.
set_batch_for() {
  local SECTION=$1 BATCH=$2
  python3 -c "
import re, sys
section='$SECTION'; batch=$BATCH; ini='$INI'
with open(ini) as f: content = f.read()
m = re.search(r'(\['+re.escape(section)+r'\])(.*?)(?=\n\[|\Z)', content, re.DOTALL)
if not m: print('ERROR'); sys.exit(1)
sec = m.group(2)
target = None
for line in sec.split('\n'):
    if '=' in line and not line.strip().startswith(('#', ';')):
        if not re.match(r'\s*(batch|ubatch)-size\s*=', line):
            target = max(target, line.index('=')) if target is not None else line.index('=')
if target is None: target = 17
new_lines = []; found = False
for line in sec.split('\n'):
    if re.match(r'\s*batch-size\s*=', line) and 'ubatch' not in line:
        pad = target - len('batch-size')
        new_lines.append('batch-size' + ' ' * pad + '= ' + str(batch))
        found = True
    elif re.match(r'\s*ubatch-size\s*=', line):
        pad = target - len('ubatch-size')
        new_lines.append('ubatch-size' + ' ' * pad + '= ' + str(batch))
    else: new_lines.append(line)
if not found:
    pad_b = target - len('batch-size'); pad_u = target - len('ubatch-size')
    insert_at = 1
    for idx, line in enumerate(new_lines):
        if '=' in line and not line.strip().startswith(('#', ';')):
            insert_at = idx + 1; break
    new_lines.insert(insert_at, 'batch-size' + ' ' * pad_b + '= ' + str(batch))
    new_lines.insert(insert_at + 1, 'ubatch-size' + ' ' * pad_u + '= ' + str(batch))
with open(ini, 'w') as f:
    f.write(content[:m.start(2)] + '\n'.join(new_lines) + content[m.end(2):])
"
}

# Copy parent JSON to child: overwrite model, apply child's sampling config, mark propagated.
inherit_json() {
  local PARENT=$1 CHILD=$2
  python3 -c "
import json, re, datetime
with open('$INI') as f: ini = f.read()

# Load parent JSON — benchmark data comes from here
with open('$MODELS_DIR/$PARENT.json') as f: data = json.load(f)

# Rebuild config from child's own models.ini (same schema as real bench)
def get_section(name):
    m = re.search(r'(\['+re.escape(name)+r'\])(.*?)(?=\n\[|\Z)', ini, re.DOTALL)
    return m.group(2) if m else ''

def kv(sec, key, default=None):
    m = re.search(r'^\s*'+re.escape(key)+r'\s*=\s*(\S+)', sec, re.MULTILINE)
    return m.group(1) if m else default

sec = get_section('$CHILD')
star = get_section('*')
hf = kv(sec, 'hf')
data['config'] = {
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
    'ctx': str(data['ctx']), 'batch': str(data['batch']),
}

data['model'] = '$CHILD'
data['bench_date'] = data.get('bench_date', datetime.datetime.now().isoformat())
data['propagated'] = True
data['propagated_from'] = '$PARENT'
data['propagated_date'] = datetime.datetime.now().isoformat()

with open('$MODELS_DIR/$CHILD.json', 'w') as f: json.dump(data, f, indent=2)
"

  # Write parent's batch/ubatch to child's models.ini section
  local PARENT_BATCH
  PARENT_BATCH=$(python3 -c "
import re
with open('$INI') as f: c = f.read()
m = re.search(r'(\['+re.escape('$PARENT')+r'\])(.*?)(?=\n\[|\Z)', c, re.DOTALL)
sec = m.group(2) if m else ''
b = re.search(r'batch-size\s*=\s*(\S+)', sec)
print(b.group(1) if b else '')
")
  [ -n "$PARENT_BATCH" ] && set_batch_for "$CHILD" "$PARENT_BATCH"
}

# Determine whether a model should inherit or be bench-marked fresh.
# Returns 0 = handled (inherit/skip, JSON written), 1 = run real bench flow.
maybe_inherit() {
  local MODEL=$1
  local PARENT
  PARENT=$(family_of "$MODEL")

  # No-inherit: always run real bench
  [ "$INHERIT_MODE" -eq 0 ] && return 1

  # If this model IS the parent
  if [ "$MODEL" = "$PARENT" ]; then
    # Already reset-benched in pre-pass: use fresh JSON (skip)
    [ "${RESET_DONE[$MODEL]:-0}" -eq 1 ] && return 0
    [ "$RESET_PARENT" -eq 1 ] && return 1          # force re-bench
    has_json "$MODEL" && return 0                    # already source — skip
    return 1                                         # not yet benched → bench it
  fi

  # Sibling: inherit from parent if parent has JSON
  if has_json "$PARENT"; then
    inherit_json "$PARENT" "$MODEL"
    return 0   # handled — skip
  fi

  # No parent JSON → behave as not-inherit
  return 1
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

# ── Cold-load stall watchdog ───────────────────────────────
# The router logs "proxy_reques: proxying request to model <model> on port <N>"
# ONLY after the model finishes loading and the request is being served.
# A hung cold-load (e.g. HF network fetch stalled) never emits this line.
# SERVED_GRACE = max seconds to wait for the proxy_reques line. Base 60s + 40s per
# 64k ctx (covers large-ctx cold-loads under contention). Set ctx-aware in each command.
SERVED_GRACE=${SERVED_GRACE:-60}

# Wait for the router log to show our request being served (proxy_reques line).
# Takes the curl PID — if the curl has already exited (request completed, whether
# 200 or 500), return 0 immediately so the caller can parse the response. Only
# return 1 (hung) if the curl is STILL running and no proxy line appeared.
# If a load-crash marker (GGML_ASSERT, cudaMalloc, "failed to load") appears in the
# log before proxy_reques, kill curl and return 0 so the caller catches the OOM via
# oom_count_since_mark (rather than treating it as a retryable network stall).
# All logs → stderr (caller may capture stdout via $()).
wait_served() {
  local PID=$1
  local i
  for i in $(seq 1 $((SERVED_GRACE / 2))); do
    if ! kill -0 "$PID" 2>/dev/null; then return 0; fi
    # Check for model load-crash / OOM markers (intermittent crashes kill the
    # child server before SERVED_GRACE; we must catch them here, not after).
    if docker logs $DOCKER_LOG 2>&1 | tail -n +$((LOG_MARK + 1)) | grep -qiE "$OMG_GREP"; then
      kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null || true
      return 0
    fi
    if docker logs $DOCKER_LOG 2>&1 | tail -n +$((LOG_MARK + 1)) \
         | grep -q "proxy_reques: proxying request to model $MODEL"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# Compute an adaptive curl timeout for a request that must fully generate
# max_tokens.  Assumes worst-case CPU decode ≈ 4 t/s with a 3x margin,
# clamped to [600, 7200] seconds.
adaptive_timeout() {
  local MAX_TOK=$1
  python3 -c "
t = $MAX_TOK / 4 * 3
t = max(600, min(7200, int(t)))
print(t)
"
}

# Bracketed halve-down + bisect (O(log)) to find the largest batch below $CEIL
# that survives full saturation. Result is written to global $BHD_RESULT.
# Returns 0 = success, 2 = STALL (caller must handle).
# Note: called directly (not via $() command substitution) so that exit/return
# propagates correctly under both standalone and suite (if-condition) dispatch.
bracketed_halve_down() {
  local CEIL=$1 CTX_VAL=$2
  local HI=$CEIL LO=0
  local BATCH=$((CEIL / 2))
  while [ "$BATCH" -ge 64 ]; do
    set_batch "$BATCH"; restart
    saturation_test "$CTX_VAL"
    local BR_RC=$?
    if [ "$BR_RC" -eq 2 ]; then log "  STALL — aborting"; return 2; fi
    if [ "$BR_RC" -eq 0 ]; then LO=$BATCH; break
    else HI=$BATCH; BATCH=$((BATCH / 2)); fi
  done
  while [ $((HI - LO)) -gt 64 ]; do
    MID=$(((LO + HI) / 2)); MID=$((MID / 64 * 64))
    [ "$MID" -le "$LO" ] && MID=$((LO + 64))
    set_batch "$MID"; restart
    saturation_test "$CTX_VAL"
    local BR_RC=$?
    if [ "$BR_RC" -eq 2 ]; then log "  STALL — aborting"; return 2; fi
    if [ "$BR_RC" -eq 0 ]; then LO=$MID; else HI=$MID; fi
  done
  BHD_RESULT=$LO
}

# Fire a chat-completions POST from $1 (payload @file) to $2 (out), watching for
# the router's proxy_reques line. On a cold-load hang: kill curl, restart, retry
# once. Sets $FIRE_PID to the curl PID on success.
# Returns: 0 = served (curl still running — caller waits), 2 = STALL (hung after retry).
# All logs → stderr (safe inside $() captures).
FIRE_PID=""
fire_request() {
  local PAYLOAD=$1 OUT=$2 LABEL=$3 TIMEOUT=${4:-600}
  local ATTEMPT PID
  for ATTEMPT in 1 2 3; do
    logmark
    curl -s --max-time "$TIMEOUT" -X POST http://localhost:8080/v1/chat/completions \
      -H 'Content-Type: application/json' -d @"$PAYLOAD" > "$OUT" 2>&1 &
    PID=$!
    if wait_served "$PID"; then
      FIRE_PID=$PID
      return 0
    fi
    kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null || true
    log "  $LABEL: cold-load hang (no proxy line in ${SERVED_GRACE}s) — restarting + retry $ATTEMPT" >&2
    restart >&2
  done
  log "  $LABEL: STALL — model never served after restart+retry (network/HF fetch)" >&2
  FIRE_PID=""
  return 2
}

# ── Probe primitives ────────────────────────────────────────
tiny_probe() {
  log "  Probe started $(date +%H:%M:%S)..."
  python3 -c "
import json
payload = {'model':'$MODEL','messages':[{'role':'user','content':'Say hello'}],'max_tokens':8}
with open('/tmp/probe_payload.json','w') as f: json.dump(payload, f)
"
  fire_request /tmp/probe_payload.json /tmp/probe.json "tiny-probe"
  local RC=$?
  if [ "$RC" -eq 2 ]; then return 2; fi
  wait "$FIRE_PID" 2>/dev/null || true
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
  fire_request /tmp/ratio_payload.json /tmp/ratio_response.json "measure-ratio"
  local RC=$?
  if [ "$RC" -eq 2 ]; then return 2; fi
  wait "$FIRE_PID" 2>/dev/null || true
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
  local MAX_TOK=$(python3 -c "print(int($CTX * 0.5))")        # real saturation decode cap
  local MEASURE_TOK=1                                          # cheap sizing decode cap
  local TARGET=$(python3 -c "print(int($CTX * 0.99))")         # prefill goal = 99% of ctx
  local SAT_SIZE=$(python3 -c "print(int($CTX * 4.0))")        # deliberate overshoot
  local ATTEMPT=1
  local MAX_ATTEMPTS=15
  SAT_PREFILL_TPS=""                                           # global: captured prefill t/s (caller reads)
  local PREFILL_TPS_RAW=""
  log "  Saturation: prefill target ~${TARGET} tokens (99% ctx), overshoot start ~${SAT_SIZE} chars"

  # ---- Phase 1: cheap sizing (max_tokens=1) — discover ratio, land near 99% ctx ----
  while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
    python3 -c "
import json
filler = 'The history of computing is long and complex. '
SAT_SIZE = $SAT_SIZE
prompt = (filler * ((SAT_SIZE // len(filler)) + 1))[:SAT_SIZE]
payload = {'model':'$MODEL','messages':[{'role':'user','content':prompt}],'max_tokens':$MEASURE_TOK,'ignore_eos':True}
with open('/tmp/sat_payload.json','w') as f: json.dump(payload, f)
"
    fire_request /tmp/sat_payload.json /tmp/sat_response.json "sat-size" "$(adaptive_timeout $MEASURE_TOK)"
    local RC=$?
    if [ "$RC" -eq 2 ]; then return 2; fi

    local WATCH=0
    while kill -0 $FIRE_PID 2>/dev/null; do
      if [ "$(oom_count_since_mark)" -gt 0 ]; then
        log "  Saturation: OOM detected — killing curl"
        kill $FIRE_PID 2>/dev/null
        break
      fi
      WATCH=$((WATCH + 1))
      [ $((WATCH % 30)) -eq 0 ] && log "    ...watchdog ${WATCH}x2s (request still running)"
      sleep 2
    done
    wait $FIRE_PID 2>/dev/null || true

    # Overshoot → rejected. Shrink and retry (fail fast, try again).
    if grep -q "exceeds the available context" /tmp/sat_response.json 2>/dev/null; then
      SAT_SIZE=$(python3 -c "print(int($SAT_SIZE * 0.9))")
      log "  Saturation: overshoot rejected (attempt $ATTEMPT) — shrinking to ~${SAT_SIZE} chars"
      ATTEMPT=$((ATTEMPT + 1))
      continue
    fi

    local OOM=$(oom_count_since_mark)
    if [ "$OOM" -gt 0 ]; then log "  Saturation: OOM"; return 1; fi

    # Capture prefill t/s ONLY from the first accepted sizing probe. The first
    # accepted request is from-scratch (no KV cache yet); later sizing probes and
    # Phase 2 reuse LCP cache and prefill only a delta (not representative).
    if [ -z "$SAT_PREFILL_TPS" ]; then
      PREFILL_TPS_RAW=$(docker logs $DOCKER_LOG 2>&1 | tail -n +$((LOG_MARK + 1)) \
        | grep "prompt eval time" | grep -oE "[0-9.]+ tokens per second" | awk '{print $1}')
      if [ -n "$PREFILL_TPS_RAW" ]; then
        SAT_PREFILL_TPS="$PREFILL_TPS_RAW"
      fi
    fi

    local PT CT
    read -r PT CT < <(python3 -c "
import json
d = json.load(open('/tmp/sat_response.json'))
if 'choices' in d:
    u = d.get('usage', {})
    print(u.get('prompt_tokens', 0) or 0, u.get('completion_tokens', 0) or 0)
else:
    print('FAIL')
" 2>/dev/null)
    if [ "$PT" = "FAIL" ] || [ -z "$PT" ]; then
      log "  Saturation: no valid response (model error / 500 / peg-native format)"
      return 3
    fi

    # Rescale toward 99% of ctx using the measured ratio; stop when already close.
    local NEW_SAT=$(python3 -c "print(int($SAT_SIZE * $TARGET / $PT))")
    log "  Saturation: measured prefill ${PT} (attempt $ATTEMPT) — rescaling to ${NEW_SAT} chars"
    if [ $((NEW_SAT - SAT_SIZE)) -lt $((SAT_SIZE / 50)) ] && [ $((NEW_SAT - SAT_SIZE)) -gt -$((SAT_SIZE / 50)) ]; then
      SAT_SIZE=$NEW_SAT
      break
    fi
    SAT_SIZE=$NEW_SAT
    ATTEMPT=$((ATTEMPT + 1))
  done

  # ---- Phase 2: real saturation (max_tokens=50% ctx) — ~99% prefill + ~1% decode ----
  python3 -c "
import json
filler = 'The history of computing is long and complex. '
SAT_SIZE = $SAT_SIZE
prompt = (filler * ((SAT_SIZE // len(filler)) + 1))[:SAT_SIZE]
payload = {'model':'$MODEL','messages':[{'role':'user','content':prompt}],'max_tokens':$MAX_TOK,'ignore_eos':True}
with open('/tmp/sat_payload.json','w') as f: json.dump(payload, f)
"
  fire_request /tmp/sat_payload.json /tmp/sat_response.json "saturation" "$(adaptive_timeout $MAX_TOK)"
  local RC=$?
  if [ "$RC" -eq 2 ]; then return 2; fi

  local WATCH=0
  while kill -0 $FIRE_PID 2>/dev/null; do
    if [ "$(oom_count_since_mark)" -gt 0 ]; then
      log "  Saturation: OOM detected — killing curl"
      kill $FIRE_PID 2>/dev/null
      break
    fi
    WATCH=$((WATCH + 1))
    [ $((WATCH % 30)) -eq 0 ] && log "    ...watchdog ${WATCH}x2s (request still running)"
    sleep 2
  done
  wait $FIRE_PID 2>/dev/null || true

  local OOM=$(oom_count_since_mark)
  if [ "$OOM" -gt 0 ]; then log "  Saturation: OOM"; return 1; fi

  local PT CT
  read -r PT CT < <(python3 -c "
import json
d = json.load(open('/tmp/sat_response.json'))
if 'choices' in d:
    u = d.get('usage', {})
    print(u.get('prompt_tokens', 0) or 0, u.get('completion_tokens', 0) or 0)
else:
    print('FAIL')
" 2>/dev/null)
  if [ "$PT" = "FAIL" ] || [ -z "$PT" ]; then
    log "  Saturation: no valid response (model error / 500 / peg-native format)"
    return 3
  fi

  if [ $((PT + CT)) -ge "$CTX" ]; then
    log "  Saturation: PASS (prompt_tokens=${PT}, completion_tokens=${CT}, total=$((PT+CT)), ctx=${CTX}, prefill=${SAT_PREFILL_TPS} t/s)"
    return 0
  fi
  log "  Saturation: accepted but no compaction (pt=${PT}+ct=${CT} < ctx=${CTX})"
  return 4
}

long_decode_check() {
  log "  Long-decode: essay prompt, max_tokens=6000..."
  python3 -c "
import json
with open('/tmp/longdec_payload.json','w') as f:
    json.dump({'model':'$MODEL','messages':[{'role':'user','content':'Write a detailed essay explaining the history of computing.'}],'max_tokens':6000,'ignore_eos':True}, f)
"
  fire_request /tmp/longdec_payload.json /tmp/longdec_response.json "long-decode" "$(adaptive_timeout 6000)"
  local RC=$?
  if [ "$RC" -eq 2 ]; then return 2; fi
  wait "$FIRE_PID" 2>/dev/null || true
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

# ── Decode-guarded prefill+decode probe ─────────────────────
# Measures both prefill and decode speed at the CURRENT batch.
# Prefill: 75%-ctx prompt, max_tokens=1 → prompt_per_second.
# Decode:  short-prompt 4000-token window → predicted_per_second, plus CPU% polling.
# Echoes "prefill_t_s|decode_t_s|avg_cpu" to stdout (all logs → stderr).
# Returns "0|0|0" on STALL/OOM (caller must reject the rung).
# Optional $2="prefill": skip decode entirely, return "prefill|0|0" (fast search probe).
decode_guarded_probe() {
  local CTX=$1
  local MODE=${2:-full}
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
filler = 'The history of computing is long and complex. '
target_chars = $PREFILL_CHARS
prompt = (filler * ((target_chars // len(filler)) + 1))[:target_chars]
payload = {'model':'$MODEL','messages':[{'role':'user','content':prompt}],'max_tokens':1,'ignore_eos':True}
with open('/tmp/perf_prefill_payload.json','w') as f: json.dump(payload, f)
"
  fire_request /tmp/perf_prefill_payload.json /tmp/perf_prefill.json "measure-prefill"
  local RC=$?
  if [ "$RC" -eq 2 ]; then echo "0|0|0"; return 0; fi
  wait "$FIRE_PID" 2>/dev/null || true

  local PFC
  PFC=$(python3 -c "
import json
val = 0
try:
    d = json.load(open('/tmp/perf_prefill.json'))
    if 'choices' in d:
        val = d.get('timings', {}).get('prompt_per_second', 0) or 0
except Exception:
    pass
print(f'{val:.1f}')
" 2>/dev/null | tail -1)

  # Prefill-only mode: skip decode, return immediately
  if [ "$MODE" = "prefill" ]; then
    echo "${PFC}|0|0"
    return 0
  fi

  # Decode probe (short prompt, full 4000-token window) — poll CPU during it
  # for GPU-residency classification
  python3 -c "
import json
payload = {'model':'$MODEL','messages':[{'role':'user','content':'Explain the history of computing in detail.'}],'max_tokens':4000,'ignore_eos':True}
with open('/tmp/perf_decode_payload.json','w') as f: json.dump(payload, f)
"
  fire_request /tmp/perf_decode_payload.json /tmp/perf_decode.json "measure-decode" "$(adaptive_timeout 4000)"
  local DEC_RC=$?
  if [ "$DEC_RC" -eq 2 ]; then echo "0|0|0"; return 0; fi
  local DEC_PID=$FIRE_PID
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

# Fast GPU/CPU residency classification. Unlike decode_guarded_probe, this only needs a
# BINARY verdict (GPU vs CPU-spill), so it skips the prefill probe and kills the
# decode curl as soon as the signal is provable — no full 4000-token wait.
#
# Classification rule (single llama-s process %):
#   cpu > 200  → CPU spillover (all cores pegged ~900-2800%) — regardless of GPU
#   gpu_util > GPU_ACTIVE_PCT AND cpu < 100 → GPU-resident (model active on GPU)
#   100-200% is noise/AMBIGUOUS — not proven GPU, not proven CPU (never forced).
# Echoes one of: GPU | CPU | AMBIGUOUS
GPU_ACTIVE_PCT=25
RESID_MIN_FLOOR_SAMPLES=10   # 20s @2s before early-kill verdicts are allowed (belt-and-suspenders)
residency_probe() {
  # stdout is reserved for the single verdict (GPU|CPU|AMBIGUOUS); all progress
  # logs go to stderr so command-substitution captures stay clean.
  python3 -c "
import json
payload = {'model':'$MODEL','messages':[{'role':'user','content':'Explain the history of computing in detail.'}],'max_tokens':4000,'ignore_eos':True}
with open('/tmp/resid_payload.json','w') as f: json.dump(payload, f)
"
  fire_request /tmp/resid_payload.json /tmp/resid_response.json "residency" "$(adaptive_timeout 4000)"
  local RC=$?
  if [ "$RC" -eq 2 ]; then
    log "  residency: STALL — model never served (network/HF fetch)" >&2
    echo "STALL"; return 0
  fi
  local R_PID=$FIRE_PID

  local R_CPU_SUM=0 R_CPU_CNT=0 R_GPU_SEEN=0
  local R_CPU=0 R_GPU=0 R_TEMP=0 R_CPU_CONSEC=0 R_GPU_CONSEC=0
  local i
  for i in $(seq 1 40); do
    local TOP STATS
    TOP=$(top -bn1 2>/dev/null | grep llama-s | head -n1)
    R_CPU=$(echo "$TOP" | awk '{print $9}' 2>/dev/null || echo "0")
    STATS=$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>/dev/null)
    R_GPU=$(echo "$STATS" | cut -d',' -f1 | tr -d ' ')
    R_TEMP=$(echo "$STATS" | cut -d',' -f2 | tr -d ' ')

    [ -n "$R_CPU" ] && [ "$R_CPU" != "0.0" ] && { R_CPU_SUM=$(echo "$R_CPU_SUM + $R_CPU" | bc 2>/dev/null || echo 0); R_CPU_CNT=$((R_CPU_CNT + 1)); }
    { [ -n "$R_GPU" ] && [ "$R_GPU" -gt "$GPU_ACTIVE_PCT" ] 2>/dev/null; } && R_GPU_SEEN=1

    # CPU-spill: definitive regardless of GPU (only all-cores >200% proves it)
    if [ "$(echo "$R_CPU > 200" | bc -l)" = "1" ]; then
      R_CPU_CONSEC=$((R_CPU_CONSEC + 1)); R_GPU_CONSEC=0
    elif [ "$(echo "$R_CPU < 100" | bc -l)" = "1" ] && [ "$R_GPU" -gt "$GPU_ACTIVE_PCT" ] 2>/dev/null; then
      R_GPU_CONSEC=$((R_GPU_CONSEC + 1)); R_CPU_CONSEC=0
    else
      # 100-200% is noise — reset both, keep polling
      R_CPU_CONSEC=0; R_GPU_CONSEC=0
    fi

    if [ "$i" -ge "$RESID_MIN_FLOOR_SAMPLES" ]; then
      if [ "$R_CPU_CONSEC" -ge 3 ]; then
        kill $R_PID 2>/dev/null
        wait $R_PID 2>/dev/null || true
        log "  residency: CPU (cpu ${R_CPU}%) — killed early" >&2
        echo "CPU"; return 0
      fi
      if [ "$R_GPU_CONSEC" -ge 3 ]; then
        kill $R_PID 2>/dev/null
        wait $R_PID 2>/dev/null || true
        log "  residency: GPU (cpu ${R_CPU}%, gpu ${R_GPU}%, temp ${R_TEMP}C) — killed early" >&2
        echo "GPU"; return 0
      fi
    fi

    if ! kill -0 $R_PID 2>/dev/null; then break; fi
    sleep 2
  done
  wait $R_PID 2>/dev/null || true

  # Fallback: classify from the full window average
  local R_AVG=0
  [ "$R_CPU_CNT" -gt 0 ] && R_AVG=$(echo "scale=1; $R_CPU_SUM / $R_CPU_CNT" | bc)
  if [ "$(echo "$R_AVG > 200" | bc -l)" = "1" ]; then
    log "  residency: CPU (avg ${R_AVG}%)" >&2
    echo "CPU"; return 0
  fi
  if [ "$(echo "$R_AVG <= 100" | bc -l)" = "1" ] && [ "$R_GPU_SEEN" -eq 1 ]; then
    log "  residency: GPU (avg cpu ${R_AVG}%, gpu active)" >&2
    echo "GPU"; return 0
  fi
  log "  residency: AMBIGUOUS (avg cpu ${R_AVG}%)" >&2
  echo "AMBIGUOUS"; return 0
}

# Find the largest GPU-resident batch when the ceiling is CPU-spilled (e.g. a
# 9B that fits 16384 OOM-wise but only runs 100% GPU at 2048). Ladders up from
# 2048 (doubling) via fast residency probes, then bisects on residency at the
# GPU/CPU boundary. Echoes the largest GPU-resident batch. stdout is reserved for
# the numeric result — all progress (set_batch/restart/log) goes to stderr.
residency_descend() {
  local UPPER=$1   # the OOM-validated ceiling to stay below
  local LO=0 HI=$UPPER B R MID
  # Probe the realistic floor (2048): if GPU, ladder up; if CPU-spilled, ladder down.
  set_batch 2048 >&2; restart >&2
  R=$(residency_probe)
  if [ "$R" = "STALL" ]; then
    log "  residency descend: STALL — model can't cold-load (network/HF fetch)" >&2
    return 2
  fi
  if [ "$R" = "GPU" ]; then
    LO=2048
    B=2048
    while [ $((B * 2)) -lt "$HI" ]; do
      B=$((B * 2))
      set_batch "$B" >&2; restart >&2
      R=$(residency_probe)
      if [ "$R" = "STALL" ]; then
        log "  residency descend: STALL at $B — model can't cold-load" >&2
        return 2
      fi
      if [ "$R" = "GPU" ]; then LO=$B
      else HI=$B; break; fi
    done
  else
    # 2048 spilled — halve down until a GPU-resident batch is found
    HI=2048
    B=1024
    while [ "$B" -ge 64 ]; do
      set_batch "$B" >&2; restart >&2
      R=$(residency_probe)
      if [ "$R" = "STALL" ]; then
        log "  residency descend: STALL at $B — model can't cold-load" >&2
        return 2
      fi
      if [ "$R" = "GPU" ]; then LO=$B; break
      else HI=$B; B=$((B / 2 / 64 * 64)); fi
    done
  fi
  if [ "$LO" -eq 0 ]; then
    log "  ERROR: no GPU-resident batch found below $UPPER — using ceiling" >&2
    set_batch "$UPPER" >&2
    echo "$UPPER"; return 0
  fi
  # Bisect on residency between LO (GPU) and HI (CPU/OOM), gap <= 64
  while [ $((HI - LO)) -gt 64 ]; do
    MID=$(((LO + HI) / 2)); MID=$((MID / 64 * 64))
    [ "$MID" -le "$LO" ] && MID=$((LO + 64))
    [ "$MID" -ge "$HI" ] && MID=$((HI - 64))
    set_batch "$MID" >&2; restart >&2
    R=$(residency_probe)
    if [ "$R" = "GPU" ]; then LO=$MID; else HI=$MID; fi
  done
  log "  Largest GPU-resident batch: $LO" >&2
  set_batch "$LO" >&2
  echo "$LO"
}

# ── Short prefill t/s probe (fast, no saturation) ──────────
# Sends a moderate ~8K-token prefill (max_tokens=1, no decode), waits for the request
# to complete, then parses the STREAMING "prompt processing" lines from the llama-cpp
# log (from LOG_MARK forward). Averages the t/s values from the non-warm-up lines.
# Warm-up: fires an untimed probe first to clear the cold-load, then times the second.
# Echoes prefill_t_s to stdout. Logs progress to stderr.
prefill_probe() {
  local PROBE_CHARS=32000  # ~10K tokens at ~3 chars/token — enough to trigger streaming prefill lines
  # Single full-length probe: model loads during this request AND produces streaming
  # prefill lines. Lines 3-7 skip the cold-load ramp → steady-state t/s.
  python3 -c "
import json
filler = 'The history of computing is long and complex. '
n = $PROBE_CHARS
prompt = (filler * ((n // len(filler)) + 1))[:n]
payload = {'model':'$MODEL','messages':[{'role':'user','content':prompt}],'max_tokens':1,'ignore_eos':True}
with open('/tmp/pp_timed.json','w') as f: json.dump(payload, f)
"
  fire_request /tmp/pp_timed.json /tmp/pp_out.json "prefill-probe" "$(adaptive_timeout 1)"
  local RC=$?
  if [ "$RC" -eq 2 ]; then echo "0"; return 0; fi
  local WATCH=0
  while kill -0 $FIRE_PID 2>/dev/null; do
    if [ "$(oom_count_since_mark)" -gt 0 ]; then kill $FIRE_PID 2>/dev/null; break; fi
    WATCH=$((WATCH + 1))
    [ $((WATCH % 10)) -eq 0 ] && log "    prefill-probe: still running (${WATCH}x2s)" >&2
    sleep 2
  done
  wait $FIRE_PID 2>/dev/null || true
  local OOM=$(oom_count_since_mark)
  if [ "$OOM" -gt 0 ]; then echo "0"; return 0; fi

  # Parse the "prompt eval time" summary line from LOG_MARK forward.
  # This line is always emitted (unlike streaming "prompt processing" lines).
  # Format: "prompt eval time = X ms / N tokens (... Z tokens per second)"
  local PPMATCH
  PPMATCH=$(docker logs $DOCKER_LOG 2>&1 | tail -n +$((LOG_MARK + 1)) \
    | grep "prompt eval time" | tail -1 \
    | grep -oE '[0-9]+\.?[0-9]* tokens per second' | awk '{print $1}')
  if [ -n "$PPMATCH" ] && [ "$PPMATCH" != "0" ]; then
    log "  prefill-probe: ${PPMATCH} t/s (${PROBE_CHARS} chars)" >&2
    echo "$PPMATCH"
  else
    echo "0"
  fi
}

# ── CPU-compute saturation sweep (find fastest prefill batch) ──
# Doubling ladder from 256, each rung measured via short prefill_probe.
# Golden-section refinement to 64 granularity finds the true fastest batch
# (which may sit between doubling rung siblings). Outputs "BATCH|TPS" to stdout.
# Then confirms winner via full saturation_test (99% ctx). Progress → stderr.
cpu_saturation_sweep() {
  local CTX=$1
  local PTS=/tmp/cpu_sweep_points.txt
  : > "$PTS"

  # Test a single batch via SHORT prefill probe (fast, no saturation).
  # Warm-up is inside prefill_probe (untimed first request, then timed).
  # Echoes tps on stdout; appends (batch tps) to $PTS.
  test_rung() {
    local TB=$1
    set_batch "$TB" >&2; restart >&2
    local TPS
    TPS=$(prefill_probe "$CTX")
    log "  batch=$TB: prefill=${TPS} t/s (short probe)" >&2
    echo "$TB $TPS" >> "$PTS"
    echo "$TPS"
  }

  log "=== CPU SATURATION SWEEP (ctx=$CTX) ===" >&2

  # ── Phase 1: doubling ladder, peak-anchored bracket ──
  log "  Ladder: doubling from 256..." >&2
  local B=256 BEST_TPS=0 BEST_BATCH=256 DESC=0 STOP=0
  while [ "$B" -le "$CTX" ]; do
    log "  Testing batch=$B..." >&2
    local TPS
    TPS=$(test_rung "$B")
    if [ "$TPS" = "STALL" ]; then log "  STALL — aborting sweep" >&2; break; fi
    if [ "$TPS" = "OOM" ]; then
      log "  OOM at batch=$B — can't use this level" >&2
      break
    fi
    if python3 -c "exit(0 if $TPS > $BEST_TPS else 1)" 2>/dev/null; then
      BEST_TPS=$TPS; BEST_BATCH=$B
    fi
    # Descending side confirmed: count consecutive rungs strictly above the peak
    # that are BELOW the best t/s. Two in a row → past the peak (noise-tolerant).
    if [ "$B" -gt "$BEST_BATCH" ] 2>/dev/null \
       && python3 -c "exit(0 if $TPS < $BEST_TPS else 1)" 2>/dev/null; then
      DESC=$((DESC + 1))
      if [ "$DESC" -ge 2 ]; then
        log "  Descending side confirmed past peak batch=$BEST_BATCH (${BEST_TPS} t/s)" >&2
        STOP=1; break
      fi
    else
      DESC=0
    fi
    B=$((B * 2))
  done

  # If we never crossed the peak (monotonic rise to ctx/OOM), best is at the top.
  if [ "$STOP" -eq 0 ]; then
    log "  No descent seen — peak is at the tested edge. Best: batch=$BEST_BATCH (${BEST_TPS} t/s)" >&2
    set_batch "$BEST_BATCH" >&2
    echo "$BEST_BATCH|$BEST_TPS"
    return 0
  fi

  # Reconstruct bracket: LO = largest tested rung below the peak, HI = smallest
  # tested rung above the peak. The true max lives somewhere in [LO, HI].
  local LO HI
  read -r LO HI < <(python3 -c "
pts = []
with open('$PTS') as f:
    for line in f:
        b, t = line.split(); pts.append((int(b), float(t)))
pts.sort()
peak = $BEST_BATCH
lo = hi = None
for b, t in pts:
    if b < peak: lo = b
    elif b == peak: continue
    elif b > peak and hi is None: hi = b
# default edges if peak is at an endpoint
if lo is None: lo = 256
if hi is None:
    # no tested rung above peak — use next doubling rung or ctx cap
    hi = min($CTX, peak * 2)
print(lo, hi)
" 2>/dev/null || echo "256 $CTX")
  [ -z "$LO" ] && LO=256
  [ -z "$HI" ] && HI=$CTX
  log "  Peak=$BEST_BATCH (${BEST_TPS} t/s) → golden-section bracket [$LO, $HI]" >&2

  # ── Phase 2: golden-section max-search, granularity=64 ──
  # Each step reuses one interior point → at most 1 NEW saturation per iteration.
  # Points already measured (in $PTS) are reused, never re-saturated.
  local A B2 A_MEAS B2_MEAS
  # helper: return stored tps if $1 already in $PTS, else "" (means "measure it")
  lookup_tps() {
    awk -v b="$1" '$1==b{print $2; exit}' "$PTS" 2>/dev/null
  }

  while [ $((HI - LO)) -gt 64 ]; do
    # Round interior points to 64-multiples, clamped strictly inside (LO, HI).
    B2=$((HI - (HI - LO) * 382 / 1000)); B2=$((B2 / 64 * 64))
    A=$((LO + (HI - LO) * 382 / 1000)); A=$((A / 64 * 64))
    [ "$A" -le "$LO" ] && A=$((LO + 64))
    [ "$B2" -ge "$HI" ] && B2=$((HI - 64))
    [ "$B2" -le "$A" ] && B2=$((A + 64))

    # If both interior points are already measured and the bracket can't admit a
    # new 64-granularity point, we've reached the limit of resolution — stop.
    A_MEAS=$(lookup_tps "$A")
    B2_MEAS=$(lookup_tps "$B2")
    if [ -n "$A_MEAS" ] && [ -n "$B2_MEAS" ]; then
      log "  No new 64-granularity point between $LO and $HI — stopping golden-section" >&2
      break
    fi

    # Measure whichever interior point(s) are not yet in $PTS.
    if [ -z "$A_MEAS" ]; then
      log "  Golden: testing A=$A (lo=$LO, hi=$HI)..." >&2
      A_MEAS=$(test_rung "$A")
      [ "$A_MEAS" = "STALL" ] && { log "  STALL — aborting sweep" >&2; break; }
    else
      log "  Golden: reuse A=$A (${A_MEAS} t/s, already measured)" >&2
    fi
    if [ -z "$B2_MEAS" ]; then
      log "  Golden: testing B2=$B2 (lo=$LO, hi=$HI)..." >&2
      B2_MEAS=$(test_rung "$B2")
      [ "$B2_MEAS" = "STALL" ] && { log "  STALL — aborting sweep" >&2; break; }
    else
      log "  Golden: reuse B2=$B2 (${B2_MEAS} t/s, already measured)" >&2
    fi

    # OOM interior points count as -inf (never a max).
    A_MEAS=$(python3 -c "print('$A_MEAS')" 2>/dev/null); [ "$A_MEAS" = "OOM" ] && A_MEAS=-1
    B2_MEAS=$(python3 -c "print('$B2_MEAS')" 2>/dev/null); [ "$B2_MEAS" = "OOM" ] && B2_MEAS=-1

    # Update overall best from these two candidates (never count -inf/OOM).
    if [ "$A_MEAS" != "-1" ] 2>/dev/null && python3 -c "exit(0 if $A_MEAS > $BEST_TPS else 1)" 2>/dev/null; then
      BEST_TPS=$A_MEAS; BEST_BATCH=$A
    fi
    if [ "$B2_MEAS" != "-1" ] 2>/dev/null && python3 -c "exit(0 if $B2_MEAS > $BEST_TPS else 1)" 2>/dev/null; then
      BEST_TPS=$B2_MEAS; BEST_BATCH=$B2
    fi

    # Narrow toward the higher-t/s side (golden-section rule).
    if python3 -c "exit(0 if $A_MEAS > $B2_MEAS else 1)" 2>/dev/null; then
      HI=$B2
    else
      LO=$A
    fi
    [ $((HI - LO)) -le 64 ] && break
  done

  # ── Confirm: run saturation_test on the top-ranked candidates (99% ctx) ──
  log "  Short-probe sweep done. Top-ranked candidates:" >&2
  python3 -c "
data = []
with open('$PTS') as f:
    for line in f: data.append((int(line.split()[0]), float(line.split()[1])))
data.sort(key=lambda x: -x[1])
for b, t in data[:5]: print(f'    batch={b}  prefill={t} t/s')
" >&2 2>/dev/null

  local CONFIRM_BATCH CONFIRM_TPS CONFIRM_FOUND=0
  while read CONFIRM_BATCH CONFIRM_TPS; do
    log "  Confirm: saturation_test at batch=$CONFIRM_BATCH..." >&2
    set_batch "$CONFIRM_BATCH" >&2; restart >&2
    saturation_test "$CTX" >&2
    local C_RC=$?
    if [ "$C_RC" -eq 0 ]; then
      log "  Confirm PASS at batch=$CONFIRM_BATCH (${CONFIRM_TPS} t/s)" >&2
      CONFIRM_FOUND=1; break
    elif [ "$C_RC" -eq 2 ]; then
      log "  STALL during confirm — aborting" >&2; break
    else
      log "  Confirm FAIL at batch=$CONFIRM_BATCH" >&2
    fi
  done < <(python3 -c "
data = []
with open('$PTS') as f:
    for line in f: data.append((int(line.split()[0]), float(line.split()[1])))
data.sort(key=lambda x: -x[1])
for b, t in data[:3]: print(b, t)
")

  if [ "$CONFIRM_FOUND" -eq 1 ]; then
    echo "$CONFIRM_BATCH|$CONFIRM_TPS"
  else
    log "  All top candidates failed confirm — keeping fastest (best-effort): batch=$BEST_BATCH (${BEST_TPS} t/s)" >&2
    set_batch "$BEST_BATCH" >&2
    echo "$BEST_BATCH|$BEST_TPS"
  fi
}

# ── GPU saturation sweep (decode-guarded fastest prefill) ──
# Doubling ladder from 256 → $CEILING, each rung measured via prefill_only_probe
# (75%-ctx prefill, max_tokens=1 — fast, no decode). Golden-section refinement to 64
# granularity finds the true fastest prefill batch. Then a SHORTLIST decode gate runs
# the full 4000-token decode on the top-5 prefill candidates only, rejecting any whose
# decode t/s < 90% of the best decode seen (catches CPU/draft spill on the actual
# winners). This keeps the same gate semantics while cutting full-decode probes from
# ~13-16 per model to ~5 (the shortlist).
# Outputs "BATCH|PREFILL_TPS" to stdout. Confirms winner via saturation_test.
gpu_saturation_sweep() {
  local CTX=$1 CEILING=$2
  local PTS=/tmp/gpu_sweep_points.txt   # batch prefill (2 cols — search is prefill-only)
  : > "$PTS"
  local DECODE_GATE_FACTOR=0.9
  local SHORTLIST_SIZE=5

  # ── test_rung: prefill-only probe (fast, no decode) ──
  test_rung() {
    local TB=$1
    set_batch "$TB" >&2; restart >&2
    local RESULT
    RESULT=$(decode_guarded_probe "$CTX" prefill)
    local PFC
    PFC=$(echo "$RESULT" | cut -d'|' -f1)
    if [ "$PFC" = "0" ]; then
      local RC_OOM
      RC_OOM=$(oom_count_since_mark)
      if [ "$RC_OOM" -gt 0 ]; then
        log "  batch=$TB: OOM" >&2
        echo "OOM"
      else
        log "  batch=$TB: STALL" >&2
        echo "STALL"
      fi
      return 0
    fi
    log "  batch=$TB: prefill=${PFC} t/s (search probe)" >&2
    echo "$TB $PFC" >> "$PTS"
    echo "$PFC"
  }

  log "=== GPU SATURATION SWEEP (ctx=$CTX, ceiling=$CEILING, decode gate=${DECODE_GATE_FACTOR}×, shortlist=$SHORTLIST_SIZE) ===" >&2

  # ── Ceiling below ladder floor: use ceiling directly (already OOM-validated upstream) ──
  if [ "$CEILING" -lt 256 ]; then
    log "  Ceiling $CEILING < 256 — probing ceiling directly (already OOM-validated upstream)" >&2
    set_batch "$CEILING" >&2; restart >&2
    local G_PRE
    G_PRE=$(decode_guarded_probe "$CTX" | cut -d'|' -f1)
    echo "$CEILING|${G_PRE:-0}"
    return 0
  fi

  # ── Phase 1: doubling ladder (prefill-only, fast) ──
  log "  Ladder: doubling from 256..." >&2
  local B=256 BEST_TPS=0 BEST_BATCH=256 DESC=0 STOP=0
  while [ "$B" -le "$CEILING" ]; do
    log "  Testing batch=$B..." >&2
    local TPS
    TPS=$(test_rung "$B")
    if [ "$TPS" = "STALL" ]; then log "  STALL — aborting sweep" >&2; break; fi
    if [ "$TPS" = "OOM" ]; then log "  OOM at batch=$B — can't use this level" >&2; break; fi
    if python3 -c "exit(0 if $TPS > $BEST_TPS else 1)" 2>/dev/null; then
      BEST_TPS=$TPS; BEST_BATCH=$B
    fi
    if [ "$B" -gt "$BEST_BATCH" ] 2>/dev/null \
       && python3 -c "exit(0 if $TPS < $BEST_TPS else 1)" 2>/dev/null; then
      DESC=$((DESC + 1))
      if [ "$DESC" -ge 2 ]; then
        log "  Descending side confirmed past peak batch=$BEST_BATCH (${BEST_TPS} t/s)" >&2
        STOP=1; break
      fi
    else
      DESC=0
    fi
    B=$((B * 2))
  done

  if [ "$STOP" -eq 0 ]; then
    log "  No descent seen — peak at tested edge. Best: batch=$BEST_BATCH (${BEST_TPS} t/s)" >&2
  fi

  # ── Phase 2: golden-section max-search on prefill (pure prefill optimization) ──
  local LO HI
  read -r LO HI < <(python3 -c "
pts = []
with open('$PTS') as f:
    for line in f:
        b, p = line.split()[:2]
        pts.append((int(b), float(p)))
pts.sort()
peak = $BEST_BATCH
lo = hi = None
for b, p in pts:
    if b < peak: lo = b
    elif b == peak: continue
    elif b > peak and hi is None: hi = b
if lo is None: lo = 256
if hi is None: hi = min($CEILING, peak * 2)
print(lo, hi)
" 2>/dev/null || echo "256 $CEILING")
  [ -z "$LO" ] && LO=256
  [ -z "$HI" ] && HI=$CEILING
  log "  Peak=$BEST_BATCH (${BEST_TPS} t/s) → golden-section bracket [$LO, $HI]" >&2

  local A B2 A_MEAS B2_MEAS
  lookup_tps() {
    awk -v b="$1" '$1==b{print $2; exit}' "$PTS" 2>/dev/null
  }

  while [ $((HI - LO)) -gt 64 ]; do
    B2=$((HI - (HI - LO) * 382 / 1000)); B2=$((B2 / 64 * 64))
    A=$((LO + (HI - LO) * 382 / 1000)); A=$((A / 64 * 64))
    [ "$A" -le "$LO" ] && A=$((LO + 64))
    [ "$B2" -ge "$HI" ] && B2=$((HI - 64))
    [ "$B2" -le "$A" ] && B2=$((A + 64))

    A_MEAS=$(lookup_tps "$A")
    B2_MEAS=$(lookup_tps "$B2")
    if [ -n "$A_MEAS" ] && [ -n "$B2_MEAS" ]; then
      log "  No new 64-granularity point between $LO and $HI — stopping golden-section" >&2
      break
    fi

    if [ -z "$A_MEAS" ]; then
      log "  Golden: testing A=$A (lo=$LO, hi=$HI)..." >&2
      A_MEAS=$(test_rung "$A")
      [ "$A_MEAS" = "STALL" ] && { log "  STALL — aborting sweep" >&2; break; }
    else
      log "  Golden: reuse A=$A (${A_MEAS} t/s, already measured)" >&2
    fi
    if [ -z "$B2_MEAS" ]; then
      log "  Golden: testing B2=$B2 (lo=$LO, hi=$HI)..." >&2
      B2_MEAS=$(test_rung "$B2")
      [ "$B2_MEAS" = "STALL" ] && { log "  STALL — aborting sweep" >&2; break; }
    else
      log "  Golden: reuse B2=$B2 (${B2_MEAS} t/s, already measured)" >&2
    fi

    A_MEAS=$(python3 -c "print('$A_MEAS')" 2>/dev/null); [ "$A_MEAS" = "OOM" ] && A_MEAS=-1
    B2_MEAS=$(python3 -c "print('$B2_MEAS')" 2>/dev/null); [ "$B2_MEAS" = "OOM" ] && B2_MEAS=-1

    if [ "$A_MEAS" != "-1" ] 2>/dev/null && python3 -c "exit(0 if $A_MEAS > $BEST_TPS else 1)" 2>/dev/null; then
      BEST_TPS=$A_MEAS; BEST_BATCH=$A
    fi
    if [ "$B2_MEAS" != "-1" ] 2>/dev/null && python3 -c "exit(0 if $B2_MEAS > $BEST_TPS else 1)" 2>/dev/null; then
      BEST_TPS=$B2_MEAS; BEST_BATCH=$B2
    fi

    if python3 -c "exit(0 if $A_MEAS > $B2_MEAS else 1)" 2>/dev/null; then
      HI=$B2
    else
      LO=$A
    fi
    [ $((HI - LO)) -le 64 ] && break
  done

  log "  Prefill search done. Best prefill: batch=$BEST_BATCH (${BEST_TPS} t/s)" >&2

  # ── Shortlist decode gate: run full decode on top-N prefill candidates ──
  local SHORTLIST_PREFILL=$(mktemp)   # top-N by prefill (batch prefill)
  python3 -c "
pts = []
with open('$PTS') as f:
    for line in f:
        b, p = line.split()[:2]
        pts.append((int(b), float(p)))
pts.sort(key=lambda x: -x[1])
for b, p in pts[:$SHORTLIST_SIZE]:
    print(f'{b} {p}')
" > "$SHORTLIST_PREFILL" 2>/dev/null

  log "  Running decode gate on top-${SHORTLIST_SIZE} prefill candidates..." >&2
  local MAX_DECODE=0 DECODE_THRESHOLD
  local SHORTLIST_RAW=$(mktemp)   # batch prefill decode (all decoded entries, prefill-desc)

  # Single pass: decode each shortlist candidate, collect raw values, track MAX_DECODE
  while IFS=' ' read -r SB SP; do
    [ -z "$SB" ] && continue
    set_batch "$SB" >&2; restart >&2
    local D_RESULT
    D_RESULT=$(decode_guarded_probe "$CTX")
    local D_PFC D_DEC
    D_PFC=$(echo "$D_RESULT" | cut -d'|' -f1)
    D_DEC=$(echo "$D_RESULT" | cut -d'|' -f2)
    if [ "$D_PFC" = "0" ] && [ "$D_DEC" = "0" ]; then
      log "  batch=$SB: decode probe STALL/OOM — DECODE-DROPPED" >&2
      echo "$SB $SP 0 STALL" >> "$SHORTLIST_RAW"
      continue
    fi
    echo "$SB $D_PFC $D_DEC HEALTHY" >> "$SHORTLIST_RAW"
    log "  batch=$SB: prefill=${D_PFC} t/s decode=${D_DEC} t/s" >&2
    if python3 -c "exit(0 if $D_DEC > $MAX_DECODE else 1)" 2>/dev/null; then
      MAX_DECODE=$D_DEC
    fi
  done < "$SHORTLIST_PREFILL"
  rm -f "$SHORTLIST_PREFILL"

  # Compute threshold
  DECODE_THRESHOLD=$(python3 -c "print($MAX_DECODE * $DECODE_GATE_FACTOR)" 2>/dev/null || echo 0)
  log "  Max decode (shortlist)=${MAX_DECODE} t/s, gate threshold=${DECODE_THRESHOLD} t/s" >&2

  # Apply decode gate: reclassify HEALTHY → DECODE-DROPPED if below threshold, display all
  local SHORTLIST_HEALTHY=$(mktemp)  # batch prefill (healthy candidates only, prefill-desc)
  while IFS=' ' read -r SB SP SD SR; do
    [ -z "$SB" ] && continue
    local TAG="$SR"
    if [ "$SR" = "HEALTHY" ]; then
      if python3 -c "exit(0 if $SD < $DECODE_THRESHOLD else 1)" 2>/dev/null; then
        TAG="DECODE-DROPPED"
      fi
    fi
    log "    batch=$SB  prefill=${SP} t/s  decode=${SD} t/s  [$TAG]" >&2
    if [ "$TAG" = "HEALTHY" ]; then
      echo "$SB $SP" >> "$SHORTLIST_HEALTHY"
    fi
  done < "$SHORTLIST_RAW"
  rm -f "$SHORTLIST_RAW"

  # ── Confirm: saturation-test decode-healthy candidates (top-3 prefill), fallback to CEILING ──
  log "" >&2
  local CONFIRM_BATCH CONFIRM_PFC CONFIRM_FOUND=0 CONFIRM_COUNT=0 CONFIRM_MAX=3

  while IFS=' ' read -r CONFIRM_BATCH CONFIRM_PFC; do
    [ -z "$CONFIRM_BATCH" ] && continue
    CONFIRM_COUNT=$((CONFIRM_COUNT + 1))
    [ "$CONFIRM_COUNT" -gt "$CONFIRM_MAX" ] && break
    log "  Confirm $CONFIRM_COUNT/$CONFIRM_MAX: saturation_test at batch=$CONFIRM_BATCH (${CONFIRM_PFC} t/s)..." >&2
    set_batch "$CONFIRM_BATCH" >&2; restart >&2
    saturation_test "$CTX" >&2
    local C_RC=$?
    if [ "$C_RC" -eq 0 ]; then
      log "  Confirm PASS at batch=$CONFIRM_BATCH (${CONFIRM_PFC} t/s)" >&2
      CONFIRM_FOUND=1; break
    elif [ "$C_RC" -eq 2 ]; then
      log "  STALL during confirm — falling back to CEILING (pre-validated batch=$CEILING)" >&2
      break
    else
      log "  Confirm FAIL at batch=$CONFIRM_BATCH — trying next candidate..." >&2
    fi
  done < "$SHORTLIST_HEALTHY"

  rm -f "$SHORTLIST_HEALTHY"

  if [ "$CONFIRM_FOUND" -eq 1 ]; then
    echo "$CONFIRM_BATCH|$CONFIRM_PFC"
  else
    log "  All decode-healthy candidates failed saturation — using CEILING (pre-validated batch=$CEILING)" >&2
    echo "$CEILING|0"
  fi
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
    python3 -c "
import json
payload = {'model':'$MODEL','messages':[{'role':'user','content':'Say hello'}],'max_tokens':8}
with open('/tmp/mtp_payload.json','w') as f: json.dump(payload, f)
"
    fire_request /tmp/mtp_payload.json /tmp/mtp_detect.json "mtp-detect"
    local RC=$?
    if [ "$RC" -eq 2 ]; then
      log "  STALL during MTP detection (network/HF fetch) — aborting"
      restore_section "$SNAP"
      exit 1
    fi
    wait "$FIRE_PID" 2>/dev/null || true

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
  fire_request /tmp/mtp_payload.json /tmp/mtp_out.json "mtp-tune" "$(adaptive_timeout 4000)"
  local RC=$?
  if [ "$RC" -eq 2 ]; then
    plog "  STALL — model never served (network/HF fetch)"
    return 2
  fi
  local PID=$FIRE_PID

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
  SERVED_GRACE=$((60 + CTX / 65536 * 40))
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
    local DEC_RC=$?
    if [ "$DEC_RC" -eq 2 ]; then
      log ""; log "  STALL during n_max=$N sweep — network/HF fetch, aborting tune"
      return 1
    fi
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
    local DEC_RC=$?
    if [ "$DEC_RC" -eq 2 ]; then
      log ""; log "  STALL during p_min=$P sweep — network/HF fetch, aborting tune"
      return 1
    fi
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

# ── SUBCOMMAND: bisect (batch ceiling + prefill sweep) ──────
# Args: MODEL, then optional TEST_BATCH
cmd_bisect() {
  local TEST_BATCH=0
  if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
    TEST_BATCH=$2
  fi

  local CTX=$(read_ctx)
  SERVED_GRACE=$((60 + CTX / 65536 * 40))
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
    log ""; log "=== TESTING BATCH $TEST_BATCH ==="
    set_batch "$TEST_BATCH"; restart
    log ""; log "=== PHASE 1: TINY PROBE ==="
    tiny_probe
    local T_RC=$?
    if [ "$T_RC" -eq 2 ]; then log "  STALL — aborting"; exit 1; fi
    if [ "$T_RC" -ne 0 ]; then log "  FAIL"; exit 1; fi
    log "  PASS"
    log ""; log "=== PHASE 2: SATURATION ==="
    saturation_test "$CTX"
    local S_RC=$?
    if [ "$S_RC" -eq 2 ]; then log "  STALL — aborting"; exit 1; fi
    if [ "$S_RC" -ne 0 ]; then log "  FAILED"; exit 1; fi
    log ""; log "=== PHASE 3: LONG-DECODE ==="
    long_decode_check
    local LD_RC=$?
    if [ "$LD_RC" -eq 2 ]; then log "  STALL — aborting"; exit 1; fi
    log ""; log "=== RESULT: batch=$TEST_BATCH ubatch=$TEST_BATCH ==="
    log "=== DONE ==="
    exit 0
  fi

  # ── EARLY RESIDENCY GATE (batch=256): route CPU-compute straight to prefill sweep ──
  log ""; log "=== EARLY RESIDENCY GATE (batch=256) ==="
  set_batch 256; restart
  local R_FIT
  R_FIT=$(residency_probe)
  if [ "$R_FIT" = "STALL" ]; then
    log "  Early gate: STALL — model can't cold-load (network/HF fetch)"
    exit 1
  fi
  if [ "$R_FIT" = "CPU" ]; then
    log "  CPU-compute at batch 256 — skipping ceiling search, running saturation sweep"
    local SWEEP_OUT
    SWEEP_OUT=$(cpu_saturation_sweep "$CTX")
    local WIN WIN_TPS
    WIN=$(echo "$SWEEP_OUT" | cut -d'|' -f1)
    WIN_TPS=$(echo "$SWEEP_OUT" | cut -d'|' -f2)
    [ -z "$WIN" ] && WIN="$SWEEP_OUT"  # fallback if no pipe present
    set_batch "$WIN"
    local VALIDATED=$WIN PASS=1 CANDIDATES=0
    log ""; log "  *** PERFORMANCE-OPTIMIZED batch=$WIN (${WIN_TPS} t/s, CPU-compute, fastest prefill) ***"
    log ""; log "=== RESULT ==="
    log "  batch=$WIN ubatch=$WIN ctx=$CTX"
    log "  candidates=$CANDIDATES saturation-confirm=$PASS/1"
    log "  saturation sweep: CPU-compute detected early, fastest prefill by saturation at 99% ctx"
    log ""; log "  Next: run bench.sh bench $MODEL"
    log "=== DONE ==="
    exit 0
  fi
  log "  GPU/AMBIGUOUS at batch 256 — proceeding with ceiling search"

  # ── PHASE 1: CEILING SEARCH ──
  # Shared ceiling_probe definition (tiny probe + saturation gate).
  ceiling_probe() {
    local B=$1
    set_batch "$B"; restart
    log "  Tiny probe @ batch=$B..."
    local T_RC=0
    tiny_probe; T_RC=$?
    if [ "$T_RC" -eq 2 ]; then
      log "  STALL at $B (network/HF fetch — not an OOM ceiling)"
      log "  Aborting bisect: model can't cold-load. Re-run when huggingface.co is reachable."
      exit 1
    fi
    local S_RC=0
    if [ "$T_RC" -eq 0 ]; then
      log "  Probe PASS at $B — saturation-validating..."
      saturation_test "$CTX"
      S_RC=$?
      if [ "$S_RC" -eq 2 ]; then
        log "  STALL during saturation at $B (network/HF fetch)"
        exit 1
      fi
      if [ "$S_RC" -eq 0 ]; then
        log "  PASS at $B (probe + saturation)"
        return 0
      fi
    fi
    if [ "$S_RC" -eq 3 ]; then
      log "  FORMAT ERROR at $B (500 / peg-native format failure)"
    elif [ "$S_RC" -eq 4 ]; then
      log "  SIZING FAILURE at $B (could not reach compaction in $ATTEMPT attempts)"
    else
      log "  OOM at $B"
    fi
    return 1
  }

  local LO HI VALIDATED PASS CANDIDATES

  # ── PHASE 1: CEILING SEARCH ──
  # ctx first, then 2048+doubling ladder.
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
        # 2048 OOMs — halve DOWN from 2048
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
    local T_RC=0
    tiny_probe; T_RC=$?
    if [ "$T_RC" -eq 2 ]; then
      log "  STALL at $MID (network/HF fetch) — aborting bisect"
      exit 1
    fi
    if [ "$T_RC" -eq 0 ]; then
      log "  Probe PASS — running saturation..."
      saturation_test "$CTX"
      local S_RC=$?
      if [ "$S_RC" -eq 2 ]; then
        log "  STALL during saturation at $MID — aborting bisect"
        exit 1
      fi
      if [ "$S_RC" -eq 0 ]; then
        log "  PASS (probe + saturation)"; LO=$MID
      elif [ "$S_RC" -eq 3 ]; then
        log "  FORMAT ERROR (500 / peg-native format failure)"; HI=$MID
      elif [ "$S_RC" -eq 4 ]; then
        log "  SIZING FAILURE (could not reach compaction)"; HI=$MID
      else
        log "  OOM"; HI=$MID
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
  saturation_test "$CTX"
  local S_RC=$?
  if [ "$S_RC" -eq 2 ]; then
    log "  STALL during final-confirm saturation — aborting"
    exit 1
  fi
  if [ "$S_RC" -eq 0 ]; then
    PASS=1
    log "  *** VALIDATED batch=$VALIDATED ***"
  else
    log "  Final confirm FAIL — bracketed halve-down search"
    bracketed_halve_down "$VALIDATED" "$CTX" || exit 1
    VALIDATED=$BHD_RESULT
    PASS=1
    log "  *** Saturation-validated batch=$VALIDATED (bracketed search) ***"
  fi

  # ── RE-CONFIRM: multi-cycle cold-load validation ──
  # The bisect's single-pass saturation can miss intermittent load crashes.
  # Re-check with N cold-loads; if any crash, step the batch down.
  # Wraps in a while loop so stepped-down values are re-submitted.
  log ""
  while true; do
    log "=== RE-CONFIRM: testing batch=$VALIDATED × 3 ==="
    local RC_PASS=0 RC_CYCLES=0
    for RC_CYCLES in 1 2 3; do
      set_batch "$VALIDATED"; restart
      tiny_probe
      local RC_T=$?
      local RC_O=$(oom_count_since_mark)
      if [ "$RC_T" -ne 0 ] || [ "$RC_O" -gt 0 ]; then
        log "  Re-confirm $RC_CYCLES: FAIL (OOM or probe failure at batch=$VALIDATED)"
        break
      fi
      RC_PASS=$((RC_PASS + 1))
      log "  Re-confirm $RC_CYCLES: PASS"
    done
    if [ "$RC_PASS" -eq 3 ]; then
      log "  Re-confirm PASSED (3/3 cycles) — batch $VALIDATED is reliable"
      break
    fi
    log "  Re-confirm FAILED ($RC_PASS/3 cycles passed) — stepping down"
    bracketed_halve_down "$VALIDATED" "$CTX" || exit 1
    VALIDATED=$BHD_RESULT
    if [ "$VALIDATED" -le 64 ]; then
      log "  ERROR: no reliable batch found above 64 — aborting"
      exit 1
    fi
    log "  Stepped down to batch=$VALIDATED — re-confirming..."
  done

  log ""; log "=== LONG-DECODE CHECK ==="
  set_batch "$VALIDATED"; restart
  long_decode_check
  local LD_RC=$?
  if [ "$LD_RC" -eq 2 ]; then
    log "  STALL during long-decode — aborting"
    exit 1
  fi

  # ── RESIDENCY GATE + SELECTION ──
  # GPU-resident models: sweep 256→ceiling via gpu_saturation_sweep, which measures
  # decode per rung and picks fastest prefill among decode-healthy candidates.
  # CPU-spilled models: descend to largest GPU-resident ceiling, then sweep.
  log ""; log "=== RESIDENCY CHECK (batch=$VALIDATED) ==="
  local R_VERDICT DESC
  R_VERDICT=$(residency_probe)
  if [ "$R_VERDICT" = "STALL" ]; then
    log "  residency: STALL — model can't cold-load (network/HF fetch)"
    exit 1
  fi
  if [ "$R_VERDICT" = "GPU" ]; then
    log "  ceiling is GPU-resident — running decode-guarded prefill sweep (256→$VALIDATED)"
  else
    # Early gate confirmed GPU-capable at 256; ceiling spilled — descend to largest GPU-resident.
    log "  ceiling spilled — descending to largest GPU-resident batch"
    DESC=$(residency_descend "$VALIDATED")
    local DESC_RC=$?
    if [ "$DESC_RC" -eq 2 ]; then
      log "  residency descend: STALL — model can't cold-load (network/HF fetch)"
      exit 1
    fi
    VALIDATED=$DESC
    log "  Largest GPU-resident batch: $VALIDATED — running decode-guarded prefill sweep (256→$VALIDATED)"
  fi

  # ── GPU SATURATION SWEEP: decode-guarded fastest prefill ──
  local SWEEP_OUT
  SWEEP_OUT=$(gpu_saturation_sweep "$CTX" "$VALIDATED")
  local WIN WIN_TPS
  WIN=$(echo "$SWEEP_OUT" | cut -d'|' -f1)
  WIN_TPS=$(echo "$SWEEP_OUT" | cut -d'|' -f2)
  [ -z "$WIN" ] && WIN="$SWEEP_OUT"  # fallback
  set_batch "$WIN"

  log ""; log "  *** PERFORMANCE-OPTIMIZED batch=$WIN (${WIN_TPS} t/s, decode-guarded prefill) ***"

  log ""; log "=== RESULT ==="
  log "  batch=$WIN ubatch=$WIN ctx=$CTX"
  log "  candidates=$CANDIDATES saturation-confirm=$PASS/1"
  log "  decode-guarded prefill sweep: fastest prefill among decode-healthy batches (decode ≥ 90% best)"
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
  SERVED_GRACE=$((60 + CTX / 65536 * 40))
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
  fire_request /tmp/ratio_payload.json /tmp/ratio_response.json "bench-ratio"
  local RC=$?
  if [ "$RC" -eq 2 ]; then
    log "  STALL on ratio probe — aborting bench"
    return 1
  fi
  wait "$FIRE_PID" 2>/dev/null || true
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
  fire_request /tmp/bench_prefill_payload.json /tmp/bench_prefill.json "bench-prefill"
  local RC=$?
  if [ "$RC" -eq 2 ]; then log "  STALL on prefill — aborting bench"; return 1; fi
  wait "$FIRE_PID" 2>/dev/null || true

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
  fire_request /tmp/bench_payload.json /tmp/bench_output.json "bench-decode" "$(adaptive_timeout 4000)"
  local RC=$?
  if [ "$RC" -eq 2 ]; then log "  STALL on decode — aborting bench"; return 1; fi
  local PID=$FIRE_PID

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

  # ── Pre-pass: reset parents before siblings inherit ──
  if [ "$RESET_PARENT" -eq 1 ]; then
    log ""
    log "=== RESET-PARENT: benching parent models first ==="
    declare -A RESET_SEEN
    for i in $MODEL_IDXS; do
      NAME=$(model_name "$i")
      PARENT_NAME=$(family_of "$NAME")
      [ -z "$PARENT_NAME" ] && continue
      [ "${RESET_SEEN[$PARENT_NAME]:-0}" -eq 1 ] && continue
      RESET_SEEN["$PARENT_NAME"]=1
      MODEL=$PARENT_NAME
      lshow ""
      lshow "=============== RESET PARENT: $PARENT_NAME ==============="
      log "  $(date +%H:%M:%S) starting bisect for $PARENT_NAME"
      if ( cmd_bisect ); then
        log "  $(date +%H:%M:%S) bisect OK for $PARENT_NAME"
      else
        log "  $(date +%H:%M:%S) bisect FAILED for $PARENT_NAME"
      fi
      log "  $(date +%H:%M:%S) starting bench for $PARENT_NAME"
      if ( cmd_bench ); then
        log "  $(date +%H:%M:%S) bench OK for $PARENT_NAME"
        RESET_DONE["$PARENT_NAME"]=1
      else
        log "  $(date +%H:%M:%S) bench FAILED for $PARENT_NAME"
      fi
    done
  fi

  # ── Main per-model flow ──
  for i in $MODEL_IDXS; do
    NAME=$(model_name "$i")
    MODEL=$NAME
    lshow ""
    lshow "=============== MODEL: $NAME ==============="
    local IS_MTP=0 BISECT_FAILED=0

    # ── Inheritance gate ──
    if maybe_inherit "$NAME"; then
      PARENT_NAME=$(family_of "$NAME")
      lshow "  $NAME: inheriting from $PARENT_NAME (JSON copied, no bench)"
      for s in mtpcheck bisect mtp bench; do
        VERDICTS["$NAME|$s"]="SKIPPED (inherited from $PARENT_NAME)"
      done
      continue
    fi

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
    elif [ "$(read_batch)" = "" ]; then
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

# ── Inheritance flags (global, apply to whole selection) ──
declare -A RESET_DONE
INHERIT_MODE=1
RESET_PARENT=0
MAIN_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --no-inherit)  INHERIT_MODE=0 ;;
    --reset-parent) RESET_PARENT=1 ;;
    *)             MAIN_ARGS+=("$arg") ;;
  esac
done
# Replace "$@" with filtered args for downstream parsing
set -- "${MAIN_ARGS[@]+"${MAIN_ARGS[@]}"}"

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

  # ── Interactive inheritance prompts ──
  echo ""
  read -r -p "Inherit values from family parent? [Y/n]: " INHERIT_INPUT
  case "${INHERIT_INPUT:-Y}" in
    [nN]|[nN][oO]) INHERIT_MODE=0; log "  Inherit mode: OFF (each model bench-marked independently)" ;;
    *)              INHERIT_MODE=1; log "  Inherit mode: ON (siblings inherit from parent's JSON)" ;;
  esac

  if [ "$INHERIT_MODE" -eq 1 ]; then
    read -r -p "Reset parent first? (re-bench parent to create fresh source) [y/N]: " RESET_INPUT
    case "${RESET_INPUT:-N}" in
      [yY]|[yY][eE][sS]) RESET_PARENT=1; log "  Reset parent: YES (parent will be re-benched first)" ;;
      *)                  RESET_PARENT=0 ;;
    esac
  fi

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
    # Pre-pass: if RESET_PARENT, bench each selected model's parent first
    if [ "$RESET_PARENT" -eq 1 ]; then
      for m in "$@"; do
        PARENT=$(family_of "$m")
        [ "${RESET_DONE[$PARENT]:-0}" -eq 1 ] && continue
        MODEL=$PARENT
        log "  Resetting parent $PARENT for $m..."
        if ( cmd_bisect ); then
          log "  bisect OK for $PARENT"
          if ( cmd_bench ); then
            log "  bench OK for $PARENT"
            RESET_DONE["$PARENT"]=1
          else
            log "  bench FAILED for $PARENT"
          fi
        else
          log "  bisect FAILED for $PARENT"
        fi
      done
    fi
    for m in "$@"; do
      MODEL=$m
      if maybe_inherit "$m"; then
        log "  $m: inheriting from $(family_of "$m")"
        continue
      fi
      ( cmd_bench ) || { echo "  $m: bench FAILED"; continue; }
    done
    ;;
  *)
    echo "Usage: bench.sh [all|mtpcheck|bisect|mtp|bench] <models...>"
    echo "       bench.sh                                    # interactive full suite"
    echo "       bench.sh all <models...>                    # non-interactive full suite"
    echo "       bench.sh mtpcheck <models...>               # MTP capability check"
    echo "       bench.sh bisect <model> [test-batch]"
    echo "       bench.sh mtp <models...>                    # n_max/p_min tuning"
    echo "       bench.sh bench <models...>                  # benchmark JSON record"
    exit 1
    ;;
esac
