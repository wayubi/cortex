#!/bin/bash
# batch_bisect.sh — Find optimal batch-size/ubatch-size via VRAM-math estimate + saturation test
#
# Phase 1 estimates the ceiling from 2 VRAM probes (buffer size scales ~linearly with
# batch), instead of a full up-then-down sweep. Falls back to classic sweep if the fit fails.
#
# Usage:
#   ./tools/batch_bisect.sh <model-name>                    # full bisection
#   ./tools/batch_bisect.sh <model-name> <test-batch>       # test specific batch
#   ./tools/batch_bisect.sh <model-name> resume <lo> <hi>   # skip coarse sweep, bisect from known bracket
#   ./tools/batch_bisect.sh <model-name> resume <batch>     # re-validate a finished/known batch
#
# Reads ctx-size from models.ini. Updates models.ini with optimal batch.
# Logs to stdout + logs/batch_bisect_{model}.log

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL=${1:-}
ARG2=${2:-}
TEST_BATCH=0
RESUME=0
RESUME_LO=0
RESUME_HI=0
RESUME_BATCH=0

if [ -z "$MODEL" ]; then
  echo "Usage: $0 <model-name> [test-batch|resume <lo> <hi>|resume <batch>]"
  exit 1
fi

if [ "$ARG2" = "resume" ]; then
  if [[ "${3:-}" =~ ^[0-9]+$ ]] && [[ "${4:-}" =~ ^[0-9]+$ ]]; then
    RESUME=1
    RESUME_LO=$3
    RESUME_HI=$4
    if ! [ "$RESUME_LO" -gt 0 ] 2>/dev/null || ! [ "$RESUME_HI" -gt "$RESUME_LO" ] 2>/dev/null; then
      echo "Usage: $0 <model-name> resume <lo> <hi>"
      echo "  lo = highest batch known to PASS, hi = lowest batch known to OOM (hi > lo > 0)"
      exit 1
    fi
  elif [[ "${3:-}" =~ ^[0-9]+$ ]]; then
    RESUME_BATCH=1
    TEST_BATCH=$3
  else
    echo "Usage: $0 <model-name> resume <lo> <hi> | resume <batch>"
    exit 1
  fi
elif [ -n "$ARG2" ]; then
  TEST_BATCH=$ARG2
fi
INI="$ROOT/llama-cpp/models.ini"
LOG_FILE="$ROOT/logs/batch_bisect_${MODEL}.log"
DOCKER_LOG="cortex-llama-cpp-1"
OMG_GREP="cudaMalloc failed|failed to allocate compute pp buffers|terminate called after throwing|failed to create MTP context|exiting due to model loading error|CUDA error: out of memory|cuMemCreate"

mkdir -p "$ROOT/logs"

log() { echo "$1" | tee -a "$LOG_FILE"; }

