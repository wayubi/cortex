# How to bench llama-server correctly (CPU + prefill + decode)

## Problem 1: CPU sampling timing
The model doesn't load into VRAM until the first request arrives. If you `sleep` too long or sample before the request, you're measuring idle time, not decode.

## Problem 2: Prefill measurement
A short prompt (~12 tokens) produces garbage prefill numbers (~30-55 t/s) that are just setup overhead, not actual prefill throughput. **Always use a long prompt sized to the model's ctx.**

## Correct procedure

```bash
MODEL=$1
LABEL=$2
PROMPT_TOKENS=$3   # ~75% of ctx-size (e.g. 12000 for 16k ctx)
MAX_TOKENS=$4      # leave room for output (e.g. 1000)

# 1. Generate a filler prompt of N tokens
FILLER="The history of computing is long and complex. "
PROMPT=""
while [ $(echo -n "$PROMPT" | wc -c) -lt $((PROMPT_TOKENS * 4)) ]; do
  PROMPT="$PROMPT$FILLER"
done
PROMPT=$(echo -n "$PROMPT" | head -c $((PROMPT_TOKENS * 4)))

# 2. Fire the request FIRST (background)
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$PROMPT\"}],\"max_tokens\":$MAX_TOKENS,\"ignore_eos\":true}" > /tmp/bench_output.json 2>&1 &
PID=$!

# 3. Wait for VRAM > 2000 MiB (model loaded into GPU)
for i in $(seq 1 60); do
  VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader | tr -d ' MiB')
  if [ "$VRAM" -gt 2000 ] 2>/dev/null; then
    echo "Model loaded: ${VRAM} MiB"
    break
  fi
  sleep 1
done

# 4. Sample CPU with top (NOT ps) every 2s during decode
for i in $(seq 1 25); do
  TOP_LINE=$(top -bn1 | grep llama-s | head -n1)
  CPU=$(echo "$TOP_LINE" | awk '{print $9}')
  VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader)
  echo "$(date +%H:%M:%S) CPU: ${CPU}% | VRAM: ${VRAM}"
  sleep 2
done
wait $PID 2>/dev/null

# 5. Extract REAL prefill + decode from response
python3 -c "
import json
d = json.load(open('/tmp/bench_output.json'))
if 'choices' in d:
    t = d.get('timings', {})
    u = d.get('usage', {})
    print(f'prefill={t.get(\"prompt_per_second\",0):.0f} t/s decode={t.get(\"predicted_per_second\",0):.1f} t/s prompt_tokens={u.get(\"prompt_tokens\",\"?\")} completion_tokens={u.get(\"completion_tokens\",\"?\")}')
else:
    print('ERROR: ' + json.dumps(d)[:200])
"
```

## Key rules

1. **Fire request FIRST** — model loads on first request, not at container start
2. **Wait for VRAM > 2GB** — confirms model weights are loaded
3. **Use `top -bn1 | grep llama-s | head -n1`** — `ps -o %cpu=` gives instantaneous snapshot and can miss spikes
4. **Sample every 2s** — fast enough to catch decode CPU, slow enough to not spam
5. **Draft on GPU** = CPU < 100% during decode; **Draft on CPU** = CPU > 200% during decode
6. **PREFILL BENCHMARK: prompt MUST be long** — ~75% of ctx-size tokens. A 12-token prompt gives garbage prefill numbers (~30-55 t/s) that are just setup overhead. Real prefill with a long prompt is 1000+ t/s.
7. **Prompt size per variant** — 4k ctx → 3000 tokens, 8k ctx → 6000 tokens, 16k ctx → 12000 tokens
8. **Don't assume prefill numbers are comparable across different prompt sizes** — only compare prefill within the same prompt size (same ctx variant)

## What went wrong before

| Mistake | Result |
|---|---|
| `sleep 15` before request | Sampled during idle, not decode |
| `sleep 5` after request start | Caught prefill/warmup, not steady decode |
| `ps -o %cpu=` | Instantaneous snapshot, missed the decode phase |
| Sampling after `wait $PID` | Request already finished, 0% CPU |
| `sleep 30` before request | Model wasn't loaded yet, no decode happening |
| 12-token prompt for prefill | Garbage numbers (~30-55 t/s), just setup overhead |
| Comparing prefill across ctx sizes | Different prompt sizes = not comparable |
