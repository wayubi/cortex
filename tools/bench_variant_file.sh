#!/bin/bash
# Benchmark with file-based payload (handles large prompts)
# Usage: ./tools/bench_variant_file.sh <model-name> <label> <prompt-tokens> [max-tokens] [vram-wait-seconds]
# Example: ./tools/bench_variant_file.sh glm-4.7-30b-a3b-flash-q4-64k "64k non-think" 40000
#
# Captures: CPU%, GPU util%, GPU temp, GPU power, VRAM, system RAM, process RSS
# Placement: polls for 160s, classifies GPU vs CPU based on sustained CPU

MODEL=$1
LABEL=$2
PROMPT_TOKENS=$3
MAX_TOKENS=${4:-4000}   # default 4000 for sustained decode
VRAM_WAIT=${5:-600}
PAYLOAD=/tmp/bench_payload.json
OUTPUT=/tmp/bench_output.json
CPU_POLL_SAMPLES=80     # 80 samples × 2s = 160s polling

if [ -z "$MODEL" ] || [ -z "$LABEL" ] || [ -z "$PROMPT_TOKENS" ]; then
  echo "Usage: $0 <model-name> <label> <prompt-tokens> [max-tokens] [vram-wait-seconds]"
  exit 1
fi

# Pre-flight check: verify batch-size is explicitly set in models.ini
BATCH_CHECK=$(grep -A 20 "\[$MODEL\]" /mnt/md2/docker-containers/cortex/llama-cpp/models.ini | grep -c "batch-size")
if [ "$BATCH_CHECK" -eq 0 ]; then
  echo "WARNING: $MODEL has no explicit batch-size in models.ini — inherits default 4096 from [*]"
  echo "This is WRONG. Run batch bisect first: AGENTS.md 'Stress-testing batch/ubatch'"
  echo "Continuing anyway (results may be unreliable)..."
fi

echo "=== RESTARTING: $LABEL ==="
cd /mnt/md2/docker-containers/cortex && docker compose restart llama-cpp
sleep 5

# Generate payload via python (handles large prompts without arg length issues)
python3 -c "
import json
filler = 'The history of computing is long and complex. '
target_chars = $PROMPT_TOKENS * 4
prompt = ''
while len(prompt) < target_chars:
    prompt += filler
prompt = prompt[:target_chars]
payload = {
    'model': '$MODEL',
    'messages': [{'role': 'user', 'content': prompt}],
    'max_tokens': $MAX_TOKENS,
    'ignore_eos': True
}
with open('$PAYLOAD', 'w') as f:
    json.dump(payload, f)
print(f'Payload written: {len(prompt)} chars, ~{$PROMPT_TOKENS} tokens')
"

echo "=== FIRING REQUEST: $LABEL (max_tokens=${MAX_TOKENS}) ==="
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d @"$PAYLOAD" > "$OUTPUT" 2>&1 &
PID=$!

# Wait for VRAM > 2GB
echo "Waiting for model to load (timeout ${VRAM_WAIT}s)..."
for i in $(seq 1 $VRAM_WAIT); do
  VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader | tr -d ' MiB')
  if [ "$VRAM" -gt 2000 ] 2>/dev/null; then
    echo "Model loaded: ${VRAM} MiB"
    break
  fi
  if [ $((i % 30)) -eq 0 ]; then
    echo "  still waiting... (${i}s, VRAM: ${VRAM:-0} MiB)"
  fi
  sleep 1
done

# Sample CPU, GPU, RAM for 160s
echo "=== SAMPLING FOR ${CPU_POLL_SAMPLES} SAMPLES (${CPU_POLL_SAMPLES}x2s = $((CPU_POLL_SAMPLES * 2))s) ==="
echo "$(date +%H:%M:%S) | CPU% | GPU% | GPU_Temp | GPU_W | VRAM | RAM_Used | RSS_MB"
CPU_SAMPLES=()
GPU_UTIL_SAMPLES=()
for i in $(seq 1 $CPU_POLL_SAMPLES); do
  # CPU from top
  TOP_LINE=$(top -bn1 | grep llama-s | head -n1)
  CPU=$(echo "$TOP_LINE" | awk '{print $9}')

  # GPU metrics
  GPU_INFO=$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,power.draw,memory.used --format=csv,noheader,nounits)
  GPU_UTIL=$(echo "$GPU_INFO" | cut -d',' -f1 | tr -d ' ')
  GPU_TEMP=$(echo "$GPU_INFO" | cut -d',' -f2 | tr -d ' ')
  GPU_POWER=$(echo "$GPU_INFO" | cut -d',' -f3 | tr -d ' ')
  VRAM=$(echo "$GPU_INFO" | cut -d',' -f4 | tr -d ' ')

  # System RAM (used in MB)
  RAM_USED=$(free -m | awk '/Mem:/ {print $3}')

  # Process RSS (llama-server, in MB)
  RSS_MB=$(ps aux | grep "llama-server" | grep -v grep | grep -v "models-preset" | awk '{print int($6/1024)}' | head -1)

  echo "$(date +%H:%M:%S) | ${CPU}% | ${GPU_UTIL}% | ${GPU_TEMP}C | ${GPU_POWER}W | ${VRAM}MiB | ${RAM_USED}MiB | ${RSS_MB}MiB"
  CPU_SAMPLES+=("$CPU")
  GPU_UTIL_SAMPLES+=("$GPU_UTIL")
  sleep 2