# Read ctx-size from models.ini (scoped to the model's own section)
CTX=$(python3 -c "
import re
with open('$INI') as f: content = f.read()
m = re.search(r'\['+re.escape('$MODEL')+r'\](.*?)(?=\n\[|\Z)', content, re.DOTALL)
sec = m.group(1) if m else ''
mm = re.search(r'^\s*ctx-size\s*=\s*(\d+)', sec, re.MULTILINE)
print(mm.group(1) if mm else '')
")
[ -z "$CTX" ] && { echo "ERROR: ctx-size not found for [$MODEL]"; exit 1; }

log "Model: $MODEL | ctx: $CTX | test-batch: $TEST_BATCH"

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

restart() {
  log "  Restarting llama-cpp..."
  cd "$ROOT" && docker compose restart llama-cpp
  sleep 5
  log "  Restarted — model will load on first request"
}

# Log-marking for precise OOM detection (catches load-time OOMs, no stale matches)
LOG_MARK=0
logmark() { LOG_MARK=$(docker logs $DOCKER_LOG 2>&1 | wc -l); }
oom_since_mark() {
  docker logs $DOCKER_LOG 2>&1 | tail -n +$((LOG_MARK + 1)) | grep -iE "$OMG_GREP" || true
}
oom_count_since_mark() { oom_since_mark | wc -l | tr -d ' '; }

# Current GPU VRAM in MiB
vram_now() {
  nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | head -1
}

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

# Measure chars-per-token ratio for this model (also warms the model up)
CHARS_PER_TOK=0
measure_ratio() {
  local MEASURE_CHARS=2000
  python3 -c "
import json
payload = {'model':'$MODEL','messages':[{'role':'user','content':('The history of computing is long and complex. '*1000)[:$MEASURE_CHARS]}],'max_tokens':1}
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
payload = {'model':'$MODEL','messages':[{'role':'user','content':('The history of computing is long and complex. '*1000)[:$SAT_SIZE]}],'max_tokens':$MAX_TOK,'ignore_eos':True}
with open('/tmp/sat_payload.json','w') as f: json.dump(payload, f)
print(f'  Payload: {len(json.dumps(payload))} bytes')
"
    logmark
    curl -s --max-time 600 -X POST http://localhost:8080/v1/chat/completions \
      -H 'Content-Type: application/json' -d @/tmp/sat_payload.json \
      > /tmp/sat_response.json 2>&1

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

# ── MAIN ──
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
  saturation_test || { log "  FAILED"; exit 1; }
  log ""; log "=== PHASE 3: LONG-DECODE ==="
  long_decode_check || true
  log ""; log "=== RESULT: batch=$TEST_BATCH ubatch=$TEST_BATCH ==="
  log "=== DONE ==="
else
  if [ "$RESUME" -eq 1 ]; then
    LO=$RESUME_LO; HI=$RESUME_HI
    log ""; log "=== RESUMING BISECT (lo=$LO, hi=$HI, gap=$((HI-LO))) — skipping coarse sweep ==="
  else
  # ── PHASE 1: VRAM-MATH CEILING ESTIMATE (2 probes, linear model) ──
  log ""; log "=== PHASE 1: VRAM-MATH CEILING ESTIMATE ==="
  # Measure VRAM used at two PASS batches, fit buffer(B) = slope*B + base,
  # then predict max_batch = (12288 - base) / slope. Falls back to the
  # classic sweep+bisect if the model OOMs at the low probe or the fit is bad.
  GPU_TOTAL_MIB=12288

  # Probe 1 at 4096 (expect PASS for most models)
  B1=4096
  set_batch "$B1"; restart; log "  Tiny probe @ batch=$B1..."
  if ! tiny_probe; then
    log "  OOM at $B1 — falling back to classic down-sweep"
    HI=$B1; BATCH=$((B1 / 2))
    while true; do
      log ""; log "  Testing batch=$BATCH..."
      set_batch "$BATCH"; restart; log "  Tiny probe..."
      if tiny_probe; then log "  PASS"; LO=$BATCH; break
      else log "  OOM"; HI=$BATCH; BATCH=$((BATCH / 2)); fi
      if [ "$BATCH" -lt 64 ]; then
        log "  ERROR: no PASS found below 64. Lower ctx or free VRAM (override-tensor=exps=CPU)."
        exit 1
      fi
    done
  else
    log "  PASS at $B1"
    sleep 2   # let VRAM settle after decode
    USED1=$(vram_now)
    log "  VRAM used @ batch=$B1: ${USED1} MiB"

    # Probe 2: pick a mid batch (expect PASS for most). If it OOMs, step down.
    B2=32768
    while [ "$B2" -gt "$B1" ]; do
      set_batch "$B2"; restart; log "  Tiny probe @ batch=$B2..."
      if tiny_probe; then
        log "  PASS at $B2"
        sleep 2
        USED2=$(vram_now)
        log "  VRAM used @ batch=$B2: ${USED2} MiB"
        break
      else
        log "  OOM at $B2 — stepping B2 down"
        B2=$((B2 / 2))
      fi
    done
    if [ "$B2" -le "$B1" ]; then
      log "  Could not get a second PASS point — falling back to classic up-sweep"
      LO=$B1; BATCH=$((B1 * 2))
      while true; do
        log ""; log "  Testing batch=$BATCH..."
        set_batch "$BATCH"; restart; log "  Tiny probe..."
        if tiny_probe; then log "  PASS"; LO=$BATCH; BATCH=$((BATCH * 2))
        else log "  OOM"; HI=$BATCH; break; fi
        [ "$BATCH" -gt 131072 ] && { log "  Stopping sweep at $BATCH"; HI=$BATCH; break; }
      done
    else
      # Linear fit: slope = (USED2-USED1)/(B2-B1), base = USED1 - slope*B1
      FIT_OK=$(python3 -c "
used1=$USED1; used2=$USED2; b1=$B1; b2=$B2; total=$GPU_TOTAL_MIB
slope = (used2 - used1) / (b2 - b1)
# guard: slope too flat (VRAM didn't grow with batch) → unreliable fit
if slope < 0.01:
    print('FLAT')
else:
    base  = used1 - slope * b1
    pred  = (total - base) / slope
    pred = pred * 0.92
    pred = int(max(pred, b2) // 64 * 64)
    print(pred)
")
      if [ "$FIT_OK" = "FLAT" ] || ! [[ "$FIT_OK" =~ ^[0-9]+$ ]]; then
        log "  Fit unreliable (slope flat or bad VRAM reads) — falling back to classic up-sweep"
        LO=$B1; BATCH=$((B1 * 2)); HI=0
        while true; do
          log ""; log "  Testing batch=$BATCH..."
          set_batch "$BATCH"; restart; log "  Tiny probe..."
          if tiny_probe; then log "  PASS"; LO=$BATCH; BATCH=$((BATCH * 2))
          else log "  OOM"; HI=$BATCH; break; fi
          [ "$BATCH" -gt 131072 ] && { log "  Stopping sweep at $BATCH"; HI=$BATCH; break; }
        done
      else
        MAX_BATCH=$FIT_OK
        SLOPE_MIB=$(python3 -c "print('%.4f' % (($USED2 - $USED1) / ($B2 - $B1)))")
        log "  Fit: slope=${SLOPE_MIB} MiB/batch → predicted max_batch=$MAX_BATCH"
        log "  Setting batch=$MAX_BATCH to verify..."
        set_batch "$MAX_BATCH"; restart; log "  Tiny probe..."
        if tiny_probe; then
          log "  PASS at predicted $MAX_BATCH"
          LO=$MAX_BATCH
          HI=$((MAX_BATCH + 64))
          log "  Bracket: lo=$LO (PASS), hi=$HI (assumed OOM above)"
        else
          log "  OOM at predicted $MAX_BATCH — stepping down for bracket"
          HI=$MAX_BATCH
          LO=$B2
          BATCH=$((MAX_BATCH - 64))
          while [ "$BATCH" -ge "$LO" ]; do
            set_batch "$BATCH"; restart; log "  Tiny probe @ batch=$BATCH..."
            if tiny_probe; then log "  PASS"; LO=$BATCH; break
            else log "  OOM"; HI=$BATCH; BATCH=$((BATCH - 64)); fi
          done
        fi
        log ""; log "  Estimated bracket: lo=$LO (PASS), hi=$HI (OOM)"
      fi
    fi
  fi
  fi

  # ── PHASE 2: REFINE BISECT (tiny probe only, until gap <= 64) ──
  log ""; log "=== PHASE 2: BISECT (lo=$LO, hi=$HI) ==="
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
      log "  PASS"; LO=$MID
    else
      log "  OOM"; HI=$MID
    fi
  done
  VALIDATED=$LO
  log "  Refined lo=$LO — max batch passing tiny probe"

  # ── VERIFY: 2 more tiny probes ──
  log ""; log "=== VERIFYING BATCH $VALIDATED ==="
  set_batch "$VALIDATED"; restart
  PASS=0
  for i in 1 2; do tiny_probe && { PASS=$((PASS+1)); log "  Verify $i: PASS"; } || log "  Verify $i: FAIL"; done

  # ── PHASE 3: SATURATION ON WINNER (step down 64 on fail) ──
  log ""; log "=== PHASE 3: SATURATION ==="
  while true; do
    log "  Testing batch=$VALIDATED..."
    set_batch "$VALIDATED"; restart
    if saturation_test; then
      log "  *** VALIDATED batch=$VALIDATED ***"
      break
    else
      log "  FAIL — stepping down 64"
      VALIDATED=$((VALIDATED - 64))
      [ "$VALIDATED" -lt 64 ] && { log "  ERROR: saturation failed below 64"; exit 1; }
    fi
  done

  log ""; log "=== LONG-DECODE CHECK ==="
  set_batch "$VALIDATED"; restart
  long_decode_check || true

  log ""; log "=== RESULT ==="
  log "  batch=$VALIDATED ubatch=$VALIDATED ctx=$CTX"
  log "  candidates=$CANDIDATES verification=$PASS/2"
  log ""; log "  Next: run bench_model.sh $MODEL"
  log "=== DONE ==="
fi
