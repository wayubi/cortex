#!/bin/bash
# Batch sweep for LFM2.5 variants
# Usage: ./tools/lfm_batch_sweep.sh <model-name> <label> <ctx-size>
# Tests batch sizes 4096, 8192, 16384, 24576

MODEL=$1
LABEL=$2
CTX=$3
INI="/mnt/md2/docker-containers/cortex/llama-cpp/models.ini"
LOG="/tmp/lfm_batch_sweep_${MODEL}.log"

if [ -z "$MODEL" ] || [ -z "$LABEL" ] || [ -z "$CTX" ]; then
  echo "Usage: $0 <model-name> <label> <ctx-size>"
  exit 1
fi

# Prompt sized to ~75% of ctx
PROMPT_TOKENS=$((CTX * 3 / 4))
FILLER="The history of computing is long and complex. "
PROMPT=""
TARGET_CHARS=$((PROMPT_TOKENS * 4))
while [ $(echo -n "$PROMPT" | wc -c) -lt $TARGET_CHARS ]; do
  PROMPT="${PROMPT}${FILLER}"
done
PROMPT=$(echo -n "$PROMPT" | head -c $TARGET_CHARS)

echo "=== BATCH SWEEP: $LABEL (ctx=$CTX, prompt ~${PROMPT_TOKENS} tokens) ===" | tee "$LOG"

for BATCH in 4096 8192 16384 24576; do
  echo "" | tee -a "$LOG"
  echo "=== batch=$BATCH ===" | tee -a "$LOG"

  # Update models.ini
  sed -i "/^\[$MODEL\]/,/^\[/ s/batch-size\s*= .*/batch-size        = $BATCH/" "$INI"
  sed -i "/^\[$MODEL\]/,/^\[/ s/ubatch-size\s*= .*/ubatch-size       = $BATCH/" "$INI"

  # Restart
  cd /mnt/md2/docker-containers/cortex && docker compose restart llama-cpp
  sleep 5

  # Wait for VRAM
  for i in $(seq 1 120); do
    VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader | tr -d ' MiB')
    if [ "$VRAM" -gt 2000 ] 2>/dev/null; then
      echo "  Model loaded: ${VRAM} MiB" | tee -a "$LOG"
      break
    fi
    sleep 1
  done

  # Fire request
  OUTPUT="/tmp/lfm_batch_${BATCH}.json"
  curl -s -X POST http://localhost:8080/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c "
import json, sys
prompt = open('/dev/stdin').read()
print(json.dumps({
    'model': '$MODEL',
    'messages': [{'role': 'user', 'content': prompt}],
    'max_tokens': 1000,
    'ignore_eos': True
}))
" <<< "$PROMPT")" > "$OUTPUT" 2>&1 &

  # Sample CPU
  for i in $(seq 1 20); do
    TOP_LINE=$(top -bn1 | grep llama-s | head -n1)
    CPU=$(echo "$TOP_LINE" | awk '{print $9}')
    VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader)
    echo "  $(date +%H:%M:%S) CPU: ${CPU}% | VRAM: ${VRAM}" | tee -a "$LOG"
    sleep 2
  done
  wait

  # Extract results
  python3 -c "
import json
d = json.load(open('$OUTPUT'))
if 'choices' in d:
    t = d.get('timings', {})
    u = d.get('usage', {})
    print(f'  batch=$BATCH: decode={t.get(\"predicted_per_second\",0):.1f} t/s prefill={t.get(\"prompt_per_second\",0):.0f} t/s prompt_tokens={u.get(\"prompt_tokens\",\"?\")}')
" 2>/dev/null | tee -a "$LOG"

  # Check for OOM
  OOM=$(docker logs --since 3m cortex-llama-cpp-1 2>&1 | grep -ci "cudaMalloc failed\|out of memory")
  if [ "$OOM" -gt 0 ]; then
    echo "  *** OOM DETECTED ***" | tee -a "$LOG"
  fi
done

echo "" | tee -a "$LOG"
echo "=== SWEEP COMPLETE ===" | tee -a "$LOG"
