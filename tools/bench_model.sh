#!/bin/bash
# bench_model.sh — Full benchmark suite for a model with optimal batch
# Usage:
#   ./tools/bench_model.sh <model-name>                    # bench with 75% of ctx as prompt
#   ./tools/bench_model.sh <model-name> <prompt-tokens>    # custom prompt size
#
# Outputs: ./llama-cpp/models/{model-name}.json

set -euo pipefail

MODEL=$1
PROMPT_TOKENS=${2:-0}
INI="/mnt/md2/docker-containers/cortex/llama-cpp/models.ini"
MODELS_DIR="/mnt/md2/docker-containers/cortex/llama-cpp/models"
JSON_FILE="${MODELS_DIR}/${MODEL}.json"
DOCKER_LOG="cortex-llama-cpp-1"

mkdir -p "$MODELS_DIR"

log() { echo "$1"; }

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

# Read metadata
META=$(python3 -c "
import re, json
with open('$INI') as f: content = f.read()
block = re.search(r'\[$MODEL\].*?(?=\n\[|\Z)', content, re.DOTALL).group(0)
n_max = re.search(r'spec-draft-n-max\s*=\s*(\d+)', block)
p_min = re.search(r'spec-draft-p-min\s*=\s*([\d.]+)', block)
reasoning = re.search(r'reasoning\s*=\s*(\w+)', block)
spec_type = re.search(r'spec-type\s*=\s*(\S+)', block)
print(json.dumps({
    'n_max': int(n_max.group(1)) if n_max else None,
    'p_min': float(p_min.group(1)) if p_min else None,
    'reasoning': reasoning.group(1) if reasoning else 'off',
    'drafter': 'in-model' if spec_type and 'draft-mtp' in spec_type.group(1) else 'none',
}))
")

# Prompt size: if not specified, use 75% of ctx
if [ "$PROMPT_TOKENS" -eq 0 ]; then
  PROMPT_TOKENS=$((CTX * 3 / 4))
fi

log "Model: $MODEL | ctx: $CTX | batch: $BATCH | prompt: ${PROMPT_TOKENS} tokens"

# ── Prefill + decode bench ──
log ""
log "=== PREFILL + DECODE BENCH ==="
cd /mnt/md2/docker-containers/cortex && docker compose restart llama-cpp
sleep 5
log "  Restarted — model will load on first request"

# Generate payload
python3 -c "
import json
filler = 'The history of computing is long and complex. '
target_chars = $PROMPT_TOKENS * 4
prompt = ''
while len(prompt) < target_chars: prompt += filler
prompt = prompt[:target_chars]
payload = {'model':'$MODEL','messages':[{'role':'user','content':prompt}],'max_tokens':4000,'ignore_eos':True}
with open('/tmp/bench_payload.json','w') as f: json.dump(payload, f)
print(f'  Payload: {len(prompt)} chars, ~{$PROMPT_TOKENS} tokens')
"

log "  Firing request..."
curl -s --max-time 600 -X POST http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' -d @/tmp/bench_payload.json \
  > /tmp/bench_output.json 2>&1 &

# Poll CPU/GPU for 160s
log "  Polling CPU/GPU for 160s..."
CPU_SAMPLES=()
GPU_SAMPLES=()
for i in $(seq 1 80); do
  TOP=$(top -bn1 2>/dev/null | grep llama-s | head -n1)
  CPU=$(echo "$TOP" | awk '{print $9}' 2>/dev/null || echo "0")
  GPU=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
  TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
  POWER=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
  VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
  log "  $(date +%H:%M:%S) CPU: ${CPU:-0}% | GPU: ${GPU:-0}% | ${TEMP:-?}C | ${POWER:-?}W | VRAM: ${VRAM:-0}MiB"
  [ -n "$CPU" ] && [ "$CPU" != "0.0" ] && CPU_SAMPLES+=("$CPU")
  [ -n "$GPU" ] && GPU_SAMPLES+=("$GPU")
  sleep 2
done
wait 2>/dev/null

# Compute averages
CPU_SUM=0; CPU_CNT=0; GPU_SUM=0; GPU_CNT=0
for c in "${CPU_SAMPLES[@]}"; do CPU_SUM=$(echo "$CPU_SUM + $c" | bc); CPU_CNT=$((CPU_CNT+1)); done
for g in "${GPU_SAMPLES[@]}"; do GPU_SUM=$(echo "$GPU_SUM + $g" | bc); GPU_CNT=$((GPU_CNT+1)); done
AVG_CPU=$(echo "scale=1; $CPU_SUM / $CPU_CNT" | bc 2>/dev/null || echo "0")
AVG_GPU=$(echo "scale=1; $GPU_SUM / $GPU_CNT" | bc 2>/dev/null || echo "0")

# Hardware snapshot
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

# Extract speed
SPEED=$(python3 -c "
import json
try:
    d = json.load(open('/tmp/bench_output.json'))
    if 'choices' in d:
        t = d.get('timings', {}); u = d.get('usage', {})
        print(json.dumps({
            'decode_t_s': t.get('predicted_per_second', 0),
            'prefill_t_s': t.get('prompt_per_second', 0),
            'prefill_ms': t.get('prompt_ms', 0),
            'decode_ms': t.get('predicted_ms', 0),
            'prefill_ms_per_tok': t.get('prompt_per_token_ms', 0),
            'decode_ms_per_tok': t.get('predicted_per_token_ms', 0),
            'prompt_tokens': u.get('prompt_tokens', 0),
            'completion_tokens': u.get('completion_tokens', 0),
        }))
    else: print('{}')
except: print('{}')
")

log ""
log "=== RESULTS ==="
python3 -c "
import json; d=json.loads('''$SPEED''')
for k,v in d.items(): print(f'  {k}: {v}')
"
log "  placement: $PLACEMENT (avg_cpu: ${AVG_CPU}%, avg_gpu: ${AVG_GPU}%)"

# Write JSON
python3 -c "
import json, datetime
speed = json.loads('$SPEED')
meta = json.loads('''$META''')
data = {
    'model': '$MODEL', 'ctx': $CTX, 'batch': $BATCH, 'ubatch': $BATCH,
    'n_max': meta['n_max'], 'p_min': meta['p_min'],
    'drafter': meta['drafter'], 'reasoning': meta['reasoning'],
    'placement': '$PLACEMENT',
    'bench_date': datetime.datetime.now().isoformat(),
    'bench_method': 'bench_model.sh v1',
    'speed': speed, 'acceptance': None,
    'hardware': {
        'avg_cpu_pct': $AVG_CPU, 'avg_gpu_util_pct': $AVG_GPU,
        'gpu_temp_c': ${GPU_TEMP:-0}, 'gpu_power_w': ${GPU_POWER:-0},
        'vram_mib': ${VRAM:-0}, 'ram_mib': ${RAM:-0}, 'rss_mib': ${RSS:-0},
    }
}
with open('$JSON_FILE', 'w') as f: json.dump(data, f, indent=2)
"

log ""
log "JSON written to $JSON_FILE"
log "=== DONE: $MODEL ==="
