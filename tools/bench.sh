#!/bin/bash
# bench.sh — Unified benchmarking pipeline: MTP capability check, batch bisect,
# MTP tuning, and full benchmark record. Single script, single scope.
#
# Usage:
#   ./tools/bench.sh                            # interactive: pick models, full suite, confirm
#   ./tools/bench.sh all <models...>            # non-interactive full suite per model
#   ./tools/bench.sh mtpcheck <models...>       # MTP capability check only (writes spec-type)
#   ./tools/bench.sh mtpverify <models...>      # MTP-on vs off output check (premise test)
#   ./tools/bench.sh bisect <model> [test-batch]
#   ./tools/bench.sh mtp <models...>            # n_max/p_min tuning (requires mtpcheck first)
#   ./tools/bench.sh bench <models...>          # full benchmark JSON record
#
# Global flags (before the subcommand): --no-inherit, --reset-parent,
# --thorough (exhaustive tuners/bisect), --strict (skip bench when mtp tuning
# failed, §6.4 part 3). Default mode is discover; --thorough re-enables the old
# exhaustive tuners/bisect. Env BENCH_THOROUGH=1 is honoured; BENCH_DISCOVER=1 is
# a deprecated no-op alias (discover is the default).
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
# smpbo and nbytes_shared added in commit 18415cf — grep pattern for server crash/error markers
OMG_GREP="cudaMalloc failed|failed to allocate compute pp buffers|terminate called after throwing|failed to create MTP context|exiting due to model loading error|CUDA error: out of memory|cuMemCreate|GGML_ASSERT|nbytes_shared|smpbo"
POLL_MIN_SAMPLES=3
POLL_MAX_SAMPLES=80
MAX_BATCH=16384          # batch search cap: never probe above min(ctx, MAX_BATCH)
MTP_TIE_NATS=0.25        # mtpverify: gap below this (nats) at the divergence token = a near-tie, premise holds
# Decode measurement (§5): speed samples use a natural-stop prompt (NO ignore_eos)
# so a looping / forced decode cannot inflate t/s or acceptance. A sample shorter
# than MIN_DECODE_TOKENS is SHORT (retried once with the LONG prompt, then ignored).
MIN_DECODE_TOKENS=512
DECODE_PROMPT="Write a comprehensive technical report on the history of computing. Cover these twelve eras in order, with a heading and at least 250 words each: mechanical calculators, Babbage and Lovelace, Hollerith and tabulation, relay computers, ENIAC and the stored program, transistors, integrated circuits, minicomputers, microprocessors, personal computers, the web, mobile and cloud. Finish with a 200-word conclusion."
DECODE_PROMPT_LONG="Write a comprehensive technical report on the history of computing. Cover these twelve eras in order, with a heading and at least 400 words each: mechanical calculators, Babbage and Lovelace, Hollerith and tabulation, relay computers, ENIAC and the stored program, transistors, integrated circuits, minicomputers, microprocessors, personal computers, the web, mobile and cloud. Finish with a 200-word conclusion. Do not summarise; write every section in full."
PREFILL_TOL=0             # discover pick tolerance. Default 0 = best-measured rung.
                          # Set to 0.03 to prefer a smaller batch within 3% of best for
                          # MTP draft headroom (plan §30.2 Change C).
PREFILL_NOISE=0.03        # discover refinement (§30.2b Change E): keep refining only while a
                          # midpoint beats the current best by more than this fraction (3%).
