#!/bin/bash
# bench_model.sh — Full benchmark record for a model with optimal batch
# Usage:
#   ./tools/bench_model.sh <model-name>                    # bench with 75% of ctx as prompt
#   ./tools/bench_model.sh <model-name> <prompt-tokens>    # custom prompt size
#
# Outputs: ./llama-cpp/models/{model-name}.json
# Captures a complete, self-contained performance record:
#   - env fingerprint (GPU/CPU/RAM/kernel/llama.cpp commit)
#   - model config (all models.ini keys for the entry + [*] defaults)
#   - speed (prefill/decode t/s and latencies)
#   - request signals (finish_reason, truncated, cache hits, tokens)
#   - MTP runtime (acceptance rate + confirmed n_max/p_min, when applicable)
#   - hardware peaks (VRAM/power/temp/clocks over the poll window)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL=$1
PROMPT_TOKENS=${2:-0}
INI="$ROOT/llama-cpp/models.ini"
MODELS_DIR="$ROOT/llama-cpp/models"
JSON_FILE="${MODELS_DIR}/${MODEL}.json"
DOCKER_LOG="cortex-llama-cpp-1"
POLL_MIN_SAMPLES=3
POLL_MAX_SAMPLES=80

mkdir -p "$MODELS_DIR"

log() { echo "$1"; }

