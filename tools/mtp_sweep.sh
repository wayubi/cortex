#!/bin/bash
# MTP n_max sweep for a given model entry
# Usage: ./tools/mtp_sweep.sh <model-name> <label> <prompt-tokens> <max-tokens>
# Example: ./tools/mtp_sweep.sh gemma-4-26b-a4b-q4-qat-mtp-16k "16k non-think" 12000 1000

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL=$1
LABEL=$2
PROMPT_TOKENS=$3
MAX_TOKENS=$4
INI="$ROOT/llama-cpp/models.ini"
LOG="/tmp/mtp_sweep_${MODEL}.log"

if [ -z "$MODEL" ] || [ -z "$LABEL" ] || [ -z "$PROMPT_TOKENS" ] || [ -z "$MAX_TOKENS" ]; then
  echo "Usage: $0 <model-name> <label> <prompt-tokens> <max-tokens>"
  exit 1
fi

# Generate filler prompt
FILLER="The history of computing is long and complex. "
PROMPT=""
TARGET_CHARS=$((PROMPT_TOKENS * 4))
while [ $(echo -n "$PROMPT" | wc -c) -lt $TARGET_CHARS ]; do
  PROMPT="${PROMPT}${FILLER}"
done
PROMPT=$(echo -n "$PROMPT" | head -c $TARGET_CHARS)

echo "=== MTP n_max SWEEP: $LABEL ===" | tee "$LOG"

for N_MAX in 1 2 3 4 5; do
  echo "" | tee -a "$LOG"
  echo "=== n_max=$N_MAX, p_min=0.7 ===" | tee -a "$LOG"

  # Update models.ini: set spec-draft-n-max for this entry
  sed -i "/^\[$MODEL\]/,/^\[/ s/spec-draft-n-max = .*/spec-draft-n-max = $N_MAX/" "$INI"

  # Restart
  cd "$ROOT" && docker compose restart llama-cpp
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
  OUTPUT="/tmp/mtp_nmax_${N_MAX}.json"
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

  # Sample CPU
  for i in $(seq 1 25); do
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
    print(f'  n_max=$N_MAX: decode={t.get(\"predicted_per_second\",0):.1f} t/s prompt_tokens={u.get(\"prompt_tokens\",\"?\")} completion_tokens={u.get(\"completion_tokens\",\"?\")}')
" 2>/dev/null | tee -a "$LOG"

  # Check logs for acceptance rate
  ACCEPT=$(docker logs --since 3m cortex-llama-cpp-1 2>&1 | grep -o "draft acceptance = [0-9.]*" | tail -1)
  if [ -n "$ACCEPT" ]; then
    echo "  $ACCEPT" | tee -a "$LOG"
  fi

  # Check for OOM
  OOM=$(docker logs --since 3m cortex-llama-cpp-1 2>&1 | grep -ci "cudaMalloc failed\|out of memory")
  if [ "$OOM" -gt 0 ]; then
    echo "  *** OOM DETECTED ***" | tee -a "$LOG"
  fi
done

echo "" | tee -a "$LOG"
echo "=== SWEEP COMPLETE ===" | tee -a "$LOG"