DECODE_CLIFF=0.70         # discover: decode at pick below this fraction of the 256 baseline = spill cliff
DECODE_WARN=0.90          # discover: below this: WARN only
MTP_TIE=0.05              # MTP tuning: candidates within 5% are a tie → smaller value wins
THOROUGH=0
STRICT=0                  # --strict: skip bench when mtp tuning failed (plan §6.4 part 3 / §7)

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

  # Write parent's MTP values (n_max/p_min) to child's models.ini section ONLY
  # when the parent JSON records mtp.tuning_status == "ok" (§6.4 part 4 / Q7).
  # Unvalidated MTP values (the old n_max_confirmed load-log field) must not
  # propagate. Batch and the rest of the JSON still always inherit.
  local PARENT_TUNING
  PARENT_TUNING=$(python3 -c "
import json
try:
    d = json.load(open('$MODELS_DIR/$PARENT.json'))
except Exception:
    print('missing'); exit()
ts = (d.get('mtp') or {}).get('tuning_status')
print(ts if ts else 'unknown')
")
  if [ "$PARENT_TUNING" = "ok" ]; then
    local PARENT_NMAX PARENT_PMIN
    PARENT_NMAX=$(python3 -c "
import re
with open('$INI') as f: c = f.read()
m = re.search(r'(\['+re.escape('$PARENT')+r'\])(.*?)(?=\n\[|\Z)', c, re.DOTALL)
sec = m.group(2) if m else ''
v = re.search(r'spec-draft-n-max\s*=\s*(\S+)', sec)
print(v.group(1) if v else '')
")
    PARENT_PMIN=$(python3 -c "
import re
with open('$INI') as f: c = f.read()
m = re.search(r'(\['+re.escape('$PARENT')+r'\])(.*?)(?=\n\[|\Z)', c, re.DOTALL)
sec = m.group(2) if m else ''
v = re.search(r'spec-draft-p-min\s*=\s*(\S+)', sec)
print(v.group(1) if v else '')
")
    python3 -c "
import re
with open('$INI') as f: c = f.read()
m = re.search(r'(\['+re.escape('$CHILD')+r'\])(.*?)(?=\n\[|\Z)', c, re.DOTALL)
if not m: exit()
sec = m.group(2); new_lines = []
nmax = '${PARENT_NMAX}'; pmin = '${PARENT_PMIN}'
for line in sec.split('\n'):
    if re.match(r'\s*spec-draft-n-max\s*=', line) and nmax:
        new_lines.append('spec-draft-n-max = ' + nmax)
    elif re.match(r'\s*spec-draft-p-min\s*=', line) and pmin:
        new_lines.append('spec-draft-p-min = ' + pmin)
    else:
        new_lines.append(line)
with open('$INI','w') as f: f.write(c[:m.start(2)] + '\n'.join(new_lines) + c[m.end(2):])
" 2>/dev/null
    log "  Inherited parent MTP config: spec-draft-n-max=${PARENT_NMAX:-?} spec-draft-p-min=${PARENT_PMIN:-?}"
  elif [ "$PARENT_TUNING" = "unknown" ]; then
    log "  MTP values NOT inherited (parent JSON predates tuning_status; re-run 'bench.sh mtp $PARENT' to stamp it)"
  else
    log "  MTP values NOT inherited (parent tuning_status=$PARENT_TUNING)"
  fi
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
    log "  $LABEL: cold-load hang (no proxy line in ${SERVED_GRACE}s) — retrying as attempt $((ATTEMPT+1))" >&2
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

  # ---- Phase 1: sizing (max_tokens=1) — discover ratio, land near 99% ctx ----
  # Timeout must cover prefill of the overshoot prompt (~ctx tokens), not max_tokens=1.
  # Pre-fill of ctx tokens at ~60 t/s worst-case with 4x margin; floor 1200s, cap 14400s.
  local SAT_TIMEOUT=$(python3 -c "print(max(1200, min(14400, int($CTX / 60 * 4))))")
  while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
    python3 -c "
import json
filler = 'The history of computing is long and complex. '
SAT_SIZE = $SAT_SIZE
prompt = (filler * ((SAT_SIZE // len(filler)) + 1))[:SAT_SIZE]
payload = {'model':'$MODEL','messages':[{'role':'user','content':prompt}],'max_tokens':$MEASURE_TOK,'ignore_eos':True}
with open('/tmp/sat_payload.json','w') as f: json.dump(payload, f)
"
    fire_request /tmp/sat_payload.json /tmp/sat_response.json "sat-size" "$SAT_TIMEOUT"
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
  # Decode-rate floor: if decode stays below 2 t/s for 3 consecutive 2s samples (~6s),
  # reject the batch. Catches pathological full-context decode collapse (e.g. REAP 198k).
  local DECODE_FLOOR=2  # t/s absolute minimum for usable decode
  local DECODE_FLOOR_SAMPLES=3  # consecutive samples below floor to trigger rejection
  # Stall detector: llama.cpp only logs its first n_gen at n_gen=100. A decode that is
  # collapsed-but-alive (e.g. 0.09 t/s) can take 15+ min to reach that, so the floor above
  # cannot fire promptly. Arm a stall timer once the DECODE task has launched (a
  # 'launch_slot_ ... processing task' MORE RECENT than the last 'prompt processing' line —
  # i.e. prefill done, generating now). If no n_gen appears within STALL_GRACE_SEC, reject.
  local STALL_GRACE_SEC=90
  local STALL_GRACE_SAMPLES=$((STALL_GRACE_SEC / 2))  # at 2s per watchdog tick
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

  local WATCH=0 SLOW=0 REJECT=0
  local NGEN_SEEN=0 DECODE_ARMED=0 ARMED_WATCH=0
  local LAST_LINE_PP=0 LAST_LINE_LAUNCH=0 LAST_LINE_NGEN=0
  while kill -0 $FIRE_PID 2>/dev/null; do
    if [ "$(oom_count_since_mark)" -gt 0 ]; then
      log "  Saturation: OOM detected — killing curl"
      kill $FIRE_PID 2>/dev/null
      break
    fi
    # ---- Track decode-task launch vs prefill progress (for stall detector) ----
    # Window is cumulative (LOG_MARK fixed), so compare LINE NUMBERS within the window,
    # not mere presence. A 'launch_slot_ ... processing task' whose line number is NEWER
    # than the last 'prompt processing' line means prefill finished and the decode task
    # has begun (decode produces n_gen, not prompt-processing) → arm the stall timer.
    local WINDOW_LOGS
    WINDOW_LOGS=$(docker logs $DOCKER_LOG 2>&1 | tail -n +$((LOG_MARK + 1)))
    LAST_LINE_PP=$(echo "$WINDOW_LOGS" | grep -n "prompt processing" | tail -1 | cut -d: -f1) || true
    LAST_LINE_LAUNCH=$(echo "$WINDOW_LOGS" | grep -n "launch_slot_.*processing task" | tail -1 | cut -d: -f1) || true
    LAST_LINE_NGEN=$(echo "$WINDOW_LOGS" | grep -n "n_gen =" | tail -1 | cut -d: -f1) || true
    [ -n "$LAST_LINE_NGEN" ] && NGEN_SEEN=1
    # Arm when the decode task is active: its launch is the most recent event (newer than
    # the last prompt-processing line) and no n_gen has appeared yet.
    if [ "$NGEN_SEEN" -eq 0 ] && [ "$DECODE_ARMED" -eq 0 ] \
       && [ -n "$LAST_LINE_LAUNCH" ] \
       && [ "$LAST_LINE_LAUNCH" -gt "${LAST_LINE_PP:-0}" ] \
       && [ "$LAST_LINE_LAUNCH" -gt "${LAST_LINE_NGEN:-0}" ]; then
      DECODE_ARMED=1
      ARMED_WATCH=$WATCH
      log "  Saturation: decode task started, arming stall timer (${STALL_GRACE_SEC}s no-n_gen)"
    fi
    # Stall gate: decode armed but no n_gen within grace → reject.
    if [ "$DECODE_ARMED" -eq 1 ] && [ "$NGEN_SEEN" -eq 0 ] \
       && [ $((WATCH - ARMED_WATCH)) -ge "$STALL_GRACE_SAMPLES" ]; then
      log "  Saturation: decode stalled — no n_gen within ${STALL_GRACE_SEC}s of decode start; rejecting batch"
      kill $FIRE_PID 2>/dev/null
      REJECT=1; break
    fi
    # Decode-rate floor: parse latest tg from n_gen streaming lines (decode-only)
    local TG
    TG=$(echo "$WINDOW_LOGS" \
         | grep "n_gen = " | tail -1 | grep -oE "tg =\s*[0-9.]+" | awk '{print $3}') || true
    if [ -n "$TG" ] 2>/dev/null; then
      if python3 -c "exit(0 if $TG < $DECODE_FLOOR else 1)" 2>/dev/null; then
        SLOW=$((SLOW + 1))
        if [ "$SLOW" -ge "$DECODE_FLOOR_SAMPLES" ]; then
          log "  Saturation: decode too slow at full context (${TG} t/s < ${DECODE_FLOOR} floor) — rejecting batch"
          kill $FIRE_PID 2>/dev/null
          REJECT=1; break
        fi
      else
        SLOW=0
      fi
    fi
    WATCH=$((WATCH + 1))
    [ $((WATCH % 30)) -eq 0 ] && log "    ...watchdog ${WATCH}x2s (request still running)"
    sleep 2
  done
  wait $FIRE_PID 2>/dev/null || true

  local OOM=$(oom_count_since_mark)
  if [ "$OOM" -gt 0 ]; then log "  Saturation: OOM"; return 1; fi
  if [ "$REJECT" -eq 1 ]; then log "  Saturation: decode rejected (too slow or stalled) — batch not validated"; return 5; fi

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

  # Allow decode to land within a small epsilon of the ctx ceiling. Small-ctx models
  # (e.g. gemma-4-12b @ 16k) stop 0-4 tokens short of ctx at 99%-ctx prefill; that IS
  # full-context saturation. EPSILON masks that boundary noise without admitting a
  # genuinely short decode (which would be thousands short, not 8).
  local EPSILON=8
  if [ $((PT + CT)) -ge $((CTX - EPSILON)) ]; then
    log "  Saturation: PASS (prompt_tokens=${PT}, completion_tokens=${CT}, total=$((PT+CT)), ctx=${CTX}, prefill=${SAT_PREFILL_TPS} t/s)"
    return 0
  fi
  log "  Saturation: accepted but no compaction (pt=${PT}+ct=${CT} < ctx=${CTX})"
  return 4
}

long_decode_check() {
  local CTX=$(read_ctx)
  local DECODE_MAX=$(python3 -c "print(max(256, min(6000, $CTX - 64)))")
  log "  Long-decode: essay prompt, max_tokens=${DECODE_MAX}..."
  python3 -c "
import json
with open('/tmp/longdec_payload.json','w') as f:
    json.dump({'model':'$MODEL','messages':[{'role':'user','content':'Write a detailed essay explaining the history of computing.'}],'max_tokens':${DECODE_MAX},'ignore_eos':True}, f)
"
  fire_request /tmp/longdec_payload.json /tmp/longdec_response.json "long-decode" "$(adaptive_timeout $DECODE_MAX)"
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

  # Decode probe (short prompt, clamped decode window) — poll CPU during it
  # for GPU-residency classification
  local DECODE_MAX=$(python3 -c "print(max(256, min(4000, $CTX - 64)))")
  python3 -c "
import json
payload = {'model':'$MODEL','messages':[{'role':'user','content':'Explain the history of computing in detail.'}],'max_tokens':${DECODE_MAX},'ignore_eos':True}
with open('/tmp/perf_decode_payload.json','w') as f: json.dump(payload, f)
"
  fire_request /tmp/perf_decode_payload.json /tmp/perf_decode.json "measure-decode" "$(adaptive_timeout $DECODE_MAX)"
  local DEC_RC=$?
  if [ "$DEC_RC" -eq 2 ]; then echo "0|0|0"; return 0; fi
  local DEC_PID=$FIRE_PID
  local CPU_SAMPLES=()
  for i in $(seq 1 40); do
    local TOP CPU
    TOP=$(top -bn1 2>/dev/null | grep llama-s | head -n1) || true
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
#   gpu_util > GPU_ACTIVE_PCT AND cpu < GPU_CPU_MAX → GPU-resident (model active on GPU)
#   GPU_CPU_MAX is 150, not 100: gemma-class decode idles one core at 100-105%, so a
#   <100 threshold never early-kills and the probe runs its full 40-sample window.
#   A real draft spill measures 270-1600% (§30.2 Change B), so <150 + GPU is still safe.
#   150-200% is noise/AMBIGUOUS — not proven GPU, not proven CPU (never forced).
# Echoes one of: GPU | CPU | AMBIGUOUS
GPU_ACTIVE_PCT=25
GPU_CPU_MAX=150           # cpu < this + GPU active => GPU-resident (plan §30.2 Change B)
RESID_MIN_FLOOR_SAMPLES=10   # 20s @2s before early-kill verdicts are allowed (belt-and-suspenders)

# ── Binary placement classifier (plan §37 Change F) ─────────
# One classifier shared by residency_probe, decode_sample and cmd_bench so the
# published record never says AMBIGUOUS. A GPU-resident llama.cpp keeps exactly
# one host thread busy feeding the GPU, so its process CPU sits at ~100% and
# wobbles to 105-110; that is not compute on the CPU. GPU utilisation is direct
# evidence of where the matrix work runs, so it decides the 150-200% band.
# Echoes one of: GPU | CPU (never AMBIGUOUS).
classify_placement() {
  local AVG_CPU=$1 AVG_GPU=$2
  if python3 -c "exit(0 if float('$AVG_CPU') > 200 else 1)" 2>/dev/null; then
    echo "CPU"; return 0
  fi
  if python3 -c "exit(0 if float('$AVG_CPU') < $GPU_CPU_MAX else 1)" 2>/dev/null \
     && python3 -c "exit(0 if float('$AVG_GPU') > $GPU_ACTIVE_PCT else 1)" 2>/dev/null; then
    echo "GPU"; return 0
  fi
  # 150-200% CPU: decide by the GPU — busy means a host thread plus sampling (GPU);
  # idle means the compute is on the CPU.
  if python3 -c "exit(0 if float('$AVG_GPU') > $GPU_ACTIVE_PCT else 1)" 2>/dev/null; then
    echo "GPU"
  else
    echo "CPU"
  fi
  return 0
}

residency_probe() {
  # stdout is reserved for the single verdict (GPU|CPU|AMBIGUOUS); all progress
  # logs go to stderr so command-substitution captures stay clean.
  local CTX=$(read_ctx)
  local DECODE_MAX=$(python3 -c "print(max(256, min(4000, $CTX - 64)))")
  python3 -c "
import json
# stream:true so llama.cpp aborts generation when residency kills the curl early
# (a non-streaming client disconnect is only noticed on the next server write,
# leaving the slot decoding the remaining tokens and stalling the next request).
payload = {'model':'$MODEL','messages':[{'role':'user','content':'Explain the history of computing in detail.'}],'max_tokens':${DECODE_MAX},'ignore_eos':True,'stream':True}
with open('/tmp/resid_payload.json','w') as f: json.dump(payload, f)
"
  fire_request /tmp/resid_payload.json /tmp/resid_response.json "residency" "$(adaptive_timeout $DECODE_MAX)"
  local RC=$?
  if [ "$RC" -eq 2 ]; then
    log "  residency: STALL — model never served (network/HF fetch)" >&2
    echo "STALL"; return 0
  fi
  local R_PID=$FIRE_PID

  local R_CPU_SUM=0 R_CPU_CNT=0 R_GPU_SUM=0 R_GPU_CNT=0 R_GPU_SEEN=0
  local R_CPU=0 R_GPU=0 R_TEMP=0 R_CPU_CONSEC=0 R_GPU_CONSEC=0
  local i
  for i in $(seq 1 40); do
    local TOP STATS
    TOP=$(top -bn1 2>/dev/null | grep llama-s | head -n1) || true
    R_CPU=$(echo "$TOP" | awk '{print $9}' 2>/dev/null || echo "0")
    STATS=$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>/dev/null)
    R_GPU=$(echo "$STATS" | cut -d',' -f1 | tr -d ' ')
    R_TEMP=$(echo "$STATS" | cut -d',' -f2 | tr -d ' ')

    [ -n "$R_CPU" ] && [ "$R_CPU" != "0.0" ] && { R_CPU_SUM=$(echo "$R_CPU_SUM + $R_CPU" | bc 2>/dev/null || echo 0); R_CPU_CNT=$((R_CPU_CNT + 1)); }
    [ -n "$R_GPU" ] && [ "$R_GPU" != "0" ] && { R_GPU_SUM=$(echo "$R_GPU_SUM + $R_GPU" | bc 2>/dev/null || echo 0); R_GPU_CNT=$((R_GPU_CNT + 1)); }
    { [ -n "$R_GPU" ] && [ "$R_GPU" -gt "$GPU_ACTIVE_PCT" ] 2>/dev/null; } && R_GPU_SEEN=1

    # CPU-spill: definitive regardless of GPU (only all-cores >200% proves it)
    if [ "$(echo "$R_CPU > 200" | bc -l)" = "1" ]; then
      R_CPU_CONSEC=$((R_CPU_CONSEC + 1)); R_GPU_CONSEC=0
    elif [ "$(echo "$R_CPU < $GPU_CPU_MAX" | bc -l)" = "1" ] && [ "$R_GPU" -gt "$GPU_ACTIVE_PCT" ] 2>/dev/null; then
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

  # Fallback: classify from the full window averages via the shared binary
  # classifier (plan §37 Change F) — never AMBIGUOUS.
  local R_AVG=0 R_GAVG=0
  [ "$R_CPU_CNT" -gt 0 ] && R_AVG=$(echo "scale=1; $R_CPU_SUM / $R_CPU_CNT" | bc)
  [ "$R_GPU_CNT" -gt 0 ] && R_GAVG=$(echo "scale=1; $R_GPU_SUM / $R_GPU_CNT" | bc)
  local R_PL
  R_PL=$(classify_placement "$R_AVG" "$R_GAVG")
  log "  residency: $R_PL (avg cpu ${R_AVG}%, avg gpu ${R_GAVG}%)" >&2
  echo "$R_PL"; return 0
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
  local CTX=${1:-65536}
  local PROBE_CHARS=$((CTX * 4))  # ~1 char/token worst case; shrink loop handles overshoot
  [ "$PROBE_CHARS" -lt "$CTX" ] && PROBE_CHARS=$CTX     # floor first (ctx-based)
  [ "$PROBE_CHARS" -gt 32000 ] && PROBE_CHARS=32000      # cap wins (keeps probe cheap)
  local MAX_ATTEMPTS=15 ATTEMPT=0

  while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    # Build prompt sized to PROBE_CHARS (ctx-proportional, no chars_per_tok dependency)
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

    # Overflow → shrink and retry (mirrors saturation_test :647-650)
    if grep -q "exceeds the available context" /tmp/pp_out.json 2>/dev/null; then
      PROBE_CHARS=$((PROBE_CHARS * 9 / 10))
      [ "$PROBE_CHARS" -lt "$CTX" ] && PROBE_CHARS=$CTX
      [ "$PROBE_CHARS" -gt 32000 ] && PROBE_CHARS=32000
      log "    prefill-probe: overflow rejected (attempt $ATTEMPT) — shrinking to ${PROBE_CHARS} chars" >&2
      continue
    fi

    local OOM=$(oom_count_since_mark)
    if [ "$OOM" -gt 0 ]; then echo "0"; return 0; fi

    # Parse the "prompt eval time" summary line from LOG_MARK forward.
    local PPMATCH
    PPMATCH=$(docker logs $DOCKER_LOG 2>&1 | tail -n +$((LOG_MARK + 1)) \
      | grep "prompt eval time" | tail -1 \
      | grep -oE '[0-9]+\.?[0-9]* tokens per second' | awk '{print $1}')
    if [ -n "$PPMATCH" ] && [ "$PPMATCH" != "0" ]; then
      log "  prefill-probe: ${PPMATCH} t/s (${PROBE_CHARS} chars)" >&2
      echo "$PPMATCH"
      return 0
    fi
    # Parse failed — no useful data, don't retry (model served but output unreadable)
    echo "0"
    return 0
  done
  echo "0"
}

# ── CPU-compute saturation sweep (find fastest prefill batch) ──
# Doubling ladder from 256, each rung measured via short prefill_probe.
# Golden-section refinement to 64 granularity finds the true fastest batch
# (which may sit between doubling rung siblings). Outputs "BATCH|TPS" to stdout.
# Then confirms winner via full saturation_test (99% ctx). Progress → stderr.
cpu_saturation_sweep() {
  local CTX=$1
  local BATCH_CAP=$(( CTX < MAX_BATCH ? CTX : MAX_BATCH ))
  local PTS=/tmp/cpu_sweep_points.txt
  : > "$PTS"

  # Test a single batch via SHORT prefill probe (fast, no saturation).
  # Warm-up is inside prefill_probe (untimed first request, then timed).
  # Classifies failures externally: prefill_probe returns "0" on both OOM and
  # network-stall; check oom_count_since_mark to distinguish.
  # Echoes: numeric t/s on success, "OOM" or "STALL" on failure.
  # Only appends to $PTS on genuine success (avoids polluting golden-section).
  test_rung() {
    local TB=$1
    set_batch "$TB" >&2; restart >&2
    local TPS
    TPS=$(prefill_probe "$CTX")
    if [ "$TPS" = "0" ]; then
      if [ "$(oom_count_since_mark)" -gt 0 ]; then
        log "  batch=$TB: OOM (short probe)" >&2
        echo "OOM"
      else
        log "  batch=$TB: STALL (short probe)" >&2
        echo "STALL"
      fi
      return 0
    fi
    log "  batch=$TB: prefill=${TPS} t/s (short probe)" >&2
    echo "$TB $TPS" >> "$PTS"
    echo "$TPS"
  }

  log "=== CPU SATURATION SWEEP (ctx=$CTX) ===" >&2

  # ── Phase 1: doubling ladder, peak-anchored bracket ──
  log "  Ladder: doubling from 256..." >&2
  local B=256 BEST_TPS=0 BEST_BATCH=256 DESC=0 STOP=0
  while [ "$B" -le "$BATCH_CAP" ]; do
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
  # Skip golden-section refinement (nothing to refine), but still confirm via saturation.
  if [ "$STOP" -eq 0 ]; then
    log "  No descent seen — peak is at the tested edge. Best: batch=$BEST_BATCH (${BEST_TPS} t/s)" >&2
    set_batch "$BEST_BATCH" >&2
  else
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
    # no tested rung above peak — use next doubling rung or cap
    hi = min($BATCH_CAP, peak * 2)
print(lo, hi)
" 2>/dev/null || echo "256 $BATCH_CAP")
  [ -z "$LO" ] && LO=256
  [ -z "$HI" ] && HI=$BATCH_CAP
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
  fi  # STOP=1 (golden-section done)

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
    local C_RC=0
    saturation_test "$CTX" >&2 || C_RC=$?
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
    echo "$CONFIRM_BATCH|$CONFIRM_TPS|${SAT_PREFILL_TPS:-}"
  else
    log "  All top candidates failed confirm — keeping fastest (best-effort): batch=$BEST_BATCH (${BEST_TPS} t/s)" >&2
    set_batch "$BEST_BATCH" >&2
    echo "$BEST_BATCH|$BEST_TPS|${SAT_PREFILL_TPS:-}"
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
    echo "$CEILING|${G_PRE:-0}|"   # no saturation_test on this path — leave prefill field empty
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
    local C_RC=0
    saturation_test "$CTX" >&2 || C_RC=$?
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
    echo "$CONFIRM_BATCH|$CONFIRM_PFC|${SAT_PREFILL_TPS:-}"
  else
    log "  All decode-healthy candidates failed saturation — using CEILING (pre-validated batch=$CEILING)" >&2
    echo "$CEILING|0|${SAT_PREFILL_TPS:-}"
  fi
}

# ── MTP capability detection (try-it-and-see) ──────────────
# Snapshots the model's section to a temp file, sets MTP config, restarts, probes.
# MTP supported = probe succeeds AND log shows MTP engagement.
# On failure, restores the original section and exits 1 (caller decides).
detect_mtp() {
  local CTX=$(read_ctx)
  SERVED_GRACE=$((60 + CTX / 65536 * 40))
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

# ── Natural-stop decode sample (§5) ─────────────────────────
# A speed/quality sample that lets the model stop at EOS (NO ignore_eos), so a
# looping forced decode cannot inflate t/s or acceptance. Polls placement exactly
# as run_decode_test does. Retries once with DECODE_PROMPT_LONG if the model
# stops short of MIN_DECODE_TOKENS, then tags the sample SHORT (callers treat
# SHORT as missing — never as a batch/MTP failure).
# Echoes (stdout, pipe-delimited):
#   SPEED|ACCEPT|PLACEMENT|AVG_CPU|QUALITY|OOM|TOKENS|MEANLEN|FINISH
#   SPEED   decode t/s (timings.predicted_per_second)
#   ACCEPT  draft acceptance rate (numeric; '' when not MTP / not parseable)
#   PLACEMENT GPU|CPU|AMBIGUOUS
#   AVG_CPU averaged llama CPU %
#   QUALITY 8-gram degeneracy on the natural-stop text
#   OOM     0/1
#   TOKENS  completion_tokens (0 → sample is SHORT)
#   MEANLEN mean draft length (numeric; '' when not MTP)
#   FINISH  finish_reason (stop|length)
# Caller must set MODEL and have a warm (post-restart) server. rc 2 = STALL.
decode_sample() {
  local LABEL=${1:-decode}
  local CTX=$(read_ctx)
  local MAX_TOK=$(python3 -c "print(max(256, min(4000, $CTX - 256)))")
  # progress to stderr (stdout is reserved for the pipe-delimited result)
  plog() { echo "$1" | tee -a "$LOG_FILE" >&2; }

  local PROMPT="$DECODE_PROMPT"
  local ATTEMPT=0
  while :; do
    ATTEMPT=$((ATTEMPT + 1))
    plog ""; plog "=== DECODE SAMPLE: $LABEL (attempt $ATTEMPT) ==="
    export DECODE_PROMPT_VAL="$PROMPT"
    python3 -c "
import json, os
payload = {'model':'$MODEL','messages':[{'role':'user','content':os.environ['DECODE_PROMPT_VAL']}],'max_tokens':$MAX_TOK}
with open('/tmp/decode_payload.json','w') as f: json.dump(payload, f)
"
    fire_request /tmp/decode_payload.json /tmp/decode_out.json "decode" "$(adaptive_timeout $MAX_TOK)"
    local RC=$?
    if [ "$RC" -eq 2 ]; then
      plog "  STALL — model never served (network/HF fetch)"
      return 2
    fi
    local PID=$FIRE_PID

    plog "  Polling CPU/GPU until request completes (max $((POLL_MAX_SAMPLES * 2))s)..."
    local CPU_SAMPLES=() GPU_SAMPLES=()
    for i in $(seq 1 $POLL_MAX_SAMPLES); do
      local TOP CPU GPU
      TOP=$(top -bn1 2>/dev/null | grep llama-s | head -n1) || true
      CPU=$(echo "$TOP" | awk '{print $9}' 2>/dev/null || echo "0")
      GPU=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
      [ -n "$CPU" ] && [ "$CPU" != "0.0" ] && CPU_SAMPLES+=("$CPU")
      [ -n "$GPU" ] && [ "$GPU" != "0" ] && GPU_SAMPLES+=("$GPU")
      [ $((i % 20)) -eq 0 ] && plog "    ...${i}x2s (CPU ${CPU}% GPU ${GPU}%)"
      sleep 2
      if [ "$i" -ge "$POLL_MIN_SAMPLES" ] && ! kill -0 $PID 2>/dev/null; then
        plog "    Request complete after ~$((i*2))s — stopping poll"
        break
      fi
    done
    wait $PID 2>/dev/null || true

    # Averages (skip first 10 samples as warmup if enough were collected)
    local CPU_SUM=0 CPU_CNT=0 AVG_CPU=0 AVG_START=0
    [ "${#CPU_SAMPLES[@]}" -gt 10 ] && AVG_START=10
    for idx in $(seq $AVG_START $((${#CPU_SAMPLES[@]} - 1))); do
      [ -z "${CPU_SAMPLES[$idx]:-}" ] && continue
      CPU_SUM=$(echo "$CPU_SUM + ${CPU_SAMPLES[$idx]}" | bc 2>/dev/null || echo 0)
      CPU_CNT=$((CPU_CNT + 1))
    done
    [ "$CPU_CNT" -gt 0 ] && AVG_CPU=$(echo "scale=1; $CPU_SUM / $CPU_CNT" | bc)
    local GPU_SUM=0 GPU_CNT=0 AVG_GPU=0
    for idx in $(seq $AVG_START $((${#GPU_SAMPLES[@]} - 1))); do
      [ -z "${GPU_SAMPLES[$idx]:-}" ] && continue
      GPU_SUM=$(echo "$GPU_SUM + ${GPU_SAMPLES[$idx]}" | bc 2>/dev/null || echo 0)
      GPU_CNT=$((GPU_CNT + 1))
    done
    [ "$GPU_CNT" -gt 0 ] && AVG_GPU=$(echo "scale=1; $GPU_SUM / $GPU_CNT" | bc)

    local PLACEMENT
    PLACEMENT=$(classify_placement "$AVG_CPU" "$AVG_GPU")

    local OOM=$(oom_count_since_mark)
    local RESULT
    RESULT=$(python3 -c "
import json
try:
    d = json.load(open('/tmp/decode_out.json'))
    if 'choices' not in d or not d['choices']: print('FAIL'); exit()
    ch = d['choices'][0]
    t = d.get('timings', {})
    u = d.get('usage', {})
    text = ch['message']['content']
    ct = u.get('completion_tokens', 0) or 0
    spd = t.get('predicted_per_second', 0)
    print('%s|%s|%s' % (('%.1f'%spd) if spd else '0', ct, ch.get('finish_reason') or ''))
except Exception as e:
    print('FAIL')
" 2>/dev/null)

    if [ "$RESULT" = "FAIL" ] || [ -z "$RESULT" ]; then
      plog "  Decode response parse failed (model error / 500)"
      echo "0||$PLACEMENT|${AVG_CPU:-0}|0|$OOM|0||length"
      return 0
    fi
    local SPEED TOKENS FINISH
    IFS='|' read -r SPEED TOKENS FINISH <<< "$RESULT"
    # If valid length (>= MIN_DECODE_TOKENS) or OOM, stop; else retry once with the long prompt.
    if [ "$OOM" -gt 0 ] || [ "${TOKENS:-0}" -ge "$MIN_DECODE_TOKENS" ] || [ "$ATTEMPT" -ge 2 ]; then
      local QUALITY ACCEPT MEANLEN
      QUALITY=$(python3 -c "
import json
try:
    d=json.load(open('/tmp/decode_out.json'))
    text=d['choices'][0]['message']['content']
except: print('?'); exit()
lines=[ln for ln in text.split('\n') if not ln.lstrip().startswith('#')]
words=(' '.join(lines)).split()
if len(words)<8: print('0'); exit()
ng=[' '.join(words[i:i+8]) for i in range(len(words)-7)]
from collections import Counter
c=Counter(ng); print(round(sum(v for v in c.values() if v>1)/len(ng),4))
")
      # acceptance parse: 'draft acceptance = X (a accepted / g generated), mean len = L'
      local ACCEPT MEANLEN
      ACCEPT=$(docker logs $DOCKER_LOG 2>&1 | tail -n +$((LOG_MARK + 1)) | grep -oE "draft acceptance = [0-9.]+" | tail -1 | awk '{print $4}')
      MEANLEN=$(docker logs $DOCKER_LOG 2>&1 | tail -n +$((LOG_MARK + 1)) | grep -oE "mean len = [0-9.]+" | tail -1 | awk '{print $4}')
      local SHORT_TAG=""
      [ "${TOKENS:-0}" -lt "$MIN_DECODE_TOKENS" ] && SHORT_TAG=" (SHORT: ${TOKENS} tokens < $MIN_DECODE_TOKENS)"
      plog "  Result: decode=${SPEED:-0} t/s | acc=${ACCEPT:-n/a} | placement=$PLACEMENT (cpu ${AVG_CPU}%) | degeneracy=${QUALITY:-?} | tokens=${TOKENS:-0} | finish=$FINISH | OOM=$OOM$SHORT_TAG"
      echo "$SPEED|${ACCEPT:-}|$PLACEMENT|${AVG_CPU:-0}|${QUALITY:-0}|$OOM|${TOKENS:-0}|${MEANLEN:-}|${FINISH:-}"
      return 0
    fi
    plog "  Sample short (${TOKENS} tokens < $MIN_DECODE_TOKENS) — retrying with the longer prompt"
    PROMPT="$DECODE_PROMPT_LONG"
  done
}

# ── MTP tuning decode test (thin wrapper over decode_sample) ──
# Keeps the historical SPEED|ACCEPT|PLACEMENT|AVG_CPU|QUALITY|OOM shape so
# existing cmd_mtp callers parse unchanged, appends TOKENS and MEANLEN.
run_decode_test() {
  local LABEL=$1
  local CTX=$(read_ctx)
  # progress to stderr (stdout is reserved for the pipe-delimited result)
  plog() { echo "$1" | tee -a "$LOG_FILE" >&2; }
  plog ""; plog "=== TEST: $LABEL ==="
  local RESULT
  RESULT=$(decode_sample "$LABEL")
  local RC=$?
  if [ "$RC" -eq 2 ]; then
    plog "  STALL — model never served (network/HF fetch)"
    return 2
  fi
  local SPEED ACCEPT PLACEMENT AVGCPU QUALITY OOM TOKENS MEANLEN FINISH
  IFS='|' read -r SPEED ACCEPT PLACEMENT AVGCPU QUALITY OOM TOKENS MEANLEN FINISH <<< "$RESULT"
  plog "  Result: decode=${SPEED:-0} t/s | acc=${ACCEPT:-n/a} | placement=$PLACEMENT (cpu ${AVGCPU:-0}%) | degeneracy=${QUALITY:-?} | tokens=${TOKENS:-0} | OOM=$OOM"
  echo "$SPEED|$ACCEPT|$PLACEMENT|$AVGCPU|$QUALITY|$OOM|$TOKENS|$MEANLEN|$FINISH"
}

# ── MTP tuning status plumbing (§6.4 part 1) ───────────────
# Both tuners (cmd_mtp_thorough and cmd_mtp_discover) and mtpcheck write
# /tmp/mtp_status_<model>.json on every exit path so cmd_bench can distinguish
# not_mtp / failed / stall / not_run / ok. Samples are accumulated line by line
# into a per-model TSV (so the EXIT trap, which runs in the tuning subshell, can
# read everything that was measured) and folded into the status JSON by
# write_mtp_status.
mtp_status_file() { echo "/tmp/mtp_status_${MODEL}.json"; }
mtp_sample_file() { echo "/tmp/mtp_samples_${MODEL}.tsv"; }

mtp_init_samples() {
  : > "$(mtp_sample_file)"
  MTP_DIE_STATUS=""
  MTP_DIE_REASON=""
  MTP_TUNED_NMAX="null"
  MTP_TUNED_PMIN="null"
}

# Append one measured sample to the per-model TSV.
# Fields (pipe-delimited): n_max p_min tps tokens placement accept degeneracy oom meanlen
mtp_add_sample() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${1:-}" "${2:-}" "${3:-0}" "${4:-0}" "${5:-}" "${6:-}" "${7:-}" "${8:-0}" "${9:-}" \
    >> "$(mtp_sample_file)"
}

# Write the status JSON from the collected samples. Args: status reason tuned_n_max tuned_p_min.
# tuned values may be 'null'. Best-effort; never let a status write fail a run.
mtp_write_status() {
  local SF; SF=$(mtp_status_file)
  MTP_STATUS="$1" MTP_REASON="$2" MTP_TN="$3" MTP_TP="$4" \
  MTP_SAMP="$(mtp_sample_file)" MTP_SF="$SF" python3 -c '
import json, os, datetime
samples = []
sf = os.environ["MTP_SAMP"]
if os.path.exists(sf):
    for ln in open(sf):
        p = ln.rstrip("\n").split("|")
        if len(p) < 9: continue
        def num(x):
            try: return int(x)
            except ValueError: pass
            try: return float(x)
            except ValueError: return x
        samples.append({
            "n_max": num(p[0]), "p_min": num(p[1]), "tps": num(p[2]),
            "tokens": num(p[3]), "placement": p[4] or None,
            "accept": num(p[5]), "degeneracy": num(p[6]),
            "oom": num(p[7]), "mean_draft_len": num(p[8]),
        })
def n_or_null(s):
    s = s.strip()
    if s == "" or s == "null": return None
    try: return int(s)
    except ValueError: pass
    try: return float(s)
    except ValueError: return None
out = {
    "status": os.environ["MTP_STATUS"],
    "reason": os.environ["MTP_REASON"] or None,
    "written_at": datetime.datetime.now().isoformat(),
    "tuned_n_max": n_or_null(os.environ["MTP_TN"]),
    "tuned_p_min": n_or_null(os.environ["MTP_TP"]),
    "samples": samples,
}
try:
    open(os.environ["MTP_SF"], "w").write(json.dumps(out))
except Exception:
    pass
' 2>/dev/null || true
}

# Called from each tuner's EXIT trap with the subshell's exit code. On success
# (rc 0) writes "ok" with the tuned values the tuner set on MTP_TUNED_NMAX/PMIN;
# on failure writes failed/stall as recorded by mtp_die / mtp_die_stall.
mtp_trap_exit() {
  local RC=$1
  if [ "$RC" -eq 0 ]; then
    mtp_write_status ok "" "${MTP_TUNED_NMAX:-null}" "${MTP_TUNED_PMIN:-null}"
  else
    mtp_write_status "${MTP_DIE_STATUS:-failed}" "${MTP_DIE_REASON:-unknown failure}" null null
  fi
}
mtp_die()       { MTP_DIE_STATUS=failed; MTP_DIE_REASON="$1"; exit 1; }
mtp_die_stall() { MTP_DIE_STATUS=stall;   MTP_DIE_REASON="$1"; exit 1; }

# Generic ini key reader (echoes the value or empty).
read_ini_val() {
  python3 -c "
import re
with open('$INI') as f: c = f.read()
m = re.search(r'\['+re.escape('$MODEL')+r'\](.*?)(?=\n\[|\Z)', c, re.DOTALL)
sec = m.group(1) if m else ''
v = re.search(r'^\s*'+re.escape('$1')+r'\s*=\s*(\S+)', sec, re.MULTILINE)
print(v.group(1) if v else '')
"
}

# ── SUBCOMMAND: mtpcheck ────────────────────────────────────
# Empirically determine MTP capability, write spec-type to models.ini.
# Exit 0 = MTP-capable (spec-type left set), 1 = not MTP (config restored).
# Writes {"status":"not_mtp"} when the model is not MTP-capable (§6.4 part 1).
# detect_mtp is run in a subshell because it exits (not returns) on the
# not-capable paths; we need its exit code so we can stamp the status file.
cmd_mtpcheck() {
  if ( detect_mtp ); then
    # MTP-capable: stamp a fresh not_run status so a later cmd_bench that runs
    # without mtp tuning (or after a crash) does not report a stale prior tune as
    # ok. cmd_mtp overwrites this with ok/failed on a real tune.
    MTP_STAT="$(mtp_status_file)" python3 -c "
import json, os, datetime
open(os.environ['MTP_STAT'],'w').write(json.dumps({'status':'not_run','written_at':datetime.datetime.now().isoformat()}))
" 2>/dev/null || true
    return 0
  else
    MTP_STAT="$(mtp_status_file)" python3 -c "
import json, os, datetime
open(os.environ['MTP_STAT'],'w').write(json.dumps({'status':'not_mtp','written_at':datetime.datetime.now().isoformat()}))
" 2>/dev/null || true
    return 1
  fi
}

# Remove a key (and its whole line) from the model's section in models.ini.
# Used by mtpverify to clear spec-type (MTP-off) without disturbing siblings.
del_key() {
  local KEY=$1
  python3 -c "
import re, sys
key='$KEY'; model='$MODEL'; ini='$INI'
with open(ini) as f: content = f.read()
m = re.search(r'(\['+re.escape(model)+r'\])(.*?)(?=\n\[|\Z)', content, re.DOTALL)
if not m: print('ERROR: section not found'); sys.exit(1)
section = m.group(2)
kept = [ln for ln in section.split('\n') if not re.match(r'\s*'+re.escape(key)+r'\s*=', ln)]
with open(ini, 'w') as f:
    f.write(content[:m.start(2)] + '\n'.join(kept) + content[m.end(2):])
print('  removed ' + key)
"
}

# ── SUBCOMMAND: mtpverify (diagnostic, premise test) ────────
# Not part of the suite. Empirically checks whether speculative decoding (MTP)
# changes the sampled output distribution. Two restarts on the SAME model:
#   run 1: spec-type removed (MTP off), run 2: spec-type=draft-mtp (MTP on).
# Both requests use temperature=0, seed=42, logprobs=true, top_logprobs=10,
# max_tokens=1024 and the identical prompt (passed via env var, not spliced).
#
# Criterion is OFF-only. The OFF (no-speculation) run is the reference sampler
# and carries real probabilities at every position; the server does NOT populate
# probabilities for speculatively-accepted tokens in the ON run (they carry a
# placeholder, so any number read from tops_on[d] at such a position is invalid).
# At the first differing token index d:
#   gap_off  = lp_off[d](off-chosen) − lp_off[d](on-chosen)
# PASS      if on-chosen ∈ OFF top-10 at d  AND  gap_off < MTP_TIE_NATS
# FAIL      otherwise — the ON run chose a token the reference distribution
#           considered clearly worse.
# REPORT    gap_on and top-5 overlap only when the ON run has real probabilities
#           at d (non-empty tops_on[d]); never gate on them.
# DRIFT     mean |lp_off − lp_on| over positions i<d where the ON run has real
#           probabilities; print "n/a" if none.
cmd_mtpverify() {
  local CTX=$(read_ctx)
  SERVED_GRACE=$((60 + CTX / 65536 * 40))
  log ""; log "=== MTP VERIFY: $MODEL ==="

  # Snapshot and restore the whole section on every exit (Ctrl-C included) so a
  # run can never leave spec-type removed from a production entry. SNAP is a
  # global (not local) so it stays in scope when the subshell EXIT trap fires.
  MTPV_SNAP=/tmp/mtpverify_section_${MODEL}.snap
  read_section > "$MTPV_SNAP"
  trap 'RC=$?; [ -f "$MTPV_SNAP" ] && restore_section "$MTPV_SNAP" >/dev/null 2>&1; exit $RC' EXIT

  export MTPV_PROMPT="Write a detailed technical report on the history of computing, covering its major eras in chronological order."
  local MAX_TOK=1024
  local OFF_JSON=/tmp/mtpv_${MODEL}_off.json
  local ON_JSON=/tmp/mtpv_${MODEL}_on.json

  # ── Shared deterministic request runner (fires against the CURRENT config) ──
  mtpv_request() {
    local OUT=$1 LABEL=$2
    python3 -c "
import json, os
payload = {'model':'$MODEL','messages':[{'role':'user','content':os.environ['MTPV_PROMPT']}],'max_tokens':$MAX_TOK,'temperature':0,'seed':42,'logprobs':True,'top_logprobs':10}
with open('${OUT}.payload','w') as f: json.dump(payload, f)
"
    fire_request "${OUT}.payload" "$OUT" "mtpverify-$LABEL" "$(adaptive_timeout $MAX_TOK)"
    local RC=$?
    if [ "$RC" -eq 2 ]; then
      log "  STALL on $LABEL run — aborting (network/HF fetch)"
      return 2
    fi
    wait "$FIRE_PID" 2>/dev/null || true
    return 0
  }

  # ── Run 1: MTP off ──
  log "  Run 1: MTP OFF (spec-type removed)"
  del_key spec-type
  restart
  if ! mtpv_request "$OFF_JSON" off; then return 1; fi
  local OOM_OFF=$(oom_count_since_mark)

  # ── Run 2: MTP on ──
  log "  Run 2: MTP ON (spec-type=draft-mtp)"
  set_key spec-type draft-mtp
  restart
  if ! mtpv_request "$ON_JSON" on; then return 1; fi
  local OOM_ON=$(oom_count_since_mark)

  # ── Optional control: MTP off at batch/2 vs MTP off at current batch ──
  # Same near-tie signature with no MTP involved → proof the flip class is not an
  # MTP effect. Non-gating. Enable with MTPV_CONTROL=1.
  local CTRL_RESULT=""
  if [ "${MTPV_CONTROL:-0}" -eq 1 ]; then
    local CUR_B=$(read_batch)
    local HALF_B=$(( CUR_B / 2 / 64 * 64 ))
    [ "$HALF_B" -lt 64 ] && HALF_B=64
    log "  CONTROL: MTP off at batch=$HALF_B vs batch=$CUR_B (non-gating)"
    local C1=/tmp/mtpv_${MODEL}_ctl1.json C2=/tmp/mtpv_${MODEL}_ctl2.json
    del_key spec-type
    set_batch "$HALF_B"; restart
    mtpv_request "$C1" "ctl1"; local O1=$(oom_count_since_mark)
    set_batch "$CUR_B"; restart
    mtpv_request "$C2" "ctl2"; local O2=$(oom_count_since_mark)
    CTRL_RESULT=$(MTPV_A="$C1" MTPV_B="$C2" MTPV_TIE=$MTP_TIE_NATS python3 -c "
import json, os
def load(p):
    d=json.load(open(p)); ch=d['choices'][0]
    lp=ch['logprobs']['content']
    ids=[t['id'] for t in lp]
    tops=[{x['id']:x['logprob'] for x in t.get('top_logprobs',[])} for t in lp]
    chos=[t['logprob'] for t in lp]
    return ids, tops, chos
a=load(os.environ['MTPV_A']); b=load(os.environ['MTPV_B'])
ia,ta,ca=a; ib,tb,cb=b
d=next((i for i in range(min(len(ia),len(ib))) if ia[i]!=ib[i]),None)
out='  CONTROL: '
if d is None: out+='identical (%d tokens)'%min(len(ia),len(ib))
else:
    # OFF-only gap (both runs are OFF; treat run A's distribution as reference)
    if ib[d] in ta[d]:
        gap=ca[d]-ta[d][ib[d]]
        out+='divergence at %d; reference chose id %d lp %.3f, other id %d lp %.3f → gap=%.3f'%(d, ia[d], ca[d], ib[d], ta[d][ib[d]], gap)
    else:
        out+='divergence at %d; other-chosen id %d absent from reference top-10'%(d, ib[d])
print(out)
")
  fi

  # ── Compare with the OFF-only margin criterion (§18.3) ──
  python3 -c "
import json, os
MTPV_OFF='$OFF_JSON'; MTPV_ON='$ON_JSON'
MTP_TIE=float($MTP_TIE_NATS)
def load(p):
    d=json.load(open(p))
    if 'choices' not in d or not d['choices']: return None, None, None
    ch=d['choices'][0]
    lp=ch.get('logprobs',{})
    cont=lp.get('content',[]) if isinstance(lp,dict) else []
    ids=[t.get('id') for t in cont]
    # tops: dict token_id -> logprob (may be empty at draft-accepted positions on the ON run)
    tops=[]
    for t in cont:
        tl=t.get('top_logprobs',[])
        tops.append({x.get('id'):x.get('logprob') for x in tl})
    spd=d.get('timings',{}).get('predicted_per_second',0)
    return ids, tops, spd

ids_off, tops_off, spd_off = load(MTPV_OFF)
ids_on,  tops_on,  spd_on  = load(MTPV_ON)

if ids_off is None or ids_on is None:
    print('  RESULT: could not parse token ids (off=%s on=%s)' % (ids_off is None, ids_on is None))
else:
    n = min(len(ids_off), len(ids_on))
    d = next((i for i in range(n) if ids_off[i] != ids_on[i]), None)

    # drift: mean |chosen_lp_off[i] - chosen_lp_on[i]| over i<d where the ON run has
    # REAL probabilities (non-empty tops_on[i]); skip placeholder positions.
    drift_sum=0.0; drift_cnt=0
    for i in range(min(n, d if d is not None else n)):
        if tops_on[i] and ids_off[i] in tops_off[i] and ids_on[i] in tops_on[i]:
            lo=tops_off[i].get(ids_off[i]); ln=tops_on[i].get(ids_on[i])
            if lo is not None and ln is not None:
                drift_sum += abs(lo-ln); drift_cnt += 1
    drift = (drift_sum/drift_cnt) if drift_cnt else None

    print('  off: %d tokens, %.1f t/s | on: %d tokens, %.1f t/s' % (len(ids_off), spd_off, len(ids_on), spd_on))
    if d is None:
        print('  RESULT: PASS (identical over common prefix, %d tokens)' % min(len(ids_off), len(ids_on)))
    else:
        off_chosen = ids_off[d]; on_chosen = ids_on[d]
        lp_off_off = tops_off[d].get(off_chosen)
        lp_off_on  = tops_off[d].get(on_chosen)
        in_top10 = (on_chosen in tops_off[d])
        # ON-side numbers are reported only when real (non-empty tops_on[d]); never gated.
        on_real = bool(tops_on[d])
        gap_on = None; overlap = None
        if on_real:
            lp_on_on=tops_on[d].get(on_chosen); lp_on_off=tops_on[d].get(off_chosen)
            if lp_on_on is not None and lp_on_off is not None: gap_on = lp_on_on - lp_on_off
            s5_off=set(list(tops_off[d].keys())[:5]); s5_on=set(list(tops_on[d].keys())[:5])
            overlap = len(s5_off & s5_on)

        if not in_top10 or lp_off_off is None or lp_off_on is None:
            print('  divergence at token %d' % d)
            print('    off chose id %s lp %s ; on-chosen id %s present in OFF top-10: %s' % (off_chosen, ('%.4f'%lp_off_off) if lp_off_off is not None else 'n/a', on_chosen, in_top10))
            print('  RESULT: FAIL — on-run chose a token the reference (OFF) distribution did not rank in its top 10')
        else:
            gap_off = lp_off_off - lp_off_on
            ok = (in_top10 and gap_off < MTP_TIE)
            verdict = 'PASS' if ok else 'FAIL'
            print('  divergence at token %d' % d)
            print('    off chose id %s lp %.4f ; on-chosen id %s lp %.4f (OFF top-10 rank) → gap_off=%.4f' % (off_chosen, lp_off_off, on_chosen, lp_off_on, gap_off))
            if on_real and gap_on is not None and overlap is not None:
                print('    on-side (real probs present): gap_on=%.4f  overlap(top5)=%d' % (gap_on, overlap))
            else:
                print('    on-side: no real probabilities at d (draft-accepted position); not gated')
            drift_str = ('%.4f'%drift) if drift is not None else 'n/a'
            print('    drift(prefix, real ON probs)=%s' % drift_str)
            print('  RESULT: %s (on-chosen ∈ OFF top-10 AND gap_off < %.2f)' % (verdict, MTP_TIE))
            if ok: print('  Premise holds: divergence is a near-tie flip under kernel logit noise.')
            else:  print('  WARNING: on-run chose a token the reference distribution considered clearly worse — output distribution appears to change.')
"
  log "  OOM: off=$OOM_OFF on=$OOM_ON (should be 0 both)"
  [ -n "$CTRL_RESULT" ] && log "$CTRL_RESULT"
  log "  MTP verify complete. Original spec-type state restored."
}

# ── MTP tuning: THOROUGH variant (old exhaustive tuner) ─────
# Empirically determines optimal n_max and p_min per model. This is the OLD
# quality-gated, fail-hard, exhaustive tuner (Phase 1 confirm + Phase 3 strict
# degeneracy confirm). Kept verbatim (plus the §6.4 status-file writes that apply
# to both tuners) and dispatched only for --thorough / the default this step.
# Phase 1: n_max sweep {2,3,4,5} at p_min=0.7 (speed axis).
# Phase 2: p_min sweep {0.5-0.9} at winning n_max (quality axis).
# Phase 3: final confirm (strict degeneracy gate).
# Total: 4 + 5 + 1 = 10 runs (~12-15 min).
cmd_mtp_thorough() {
  if ! grep -q "spec-type.*draft-mtp" <(read_section); then
    echo "  ERROR: $MODEL has no spec-type=draft-mtp — run 'bench.sh mtpcheck $MODEL' first"
    exit 1
  fi
  local CTX=$(read_ctx)
  SERVED_GRACE=$((60 + CTX / 65536 * 40))

  # Snapshot original n_max/p_min so a failed run restores the pre-run config
  # (mirrors cmd_bisect's restore_batch EXIT trap).
  local ORIG_NMAX ORIG_PMIN
  ORIG_NMAX=$(read_ini_val spec-draft-n-max)
  ORIG_PMIN=$(read_ini_val spec-draft-p-min)
  local RESTORED=0
  restore_mtp() {
    [ "${RESTORED:-0}" -eq 1 ] && return
    RESTORED=1
    log "  Restoring original spec-draft-n-max=${ORIG_NMAX:-unset} spec-draft-p-min=${ORIG_PMIN:-unset} (run did not complete)"
    [ -n "${ORIG_NMAX:-}" ] && set_key spec-draft-n-max "$ORIG_NMAX" >/dev/null 2>&1
    [ -n "${ORIG_PMIN:-}" ] && set_key spec-draft-p-min "$ORIG_PMIN" >/dev/null 2>&1
  }
  # On failure restore the ini AND stamp the status file; on success (rc 0) the
  # ok status is written explicitly below (this tuner clears the trap).
  trap 'RC=$?; if [ "$RC" -ne 0 ]; then restore_mtp; fi; mtp_trap_exit "$RC" || true; exit $RC' EXIT

  mtp_init_samples
  log ""; log "Model: $MODEL | ctx: $CTX | mode: THOROUGH"

  # ── Phase 1: n_max sweep {2,3,4,5} at p_min=0.7 (speed axis) ──
  local NMAX_VALUES="2 3 4 5"
  local SWEEP_PMIN=0.7
  local WIN_NMAX=0 WIN_SPEED=0
  declare -A NMAX_RESULTS
  log ""; log "=== PHASE 1: n_max SWEEP (p_min=$SWEEP_PMIN) ==="
  for N in $NMAX_VALUES; do
    set_key spec-draft-n-max "$N"
    set_key spec-draft-p-min "$SWEEP_PMIN"
    restart
    local RESULT SPEED ACC PLACEMENT AVGCPU QUALITY OOM TOKENS MEANLEN FINISH
    RESULT=$(run_decode_test "n_max=$N, p_min=$SWEEP_PMIN")
    local DEC_RC=$?
    if [ "$DEC_RC" -eq 2 ]; then
      log ""; log "  STALL during n_max=$N sweep — network/HF fetch, aborting tune"
      mtp_die_stall "STALL during n_max=$N sweep"
    fi
    IFS='|' read -r SPEED ACC PLACEMENT AVGCPU QUALITY OOM TOKENS MEANLEN FINISH <<< "$RESULT"
    mtp_add_sample "$N" "$SWEEP_PMIN" "$SPEED" "$TOKENS" "$PLACEMENT" "$ACC" "$QUALITY" "$OOM" "$MEANLEN"
    NMAX_RESULTS[$N]="$SPEED|$ACC|$PLACEMENT|$QUALITY|$OOM|$TOKENS|$MEANLEN"
    # Quality gate: reject clearly degenerate (degeneracy > 0.15).
    local QUAL_OK=0
    python3 -c "exit(0 if float(${QUALITY:-1}) < 0.15 else 1)" 2>/dev/null && QUAL_OK=1
    if [ "$OOM" -eq 0 ] && [ "$PLACEMENT" != "CPU" ] && [ "$QUAL_OK" -eq 1 ]; then
      if python3 -c "exit(0 if float($SPEED) > float($WIN_SPEED) else 1)" 2>/dev/null; then
        WIN_NMAX=$N; WIN_SPEED=$SPEED
      fi
    fi
  done
  if [ "$WIN_NMAX" -eq 0 ]; then
    log ""; log "  No n_max passed all filters (OOM/degenerate/CPU) — failing model, no auto fallback"
    mtp_die "no n_max passed all filters (OOM/degenerate/CPU)"
  fi
  log ""; log "  PHASE 1 WINNER: n_max=$WIN_NMAX"

  # ── Phase 1 confirm: strict re-check of n_max winner at sweep p_min ──
  # Converts the single-sample n_max pick to a two-sample-agree gate (same fail-hard philosophy as Phase 3).
  log ""; log "=== PHASE 1 CONFIRM (n_max=$WIN_NMAX, p_min=$SWEEP_PMIN) ==="
  set_key spec-draft-n-max "$WIN_NMAX"
  set_key spec-draft-p-min "$SWEEP_PMIN"
  restart
  local CONFIRM1_RESULT CONFIRM1_SPEED CONFIRM1_QUALITY CONFIRM1_OOM CONFIRM1_PLACEMENT
  CONFIRM1_RESULT=$(run_decode_test "n_max=$WIN_NMAX, p_min=$SWEEP_PMIN (phase-1 confirm)")
  local CONFIRM1_RC=$?
  if [ "$CONFIRM1_RC" -eq 2 ]; then
    log ""; log "  STALL during phase-1 confirm — aborting tune"
    mtp_die_stall "STALL during phase-1 confirm"
  fi
  IFS='|' read -r CONFIRM1_SPEED CONFIRM1_ACCEPT CONFIRM1_PLACEMENT _ CONFIRM1_QUALITY CONFIRM1_OOM CONFIRM1_TOKENS CONFIRM1_MEANLEN _ <<< "$CONFIRM1_RESULT"
  mtp_add_sample "$WIN_NMAX" "$SWEEP_PMIN" "$CONFIRM1_SPEED" "$CONFIRM1_TOKENS" "$CONFIRM1_PLACEMENT" "$CONFIRM1_ACCEPT" "$CONFIRM1_QUALITY" "$CONFIRM1_OOM" "$CONFIRM1_MEANLEN"
  log "  Phase-1 confirm: decode=${CONFIRM1_SPEED} t/s | degeneracy=${CONFIRM1_QUALITY} | OOM=$CONFIRM1_OOM"

  # Strict gate: same criteria as Phase 3 confirm.
  local CONFIRM1_CLEAN=0
  python3 -c "exit(0 if float(${CONFIRM1_QUALITY:-1}) < 0.05 else 1)" 2>/dev/null && CONFIRM1_CLEAN=1
  if [ "$CONFIRM1_OOM" -eq 0 ] && [ "$CONFIRM1_PLACEMENT" != "CPU" ] && [ "$CONFIRM1_CLEAN" -eq 1 ]; then
    log "  Phase-1 confirm PASSED (degeneracy=${CONFIRM1_QUALITY} < 0.05)"
  else
    log "  Phase-1 confirm FAILED (degeneracy=${CONFIRM1_QUALITY:-?}) — failing model, no auto fallback"
    mtp_die "phase-1 confirm failed (degeneracy=${CONFIRM1_QUALITY:-?})"
  fi

  # ── Phase 2: p_min sweep {0.5,0.6,0.7,0.8,0.9} at winning n_max ──
  local PMIN_VALUES="0.5 0.6 0.7 0.8 0.9"
  local WIN_PMIN=0 WIN_PMIN_SPEED=0
  declare -A PMIN_RESULTS
  log ""; log "=== PHASE 2: p_min SWEEP (n_max=$WIN_NMAX) ==="
  for P in $PMIN_VALUES; do
    set_key spec-draft-n-max "$WIN_NMAX"
    set_key spec-draft-p-min "$P"
    restart
    local RESULT SPEED ACC PLACEMENT AVGCPU QUALITY OOM TOKENS MEANLEN FINISH
    RESULT=$(run_decode_test "n_max=$WIN_NMAX, p_min=$P")
    local DEC_RC=$?
    if [ "$DEC_RC" -eq 2 ]; then
      log ""; log "  STALL during p_min=$P sweep — network/HF fetch, aborting tune"
      mtp_die_stall "STALL during p_min=$P sweep"
    fi
    IFS='|' read -r SPEED ACC PLACEMENT AVGCPU QUALITY OOM TOKENS MEANLEN FINISH <<< "$RESULT"
    mtp_add_sample "$WIN_NMAX" "$P" "$SPEED" "$TOKENS" "$PLACEMENT" "$ACC" "$QUALITY" "$OOM" "$MEANLEN"
    PMIN_RESULTS[$P]="$SPEED|$ACC|$PLACEMENT|$QUALITY|$OOM|$TOKENS|$MEANLEN"
    # Quality gate: reject clearly degenerate (degeneracy > 0.15).
    local QUAL_OK=0
    python3 -c "exit(0 if float(${QUALITY:-1}) < 0.15 else 1)" 2>/dev/null && QUAL_OK=1
    if [ "$OOM" -eq 0 ] && [ "$PLACEMENT" != "CPU" ] && [ "$QUAL_OK" -eq 1 ]; then
      if python3 -c "exit(0 if float($SPEED) > float($WIN_PMIN_SPEED) else 1)" 2>/dev/null; then
        WIN_PMIN=$P; WIN_PMIN_SPEED=$SPEED
      fi
    fi
  done
  if [ "$WIN_PMIN" -eq 0 ]; then
    log ""; log "  No p_min passed all filters (OOM/degenerate/CPU) — failing model, no auto fallback"
    mtp_die "no p_min passed all filters (OOM/degenerate/CPU)"
  fi
  log ""; log "  PHASE 2 WINNER: p_min=$WIN_PMIN"

  # ── Phase 3: final confirm (strict degeneracy gate) ──
  local FINAL_NMAX=$WIN_NMAX FINAL_PMIN=$WIN_PMIN
  log ""; log "=== PHASE 3: FINAL CONFIRM (n_max=$FINAL_NMAX, p_min=$FINAL_PMIN) ==="
  set_key spec-draft-n-max "$FINAL_NMAX"
  set_key spec-draft-p-min "$FINAL_PMIN"
  restart
  local CONFIRM_RESULT CONFIRM_SPEED CONFIRM_QUALITY CONFIRM_OOM CONFIRM_PLACEMENT
  CONFIRM_RESULT=$(run_decode_test "n_max=$FINAL_NMAX, p_min=$FINAL_PMIN (final confirm)")
  local CONFIRM_RC=$?
  if [ "$CONFIRM_RC" -eq 2 ]; then
    log ""; log "  STALL during final confirm — aborting tune"
    mtp_die_stall "STALL during final confirm"
  fi
  IFS='|' read -r CONFIRM_SPEED CONFIRM_ACCEPT CONFIRM_PLACEMENT _ CONFIRM_QUALITY CONFIRM_OOM CONFIRM_TOKENS CONFIRM_MEANLEN _ <<< "$CONFIRM_RESULT"
  mtp_add_sample "$FINAL_NMAX" "$FINAL_PMIN" "$CONFIRM_SPEED" "$CONFIRM_TOKENS" "$CONFIRM_PLACEMENT" "$CONFIRM_ACCEPT" "$CONFIRM_QUALITY" "$CONFIRM_OOM" "$CONFIRM_MEANLEN"
  log "  Final confirm: decode=${CONFIRM_SPEED} t/s | degeneracy=${CONFIRM_QUALITY} | OOM=$CONFIRM_OOM"

  # Strict gate: < 0.05 = clean PASS; >= 0.05 = fail (no runner-up fallback).
  local CONFIRM_CLEAN=0
  python3 -c "exit(0 if float(${CONFIRM_QUALITY:-1}) < 0.05 else 1)" 2>/dev/null && CONFIRM_CLEAN=1
  if [ "$CONFIRM_OOM" -eq 0 ] && [ "$CONFIRM_PLACEMENT" != "CPU" ] && [ "$CONFIRM_CLEAN" -eq 1 ]; then
    log "  Final confirm PASSED (degeneracy=${CONFIRM_QUALITY} < 0.05)"
  else
    log "  Final confirm FAILED (degeneracy=${CONFIRM_QUALITY:-?}) — failing model, no auto fallback"
    mtp_die "final confirm failed (degeneracy=${CONFIRM_QUALITY:-?})"
  fi

  # ── Apply winners (success path — trap will not restore) ──
  trap - EXIT
  log ""; log "=== APPLYING WINNERS ==="
  set_key spec-draft-n-max "$FINAL_NMAX"
  set_key spec-draft-p-min "$FINAL_PMIN"
  # Stamp ok (the EXIT trap was cleared above, so write explicitly).
  mtp_write_status ok "" "$FINAL_NMAX" "$FINAL_PMIN" || true

  log ""; log "=== SUMMARY: $MODEL ==="
  log "  n_max sweep (p_min=$SWEEP_PMIN):"
  for N in $NMAX_VALUES; do
    log "    n_max=$N: ${NMAX_RESULTS[$N]:-skipped}"
  done
  log "  p_min sweep (n_max=$WIN_NMAX):"
  for P in $PMIN_VALUES; do
    log "    p_min=$P: ${PMIN_RESULTS[$P]:-skipped}"
  done
  log "  WINNERS: spec-draft-n-max=$FINAL_NMAX spec-draft-p-min=$FINAL_PMIN"
  log "  (restart llama-cpp to apply)"
  log "=== DONE ==="
}

# ── MTP discover-mode ranking helpers (read the collected sample TSV) ──
# Valid phase-1 sample: p_min == 0.7, placement != CPU, oom == 0, tokens >= MIN.
mtp_mean_for() {  # $1 nmax $2 pmin -> mean tps over valid samples of that config ('' if none)
  local NM=$1 PM=$2
  MTP_SAMP="$(mtp_sample_file)" MTP_MIN=$MIN_DECODE_TOKENS python3 -c "
import os
rows = []
for ln in open(os.environ['MTP_SAMP']):
    p = ln.rstrip('\n').split('|')
    if len(p) < 9: continue
    if p[0] != '$NM' or p[1] != '$PM': continue
    try: tps = float(p[2]); tok = int(p[3]); oom = int(p[7])
    except Exception: continue
    if oom or p[4] == 'CPU' or tok < int(os.environ['MTP_MIN']): continue
    rows.append(tps)
if not rows:
    print('')
else:
    print('%.4f' % (sum(rows) / len(rows)))
"
}

# Phase-1 winner with the §6.2 tie rule (plan §25#3): pick the smallest n_max
# whose mean is within MTP_TIE of the best mean. Unlike a best-vs-runner-up test,
# this considers every measured candidate, so a low n_max that is within tolerance
# (e.g. n_max=2 when 4 is best but 2 is within 5%) is preferred for draft-buffer
# headroom, independent of measurement order.
mtp_phase1_winner() {
  MTP_SAMP="$(mtp_sample_file)" MTP_MIN=$MIN_DECODE_TOKENS MTP_TIE="$MTP_TIE" python3 -c '
import os, sys
rows = []
for ln in open(os.environ["MTP_SAMP"]):
    p = ln.rstrip("\n").split("|")
    if len(p) < 9: continue
    if p[1] != "0.7": continue
    try: tps = float(p[2]); tok = int(p[3]); oom = int(p[7])
    except Exception: continue
    if oom or p[4] == "CPU" or tok < int(os.environ["MTP_MIN"]): continue
    rows.append((int(p[0]), tps))
agg = {}
for nm, t in rows: agg.setdefault(nm, []).append(t)
rank = sorted(((nm, sum(l) / len(l)) for nm, l in agg.items()), key=lambda x: -x[1])
if not rank:
    sys.exit(1)
best_mean = rank[0][1]
threshold = best_mean * (1 - float(os.environ["MTP_TIE"]))
# smallest n_max whose mean >= threshold
winner = min((nm for nm, m in rank if m >= threshold), key=lambda x: (int(x), ))
print(winner)
'
}

# ── SUBCOMMAND: mtp DISCOVER variant (plan §6.1/§6.2) ────────
# Adaptive, non-exhaustive n_max/p_min search. NO quality gate (MTP parameters
# cannot change the output distribution — §18 premise); placement / OOM / SHORT
# are the only rejections and degeneracy is only a WARN diagnostic. Always
# includes the ini's current n_max (it was validated by the batch ladder).
cmd_mtp_discover() {
  local CTX=$(read_ctx)
  SERVED_GRACE=$((60 + CTX / 65536 * 40))

  # Snapshot/restore original n_max & p_min on any failure (EXIT trap).
  local ORIG_NMAX ORIG_PMIN
  ORIG_NMAX=$(read_ini_val spec-draft-n-max)
  ORIG_PMIN=$(read_ini_val spec-draft-p-min)
  local RESTORED=0
  restore_mtp() {
    [ "${RESTORED:-0}" -eq 1 ] && return
    RESTORED=1
    log "  Restoring original spec-draft-n-max=${ORIG_NMAX:-unset} spec-draft-p-min=${ORIG_PMIN:-unset} (run did not complete)"
    [ -n "${ORIG_NMAX:-}" ] && set_key spec-draft-n-max "$ORIG_NMAX" >/dev/null 2>&1
    [ -n "${ORIG_PMIN:-}" ] && set_key spec-draft-p-min "$ORIG_PMIN" >/dev/null 2>&1
  }
  trap 'RC=$?; if [ "$RC" -ne 0 ]; then restore_mtp; fi; mtp_trap_exit "$RC" || true; exit $RC' EXIT

  mtp_init_samples

  log ""; log "Model: $MODEL | ctx: $CTX | mode: DISCOVER"
  local P_REF=0.7
  local CUR=${ORIG_NMAX:-}
  [ -z "$CUR" ] && CUR=2
  log "  ini spec-draft-n-max=$CUR spec-draft-p-min=${ORIG_PMIN:-unset}"

  # ── Phase 1: n_max ladder at p_ref ──
  # S = sorted dedup{2, 4, cur}; n_max bounded to [2,6].
  local S="2 4"
  case "$CUR" in 2|4) : ;; *) S="$S $CUR" ;; esac
  S=$(printf '%s\n' $S | sort -n -u | tr '\n' ' ')
  log ""; log "=== PHASE 1: n_max LADDER $S at p_min=$P_REF ==="

  # Measure one (n_max,p_min) config at p_ref, log its sample, echo
  # "tps|tokens|placement|oom" on success; returns 2 on STALL.
  discover_measure() {
    local N=$1 P=$2 LABEL=$3
    set_key spec-draft-n-max "$N" >/dev/null 2>&1
    set_key spec-draft-p-min "$P" >/dev/null 2>&1
    # restart and log write to stdout via log(); when this function is captured in
    # $(... ) (run_ph1) that would pollute the result line, so send them to stderr.
    restart >&2
    local RESULT DR
    RESULT=$(decode_sample "n_max=$N p_min=$P ($LABEL)")
    DR=$?
    if [ "$DR" -eq 2 ]; then
      log "  STALL during $LABEL (n_max=$N p_min=$P) — network/HF fetch" >&2
      return 2
    fi
    local SPEED ACCEPT PLACEMENT AVGCPU QUALITY OOM TOKENS MEANLEN FINISH
    IFS='|' read -r SPEED ACCEPT PLACEMENT AVGCPU QUALITY OOM TOKENS MEANLEN FINISH <<< "$RESULT"
    mtp_add_sample "$N" "$P" "$SPEED" "$TOKENS" "$PLACEMENT" "$ACCEPT" "$QUALITY" "$OOM" "$MEANLEN"
    # degeneracy is diagnostic only — WARN, never a gate.
    if [ -n "$QUALITY" ] && python3 -c "exit(0 if float('$QUALITY') > 0.15 else 1)" 2>/dev/null; then
      log "  WARN: n_max=$N p_min=$P degeneracy=${QUALITY} > 0.15 (diagnostic, not a gate)" >&2
    fi
    echo "$SPEED|$TOKENS|$PLACEMENT|$OOM"
    return 0
  }

  # run_ph1: measure n_max $1 at p_ref and remember its validity.
  run_ph1() {
    local NM=$1 R SP TK PL OO DR
    # discover_measure sends all progress to stderr, so stdout is exactly the
    # "SPEED|TOKENS|PLACEMENT|OOM" result line; capture it directly so $? still
    # reflects discover_measure's exit code (2 = STALL).
    R=$(discover_measure "$NM" "$P_REF" "phase-1 n_max=$NM")
    DR=$?
    if [ "$DR" -eq 2 ]; then mtp_die_stall "STALL measuring n_max=$NM at p_min=$P_REF"; fi
    IFS='|' read -r SP TK PL OO <<< "$R"
    SP=${SP:-0}; TK=${TK:-0}; OO=${OO:-1}; PL=${PL:-SHORT}
    if [ "$OO" -eq 0 ] && [ "$PL" != "CPU" ] && [ "$TK" -ge "$MIN_DECODE_TOKENS" ]; then
      log "  n_max=$NM: PASS (${SP} t/s, ${TK} tokens, $PL)"
    else
      log "  n_max=$NM: rejected (placement=$PL oom=$OO tokens=$TK)"
    fi
  }

  local NM
  for NM in $S; do run_ph1 "$NM"; done

  # Every candidate rejected (placement/OOM) or all samples SHORT → fail.
  if ! mtp_phase1_winner >/dev/null 2>&1; then
    log "  No valid n_max candidate (all rejected by placement/OOM or all samples SHORT)"
    mtp_die "every n_max candidate rejected (placement/OOM) or every sample SHORT"
  fi

  # Extend to untested neighbours of the current best, within [2,6].
  local B
  B=$(mtp_phase1_winner 2>/dev/null) || mtp_die "no n_max winner"
  local MEAS="$S"
  measured_n() { printf '%s\n' $MEAS | grep -qx "$1"; }
  local NX
  NX=$((B + 1))
  if [ "$NX" -le 6 ] && ! measured_n "$NX"; then run_ph1 "$NX"; MEAS="$MEAS $NX"; fi
  NX=$((B - 1))
  if [ "$NX" -ge 2 ] && ! measured_n "$NX"; then run_ph1 "$NX"; MEAS="$MEAS $NX"; fi

  # Re-measure the best and the runner-up once more (mean = two samples).
  local TOP1 TOP2 R1 R2
  R1=$(mtp_phase1_winner 2>/dev/null) || mtp_die "no n_max winner after neighbour extension"
  TOP1=$R1
  # runner-up = highest-mean n_max other than TOP1, via a dedicated python pass.
  TOP2=$(MTP_SAMP="$(mtp_sample_file)" MTP_MIN=$MIN_DECODE_TOKENS MTP_TIE="$MTP_TIE" python3 -c "
import os, sys
rows=[]
for ln in open(os.environ['MTP_SAMP']):
    p=ln.rstrip('\n').split('|')
    if len(p)<9: continue
    if p[1]!='0.7': continue
    try: tps=float(p[2]); tok=int(p[3]); oom=int(p[7])
    except Exception: continue
    if oom or p[4]=='CPU' or tok < int(os.environ['MTP_MIN']): continue
    rows.append((p[0],tps))
agg={}
for nm,t in rows: agg.setdefault(nm,[]).append(t)
ex='$TOP1'
rank=sorted((nm for nm,l in agg.items() if nm!=ex), key=lambda nm: -(sum(agg[nm])/len(agg[nm])))
print(rank[0] if rank else '')
")
  if [ -n "$TOP2" ] && [ "$TOP2" != "$TOP1" ]; then
    run_ph1 "$TOP2"
  fi
  # (re-)confirm the top candidate; fold the neighbour in if it is now the best.
  if [ -n "$TOP1" ]; then run_ph1 "$TOP1"; fi

  local WIN_NMAX
  WIN_NMAX=$(mtp_phase1_winner 2>/dev/null) || mtp_die "no n_max winner after re-measure"
  log ""; log "  PHASE 1 WINNER: n_max=$WIN_NMAX"

  # ── Phase 2: p_min at WIN_NMAX (reference = its 0.7 mean) ──
  local REF
  REF=$(mtp_mean_for "$WIN_NMAX" "$P_REF")
  [ -z "$REF" ] && { log "  No valid 0.7 reference at n_max=$WIN_NMAX — should not happen"; mtp_die "no valid 0.7 reference at n_max=$WIN_NMAX"; }
  local PP="0.5 0.9"
  case "${ORIG_PMIN:-0.7}" in 0.5|0.9|0.7|"") : ;; *) PP="$PP $ORIG_PMIN" ;; esac
  log ""; log "=== PHASE 2: p_min at n_max=$WIN_NMAX (ref p=0.7 = ${REF} t/s) ==="
  local WIN_PMIN="$P_REF" WIN_CAND="" WIN_CAND_TP=""
  for P in $PP; do
    log "  measuring p_min=$P ..."
    discover_measure "$WIN_NMAX" "$P" "phase-2 p_min=$P"
    local D2=$?
    if [ "$D2" -eq 2 ]; then mtp_die_stall "STALL measuring p_min=$P at n_max=$WIN_NMAX"; fi
    local m
    m=$(mtp_mean_for "$WIN_NMAX" "$P")
    if [ -z "$m" ]; then log "    p_min=$P: no valid sample — skipping"; continue; fi
    if python3 -c "exit(0 if float('$m') > float('$REF') * (1 + $MTP_TIE) else 1)" 2>/dev/null; then
      if [ -z "$WIN_CAND" ] || python3 -c "exit(0 if float('$m') > float('$WIN_CAND_TP') else 1)" 2>/dev/null; then
        WIN_CAND="$P"; WIN_CAND_TP="$m"
      fi
    fi
  done
  if [ -n "${WIN_CAND:-}" ]; then
    # §30.3: confirm the win with a second sample before switching away from 0.7
    # (a single sample can beat the reference by >5% on noise). One extra run.
    log "  p_min=$WIN_CAND (${WIN_CAND_TP} t/s) beat 0.7 by > ${MTP_TIE} on one sample — confirming with a second"
    discover_measure "$WIN_NMAX" "$WIN_CAND" "phase-2 p_min=$WIN_CAND (confirm)" || mtp_die_stall "STALL confirming p_min=$WIN_CAND"
    local m2
    m2=$(mtp_mean_for "$WIN_NMAX" "$WIN_CAND")
    if [ -n "$m2" ] && python3 -c "exit(0 if float('$m2') > float('$REF') * (1 + $MTP_TIE) else 1)" 2>/dev/null; then
      log "  confirmed: p_min=$WIN_CAND (${m2} t/s, 2-sample mean) still beats 0.7 — chosen"
      WIN_PMIN="$WIN_CAND"; WIN_CAND_TP="$m2"
    else
      log "  p_min=$WIN_CAND did NOT hold on a second sample (mean ${m2:-n/a} t/s) — keeping 0.7"
    fi
  else
    log "  no p_min beats 0.7 (${REF} t/s) by more than ${MTP_TIE} — keeping 0.7"
  fi

  # ── Apply winners (trap writes ok on rc 0) ──
  log ""; log "=== APPLYING WINNERS ==="
  set_key spec-draft-n-max "$WIN_NMAX" >/dev/null
  set_key spec-draft-p-min "$WIN_PMIN" >/dev/null
  MTP_TUNED_NMAX=$WIN_NMAX
  MTP_TUNED_PMIN=$WIN_PMIN
  log ""; log "  WINNERS: spec-draft-n-max=$WIN_NMAX spec-draft-p-min=$WIN_PMIN"
  log "  (restart llama-cpp to apply)"
  log "=== DONE ==="
}

# ── SUBCOMMAND: mtp (dispatcher) ────────────────────────────
# Decides which tuner runs. This step keeps the DEFAULT on the OLD path
# Dispatcher. Default is DISCOVER; --thorough / THOROUGH=1 selects the old
# exhaustive tuner (cmd_mtp_thorough). BENCH_DISCOVER=1 is a deprecated alias for
# discover (kept for backward compatibility with the Step-C/D env).
cmd_mtp() {
  if ! grep -q "spec-type.*draft-mtp" <(read_section); then
    echo "  ERROR: $MODEL has no spec-type=draft-mtp — run 'bench.sh mtpcheck $MODEL' first"
    exit 1
  fi
  if [ "${THOROUGH:-0}" -eq 1 ]; then
    cmd_mtp_thorough
  else
    cmd_mtp_discover
  fi
}

# ── cmd_bisect_thorough: legacy exhaustive batch search (kept verbatim) ──
# The pre-refactor cmd_bisect body (batch ceiling + 64-granularity bisect +
# shortlist decode gate), preserved byte-for-byte so `--thorough` reproduces the
# old search. The [test-batch] single-batch block near the top is duplicated into
# the shared cmd_bisect_test_batch helper; it is kept inline here too so a direct
# call to this function still behaves exactly like the original cmd_bisect.
# Args: MODEL, then optional TEST_BATCH.
cmd_bisect_thorough() {
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
    [ "${RESTORED:-0}" -eq 1 ] && return
    if [ -n "${ORIG_BATCH:-}" ]; then
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
    local T_RC=0
    tiny_probe || T_RC=$?
    if [ "$T_RC" -eq 2 ]; then log "  STALL — aborting"; exit 1; fi
    if [ "$T_RC" -ne 0 ]; then log "  FAIL"; exit 1; fi
    log "  PASS"
    log ""; log "=== PHASE 2: SATURATION ==="
    local S_RC=0
    saturation_test "$CTX" || S_RC=$?
    if [ "$S_RC" -eq 2 ]; then log "  STALL — aborting"; exit 1; fi
    if [ "$S_RC" -ne 0 ]; then log "  FAILED"; exit 1; fi
    log ""; log "=== PHASE 3: LONG-DECODE ==="
    local LD_RC=0
    long_decode_check || LD_RC=$?
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
    local WIN WIN_TPS WIN_PREFILL
    WIN=$(echo "$SWEEP_OUT" | cut -d'|' -f1)
    WIN_TPS=$(echo "$SWEEP_OUT" | cut -d'|' -f2)
    WIN_PREFILL=$(echo "$SWEEP_OUT" | cut -d'|' -f3)
    [ -z "$WIN" ] && WIN="$SWEEP_OUT"  # fallback if no pipe present
    set_batch "$WIN"
    local VALIDATED=$WIN PASS=1 CANDIDATES=0
    log ""; log "  *** CPU-compute batch=$WIN chosen: fastest by short-probe prefill (${WIN_TPS} t/s), saturation-safe at 99% ctx ***"
    log ""; log "=== RESULT ==="
    log "  batch=$WIN ubatch=$WIN ctx=$CTX"
    log "  candidates=$CANDIDATES saturation-confirm=$PASS/1"
    log "  CPU-compute early-detected. Batch ranked by short-probe prefill (${WIN_TPS} t/s);"
    [ -n "$WIN_PREFILL" ] && log "  saturation_prefill=${WIN_PREFILL} t/s (real full-context; from last confirm attempt on fallback path)"
    log "  saturation_test confirmed no-OOM at 99% ctx."
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
    tiny_probe || T_RC=$?
    if [ "$T_RC" -eq 2 ]; then
      log "  STALL at $B (network/HF fetch — not an OOM ceiling)"
      log "  Aborting bisect: model can't cold-load. Re-run when huggingface.co is reachable."
      exit 1
    fi
    local S_RC=0
    if [ "$T_RC" -eq 0 ]; then
      # Residency gate: reject CPU-spilled batches immediately (avoid minutes of saturation).
      # A GPU model that CPU-spills at high batch is above the usable ceiling.
      log "  Probe PASS at $B — checking residency..."
      local R_V
      R_V=$(residency_probe)
      if [ "$R_V" = "CPU" ]; then
        log "  CPU-spillover at $B — not GPU-resident, descending"
        return 1
      fi
      log "  GPU-resident at $B — saturation-validating..."
      saturation_test "$CTX" || S_RC=$?
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
      log "  SIZING FAILURE at $B (could not reach compaction)"
    else
      log "  OOM at $B"
    fi
    return 1
  }

  local LO HI VALIDATED PASS CANDIDATES

  # ── PHASE 1: CEILING SEARCH ──
  # Cap search at min(ctx, MAX_BATCH); never probe batches above the cap.
  local CEIL
  CEIL=$(( CTX < MAX_BATCH ? CTX : MAX_BATCH ))
  log ""; log "=== PHASE 1: CEILING SEARCH (ceiling=$CEIL, ctx=$CTX, ladder 2048→up) ==="
  LO=0; HI=0; VALIDATED=0

  # Probe 1: search top (= ctx for small-ctx, capped for large-ctx)
  if ceiling_probe "$CEIL"; then
    LO=$CEIL; HI=$((CEIL + 64)); VALIDATED=$CEIL
    log "  Bracket: lo=$LO (PASS), hi=$HI (assumed OOM above)"
  else
    HI=$CEIL
    if [ "$CEIL" -gt 2048 ]; then
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
      # CEIL <= 2048 and failed — halve down from CEIL
      B=$((CEIL / 2 / 64 * 64))
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
    tiny_probe || T_RC=$?
    if [ "$T_RC" -eq 2 ]; then
      log "  STALL at $MID (network/HF fetch) — aborting bisect"
      exit 1
    fi
    if [ "$T_RC" -eq 0 ]; then
      # Residency gate: reject CPU-spilled batches immediately.
      log "  Probe PASS — checking residency..."
      local R_V
      R_V=$(residency_probe)
      if [ "$R_V" = "CPU" ]; then
        log "  CPU-spillover at $MID — not GPU-resident, descending"
        HI=$MID
      else
        log "  GPU-resident at $MID — running saturation..."
        local S_RC=0
        saturation_test "$CTX" || S_RC=$?
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
      fi
    else
      log "  OOM (probe)"; HI=$MID
    fi
  done
  VALIDATED=$LO
  log "  Refined lo=$LO — max batch passing tiny probe AND saturation"

  # ── FINAL CONFIRM (winner already passed saturation in the gated bisect;
  #    this fresh-restart run is the authoritative full-context saturation test) ──
  log ""; log "=== FINAL CONFIRM (batch=$VALIDATED) ==="
  set_batch "$VALIDATED"; restart
  PASS=0
  local S_RC=0
  saturation_test "$CTX" || S_RC=$?
  if [ "$S_RC" -eq 2 ]; then
    log "  STALL during final-confirm saturation — aborting"
    exit 1
  fi
  if [ "$S_RC" -eq 0 ]; then
    PASS=1
    log "  *** VALIDATED batch=$VALIDATED ***"
  else
    log "  Final confirm FAIL — chosen batch $VALIDATED failed full-context saturation"
    log "  Failing model (no auto step-down). Inspect logs; re-run to retry."
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
  local WIN WIN_TPS WIN_PREFILL
  WIN=$(echo "$SWEEP_OUT" | cut -d'|' -f1)
  WIN_TPS=$(echo "$SWEEP_OUT" | cut -d'|' -f2)
  WIN_PREFILL=$(echo "$SWEEP_OUT" | cut -d'|' -f3)
  [ -z "$WIN" ] && WIN="$SWEEP_OUT"  # fallback
  set_batch "$WIN"

  # ── LONG-DECODE CHECK (on the final chosen batch, not the ceiling) ──
  log ""; log "=== LONG-DECODE CHECK (batch=$WIN) ==="
  set_batch "$WIN"; restart
  local LD_RC=0
  long_decode_check || LD_RC=$?
  if [ "$LD_RC" -ne 0 ]; then
    log "  LONG-DECODE failed (rc=$LD_RC) on chosen batch $WIN — failing model"
    exit 1
  fi

  log ""; log "  *** PERFORMANCE-OPTIMIZED batch=$WIN (${WIN_TPS} t/s, decode-guarded prefill) ***"

  log ""; log "=== RESULT ==="
  log "  batch=$WIN ubatch=$WIN ctx=$CTX"
  log "  candidates=$CANDIDATES saturation-confirm=$PASS/1"
  log "  decode-guarded prefill sweep: fastest prefill among decode-healthy batches (decode ≥ 90% best)"
  [ -n "$WIN_PREFILL" ] && log "  saturation_prefill=${WIN_PREFILL} t/s (real full-context; from last confirm attempt on fallback path)"
  log ""; log "  Next: run bench.sh bench $MODEL"
  log "=== DONE ==="
}

# ── SUBCOMMAND: bisect — thin dispatcher ────────────────────
# Reads the 2nd arg as an optional single-batch test. A positive integer routes to
# the shared cmd_bisect_test_batch (used by BOTH bisect routes). Otherwise dispatch
# between the discover-mode ladder (plan §4, cmd_bisect_discover) and the legacy
# exhaustive search (cmd_bisect_thorough).
# Default is DISCOVER; --thorough / THOROUGH=1 selects the old exhaustive path.
# BENCH_DISCOVER=1 is a deprecated alias for discover.
cmd_bisect() {
  if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
    cmd_bisect_test_batch "$2"
    return
  fi
  if [ "${THOROUGH:-0}" -eq 1 ]; then
    cmd_bisect_thorough "$@"
  else
    cmd_bisect_discover "$@"
  fi
}

# ── Shared single-batch test (both bisect routes) ───────────
# A numeric test-batch runs: tiny probe → saturation → long-decode on that one
# batch. On any failure restores the original batch and exits nonzero (EXIT trap).
# Global MODEL must be set. $1 = batch value.
cmd_bisect_test_batch() {
  local BATCH=$1
  local CTX=$(read_ctx)
  [ -z "$CTX" ] && { log "ERROR: ctx-size not found for [$MODEL]"; exit 1; }
  SERVED_GRACE=$((60 + CTX / 65536 * 40))
  local ORIG_BATCH=$(read_batch)
  local RESTORED=0
  restore_batch() {
    [ "${RESTORED:-0}" -eq 1 ] && return
    if [ -n "${ORIG_BATCH:-}" ]; then
      log "  Restoring original batch=$ORIG_BATCH (run did not complete)"
      set_batch "$ORIG_BATCH" >/dev/null 2>&1
    fi
    RESTORED=1
  }
  # Restore on failure only; the success path leaves the batch at $BATCH before exiting 0.
  trap 'RC=$?; if [ "$RC" -ne 0 ]; then restore_batch; fi; exit $RC' EXIT

  log "Model: $MODEL | ctx: $CTX | test-batch: $BATCH"
  log ""; log "=== TESTING BATCH $BATCH ==="
  set_batch "$BATCH"; restart
  log ""; log "=== PHASE 1: TINY PROBE ==="
  local T_RC=0
  tiny_probe || T_RC=$?
  if [ "$T_RC" -eq 2 ]; then log "  STALL — aborting"; exit 1; fi
  if [ "$T_RC" -ne 0 ]; then log "  FAIL"; exit 1; fi
  log "  PASS"
  log ""; log "=== PHASE 2: SATURATION ==="
  local S_RC=0
  saturation_test "$CTX" || S_RC=$?
  if [ "$S_RC" -eq 2 ]; then log "  STALL — aborting"; exit 1; fi
  if [ "$S_RC" -ne 0 ]; then log "  FAILED"; exit 1; fi
  log ""; log "=== PHASE 3: LONG-DECODE ==="
  local LD_RC=0
  long_decode_check || LD_RC=$?
  if [ "$LD_RC" -eq 2 ]; then log "  STALL — aborting"; exit 1; fi
  log ""; log "=== RESULT: batch=$BATCH ubatch=$BATCH ==="
  log "=== DONE ==="
  exit 0
}

# ── Sized prefill t/s probe (§4.2) ──────────────────────────
# Same prompt length for EVERY rung of one model so rungs are ranked on identical
# work (prefill t/s falls with prompt length, so a batch-proportional prompt would
# bias large batches down). Length = min(floor(0.75×ctx), 16384) tokens; chars =
# tokens × chars/tok (measure_ratio once at rung 256; fallback 4.0 chars/tok).
# No separate warm-up: the caller's tiny_probe already loaded and warmed the
# instance. Reuses prefill_probe's body approach — log-parsed 'prompt eval time',
# overflow-shrink retry, OOM check.
# Echoes prefill_t_s to stdout; "0" on OOM/stall/parse-fail. Progress → stderr.
# §39.2#1 (Change G): the SAME measurement rule applies to every point in the JSON
# — a ladder rung and a refinement candidate are measured identically. So the
# "first probe under 5 s → median of three" policy lives HERE (in the one function
# both the ladder and discover_measure_candidate call), not only in the refinement
# path. Every sized-prefill value recorded for a batch is therefore a median when
# the probe is fast, never a single high-noise sample that could out-rank a median.
# §40.2#2: the FIRST prefill at a new ubatch shape pays a one-time setup cost (CUDA
# graph capture for that shape), which weighs more on larger ubatches (a fixed-
# length probe holds fewer of them). So run ONE untimed warm-up probe first, then
# take the timed sample(s): a slow probe (>5 s, every 64K/256K and CPU-compute
# model) is one timed sample after warm-up; a fast probe is the median of three.
prefill_probe_sized() {
  local CTX=${1:-65536} WARM T0 RAW0 RAW1 RAW2
  WARM=$(prefill_probe_sized_raw "$CTX")
  if [ "$WARM" = "0" ] || [ -z "$WARM" ]; then echo "0"; return 0; fi
  log "  prefill-sized: warm-up done (~${WARM} t/s)" >&2
  T0=$(date +%s)
  RAW0=$(prefill_probe_sized_raw "$CTX")
  if [ "$RAW0" = "0" ] || [ -z "$RAW0" ] || [ $(( $(date +%s) - T0 )) -ge 5 ]; then
    echo "${RAW0:-0}"
    return 0
  fi
  RAW1=$(prefill_probe_sized_raw "$CTX")
  RAW2=$(prefill_probe_sized_raw "$CTX")
  local MED
  MED=$(python3 -c "
vals=[]
for v in ['$RAW0','$RAW1','$RAW2']:
    try:
        f=float(v)
        if f>0: vals.append(f)
    except Exception: pass
print('%.1f' % sorted(vals)[len(vals)//2])
" 2>/dev/null || echo "$RAW0")
  log "  prefill-sized: median-of-3 (probe <5s) → ${MED} t/s" >&2
  echo "$MED"
}
prefill_probe_sized_raw() {
  local CTX=${1:-65536}
  local PROBE_TOKENS
  PROBE_TOKENS=$(python3 -c "print(int(min(int($CTX * 0.75), 16384)))")
  local CPT=4.0
  if python3 -c "exit(0 if float(${CHARS_PER_TOK:-0}) > 0 else 1)" 2>/dev/null; then
    CPT=$CHARS_PER_TOK
  fi
  local PROBE_CHARS
  PROBE_CHARS=$(python3 -c "print(int($PROBE_TOKENS * $CPT))")
  [ "$PROBE_CHARS" -lt 16 ] && PROBE_CHARS=16
  local MAX_ATTEMPTS=15 ATTEMPT=0

  while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    python3 -c "
import json
filler = 'The history of computing is long and complex. '
n = $PROBE_CHARS
prompt = (filler * ((n // len(filler)) + 1))[:n]
# cache_prompt:false so no prefix of the prompt is served from the slot's prompt
# cache (measure_ratio runs a filler prefix just before rung 256); otherwise the
# log-parsed throughput is a few-token figure, not the full probe (plan §25#2).
payload = {'model':'$MODEL','messages':[{'role':'user','content':prompt}],'max_tokens':1,'ignore_eos':True,'cache_prompt':False}
with open('/tmp/pp_sized.json','w') as f: json.dump(payload, f)
"
    fire_request /tmp/pp_sized.json /tmp/pp_sized_out.json "prefill-sized" "$(adaptive_timeout 1)"
    local RC=$?
    if [ "$RC" -eq 2 ]; then echo "0"; return 0; fi

    local WATCH=0
    while kill -0 $FIRE_PID 2>/dev/null; do
      if [ "$(oom_count_since_mark)" -gt 0 ]; then kill $FIRE_PID 2>/dev/null; break; fi
      WATCH=$((WATCH + 1))
      [ $((WATCH % 10)) -eq 0 ] && log "    prefill-sized: still running (${WATCH}x2s)" >&2
      sleep 2
    done
    wait $FIRE_PID 2>/dev/null || true

    # Overflow → shrink and retry (mirrors saturation_test / prefill_probe).
    if grep -q "exceeds the available context" /tmp/pp_sized_out.json 2>/dev/null; then
      PROBE_CHARS=$((PROBE_CHARS * 9 / 10))
      [ "$PROBE_CHARS" -lt 16 ] && PROBE_CHARS=16
      log "    prefill-sized: overflow rejected (attempt $ATTEMPT) — shrinking to ${PROBE_CHARS} chars" >&2
      continue
    fi

    local OOM=$(oom_count_since_mark)
    if [ "$OOM" -gt 0 ]; then echo "0"; return 0; fi

    # Parse the "prompt eval time" summary line from LOG_MARK forward.
    local PPMATCH
    PPMATCH=$(docker logs $DOCKER_LOG 2>&1 | tail -n +$((LOG_MARK + 1)) \
      | grep "prompt eval time" | tail -1 \
      | grep -oE '[0-9]+\.?[0-9]* tokens per second' | awk '{print $1}')
    if [ -n "$PPMATCH" ] && [ "$PPMATCH" != "0" ]; then
      log "  prefill-sized: ${PPMATCH} t/s (~${PROBE_TOKENS} tokens, ${PROBE_CHARS} chars)" >&2
      echo "$PPMATCH"
      return 0
    fi
    # Parse failed — no useful data, don't retry (model served but output unreadable).
    echo "0"
    return 0
  done
  echo "0"
}

# ── SUBCOMMAND: bisect discover mode (plan §4, the default) ──
# One coarse ladder (powers of two from 256 up to min(ctx, MAX_BATCH)), three cheap
# measurements per rung (tiny → residency → sized prefill), then a smallest-within-
# 3%-of-best pick (optional ceiling-edge midpoint refinement), then one-restart
# confirm at pick (saturation + long-decode + decode-cliff check). Safety gates are
# unchanged (OOM grep source-of-truth, residency verdict, ini restore on failure).
# Sets the winning batch in models.ini; writes /tmp/discover_points.txt and
# /tmp/discover_${MODEL}.json. Same restore-on-nonzero EXIT trap as the thorough path.
# Args: MODEL, then optional TEST_BATCH (numeric → shared cmd_bisect_test_batch).
cmd_bisect_discover() {
  # Shared single-batch test path (defensive: the dispatcher also routes numeric
  # batches here before ever reaching this function).
  if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
    cmd_bisect_test_batch "$2"
    return
  fi

  local CTX=$(read_ctx)
  [ -z "$CTX" ] && { log "ERROR: ctx-size not found for [$MODEL]"; exit 1; }
  SERVED_GRACE=$((60 + CTX / 65536 * 40))

  local ORIG_BATCH=$(read_batch)
  local RESTORED=0
  restore_batch() {
    [ "${RESTORED:-0}" -eq 1 ] && return
    if [ -n "${ORIG_BATCH:-}" ]; then
      log "  Restoring original batch=$ORIG_BATCH (run did not complete)"
      set_batch "$ORIG_BATCH" >/dev/null 2>&1
    fi
    RESTORED=1
  }
  # Restore on failure only; the success path sets the winner before exiting 0.
  trap 'RC=$?; if [ "$RC" -ne 0 ]; then restore_batch; fi; exit $RC' EXIT

  log "Model: $MODEL | ctx: $CTX | mode: discover"
  local CAP=$(( CTX < MAX_BATCH ? CTX : MAX_BATCH ))
  # Fixed prompt length per model, for the prefill probe and the single-ubatch label.
  local PROBE_TOKENS
  PROBE_TOKENS=$(python3 -c "print(int(min(int($CTX * 0.75), 16384)))")

  # Change A (§30.2): a "simple" non-MTP model has no draft to spill and no
  # override-tensor (CPU expert offload), so decode is batch-independent. Its
  # residency can only say GPU (or CPU if it is a genuine CPU-compute model — the
  # rung-256 probe still sets MODE), and neither DEC_BASE nor the pick decode
  # sample / cliff check can change the batch answer. Skip residency after rung
  # 256 and skip the decode baseline + pick decode-sample/cliff for these models.
  # Saturation, long-decode and the OOM gates are unchanged.
  local SIMPLE_NONMTP=0
  if ! grep -q "spec-type.*draft-mtp" <(read_section) \
     && ! grep -q "override-tensor" <(read_section); then
    SIMPLE_NONMTP=1
  fi

  # ── Phase A: one ladder, three measurements per rung ──
  log ""; log "=== DISCOVER LADDER (cap=$CAP, prefill probe ~${PROBE_TOKENS} tokens) ==="
  local POINTS=/tmp/discover_points.txt
  : > "$POINTS"
  local B=256
  local MODE=""                 # "", GPU, or CPU (CPU skips residency + decode-cliff)
  local BEST_PREFILL=0
  local PREV_BELOW=0
  local CEIL_FAIL_B="" CEIL_FAIL_R="" CEIL_BREAK=""   # ceiling info (informational)
  local DEC_BASE="" DEC_BASE_RC=0
  local PASS_B=() PASS_P=()     # parallel arrays of PASS rungs (ascending B)
  local PICK=0 PICK_PF=0
  local STEPS_DN=0

  while [ "$B" -le "$CAP" ]; do
    log ""; log "--- rung batch=$B ---"
    set_batch "$B"; restart
    log "  Tiny probe @ batch=$B..."
    local T_RC=0
    tiny_probe || T_RC=$?
    if [ "$T_RC" -eq 2 ]; then
      log "  STALL at $B (network/HF fetch — not an OOM ceiling)"
      log "  Aborting bisect: model can't cold-load. Re-run when huggingface.co is reachable."
      exit 1
    fi
    if [ "$T_RC" -ne 0 ]; then
      log "  OOM at $B (tiny probe / load)"
      echo "$B OOM" >> "$POINTS"
      CEIL_FAIL_B=$B; CEIL_FAIL_R="OOM"; CEIL_BREAK=1
      break
    fi
    log "  Tiny PASS @ $B"

    # Residency (skipped entirely once MODE=CPU). Change A: a simple non-MTP
    # model runs residency once at rung 256 to set MODE; later rungs skip it
    # (no draft to spill, so the verdict cannot change).
    if [ "$MODE" != "CPU" ] && { [ "$SIMPLE_NONMTP" -eq 0 ] || [ "$B" -eq 256 ]; }; then
      local R_V
      R_V=$(residency_probe)
      if [ "$R_V" = "STALL" ]; then
        log "  STALL during residency at $B — aborting discover"
        exit 1
      fi
      if [ "$R_V" = "CPU" ]; then
        if [ "$B" -eq 256 ]; then
          log "  CPU-compute detected at batch 256 → MODE=CPU (no residency probes after this rung)"
          MODE="CPU"
        else
          log "  CPU-spillover at $B — not GPU-resident, stopping ladder"
          echo "$B SPILL" >> "$POINTS"
          CEIL_FAIL_B=$B; CEIL_FAIL_R="SPILL"; CEIL_BREAK=1
          break
        fi
      else
        MODE="GPU"
        if [ "$R_V" = "AMBIGUOUS" ]; then
          log "  AMBIGUOUS at $B (treated as GPU — not-proven-CPU counts as GPU)"
        else
          log "  GPU-resident at $B"
        fi
      fi
    fi

    # Measure chars-per-token once (before the first sized prefill, at rung 256).
    if ! python3 -c "exit(0 if float(${CHARS_PER_TOK:-0}) > 0 else 1)" 2>/dev/null; then
      measure_ratio >&2 || true
    fi

    # Sized prefill probe (identical prompt length on every rung).
    local PF=0
    PF=$(prefill_probe_sized "$CTX")
    if [ "$PF" = "0" ]; then
      if [ "$(oom_count_since_mark)" -gt 0 ]; then
        log "  OOM at $B (prefill probe)"
        echo "$B OOM" >> "$POINTS"
        CEIL_FAIL_B=$B; CEIL_FAIL_R="OOM"; CEIL_BREAK=1
        break
      fi
      log "  prefill probe STALL at $B — aborting discover"
      exit 1
    fi
    local SINGLE=""
    [ "$B" -ge "$PROBE_TOKENS" ] && SINGLE=" (single-ubatch)"
    log "  batch=$B prefill=${PF} t/s$SINGLE — PASS"
    PASS_B+=("$B"); PASS_P+=("$PF")
    echo "$B PASS $PF" >> "$POINTS"

    # Decode baseline at the first GPU rung (256), after the prefill measurement.
    # Change A: skipped for simple non-MTP models (decode is batch-independent).
    if [ "$B" -eq 256 ] && [ "$MODE" = "GPU" ] && [ "$SIMPLE_NONMTP" -eq 0 ]; then
      if ! DEC_BASE=$(decode_sample "256-baseline"); then
        log "  STALL during 256 decode baseline — aborting discover"
        exit 1
      fi
      DEC_BASE_RC=0
      local DB_SPEED DB_TOK
      DB_SPEED=$(echo "$DEC_BASE" | cut -d'|' -f1)
      DB_TOK=$(echo "$DEC_BASE" | cut -d'|' -f7)
      log "  DEC_BASE (batch 256): ${DB_SPEED:-?} t/s, ${DB_TOK:-0} tokens"
    fi

    # Two consecutive PASS rungs below best×(1−PREFILL_TOL) → past the peak, stop.
    if python3 -c "exit(0 if float($PF) > float($BEST_PREFILL) else 1)" 2>/dev/null; then
      BEST_PREFILL=$PF
    fi
    local THIS_BELOW=0
    if python3 -c "exit(0 if float($PF) < float($BEST_PREFILL) * (1 - $PREFILL_TOL) else 1)" 2>/dev/null; then
      THIS_BELOW=1
    fi
    if [ "$THIS_BELOW" -eq 1 ] && [ "$PREV_BELOW" -eq 1 ]; then
      log "  Two consecutive PASS rungs below best (${BEST_PREFILL}) — stopping ladder (peak passed)"
      CEIL_BREAK=2
      break
    fi
    PREV_BELOW=$THIS_BELOW
    B=$((B * 2))
  done

  # Summary of the coarse ladder (informational ceiling; nothing downstream consumes it).
  local LADDER_TXT
  LADDER_TXT=$(python3 -c "
lines = [l.split() for l in open('$POINTS') if l.strip()]
out = []
for toks in lines:
    b = toks[0]
    if toks[1] == 'PASS': out.append(b + '=' + toks[2])
    else: out.append(b + '=' + toks[1])
print(' '.join(out))
")
  log ""; log "  ladder: $LADDER_TXT"
  local HIGHPASS=0
  [ "${#PASS_B[@]}" -gt 0 ] && HIGHPASS=${PASS_B[${#PASS_B[@]}-1]}
  local MODE_TXT=${MODE:-unknown}
  if [ -n "$CEIL_FAIL_B" ]; then
    log "  mode=$MODE_TXT  ceiling(coarse)=${HIGHPASS} PASS / ${CEIL_FAIL_B} ${CEIL_FAIL_R}"
  else
    log "  mode=$MODE_TXT  ceiling(coarse) ≥ ${HIGHPASS} PASS (not probed higher)"
  fi
  if [ "${#PASS_B[@]}" -eq 0 ]; then
    log "  ERROR: no batch passed at any rung down to 256. Lower ctx or free VRAM (override-tensor=exps=CPU)."
    exit 1
  fi

  # ── Phase B: pick = best PASS point; Change G golden-section refinement (§38) ──
  # PREFILL_TOL default 0 → best-measured rung; a user-set value keeps the
  # smallest-within-tolerance rule. Refinement tracks extra points in
  # REFINE_B[]/REFINE_P[] (for step-down + JSON), never in the ladder arrays.
  local THRESH
  THRESH=$(python3 -c "print(float($BEST_PREFILL) * (1 - $PREFILL_TOL))")
  PICK=0
  for idx in "${!PASS_B[@]}"; do
    if python3 -c "exit(0 if float('${PASS_P[$idx]}') >= float($THRESH) else 1)" 2>/dev/null; then
      PICK=${PASS_B[$idx]}; PICK_PF=${PASS_P[$idx]}; break
    fi
  done
  [ "$PICK" -eq 0 ] && { PICK=${PASS_B[0]}; PICK_PF=${PASS_P[0]}; }
  log "  best prefill=${BEST_PREFILL} t/s; pick=$PICK (TOL=$PREFILL_TOL)"

  local REFINE_B=() REFINE_P=()

  # Measure one candidate batch. Echoes its prefill t/s, or "0" if it is not a
  # PASS (OOM / CPU-spill / probe failure). rc 2 = STALL (abort).
  # All progress (set_batch/restart/tiny_probe/residency/log) goes to stderr so
  # stdout carries ONLY the numeric prefill when captured via $(...) — otherwise
  # the points append and the caller's parse are polluted by progress lines.
  # Optional $2 (SKIP_RES=1) forces residency to be skipped even for a non-simple
  # GPU model — used for interior points of a PASS/PASS bracket (Change G, §38):
  # memory is monotonic in batch, so nothing between two passing rungs can spill.
  discover_measure_candidate() {
    local CB=$1 SKIP_RES=${2:-0}
    set_batch "$CB" >&2; restart >&2
    local TR=0
    tiny_probe >&2 || TR=$?
    if [ "$TR" -eq 2 ]; then log "  STALL measuring candidate $CB — aborting" >&2; return 2; fi
    if [ "$TR" -ne 0 ]; then echo "0"; return 0; fi
    if [ "$SKIP_RES" -ne 1 ] && [ "$MODE" != "CPU" ] && { [ "$SIMPLE_NONMTP" -eq 0 ] || [ "$CB" -eq 256 ]; }; then
      local RV
      RV=$(residency_probe)
      if [ "$RV" = "CPU" ]; then echo "0"; return 0; fi
      if [ "$RV" = "STALL" ]; then log "  STALL at $CB (residency) — aborting" >&2; return 2; fi
    fi
    # §39.2#1: prefill_probe_sized now does the <5s median-of-3 itself (the SAME
    # rule the ladder uses), so every batch is measured identically.
    local CPF
    CPF=$(prefill_probe_sized "$CTX")
    if [ "$CPF" = "0" ] || [ -z "$CPF" ]; then echo "0"; return 0; fi
    echo "$CPF"
    return 0
  }

  # ── Phase B refinement — Change G: unconditional golden-section to 64 (§38) ──
  # Supersedes Change E's noise-stopping rules (keep this structure; the policy is
  # now: always refine the bracket around the Change C pick down to 64-token
  # granularity, cheap because memory is monotonic in batch). Refinement runs for
  # ALL modes: the prefill curve is not flat where it matters on simple non-MTP
  # models (lfm 8K/16K/32K rose to 2112/2176/3008) or CPU-compute (gpt-oss rises
  # to 2048, falls at 4096). Change A still only skips residency and decode
  # samples on simple models (batch-independent), not prefill refinement.

  # find_measured $batch: echo the stored prefill of an already-measured PASS
  # point (ladder rung or refinement), or nothing if it was never measured.
  find_measured() {
    local q=$1 i
    for i in "${!REFINE_B[@]}"; do
      if [ "${REFINE_B[$i]}" -eq "$q" ]; then echo "${REFINE_P[$i]}"; return 0; fi
    done
    for i in "${!PASS_B[@]}"; do
      if [ "${PASS_B[$i]}" -eq "$q" ]; then echo "${PASS_P[$i]}"; return 0; fi
    done
    return 0
  }

  # Measure one golden candidate in the MAIN shell. It returns its result through
  # the global GOLD_RES (not stdout) so the REFINE_B[]/REFINE_P[]/POINTS/PICK
  # bookkeeping survives — a $( )-wrapped function would run in a subshell and lose
  # those mutations. GOLD_RES = "0" when the candidate failed (OOM/CPU-spill/probe
  # failure → caller makes it the new upper bound). Exits on STALL.
  GOLD_RES=""
  golden_probe() {
    local CB=$1 SK=$2 MF
    GOLD_RES=""
    MF=$(discover_measure_candidate "$CB" "$SK") || { log "  STALL at $CB — aborting"; exit 1; }
    if [ "$MF" = "0" ] || [ -z "$MF" ]; then
      log "  golden $CB failed (OOM/CPU-spill/probe) — becomes new upper bound" >&2
      echo "$CB FAIL" >> "$POINTS"
      GOLD_RES="0"; return 0
    fi
    REFINE_B+=("$CB"); REFINE_P+=("$MF")
    echo "$CB PASS $MF" >> "$POINTS"
    if python3 -c "exit(0 if float('$MF') > float('$PICK_PF') else 1)" 2>/dev/null; then
      log "  golden $CB (${MF} t/s) > best pick $PICK (${PICK_PF} t/s) — adopt as pick" >&2
      PICK=$CB; PICK_PF=$MF
    fi
    GOLD_RES=$MF
    return 0
  }

  # ── Bracket determination ──
  # BLO = nearest measured PASS strictly below PICK (256 if none); BHI = nearest
  # measured PASS strictly above PICK if one exists; else, at a ceiling edge
  # (PICK==HIGHPASS with an OOM/SPILL rung above), BHI = that failed rung; else
  # PICK is the top measured rung with nothing above (ladder ended at/below cap
  # with the best at the top) — §39.2#2: refine DOWN in [BLO, PICK], because the
  # true prefill peak can sit between the lower rung and the cap at a non-rung
  # (lfm 4K: pick 4096 = cap, peak actually ~3K, bracket [2048, 4096] must be
  # searched). Exception: if BLO >= PROBE_TOKENS the whole bracket is a single
  # ubatch of the same prompt and measures identically — skip and log why.
  local BLO=0 BHI=0 PB B_IDX
  for B_IDX in "${!PASS_B[@]}"; do
    PB=${PASS_B[$B_IDX]}
    if [ "$PB" -lt "$PICK" ] && [ "$PB" -gt "$BLO" ]; then BLO=$PB; fi
    if [ "$PB" -gt "$PICK" ] && { [ "$BHI" -eq 0 ] || [ "$PB" -lt "$BHI" ]; }; then BHI=$PB; fi
  done
  [ "$BLO" -eq 0 ] && BLO=256
  if [ "$BHI" -eq 0 ]; then
    if [ "$PICK" -eq "$HIGHPASS" ] && [ -n "$CEIL_FAIL_B" ] \
       && { [ "$CEIL_FAIL_R" = "OOM" ] || [ "$CEIL_FAIL_R" = "SPILL" ]; } \
       && [ "$CEIL_FAIL_B" -gt "$PICK" ]; then
      BHI=$CEIL_FAIL_B          # ceiling edge: upper bound is the failed rung
    elif [ "$BLO" -ge "$PROBE_TOKENS" ]; then
      log "  top-rung pick=$PICK, whole bracket [${BLO}, ${PICK}] is single-ubatch (BLO ${BLO} >= probe ${PROBE_TOKENS}) — skip refinement"
      BHI=$BLO
    else
      BHI=$PICK                 # top rung, nothing above: refine [BLO, PICK]
    fi
  fi

  if [ "$BHI" -le "$BLO" ]; then
    log "  no bracket above/below — skip refinement (lo=$BLO hi=$BHI)"
  else
    log ""; log "  golden-section refinement: bracket [$BLO, $BHI] → 64-token granularity (Change G)"
    # Golden-section maximisation of prefill over [GS_LO, GS_HI], candidates
    # rounded to 64 and any point already measured is reused (never re-probed).
    # Endpoints are measured PASS rungs except when BHI is the failed ceiling rung
    # — its value is never compared, only used to bound the search (memory is
    # monotonic in batch, so a point above a spill/fail also fails). Residency is
    # skipped on an interior probe whenever the current upper bound is itself a
    # measured PASS (nothing in a PASS/PASS bracket can spill); it runs only while
    # the active upper bound is a failed (unmeasured) rung and the model is not
    # SIMPLE_NONMTP and not MODE=CPU.
    local GS_LO=$BLO GS_HI=$BHI GS_STEPS=0 GSW GA GB FGA FGB UPPER_MEAS SKRES
    while [ $((GS_HI - GS_LO)) -gt 64 ] && [ "$GS_STEPS" -lt 14 ]; do
      GS_STEPS=$((GS_STEPS + 1))
      GSW=$((GS_HI - GS_LO))
      GA=$(( GS_LO + GSW * 382 / 1000 )); GA=$(( GA / 64 * 64 ))   # interior, ~0.382
      GB=$(( GS_HI - GSW * 382 / 1000 )); GB=$(( GB / 64 * 64 ))   # interior, ~0.618
      [ "$GA" -le "$GS_LO" ] && GA=$(( GS_LO + 64 ))
      [ "$GB" -ge "$GS_HI" ] && GB=$(( GS_HI - 64 ))
      if [ "$GB" -le "$GA" ]; then
        log "  golden: bracket [$GS_LO, $GS_HI] can't admit a new interior pair — stop"
        break
      fi
      # Residency policy for interior probes this step.
      UPPER_MEAS=$(find_measured "$GS_HI")
      SKRES=1
      if [ "$SIMPLE_NONMTP" -eq 0 ] && [ "$MODE" != "CPU" ] && [ -z "$UPPER_MEAS" ]; then
        SKRES=0
      fi
      log ""; log "  golden step $GS_STEPS: bracket [$GS_LO, $GS_HI] (a=$GA b=$GB, residency=${SKRES})"
      FGA=$(find_measured "$GA")
      if [ -z "$FGA" ]; then
        golden_probe "$GA" "$SKRES"
        FGA=$GOLD_RES
        if [ "$FGA" = "0" ] || [ -z "$FGA" ]; then
          log "  golden GA=$GA failed — upper bound → $GA"
          GS_HI=$GA; continue
        fi
      else
        log "  golden: reuse GA=$GA (${FGA} t/s)" >&2
      fi
      FGB=$(find_measured "$GB")
      if [ -z "$FGB" ]; then
        golden_probe "$GB" "$SKRES"
        FGB=$GOLD_RES
        if [ "$FGB" = "0" ] || [ -z "$FGB" ]; then
          log "  golden GB=$GB failed — upper bound → $GB"
          GS_HI=$GB; continue
        fi
      else
        log "  golden: reuse GB=$GB (${FGB} t/s)" >&2
      fi
      # Keep the sub-bracket that CONTAINS the better interior point (max search):
      # better at GA (left) → the max is in [GS_LO, GB], so hi=GB; else lo=GA.
      if python3 -c "exit(0 if float('$FGA') >= float('$FGB') else 1)" 2>/dev/null; then
        GS_HI=$GB
      else
        GS_LO=$GA
      fi
      log "  golden: GA=$GA=${FGA} t/s GB=$GB=${FGB} t/s → bracket [$GS_LO, $GS_HI]" >&2
    done
  fi

  log "  after refinement: pick=$PICK (${PICK_PF} t/s)"

  # Change E rule 3: on a confirm failure, step down through the measured points
  # (refinement points first, largest below PICK, then ladder rungs). Echoes the
  # largest measured PASS point strictly below $1, or empty if none.
  discover_stepdown_candidate() {
    local CUR=$1 BESTDN=0
    local i
    for i in "${!REFINE_B[@]}"; do
      if [ "${REFINE_B[$i]}" -lt "$CUR" ] && [ "${REFINE_B[$i]}" -gt "$BESTDN" ]; then BESTDN=${REFINE_B[$i]}; fi
    done
    for i in "${!PASS_B[@]}"; do
      if [ "${PASS_B[$i]}" -lt "$CUR" ] && [ "${PASS_B[$i]}" -gt "$BESTDN" ]; then BESTDN=${PASS_B[$i]}; fi
    done
    echo "$BESTDN"
  }

  # ── Phase C: confirm at PICK (one restart per attempt, ≤2 step-downs) ──
  set_batch "$PICK"
  log ""; log "=== DISCOVER CONFIRM (pick=$PICK, mode=$MODE) ==="
  while :; do
    log "  Confirm restart @ pick=$PICK..."
    set_batch "$PICK"; restart
    log ""; log "  === SATURATION at $PICK ==="
    local SC_RC=0
    saturation_test "$CTX" || SC_RC=$?
    if [ "$SC_RC" -eq 2 ]; then log "  STALL during saturation — aborting"; exit 1; fi
    if [ "$SC_RC" -ne 0 ]; then
      if [ "$SC_RC" -eq 3 ]; then
        log "  saturation FORMAT ERROR at pick=$PICK (HTTP 500 / peg-native format) — not a batch failure; stepping down"
      elif [ "$SC_RC" -eq 4 ]; then
        log "  saturation SIZING FAILURE at pick=$PICK (could not reach compaction); stepping down"
      else
        log "  saturation OOM at pick=$PICK; stepping down"
      fi
      # step down (below): largest measured point (refine then ladder rung)
      local NEWPICK
      NEWPICK=$(discover_stepdown_candidate "$PICK")
      if [ -z "$NEWPICK" ] || [ "$NEWPICK" -eq 0 ] || [ "$STEPS_DN" -ge 2 ]; then
        log "  No lower measured PASS point below $PICK (or step-down limit reached) — failing model"
        log "  Inspect logs; re-run to retry."
        exit 1
      fi
      STEPS_DN=$((STEPS_DN + 1))
      log "  Stepping down: pick $PICK → $NEWPICK"
      PICK=$NEWPICK; PICK_PF=0
      continue
    fi
    log "  saturation PASS at pick=$PICK"

    log ""; log "  === LONG-DECODE at $PICK ==="
    local LC_RC=0
    long_decode_check || LC_RC=$?
    if [ "$LC_RC" -eq 2 ]; then log "  STALL during long-decode — aborting"; exit 1; fi
    if [ "$LC_RC" -ne 0 ]; then
      log "  long-decode FAIL at pick=$PICK — stepping down"
      local NEWPICK2
      NEWPICK2=$(discover_stepdown_candidate "$PICK")
      if [ -z "$NEWPICK2" ] || [ "$NEWPICK2" -eq 0 ] || [ "$STEPS_DN" -ge 2 ]; then
        log "  No lower measured PASS point below $PICK (or step-down limit reached) — failing model"
        log "  Inspect logs; re-run to retry."
        exit 1
      fi
      STEPS_DN=$((STEPS_DN + 1))
      log "  Stepping down: pick $PICK → $NEWPICK2"
      PICK=$NEWPICK2; PICK_PF=0
      continue
    fi
    log "  long-decode PASS at pick=$PICK"

    # Decode-cliff check (GPU mode only). CPU placement → step down (definitive);
    # SHORT either side → keep; <0.70 → re-sample once then decide; <0.90 → WARN.
    # Change A: skipped for simple non-MTP models (decode is batch-independent;
    # the cliff check only guards MTP draft / KV spill, which these cannot have).
    local CONFIRM_OK=1
    if [ "$MODE" = "GPU" ] && [ "$SIMPLE_NONMTP" -eq 0 ]; then
      local DEC_PICK
      if ! DEC_PICK=$(decode_sample "pick-confirm"); then
        log "  STALL during pick decode sample — aborting"; exit 1
      fi
      local DP_SPEED DP_PLAC DP_TOK DP_OOM
      DP_SPEED=$(echo "$DEC_PICK" | cut -d'|' -f1)
      DP_PLAC=$(echo "$DEC_PICK" | cut -d'|' -f3)
      DP_TOK=$(echo "$DEC_PICK" | cut -d'|' -f7)
      DP_OOM=$(echo "$DEC_PICK" | cut -d'|' -f6)
      log "  DEC_PICK: ${DP_SPEED:-?} t/s | placement=$DP_PLAC | tokens=${DP_TOK:-0} | oom=$DP_OOM"
      if [ "$DP_OOM" = "1" ]; then
        log "  OOM in pick decode sample — stepping down"
        CONFIRM_OK=0
      elif [ "$DP_PLAC" = "CPU" ]; then
        log "  draft/KV spill at pick (CPU placement) — stepping down"
        CONFIRM_OK=0
      else
        local BASE_SPEED BASE_TOK
        BASE_SPEED=$(echo "$DEC_BASE" | cut -d'|' -f1)
        BASE_TOK=$(echo "$DEC_BASE" | cut -d'|' -f7)
        if [ -z "$BASE_SPEED" ] || [ -z "$DP_SPEED" ] \
           || python3 -c "exit(0 if int('${BASE_TOK:-0}') < $MIN_DECODE_TOKENS or int('${DP_TOK:-0}') < $MIN_DECODE_TOKENS else 1)" 2>/dev/null; then
          log "  cliff speed check skipped (SHORT sample); placement GPU at pick — keeping pick"
        elif python3 -c "exit(0 if float('$DP_SPEED') < float('$BASE_SPEED') * $DECODE_CLIFF else 1)" 2>/dev/null; then
          log "  decode at pick ${DP_SPEED} t/s < ${DECODE_CLIFF}× baseline ${BASE_SPEED} — re-sampling once"
          local DEC_PICK2
          if ! DEC_PICK2=$(decode_sample "pick-resample"); then
            log "  STALL during pick re-sample — aborting"; exit 1
          fi
          local DP2_SPEED
          DP2_SPEED=$(echo "$DEC_PICK2" | cut -d'|' -f1)
          local MEAN
          MEAN=$(python3 -c "print((float('$DP_SPEED') + float('$DP2_SPEED')) / 2)")
          if python3 -c "exit(0 if float('$MEAN') < float('$BASE_SPEED') * $DECODE_CLIFF else 1)" 2>/dev/null; then
            log "  re-sample mean ${MEAN} t/s still < ${DECODE_CLIFF}× baseline — stepping down"
            CONFIRM_OK=0
          else
            log "  WARN: first sample slow, re-sample recovered (mean ${MEAN} t/s) — keeping pick"
          fi
        elif python3 -c "exit(0 if float('$DP_SPEED') < float('$BASE_SPEED') * $DECODE_WARN else 1)" 2>/dev/null; then
          log "  WARN: decode ${DP_SPEED} t/s in ${DECODE_WARN}–${DECODE_CLIFF} noise band — keeping pick"
        fi
      fi
    fi

    if [ "$CONFIRM_OK" -eq 0 ]; then
      local NEWPICK3
      NEWPICK3=$(discover_stepdown_candidate "$PICK")
      if [ -z "$NEWPICK3" ] || [ "$NEWPICK3" -eq 0 ] || [ "$STEPS_DN" -ge 2 ]; then
        log "  No lower measured PASS point below $PICK (or step-down limit reached) — failing model"
        log "  Inspect logs; re-run to retry."
        exit 1
      fi
      STEPS_DN=$((STEPS_DN + 1))
      log "  Stepping down: pick $PICK → $NEWPICK3"
      PICK=$NEWPICK3; PICK_PF=0
      continue
    fi
    break   # pick confirmed
  done

  # ── Result block (§4.5) ──
  set_batch "$PICK"
  log ""; log "=== RESULT ==="
  log "  batch=$PICK ubatch=$PICK ctx=$CTX"
  if python3 -c "exit(0 if float('$PREFILL_TOL') > 0 else 1)" 2>/dev/null; then
    log "  mode=$MODE_TXT  pick=$PICK (smallest within ${PREFILL_TOL} of best ${BEST_PREFILL} t/s)"
  else
    log "  mode=$MODE_TXT  pick=$PICK (best measured, ${PICK_PF} t/s)"
  fi
  if [ -n "$CEIL_FAIL_B" ]; then
    log "  ceiling(coarse)=${HIGHPASS} PASS / ${CEIL_FAIL_B} ${CEIL_FAIL_R}"
  else
    log "  ceiling(coarse) ≥ ${HIGHPASS} PASS (not probed higher)"
  fi
  log "  confirm: saturation PASS, long-decode PASS"
  if [ "$MODE" = "GPU" ] && [ -n "$DEC_BASE" ]; then
    log "  decode $(echo "$DEC_PICK" | cut -d'|' -f1) t/s @pick vs $(echo "$DEC_BASE" | cut -d'|' -f1) t/s @256 (GPU)"
  fi
  log ""; log "  Next: run bench.sh bench $MODEL"
  log "=== DONE ==="

  # Write the discover JSON for cmd_bench to merge (§4.5). §40.2#1: the refine
  # batch list is passed through an env var, NOT embedded as "${REFINE_B[@]}"
  # inside this double-quoted python -c string — once there are two or more
  # points, [@] expands to separate shell words, splitting the program across
  # several python3 -c arguments so Python sees a truncated first chunk and the
  # writer silently fails (which the old "2>/dev/null || true" hid). A stale or
  # missing discover block must never be merged into a bench record, so this
  # writer FAILS the bisect (exit 1) if the JSON is not written.
  local DISC_JSON="/tmp/discover_${MODEL}.json"
  export DISC_REFINE="${REFINE_B[*]:-}"
  if ! python3 -c "
import json, datetime, os
model='$MODEL'
refine_batches=set(int(x) for x in os.environ.get('DISC_REFINE','').split() if x)
points=[l.split() for l in open('$POINTS') if l.strip()]
ladder=[]
for t in points:
    b=int(t[0]); st=t[1]; pf=(float(t[2]) if len(t)>2 and t[2] not in ('OOM','SPILL','PASS') else None)
    if st=='PASS' and b in refine_batches:
        st='REFINE'
    ladder.append({'batch':b,'status':st,'prefill':pf})
discover={
  'mode':'$MODE_TXT',
  'ladder':ladder,
  'best_prefill':float('$BEST_PREFILL'),
  'pick':int('$PICK'),
  'pick_rule':f'best measured PASS point (incl. ${PREFILL_NOISE}-aware refinement); TOL=${PREFILL_TOL}',
  'refine_points':sorted(refine_batches),
  'ceiling_coarse':('${HIGHPASS}' + (' PASS / ${CEIL_FAIL_B} ${CEIL_FAIL_R}' if '${CEIL_FAIL_B}' else ' PASS (not probed higher)')),
  'ladder_break':'${CEIL_BREAK:-0}',
  'written_at':datetime.datetime.now().isoformat(),
}
with open('$DISC_JSON','w') as f:
    json.dump(discover,f,indent=2)
"; then
    log "  ERROR: failed to write discover JSON $DISC_JSON"
    exit 1
  fi
  exit 0
}

# ── SUBCOMMAND: bench (full benchmark record) ───────────────
cmd_bench() {
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

  # Prompt size: 75% of ctx (CTX now guaranteed set)
  local PROMPT_TOKENS=$((CTX * 3 / 4))

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
  # Phase B decode uses the natural-stop DECODE_PROMPT (see below); max_tokens is
  # only a safety cap so the decode window fits even on small-ctx models. Match
  # decode_sample's formula max(256, min(4000, ctx-256)) (plan §25#4).
  local DECODE_MAX_TOKENS
  DECODE_MAX_TOKENS=$(python3 -c "print(max(256, min(4000, $CTX - 256)))")

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

  # Prefill-aware timeout: covers prefilling PROMPT_TOKENS tokens at ~60 t/s worst-case
  # with 4x margin; matches the SAT_TIMEOUT pattern used in saturation_test.
  local BENCH_PREFILL_TIMEOUT=$(python3 -c "print(max(1200, min(14400, int($PROMPT_TOKENS / 60 * 4))))")
  log "  Phase A: prefill request ($PROMPT_TOKENS tokens, timeout ${BENCH_PREFILL_TIMEOUT}s)..."
  fire_request /tmp/bench_prefill_payload.json /tmp/bench_prefill.json "bench-prefill" "$BENCH_PREFILL_TIMEOUT"
  local RC=$?
  if [ "$RC" -eq 2 ]; then log "  STALL on prefill — aborting bench"; return 1; fi
  wait "$FIRE_PID" 2>/dev/null || true

  # ── Phase B: DECODE (natural-stop prompt, placement polling) ───────
  # §5.2 / plan §23.2#1: the bench decode must NOT force tokens (ignore_eos
  # would loop-inflate decode t/s and draft acceptance). Use DECODE_PROMPT
  # (natural stop) so the recorded decode_t_s is the real figure. cmd_bench's own
  # placement / hardware polling below is unchanged.
  export DECODE_PROMPT_VAL="$DECODE_PROMPT"
  python3 -c "
import json, os
payload = {'model':'$MODEL','messages':[{'role':'user','content':os.environ['DECODE_PROMPT_VAL']}],'max_tokens':$DECODE_MAX_TOKENS}
with open('/tmp/bench_payload.json','w') as f: json.dump(payload, f)
print(f'  Decode payload: DECODE_PROMPT (natural stop, max_tokens=$DECODE_MAX_TOKENS)')
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
    TOP=$(top -bn1 2>/dev/null | grep llama-s | head -n1) || true
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

  # Classify placement (shared binary classifier, plan §37 Change F)
  local PLACEMENT
  PLACEMENT=$(classify_placement "$AVG_CPU" "$AVG_GPU")

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
    # 8-gram degeneracy on the natural-stop output (§5.2), heading lines stripped.
    try:
        _text = dd['choices'][0]['message']['content']
        _lines = [ln for ln in _text.split('\n') if not ln.lstrip().startswith('#')]
        _w = (' '.join(_lines)).split()
        if len(_w) >= 8:
            from collections import Counter
            _ng = [' '.join(_w[i:i+8]) for i in range(len(_w)-7)]
            _c = Counter(_ng)
            out['request']['degeneracy'] = round(sum(v for v in _c.values() if v > 1) / len(_ng), 4)
        else:
            out['request']['degeneracy'] = 0
    except Exception:
        out['request']['degeneracy'] = None

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
        'draft_mean_len': None, 'n_max_loaded': None, 'p_min_loaded': None,
    }))
    exit()
logs = '''$REQ_LOGS'''
# acceptance from the bench request's decode
acc = re.search(r'draft acceptance = ([0-9.]+)\s*\(\s*(\d+)\s+accepted\s*/\s*(\d+)\s+generated\), mean len =\s*([0-9.]+)', logs)
# confirmed params from load log — scoped to THIS model's load block via its --alias
load_logs = open('/tmp/load_logs.txt').read()
def load_val(flag):
    # find the LAST --alias <MODEL> load block (the bench's own fresh load), then
    # look backward for the flag/value pair. Using the last block avoids grabbing a
    # stale earlier load (e.g. from the bisect/mtp phase at a different n_max) that
    # a 2000-char backscan from the FIRST match would hit (plan §31 finding 2).
    matches = list(re.finditer(r'--alias\s*\n[^\n]*' + re.escape('$MODEL'), load_logs))
    if not matches:
        return None
    m = matches[-1]
    block = load_logs[max(0, m.start() - 2000):m.start()]
    m2 = re.search(re.escape(flag) + r'\s*\n[^\n]*load:\s*(\S+)', block)
    return m2.group(1) if m2 else None
def _num(x):
    # load_val returns the raw string; coerce to int/float so n_max_loaded and
    # p_min_loaded match the numeric configured_n_max/p_min types (plan §25#6).
    if x is None: return None
    try: return int(x)
    except ValueError: pass
    try: return float(x)
    except ValueError: return x
print(json.dumps({
    'acceptance': float(acc.group(1)) if acc else None,
    'draft_accepted': int(acc.group(2)) if acc else None,
    'draft_generated': int(acc.group(3)) if acc else None,
    'draft_mean_len': float(acc.group(4)) if acc else None,
    'n_max_loaded': _num(load_val(r'--spec-draft-n-max')),
    'p_min_loaded': _num(load_val(r'--draft-p-min')),
}))
")

  log ""
  log "=== RESULTS ==="
  # Write the speed/request summary to BOTH the log file and stdout (plan §25#5:
  # previously it went to stdout only, so a run's published figures were absent
  # from the log). Single python appends to $LOG_FILE and echoes to stdout.
  python3 -c "
import json
d=json.loads('''$SPEED''')
out=''
for k,v in d.items(): out += f'  {k}: {v}\n'
open('$LOG_FILE','a').write(out)
print(out, end='')
"
  log "  placement: $PLACEMENT (avg_cpu: ${AVG_CPU}%, avg_gpu: ${AVG_GPU}%)"

  local SAMPLE_COUNT=${#CPU_SAMPLES[@]}

  # Write JSON
  python3 - << PYEOF
import json, datetime, os, sys
speed = json.loads('''$SPEED''')
meta = json.loads('''$META''')
mtp = json.loads('''$MTP''')
env = json.loads('''$ENV_JSON''')

# Merge the §6.4 MTP tuning status file (/tmp/mtp_status_<model>.json) if present
# (ok / failed / stall / not_mtp). tuning_status defaults to not_run when absent
# (mtp tuning never ran for this bench, e.g. a direct 'bench.sh bench' run).
status = {}
_status_path = '/tmp/mtp_status_${MODEL}.json'
if os.path.exists(_status_path):
    try:
        with open(_status_path) as _sf: status = json.load(_sf)
    except Exception:
        status = {}
_mtp_tuning = {
    'tuning_status': status.get('status') if status else 'not_run',
    'tuning_reason': status.get('reason') if status else None,
    'tuned_n_max': status.get('tuned_n_max') if status else None,
    'tuned_p_min': status.get('tuned_p_min') if status else None,
    'tuning_samples': status.get('samples') if status and status.get('samples') is not None else [],
    'tuning_written_at': status.get('written_at') if status else None,
}

# Stale-status guard (plan §25#1 + §31 finding 3): if the status file says "ok"
# but the tuned values do not match what the ini/config says (configured_n_max /
# p_min) OR what the server actually loaded for this bench (mtp.n_max_loaded /
# p_min_loaded), the tune is not in effect for this record. Relabel it "stale"
# but keep the tuned values for reference, and surface it via stderr and the log.
if _mtp_tuning['tuning_status'] == 'ok':
    _cn = meta['mtp'].get('n_max'); _cp = meta['mtp'].get('p_min')
    _tn = _mtp_tuning['tuned_n_max']; _tp = _mtp_tuning['tuned_p_min']
    _ln = mtp.get('n_max_loaded'); _lp = mtp.get('p_min_loaded')
    _why = None
    if (_tn is not None and _tn != _cn) or (_tp is not None and _tp != _cp):
        _why = 'configured differs: tuned n_max/p_min (%s/%s) != configured (%s/%s)' % (_tn, _tp, _cn, _cp)
    elif (_ln is not None and _tn is not None and _ln != _tn) or (_lp is not None and _tp is not None and _lp != _tp):
        _why = 'loaded differs: tuned n_max/p_min (%s/%s) != loaded (%s/%s)' % (_tn, _tp, _ln, _lp)
    if _why:
        _mtp_tuning['tuning_status'] = 'stale'
        _mtp_tuning['tuning_reason'] = _why
        _warn = '[bench] WARNING: mtp tuning_status stale (%s)\n' % _why
        sys.stderr.write(_warn)
        try:
            open('$LOG_FILE', 'a').write(_warn)
        except Exception:
            pass

# Merge the §4.5 discover-ladder result (/tmp/discover_<model>.json) if present.
# cmd_bisect_discover writes it; a thorough or bench-only run has none → discover={}.
discover = {}
_disc_path = '/tmp/discover_${MODEL}.json'
if os.path.exists(_disc_path):
    try:
        with open(_disc_path) as _df: discover = json.load(_df)
    except Exception:
        discover = {}

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
        'decode_prompt_tokens': speed.get('request', {}).get('decode_prompt_tokens', 0),
        'model_file_size_gb': ${MODEL_FILE_SIZE:-null},
        'build_info': '${BUILD_INFO}',
        'wall_time_s': $WALL_TIME_S,
    },
    'speed': speed.get('speed', {}),
    'request': speed.get('request', {}),
    'mtp': {
        **mtp,
        **_mtp_tuning,
        'configured_n_max': meta['mtp']['n_max'],
        'configured_p_min': meta['mtp']['p_min'],
        'drafter': meta['mtp']['drafter'],
    },
    'discover': discover if discover else {},
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
PYEOF

  # Verify the JSON was actually written and is newer than this run's start
  # (plan §25#5): a failed/partial write must not reach '=== DONE ===' as a pass.
  if [ ! -f "$JSON_FILE" ] || [ ! -s "$JSON_FILE" ] \
     || [ "$(stat -c %Y "$JSON_FILE" 2>/dev/null || echo 0)" -lt "$REQUEST_START" ]; then
    log "  ERROR: JSON not written or stale at $JSON_FILE — failing bench"
    return 1
  fi
  log "  JSON written to $JSON_FILE"

  log "=== DONE: $MODEL ==="
}

# ── Reset one parent via the full 4-step flow (shared by both pre-passes) ──
# Runs each cmd in a subshell to contain its exit(); sets global RESET_DONE on bench success.
reset_parent_full() {
  local P=$1
  MODEL=$P
  log ""
  lshow "=============== RESET PARENT: $P ==============="

  # step 1: mtpcheck (detect_mtp uses exit 1 → must be subshelled)
  log "  $(date +%H:%M:%S) starting mtpcheck for $P"
  local IS_MTP=0
  if ( cmd_mtpcheck ); then
    IS_MTP=1
    log "  $(date +%H:%M:%S) mtpcheck OK for $P (MTP-capable)"
  else
    log "  $(date +%H:%M:%S) mtpcheck: NOT MTP for $P"
  fi

  # step 2: bisect (runs against true MTP state set by mtpcheck)
  log "  $(date +%H:%M:%S) starting bisect for $P"
  if ( cmd_bisect ); then
    log "  $(date +%H:%M:%S) bisect OK for $P"
  else
    log "  $(date +%H:%M:%S) bisect FAILED for $P — skipping mtp+bench"
    return 1
  fi

  # step 3: mtp tuning (only if MTP-capable and bisect succeeded)
  local MTP_OK=1
  if [ "$IS_MTP" -eq 1 ]; then
    log "  $(date +%H:%M:%S) starting mtp for $P"
    if ( cmd_mtp ); then
      log "  $(date +%H:%M:%S) mtp OK for $P"
    else
      MTP_OK=0
      log "  $(date +%H:%M:%S) mtp FAILED for $P"
    fi
  fi

  # step 4: bench. With --strict, a failed mtp tune skips bench (§6.4 part 3);
  # the JSON would otherwise carry tuning_status:failed.
  if [ "$MTP_OK" -eq 0 ] && [ "$STRICT" -eq 1 ]; then
    log "  $(date +%H:%M:%S) bench: SKIPPED (mtp failed, --strict)"
    return 0
  fi
  log "  $(date +%H:%M:%S) starting bench for $P"
  if ( cmd_bench ); then
    log "  $(date +%H:%M:%S) bench OK for $P"
    RESET_DONE["$P"]=1
  else
    log "  $(date +%H:%M:%S) bench FAILED for $P"
  fi
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
      reset_parent_full "$PARENT_NAME" || true
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
      if [ "${RESET_DONE[$NAME]:-0}" -eq 1 ]; then
        lshow "  $NAME: already reset-benched in pre-pass"
        for s in mtpcheck bisect mtp bench; do
          VERDICTS["$NAME|$s"]="OK (reset)"
        done
      elif [ "$NAME" = "$PARENT_NAME" ]; then
        lshow "  $NAME: family head, already benched (skip)"
        for s in mtpcheck bisect mtp bench; do
          VERDICTS["$NAME|$s"]="SKIPPED (family head)"
        done
      else
        lshow "  $NAME: inheriting from $PARENT_NAME (JSON copied, no bench)"
        for s in mtpcheck bisect mtp bench; do
          VERDICTS["$NAME|$s"]="SKIPPED (inherited from $PARENT_NAME)"
        done
      fi
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
    local MTP_FAILED=0
    if [ "$BISECT_FAILED" -eq 1 ]; then
      VERDICTS["$NAME|mtp"]="SKIPPED (bisect failed)"
    elif [ "$IS_MTP" -eq 0 ]; then
      VERDICTS["$NAME|mtp"]="SKIPPED (not MTP)"
    else
      lshow "  $(date +%H:%M:%S) starting mtp for $NAME"
      if ( cmd_mtp ); then
        VERDICTS["$NAME|mtp"]="OK"
      else
        MTP_FAILED=1
        VERDICTS["$NAME|mtp"]="FAIL"
      fi
      lshow "  $(date +%H:%M:%S) finished mtp for $NAME"
    fi

    # step 4: bench. With --strict, a failed mtp tune skips bench (§6.4 part 3);
    # otherwise bench still runs and its JSON records tuning_status:failed.
    if [ "$BISECT_FAILED" -eq 1 ]; then
      lshow "  bench: SKIPPED (bisect failed — models.ini batch unreliable)"
      VERDICTS["$NAME|bench"]="SKIPPED (bisect failed)"
    elif [ "$MTP_FAILED" -eq 1 ] && [ "$STRICT" -eq 1 ]; then
      lshow "  bench: SKIPPED (mtp failed, --strict)"
      VERDICTS["$NAME|bench"]="SKIPPED (mtp failed)"
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
  lshow "$(printf '%-45s %-8s %-8s %-8s %-8s' MODEL mtpcheck bisect mtp bench)"
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
    --thorough)    THOROUGH=1 ;;
    --strict)      STRICT=1 ;;
    *)             MAIN_ARGS+=("$arg") ;;
  esac
done
# Env fallbacks: BENCH_THOROUGH=1 (and BENCH_DISCOVER, deprecated, is the old
# discover selector and is now the default, so it is ignored).
if [ "${THOROUGH:-0}" -eq 0 ] && [ "${BENCH_THOROUGH:-0}" -eq 1 ]; then
  THOROUGH=1
fi
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

  # Search depth: discover (fast, default) vs thorough (exhaustive legacy search).
  read -r -p "Search depth? [D]iscover / [t]horough: " DEPTH_INPUT
  case "${DEPTH_INPUT:-D}" in
    [tT]|[tT][hH][oO][rR][oO][uU][gG][hH]) THOROUGH=1; log "  Search depth: THOROUGH (legacy exhaustive)" ;;
    *)                                      THOROUGH=0; log "  Search depth: discover (fast)" ;;
  esac

  lshow "=== MASTER PLAN ==="
  lshow "  models: $(for i in $MODEL_IDXS; do echo -n "$(model_name "$i") "; done)"
  lshow "  steps: mtpcheck bisect mtp bench (full suite)"
  if [ "$THOROUGH" -eq 1 ]; then lshow "  depth: thorough"; else lshow "  depth: discover"; fi
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
  mtpverify)
    for m in "$@"; do
      MODEL=$m
      ( cmd_mtpverify ) || { echo "  $m: mtpverify FAILED"; continue; }
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
        reset_parent_full "$PARENT" || true
      done
    fi
    for m in "$@"; do
      MODEL=$m
      if maybe_inherit "$m"; then
        if [ "$m" = "$(family_of "$m")" ]; then
          log "  $m: family head, already benched (skip)"
        else
          log "  $m: inheriting from $(family_of "$m") (JSON copied, no bench)"
        fi
        continue
      fi
      ( cmd_bench ) || { echo "  $m: bench FAILED"; continue; }
    done
    ;;
  *)
    echo "Usage: bench.sh [all|mtpcheck|mtpverify|bisect|mtp|bench] <models...>"
    echo "       bench.sh                                    # interactive full suite"
    echo "       bench.sh all <models...>                    # non-interactive full suite"
    echo "       bench.sh mtpcheck <models...>               # MTP capability check"
    echo "       bench.sh mtpverify <models...>              # MTP-on vs off output check (premise test)"
    echo "       bench.sh bisect <model> [test-batch]"
    echo "       bench.sh mtp <models...>                    # n_max/p_min tuning"
    echo "       bench.sh bench <models...>                  # benchmark JSON record"
    echo "       global flags: --no-inherit --reset-parent --thorough --strict"
    echo "       env: BENCH_THOROUGH=1 selects the thorough (legacy) tuners; discover is the default"
    exit 1
    ;;
esac
