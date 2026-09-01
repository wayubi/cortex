# How to bench llama-server correctly (CPU + prefill + decode)

## Problem 1: CPU sampling timing
The model doesn't load into VRAM until the first request arrives. If you `sleep` too long or sample before the request, you're measuring idle time, not decode.

## Problem 2: Prefill measurement
A short prompt (~12 tokens) produces garbage prefill numbers (~30-55 t/s) that are just setup overhead, not actual prefill throughput. **Always use a long prompt sized to the model's ctx.**

## Problem 3: GPU/CPU placement verification (CRITICAL)
**A short decode (1000 tokens) with 50s polling is NOT enough to verify GPU placement.** Models show ~100% CPU in the first 50s, then spike to 1300%+ after. This caused false "GPU" classifications.

**Correct procedure:**
- Use `max_tokens=4000` (sustained decode, ~160s)
- Poll CPU for 80 samples × 2s = 160 seconds
- Average CPU from sample 10+ (skip warmup)
- Classify: avg CPU < 100% = **GPU**, avg CPU > 200% = **CPU**, 100-200% = **AMBIGUOUS**

**Example of the trap:**
```
08:20:35 CPU: 97.6%  | VRAM: 8561 MiB  — first 50s: looks like GPU
08:20:41 CPU: 84.8%  | VRAM: 10927 MiB — still looks like GPU
08:20:44 CPU: 98.1%  | VRAM: 10927 MiB — still looks like GPU
...
08:29:41 CPU: 786.2% | VRAM: 10865 MiB — 10 MINUTES LATER: CPU spikes
08:29:43 CPU: 1390%  | VRAM: 10881 MiB — definitely CPU, not GPU
```

## Key rules

1. **Fire request FIRST** — model loads on first request, not at container start
2. **Wait for VRAM > 2GB** — confirms model weights are loaded
3. **Use `top -bn1 | grep llama-s | head -n1`** — `ps -o %cpu=` gives instantaneous snapshot and can miss spikes
4. **Default max_tokens=4000** — long decode reveals true placement
5. **Poll CPU for 160s** — 80 samples × 2s. Never use 50s.
6. **Placement classification** — average CPU from sample 10+: <100% = GPU, >200% = CPU, 100-200% = AMBIGUOUS
7. **Coder variants are independent models** — bench them separately, no copying between entries
8. **PREFILL BENCHMARK: prompt MUST be long** — ~75% of ctx-size tokens. A 12-token prompt gives garbage prefill numbers (~30-55 t/s) that are just setup overhead.
9. **Prompt size per variant** — 4k ctx → 3000 tokens, 8k ctx → 6000 tokens, 16k ctx → 12000 tokens
10. **Don't assume prefill numbers are comparable across different prompt sizes** — only compare prefill within the same prompt size (same ctx variant)

## What went wrong before

| Mistake | Result |
|---|---|
| 1000-token decode with 50s polling | CPU looked like ~100% (GPU), actually 1300% (CPU) |
| `sleep 15` before request | Sampled during idle, not decode |
| `sleep 5` after request start | Caught prefill/warmup, not steady decode |
| `ps -o %cpu=` | Instantaneous snapshot, missed the decode phase |
| Sampling after `wait $PID` | Request already finished, 0% CPU |
| `sleep 30` before request | Model wasn't loaded yet, no decode happening |
| 12-token prompt for prefill | Garbage numbers (~30-55 t/s), just setup overhead |
| Comparing prefill across ctx sizes | Different prompt sizes = not comparable |
| Using max_tokens=1000 | Decode too short, placement not revealed |
| Polling only 25 samples (50s) | CPU spike after 50s missed |