# ── Environment fingerprint (host-level, captured once) ─────
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
BUILD_INFO=$(curl -s --max-time 5 http://localhost:8080/props 2>/dev/null | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get('build_info', ''))
except: print('')
" 2>/dev/null || echo "")

# Read ctx-size
CTX=$(python3 -c "
import re
with open('$INI') as f: content = f.read()
m = re.search(r'\[$MODEL\].*?ctx-size\s*=\s*(\d+)', content, re.DOTALL)
print(m.group(1) if m else '')
")
[ -z "$CTX" ] && { echo "ERROR: ctx-size not found"; exit 1; }

# Read batch-size
BATCH=$(python3 -c "
import re
with open('$INI') as f: content = f.read()
m = re.search(r'\[$MODEL\].*?batch-size\s*=\s*(\d+)', content, re.DOTALL)
print(m.group(1) if m else '')
")
[ -z "$BATCH" ] && { echo "ERROR: batch-size not found — run batch_bisect.sh first"; exit 1; }

# Read full config: model section + [*] defaults
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
cd "$ROOT" && docker compose restart llama-cpp
sleep 5
log "  Restarted — model will load on first request"

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
MEASURED_TOK=$(python3 -c "
import json
try:
    d = json.load(open('/tmp/ratio_response.json'))
    print(d.get('usage',{}).get('prompt_tokens',0))
except: print(0)
" 2>/dev/null || echo 0)
if [ "$MEASURED_TOK" -gt 0 ] 2>/dev/null; then
  CHARS_PER_TOK=$(python3 -c "print('%.1f' % (2000 / $MEASURED_TOK))" 2>/dev/null || echo 0)
  log "  Measured: 2000 chars = $MEASURED_TOK tokens → ${CHARS_PER_TOK} chars/tok"
  PROMPT_CHARS=$(python3 -c "print(int($PROMPT_TOKENS * $CHARS_PER_TOK))" 2>/dev/null || echo $((PROMPT_TOKENS * 4)))
else
  log "  Measure probe failed — fallback to $((PROMPT_TOKENS * 4)) chars"
  PROMPT_CHARS=$((PROMPT_TOKENS * 4))
fi

# ── Phase A: PREFILL (75%-ctx prompt, max_tokens=1) ─────────
# Decouple decode sizing: decode uses a short 150-token prompt so the full
# decode window fits even on small-ctx models (4k → ~3946 decode tokens).
DECODE_PROMPT_TOKENS=150
DECODE_MAX_TOKENS=$((CTX - DECODE_PROMPT_TOKENS))
[ "$DECODE_MAX_TOKENS" -gt 4000 ] && DECODE_MAX_TOKENS=4000
DECODE_PROMPT_CHARS=$(python3 -c "print(int($DECODE_PROMPT_TOKENS * $CHARS_PER_TOK))" 2>/dev/null || echo $((DECODE_PROMPT_TOKENS * 4)))

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
REQUEST_START=$(date +%s)

log "  Phase B: firing decode request..."
curl -s --max-time 600 -X POST http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' -d @/tmp/bench_payload.json \
  > /tmp/bench_output.json 2>&1 &
PID=$!

# Poll CPU/GPU until the request completes (min 3 samples, capped at 160s)
log "  Polling CPU/GPU until request completes (max $((POLL_MAX_SAMPLES * 2))s)..."
CPU_SAMPLES=()
GPU_SAMPLES=()
MEM_SAMPLES=()
TEMP_SAMPLES=()
POWER_SAMPLES=()
VRAM_SAMPLES=()
CLOCK_SM_SAMPLES=()
CLOCK_MEM_SAMPLES=()
for i in $(seq 1 $POLL_MAX_SAMPLES); do
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
REQUEST_END=$(date +%s)
WALL_TIME_S=$((REQUEST_END - REQUEST_START))

# Log-window capture for THIS request (MTP acceptance)
REQ_LOGS=$(docker logs $DOCKER_LOG 2>&1 | tail -n +$((LOG_MARK + 1)))
# Load-confirmation lines appear when the model first loads (during the ratio warm-up,
# BEFORE LOG_MARK). Capture them from the whole log since the container started.
docker logs $DOCKER_LOG > /tmp/load_logs.txt 2>&1 || true

# Compute averages (bc-based)
CPU_SUM=0; CPU_CNT=0; GPU_SUM=0; GPU_CNT=0; MEM_SUM=0; MEM_CNT=0
for c in "${CPU_SAMPLES[@]}"; do CPU_SUM=$(echo "$CPU_SUM + $c" | bc); CPU_CNT=$((CPU_CNT+1)); done
for g in "${GPU_SAMPLES[@]}"; do GPU_SUM=$(echo "$GPU_SUM + $g" | bc); GPU_CNT=$((GPU_CNT+1)); done
for m in "${MEM_SAMPLES[@]}"; do MEM_SUM=$(echo "$MEM_SUM + $m" | bc); MEM_CNT=$((MEM_CNT+1)); done
AVG_CPU=$(echo "scale=1; $CPU_SUM / $CPU_CNT" | bc 2>/dev/null || echo "0")
AVG_GPU=$(echo "scale=1; $GPU_SUM / $GPU_CNT" | bc 2>/dev/null || echo "0")
AVG_MEM=$(echo "scale=1; $MEM_SUM / $MEM_CNT" | bc 2>/dev/null || echo "0")

# Peaks (shell max)
PEAK_VRAM=0; PEAK_POWER=0; PEAK_TEMP=0; PEAK_CLOCK_SM=0; PEAK_CLOCK_MEM=0
for v in "${VRAM_SAMPLES[@]}"; do [ "${v:-0}" -gt "$PEAK_VRAM" ] 2>/dev/null && PEAK_VRAM=$v; done
for p in "${POWER_SAMPLES[@]}"; do
  [ -n "$p" ] && [ "$(echo "$p > $PEAK_POWER" | bc)" = "1" ] 2>/dev/null && PEAK_POWER=$p
done
for t in "${TEMP_SAMPLES[@]}"; do [ "${t:-0}" -gt "$PEAK_TEMP" ] 2>/dev/null && PEAK_TEMP=$t; done
for c in "${CLOCK_SM_SAMPLES[@]}"; do [ "${c:-0}" -gt "$PEAK_CLOCK_SM" ] 2>/dev/null && PEAK_CLOCK_SM=$c; done
for c in "${CLOCK_MEM_SAMPLES[@]}"; do [ "${c:-0}" -gt "$PEAK_CLOCK_MEM" ] 2>/dev/null && PEAK_CLOCK_MEM=$c; done

# CPU stddev (placement confidence)
CPU_STDDEV=0
if [ "$CPU_CNT" -gt 1 ]; then
  CPU_VALS_STR=$(printf '%s\n' "${CPU_SAMPLES[@]}")
  CPU_STDDEV=$(printf '%s\n' "$CPU_VALS_STR" | python3 -c "
import sys, statistics
vals = [float(x) for x in sys.stdin.read().split()]
print(f'{statistics.stdev(vals):.1f}')
" 2>/dev/null || echo "0")
fi

# Final hardware snapshot
HW=$(nvidia-smi --query-gpu=temperature.gpu,power.draw,memory.used --format=csv,noheader,nounits 2>/dev/null)
GPU_TEMP=$(echo "$HW" | cut -d',' -f1 | tr -d ' ')
GPU_POWER=$(echo "$HW" | cut -d',' -f2 | tr -d ' ')
VRAM=$(echo "$HW" | cut -d',' -f3 | tr -d ' ')
RAM=$(free -m | awk '/Mem:/ {print $3}')
RSS=$(ps aux 2>/dev/null | grep llama-server | grep -v grep | grep -v models-preset | awk '{print int($6/1024)}' | head -1)

# Classify placement
if (( $(echo "$AVG_CPU < 100" | bc -l) )); then PLACEMENT="GPU"
elif (( $(echo "$AVG_CPU > 200" | bc -l) )); then PLACEMENT="CPU"
else PLACEMENT="AMBIGUOUS"; fi

# Extract speed + request signals (prefill from phase A, decode from phase B)
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

SAMPLE_COUNT=${#CPU_SAMPLES[@]}

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
