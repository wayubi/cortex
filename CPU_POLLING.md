# How to bench llama-server correctly (CPU + prefill + decode)

**What this file is for.** The measurement constants in `tools/bench.sh` look arbitrary until you know what they cost to learn. This is that record: each rule below was paid for by a wrong benchmark, and each one is still enforced somewhere in the script. Before "optimising" a poll window, a decode length or a prompt size, read the failure it was chosen to prevent.

The procedure itself is automated. You do not run these steps by hand; `bench.sh` does. See `AGENTS.md` for the current pipeline.

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
- Classify from the average (see rule 6 for the current thresholds)

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

Each rule names where it is enforced, so a change to the code can be checked against the reason for the rule.

1. **Fire the request FIRST** — the model loads on the first request, not at container start. *(`fire_request`, used by every probe.)*
2. ~~Wait for VRAM > 2GB to confirm weights are loaded.~~ **Superseded.** Readiness is now detected from the router's `proxy_reques` log line, which is a direct signal that the request is being served rather than a proxy for it. *(`wait_served`.)*
3. **Use `top -bn1 | grep llama-s | head -n1`** — `ps -o %cpu=` gives an instantaneous snapshot and can miss spikes. *(`residency_probe`, `decode_sample`, `cmd_bench`.)*
4. **Default `max_tokens=4000`** — a long decode reveals true placement. Clamped to the context size on small-ctx models. *(`decode_sample`, `cmd_bench`.)*
5. **Poll for 160s** — 80 samples × 2s. Never use 50s. *(`POLL_MAX_SAMPLES=80`.)* Note the poll is a monitor only; a `wait` after it blocks with no cap until the request actually finishes.
6. **Placement classification is BINARY** — there is no ambiguous verdict. `classify_placement` returns CPU when the process is above 200%, GPU when it is below `GPU_CPU_MAX` (150%) with GPU utilisation above 25%, and otherwise decides on GPU utilisation alone. *(Shared by `residency_probe`, `decode_sample` and `cmd_bench`.)*
   **This replaces the old three-way rule** (<100% GPU, >200% CPU, 100-200% AMBIGUOUS). The 100% threshold was wrong: a GPU-resident llama.cpp keeps exactly one host thread busy feeding the GPU, so it reads 100-110% and was being classified as ambiguous. A real spill measures 270-1600%.
7. **Coder and think variants INHERIT from their family head** — they are not benched separately. A family is every entry sharing the same `hf` and the same `ctx-size`. *(`family_of`, `inherit_json`, `maybe_inherit`.)*
   **This reverses the old rule** ("bench them separately, no copying"), which predated family inheritance. Sampling parameters, the reasoning toggle and the chat template do not change throughput. The exception is near the memory ceiling, where `reasoning = on` has sustained a slightly larger batch than `off` on the same GGUF and ctx; bench those with `--no-inherit`.
8. **PREFILL BENCHMARK: the prompt MUST be long** — ~75% of ctx-size tokens. A 12-token prompt gives garbage numbers (~30-55 t/s) that are just setup overhead. *(`cmd_bench` Phase A.)*
9. **Prompt size per variant** — 4k ctx → 3000 tokens, 8k ctx → 6000, 16k ctx → 12000.
10. **Don't compare prefill numbers across different prompt sizes** — prefill throughput falls as the prompt grows, so only compare within the same prompt size. *(This is why the discover ladder probes every batch of one model with a single fixed prompt length, `min(0.75 × ctx, 16384)` tokens: the rungs must rank on identical work.)*
11. **Warm up before timing, and take a median on fast probes** — the first prefill at a new ubatch shape pays a one-time setup cost, and it weighs more on larger ubatches. Measuring without a warm-up biased every ladder against the larger batch. *(`prefill_probe_sized`: one untimed probe, then a timed sample, or the median of three when the probe finishes in under 5s.)*
12. **Never force tokens past EOS in a speed measurement** — `ignore_eos` on a decode that outruns the model's natural stop produces looping text, and looping inflates both draft acceptance and t/s. It once made the slowest clean configuration look like the worst one. Keep `ignore_eos` only where the point is memory pressure. *(`decode_sample` uses natural stop; `saturation_test` and `long_decode_check` still force, deliberately.)*

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
| GPU threshold at CPU < 100% | GPU-resident models read 100-110% and came back AMBIGUOUS |
| Timing the first probe at a new batch | One-time graph setup counted as throughput; penalised large batches by ~10% |
| `ignore_eos` on a speed sample | Looping inflated acceptance and t/s; the clean config measured slowest |
| Scaling the probe prompt with the batch | Larger batches got longer prompts, so they measured slower for the wrong reason |
