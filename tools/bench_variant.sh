#!/bin/bash
# Benchmark a llama-cpp model variant: decode speed, prefill speed, CPU placement
# Usage: ./tools/bench_variant.sh <model-name> <label>
# Example: ./tools/bench_variant.sh qwen3.6-35b-q4-mtp-4k "4k non-think"

MODEL=$1
LABEL=$2
OUTPUT=/tmp/bench_output.json

if [ -z "$MODEL" ] || [ -z "$LABEL" ]; then
  echo "Usage: $0 <model-name> <label>"
  exit 1
fi

echo "=== RESTARTING: $LABEL ==="
cd /mnt/md2/docker-containers/cortex && docker compose restart llama-cpp
sleep 5

# Fire request (triggers model load)
echo "=== FIRING REQUEST: $LABEL ==="
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a detailed essay explaining the history of computing.\"}],\"max_tokens\":4000,\"ignore_eos\":true}" > "$OUTPUT" 2>&1 &
PID=$!

# Wait for VRAM > 2GB (model loaded into GPU)
echo "Waiting for model to load..."
for i in $(seq 1 60); do
  VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader | tr -d ' MiB')
  if [ "$VRAM" -gt 2000 ] 2>/dev/null; then
    echo "Model loaded: ${VRAM} MiB"
    break
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

# Extract speeds from saved output
python3 -c "
import json
d = json.load(open('$OUTPUT'))
if 'choices' in d:
    t = d.get('timings', {})
    u = d.get('usage', {})
    print(f'RESULTS: prompt={u.get(\"prompt_tokens\",\"?\")}t completion={u.get(\"completion_tokens\",\"?\")}t prefill={t.get(\"prompt_per_second\",0):.0f} t/s decode={t.get(\"predicted_per_second\",0):.1f} t/s')
else:
    print('ERROR: ' + json.dumps(d)[:200])
"
echo "=== DONE: $LABEL ==="
