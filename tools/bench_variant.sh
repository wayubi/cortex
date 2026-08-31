#!/bin/bash
# Benchmark a llama-cpp model variant: decode speed, prefill speed, GPU/CPU placement
# Usage: ./tools/bench_variant.sh <model-name> <label> <prompt-tokens> [max-tokens] [vram-wait-seconds]
# Example: ./tools/bench_variant.sh qwen-3.6-35b-a3b-q4-mtp-16k "16k non-think" 12000
#
# Defaults: max-tokens=4000 (long decode reveals true placement)
# Placement: polls CPU for 160s after VRAM stabilizes, classifies GPU vs CPU

MODEL=$1
LABEL=$2
PROMPT_TOKENS=$3
MAX_TOKENS=${4:-4000}   # default 4000 for sustained decode
VRAM_WAIT=${5:-600}     # optional 5th arg: VRAM wait seconds (default 600 for first-run download)
OUTPUT=/tmp/bench_output.json
CPU_POLL_SAMPLES=80     # 80 samples × 2s = 160s polling
STABILIZE_DELAY=10      # seconds to wait after VRAM stabilizes before averaging CPU

if [ -z "$MODEL" ] || [ -z "$LABEL" ] || [ -z "$PROMPT_TOKENS" ]; then
  echo "Usage: $0 <model-name> <label> <prompt-tokens> [max-tokens] [vram-wait-seconds]"
  exit 1
fi

echo "=== RESTARTING: $LABEL ==="
cd /mnt/md2/docker-containers/cortex && docker compose restart llama-cpp
sleep 5

# Generate a filler prompt of N tokens (~4 chars per token for English)
FILLER="The history of computing is long and complex. "
PROMPT=""
TARGET_CHARS=$((PROMPT_TOKENS * 4))
while [ $(echo -n "$PROMPT" | wc -c) -lt $TARGET_CHARS ]; do
  PROMPT="${PROMPT}${FILLER}"
done
PROMPT=$(echo -n "$PROMPT" | head -c $TARGET_CHARS)

echo "=== FIRING REQUEST: $LABEL (prompt ~${PROMPT_TOKENS} tokens, max_tokens=${MAX_TOKENS}) ==="
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c "
import json, sys
prompt = open('/dev/stdin').read()
print(json.dumps({
    'model': '$MODEL',
    'messages': [{'role': 'user', 'content': prompt}],
    'max_tokens': $MAX_TOKENS,
    'ignore_eos': True
}))
" <<< "$PROMPT")" > "$OUTPUT" 2>&1 &
PID=$!

# Wait for VRAM > 2GB (model loaded into GPU)
# First run may need to download the model — use VRAM_WAIT (default 600s)
echo "Waiting for model to load (timeout ${VRAM_WAIT}s)..."
VRAM_STABILIZED=0
VRAM_PREV=0
for i in $(seq 1 $VRAM_WAIT); do
  VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader | tr -d ' MiB')
  if [ "$VRAM" -gt 2000 ] 2>/dev/null && [ "$VRAM_STABILIZED" -eq 0 ]; then
    # VRAM jumped — model started loading, wait for it to stabilize
    if [ "$VRAM" = "$VRAM_PREV" ]; then
      VRAM_STABILIZED=1
      echo "Model loaded: ${VRAM} MiB (VRAM stable)"
    fi
    VRAM_PREV=$VRAM
  fi
  if [ $((i % 30)) -eq 0 ]; then
    echo "  still waiting... (${i}s, VRAM: ${VRAM:-0} MiB)"
  fi
  sleep 1
done

# If VRAM never stabilized (timeout), report current VRAM
if [ "$VRAM_STABILIZED" -eq 0 ]; then
  VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader | tr -d ' MiB')
  echo "VRAM timeout: ${VRAM:-0} MiB"
fi

# Sample CPU with top every 2s during decode
# Phase 1: Collect raw samples for 160s
echo "=== SAMPLING CPU FOR ${CPU_POLL_SAMPLES} SAMPLES (${CPU_POLL_SAMPLES}x2s = $((CPU_POLL_SAMPLES * 2))s) ==="
CPU_SAMPLES=()
VRAM_SAMPLES=()
for i in $(seq 1 $CPU_POLL_SAMPLES); do
  TOP_LINE=$(top -bn1 | grep llama-s | head -n1)
  CPU=$(echo "$TOP_LINE" | awk '{print $9}')
  VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader)
  echo "$(date +%H:%M:%S) CPU: ${CPU}% | VRAM: ${VRAM}"
  CPU_SAMPLES+=("$CPU")
  VRAM_SAMPLES+=("$VRAM")
  sleep 2
done

# Phase 2: Wait for request to complete, extract results
wait $PID 2>/dev/null

# Phase 3: Compute average CPU from the point where VRAM stabilized
# Skip first 10 samples (warmup), average the rest
AVG_START=10
CPU_SUM=0
CPU_COUNT=0
for i in $(seq $AVG_START $((${#CPU_SAMPLES[@]} - 1))); do
  VAL="${CPU_SAMPLES[$i]}"
  if [ -n "$VAL" ] && [ "$VAL" != "0.0" ]; then
    CPU_SUM=$(echo "$CPU_SUM + $VAL" | bc)
    CPU_COUNT=$((CPU_COUNT + 1))
  fi
done
if [ "$CPU_COUNT" -gt 0 ]; then
  AVG_CPU=$(echo "scale=1; $CPU_SUM / $CPU_COUNT" | bc)
else
  AVG_CPU="0"
fi

# Phase 4: Classify placement
# GPU: sustained CPU < 100% (model compute on GPU, only host overhead)
# CPU: sustained CPU > 200% (model compute on CPU)
# Ambiguous: 100-200% (need manual check)
if (( $(echo "$AVG_CPU < 100" | bc -l) )); then
  PLACEMENT="GPU"
elif (( $(echo "$AVG_CPU > 200" | bc -l) )); then
  PLACEMENT="CPU"
else
  PLACEMENT="AMBIGUOUS"
fi

# Check for OOM in logs
OOM=$(docker logs --since 2m cortex-llama-cpp-1 2>&1 | grep -ci "cudaMalloc failed\|out of memory\|exiting due to")
if [ "$OOM" -gt 0 ]; then
  echo "=== OOM DETECTED ==="
  docker logs --since 2m cortex-llama-cpp-1 2>&1 | grep -i "cudaMalloc failed\|out of memory\|exiting due to" | tail -5
fi

# Extract REAL prefill + decode from response
echo "=== RESULTS: $LABEL ==="
python3 -c "
import json
d = json.load(open('$OUTPUT'))
if 'choices' in d:
    t = d.get('timings', {})
    u = d.get('usage', {})
    print(f'prefill={t.get(\"prompt_per_second\",0):.0f} t/s decode={t.get(\"predicted_per_second\",0):.1f} t/s prompt_tokens={u.get(\"prompt_tokens\",\"?\")} completion_tokens={u.get(\"completion_tokens\",\"?\")}')
else:
    print('ERROR: ' + json.dumps(d)[:200])
"
echo "=== PLACEMENT: ${PLACEMENT} (avg CPU ${AVG_CPU}% from sample ${AVG_START}+, ${CPU_COUNT} samples) ==="
echo "=== DONE: $LABEL ==="
