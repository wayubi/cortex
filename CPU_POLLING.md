# How to poll CPU usage for llama-server correctly

## The problem
The model doesn't load into VRAM until the first request arrives. If you `sleep` too long or sample before the request, you're measuring idle time, not decode.

## Correct procedure

```bash
# 1. Fire the request FIRST (background)
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<model>","messages":[{"role":"user","content":"..."}],"max_tokens":4000,"ignore_eos":true}' > /dev/null 2>&1 &
PID=$!

# 2. Wait for VRAM > 2000 MiB (model loaded into GPU)
for i in $(seq 1 60); do
  VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader | tr -d ' MiB')
  if [ "$VRAM" -gt 2000 ] 2>/dev/null; then
    echo "Model loaded: ${VRAM} MiB"
    break
  fi
  sleep 1
done

# 3. Sample CPU with top (NOT ps) every 2s
for i in $(seq 1 25); do
  TOP_LINE=$(top -bn1 | grep llama-s | head -n1)
  CPU=$(echo "$TOP_LINE" | awk '{print $9}')
  VRAM=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader)
  echo "$(date +%H:%M:%S) CPU: ${CPU}% | VRAM: ${VRAM}"
  sleep 2
done
wait $PID 2>/dev/null
```

## Key rules

1. **Fire request FIRST** — model loads on first request, not at container start
2. **Wait for VRAM > 2GB** — confirms model weights are loaded
3. **Use `top -bn1 | grep llama-s | head -n1`** — `ps -o %cpu=` gives instantaneous snapshot and can miss spikes; `top -bn1` gives a 1-second average
4. **Sample every 2s** — fast enough to catch decode CPU, slow enough to not spam
5. **Decode runs for ~90-120s** at 4000 tokens — sample for at least 30 samples (60s)
6. **Draft on GPU** = CPU < 100% during decode; **Draft on CPU** = CPU > 200% during decode

## What went wrong before

| Mistake | Result |
|---|---|
| `sleep 15` before request | Sampled during idle, not decode |
| `sleep 5` after request start | Caught prefill/warmup, not steady decode |
| `ps -o %cpu=` | Instantaneous snapshot, missed the decode phase |
| Sampling after `wait $PID` | Request already finished, 0% CPU |
| `sleep 30` before request | Model wasn't loaded yet, no decode happening |
