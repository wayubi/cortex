#!/bin/bash
# Benchmark a llama-cpp model variant: decode speed, prefill speed, CPU placement
# Usage: ./tools/bench_variant.sh <model-name> <label> <prompt-tokens> <max-tokens>
# Example: ./tools/bench_variant.sh gemma-4-26b-a4b-q4-qat-mtp-16k "16k non-think" 12000 1000

MODEL=$1
LABEL=$2
PROMPT_TOKENS=$3
MAX_TOKENS=$4
OUTPUT=/tmp/bench_output.json
VRAM_WAIT=${5:-600} # optional 5th arg: VRAM wait seconds (default 600 for first-run download)

if [ -z "$MODEL" ] || [ -z "$LABEL" ] || [ -z "$PROMPT_TOKENS" ] || [ -z "$MAX_TOKENS" ]; then
  echo "Usage: $0 <model-name> <label> <prompt-tokens> <max-tokens> [vram-wait-seconds]"
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

echo "=== FIRING REQUEST: $LABEL (prompt ~${PROMPT_TOKENS} tokens) ==="
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

# Sample CPU with top every 2s during decode
echo "=== SAMPLING CPU DURING DECODE ==="
for i in $(seq 1 25); do
  TOP_LINE=$(top -bn1 | grep llama-s | head -n1)
  CPU=$(echo "$TOP_LINE" | awk '{print $9}')
  VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader)
  echo "$(date +%H:%M:%S) CPU: ${CPU}% | VRAM: ${VRAM}"
  sleep 2
done
wait $PID 2>/dev/null

# Check for OOM in logs
OOM=$(docker logs --since 2m cortex-llama-cpp-1 2>&1 | grep -ci "cudaMalloc failed\|failed to allocate\|out of memory\|exiting due to")
if [ "$OOM" -gt 0 ]; then
  echo "=== OOM DETECTED ==="
  docker logs --since 2m cortex-llama-cpp-1 2>&1 | grep -i "cudaMalloc failed\|failed to allocate\|out of memory\|exiting due to" | tail -5
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
echo "=== DONE: $LABEL ==="