done

wait $PID 2>/dev/null

# Average CPU from sample 10+ (skip warmup)
AVG_START=10
CPU_SUM=0
CPU_COUNT=0
GPU_UTIL_SUM=0
GPU_UTIL_COUNT=0
for i in $(seq $AVG_START $((${#CPU_SAMPLES[@]} - 1))); do
  C_VAL="${CPU_SAMPLES[$i]}"
  G_VAL="${GPU_UTIL_SAMPLES[$i]}"
  if [ -n "$C_VAL" ] && [ "$C_VAL" != "0.0" ]; then
    CPU_SUM=$(echo "$CPU_SUM + $C_VAL" | bc)
    CPU_COUNT=$((CPU_COUNT + 1))
  fi
  if [ -n "$G_VAL" ]; then
    GPU_UTIL_SUM=$(echo "$GPU_UTIL_SUM + $G_VAL" | bc)
    GPU_UTIL_COUNT=$((GPU_UTIL_COUNT + 1))
  fi
done
if [ "$CPU_COUNT" -gt 0 ]; then
  AVG_CPU=$(echo "scale=1; $CPU_SUM / $CPU_COUNT" | bc)
else
  AVG_CPU="0"
fi
if [ "$GPU_UTIL_COUNT" -gt 0 ]; then
  AVG_GPU_UTIL=$(echo "scale=1; $GPU_UTIL_SUM / $GPU_UTIL_COUNT" | bc)
else
  AVG_GPU_UTIL="0"
fi

# Classify placement
if (( $(echo "$AVG_CPU < 100" | bc -l) )); then
  PLACEMENT="GPU"
elif (( $(echo "$AVG_CPU > 200" | bc -l) )); then
  PLACEMENT="CPU"
else
  PLACEMENT="AMBIGUOUS"
fi

# Check for OOM
OOM=$(docker logs --since 2m cortex-llama-cpp-1 2>&1 | grep -ci "cudaMalloc failed\|out of memory\|exiting due to")
if [ "$OOM" -gt 0 ]; then
  echo "=== OOM DETECTED ==="
  docker logs --since 2m cortex-llama-cpp-1 2>&1 | grep -i "cudaMalloc failed\|out of memory\|exiting due to" | tail -5
fi

# Extract results
echo "=== RESULTS: $LABEL ==="
python3 -c "
import json
d = json.load(open('$OUTPUT'))
if 'choices' in d:
    t = d.get('timings', {})
    u = d.get('usage', {})
    print(f'prefill={t.get(\"prompt_per_second\",0):.0f} t/s decode={t.get(\"predicted_per_second\",0):.1f} t/s')
    print(f'prefill_total={t.get(\"prompt_ms\",0):.0f}ms decode_total={t.get(\"predicted_ms\",0):.0f}ms')
    print(f'prefill_per_token={t.get(\"prompt_per_token_ms\",0):.2f}ms/token decode_per_token={t.get(\"predicted_per_token_ms\",0):.2f}ms/token')
    print(f'prompt_tokens={u.get(\"prompt_tokens\",\"?\")} completion_tokens={u.get(\"completion_tokens\",\"?\")} total_tokens={u.get(\"total_tokens\",\"?\")}')
    print(f'cache_hits={t.get(\"cache_n\",0)}')
else:
    print('ERROR: ' + json.dumps(d)[:200])
"
echo "=== PLACEMENT: ${PLACEMENT} (avg CPU ${AVG_CPU}%, avg GPU util ${AVG_GPU_UTIL}%) ==="
echo "=== DONE: $LABEL ==="
