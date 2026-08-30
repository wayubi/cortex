# BENCHMARKS

All measured on this stack (OpenResty → llama-cpp router, RTX 3060 12 GB, Xeon E5-2697 v3). `t/s` = decode tokens/sec unless noted.

## Build context

| Build | version | date | notes |
|---|---|---|---|
| `1acee6b` | 1 | May 22, 2026 | pre-rebuild; Gemma 4 arch unsupported; older fit/kernels |
| `3737e41` | 0.3.0-dev | Aug 25, 2026 | current; rebuilt from master; much faster prefill, more efficient fit, Gemma 4 MTP support |

Old-build numbers are kept for comparison; only new-build numbers are current.

## Current configs + decode t/s (new build)

Decode measured via 6000-token long-decode (real prompt) and 4000-token essay bench; acceptance = draft acceptance (MTP).

| Model | ctx | batch | n_max / p_min | drafter | long-decode t/s | essay t/s | prefill t/s | acceptance |
|---|---|---|---|---|---|---|---|---|
| `qwen3.5-9b-q4-mtp-16k` | 16k | 2048 | 2 / 0.7 | in-model | 70.4 | ~66 | **1545** | ~0.95 |
| `qwen3.5-9b-q4-mtp-think-16k` | 16k | 2048 | 2 / 0.5 | in-model | 67.4 | 63.6 | ~1545 | ~0.84 |
| `qwen3.6-35b-q4-mtp-16k` | 16k | 3584 | 2 / 0.7 | in-model | 45.9 | — | **1192** | ~0.96 |
| `qwen3.6-35b-q4-mtp-think-16k` | 16k | 3584 | 2 / 0.7 | in-model | 44.4 | — | ~1192 | ~0.94 |
| `qwen3.6-35b-q4-mtp-8k` | 8k | 8192 | 2 / 0.7 | in-model | 37.5 | — | **1272** | ~0.96 |
| `qwen3.6-35b-q4-mtp-think-8k` | 8k | 8192 | 2 / 0.7 | in-model | 36.8 | — | **1334** | ~0.94 |
| `qwen3.6-35b-q4-mtp-4k` | 4k | 4096 | 2 / 0.7 | in-model | 33.6 | — | **1067** | ~0.96 |
| `qwen3.6-35b-q4-mtp-think-4k` | 4k | 4096 | 2 / 0.7 | in-model | 33.7 | — | ~1067 | ~0.94 |
| `gemma-4-12b-q4-qat-mtp-16k` | 16k | 8640 | 5 / 0.7 | **Q4_0 (root)** | **86.1** | 79.3 | — | ~0.79 |
| `gemma-4-12b-q4-qat-mtp-think-16k` | 16k | 8576 | 5 / 0.5 | **Q4_0 (root)** | 76.7 | ~70 | — | ~0.56–0.71 |
| `gemma-4-12b-qat-q8-16k` | 16k | 8640 | 5 / 0.7 | Q8_0 (MTP/) | — | 74.2 | — | ~0.785 |
| `gemma-4-12b-qat-q8-think-16k` | 16k | 8576 | 5 / 0.5 | Q8_0 (MTP/) | — | 63.8 | — | ~0.58 |
| `gemma-4-12b-q6-mtp-16k` (non-QAT) | 16k | 1088 | 7 / 0.7 | Q4_0 (root, q4_0 KV) | ~60 | ~46 | ~1065 | ~0.75 |
| `gemma-4-12b-q6-mtp-think-16k` (non-QAT) | 16k | 1088 | 7 / 0.7 | Q4_0 (root, q4_0 KV) | 59.8 | ~46 | ~1065 | ~0.69 |
| `lfm2.5-8b-a1b-q8-think-16k` | 16k | 8192 | — | none (no MTP) | 110.2 | — | 376 | — |
| `lfm2.5-8b-a1b-q4-think-16k` | 16k | 16384 | — | none (no MTP) | ~131 | — | **5972** | — |
| `lfm2.5-8b-a1b-q4-think-32k` | 32k | 16384 | — | none (no MTP) | ~134 | — | 5611 | — |
| `lfm2.5-8b-a1b-q4-think-64k` | 64k | 8192 | — | none (no MTP) | ~128 | — | 5599 | — |
| `ornith-1.5-9b-q4-mtp-think-64k` | 64k | 8192 | 3 / 0.7 | in-model | ~53 | 46 | **1523** | ~0.89 |
| `ornith-1.5-9b-q4-mtp-coder-64k` | 64k | 8192 | 3 / 0.7 | in-model | ~53 | — | ~1523 | ~0.94 |
| `ornith-1.5-9b-q4-mtp-think-128k` | 128k | 4736 | 2 / 0.7 | in-model | ~53 | — | **1530** | ~0.91 |
| `ornith-1.5-9b-q4-mtp-coder-128k` | 128k | 4736 | 2 / 0.7 | in-model | ~53 | — | ~1530 | ~0.95 |
| `ornith-1.5-9b-q4-mtp-think-256k` | 256k | 960 | 2 / 0.7 | in-model | ~54 | — | **1523** | ~0.93 |
| `ornith-1.5-9b-q4-mtp-coder-256k` | 256k | 960 | 2 / 0.7 | in-model | ~54 | — | ~1523 | ~0.92 |
| `zamai-llama3-pashto-q8-8k` | 8k | 8192 | — | none (no MTP) | 34.0 | — | 2012 | — |

## Old-build references (stale)

| Model | decode t/s | prefill t/s |
|---|---|---|
| qwen3.5-9b-q4-mtp-16k | ~58 (MTP flat) | ~370 |
| qwen3.5-9b-q4-mtp-think-16k | 52.7–58.9 (p_min sweep) | ~370 |
| qwen3.6-35b-q4-mtp-16k | ~38 | ~410 |
| qwen3.6-35b-q4-mtp-think-16k | ~36.5 | ~410 |

## Batch tuning results

### qwen3.5-9b-q4-mtp-16k (new build)
- Practical sweet spot **2048**: prefill already maxed (1545 t/s at both 2048 and 4096), decode flat (~66) across 1024–4096.
- VRAM ceiling ~16384 but **CPU-pegged** there (1693%, decode drops to <18 t/s) — never use.

### qwen3.6-35b-q4-mtp-16k (new build)
- Practical sweet spot **3584** (prefill peak): 950@2048 → 1054@3072 → **1192@3584** → 1142@4096.
- Old ceiling 576 (640 OOM on old build) → new fit allows 3584+.
- VRAM 10769 MiB. 100% GPU confirmed (0% CPU during sustained decode).

### qwen3.6-35b-q4-mtp-4k / 8k (new build)
- **4k non-think** batch=4096: prefill ~1067 t/s, decode ~33.6 t/s, VRAM 10697 MiB. 100% GPU (0% CPU confirmed).
- **4k think** batch=4096: decode ~33.7 t/s, VRAM 10697 MiB. 100% GPU (0% CPU confirmed).
- **8k non-think** batch=8192: prefill ~1272 t/s, decode ~37.5 t/s, VRAM ~10583 MiB. 100% GPU (0% CPU confirmed).
- **8k think** batch=8192: prefill ~1334 t/s, decode ~35.6 t/s, VRAM ~10583 MiB. 100% GPU (0% CPU confirmed).
- **16k non-think** batch=3584: decode ~45.9 t/s, VRAM 10769 MiB. 100% GPU (0% CPU confirmed).
- **16k think** batch=3584: decode ~44.4 t/s, VRAM 10769 MiB. 100% GPU (0% CPU confirmed).
- Batch > ctx is wasteful (prompt can't exceed ctx). VRAM flat regardless of batch — model weights + KV dominate. Set batch = ctx for max useful value.
- **MTP sweep (n_max 1-3, p_min 0.7)**: all variants within ±10-15% noise across n_max values — same as 16k result. Defaults retained (n_max=2, p_min=0.7).

### gemma-4-12b-qat (new build)
- Non-think **8640** (8704 OOM), think **8576** (8640 marginal) — dense 12B small per-unit graph.
- Long-decode + full-16K saturation validated.

### gemma-4-12b (non-QAT, UD-Q6_K_XL — new build)
- **100% GPU @ 16K requires `spec-draft-type-k/v = q4_0` + batch 1088** (10 GB main + 0.7 GB draft + KV + compute ≈ 11.5 GB). Batch bisect: **1024 PASS, 1088 PASS, 1152 FAIL, 1280 FAIL, 1536 FAIL, 2048 FAIL** — at 1152+ the **MTP draft falls to CPU** (300%+ CPU, decode 36–38 t/s); at 1088 it stays on GPU (~81% CPU, **59.8 t/s** long-decode, prefill ~1065 t/s). `spec-draft-ngl` forcing the draft to GPU backfired (main layer dropped to CPU, 17.7 t/s).
- Q8 main (UD-Q8_K_XL 13 GB / Q8_0 12 GB) does NOT fit 100% GPU at any ctx (4K/8K/16K all offload ~0.6–1 GB to CPU) — dead end without CPU offload.
- n_max sweep (essay, p_min 0.7): 5=22, 6=27, **7=33** (peak), 8=25. p_min @ 7: 0.5=30, **0.7=33**, 0.9=33.6.
- Think: n_max **7** (6=28.5, 7=29.6, 8=27.8); p_min **0.7** (0.5=19/acc 0.39 — bad; 0.9=23.3); math gate 6/6.
- Q6 decode (~50 t/s) is still slower than the QAT Q4 (~86/77) — ~1.5× the weight bytes.

### lfm2.5-8b-a1b-q8-think-16k (UD-Q8_K_XL — new build)
- **No MTP** (Liquid doesn't ship a drafter), no reasoning toggle (always CoT). 8.3B total / 1.5B active params.
- 1.5B active → tiny compute → always fits on GPU regardless of batch. CPU stays ~96% (host orchestration only, no spill). VRAM: 10863 MiB (9.34 GB model + ~1.5 GB KV + graph).
- Batch sweep (decode t/s): 4096=111.8, **8192=111.1** (best), 12288=110.6, 16384=86.9, 20480=77.1, 32768=88.5, 65536=88.8.
- **Batch 8192** chosen (best decode + prefill 352 t/s). Saturation + long-decode validated.
- Decode 110.2 t/s (long-decode), prefill 376 t/s — fastest model in the stack.

### lfm2.5-8b-a1b-q4-think-{16k,32k,64k} (UD-Q4_K_XL — new build)
- Same lfm2moe arch (24 blocks, only 6 layers carry KV, 32 exp / 4 active, 1.5B active). Native ctx 128000 → 64K is within native.
- Q4 frees ~4.5 GB: VRAM 6353 MiB @ 16k vs Q8's 10863 MiB.
- **Q4 decode is faster than Q8**: ~131 t/s vs 110 (Q4 weights halve memory bandwidth).
- Per-entry batch bisects: **16k=16384** (prefill peak 5972 t/s; decode 131 flat), **32k=16384** (decode 134, prefill 5611), **64k=8192** (decode 128, prefill 5599; 24576+ spills to CPU — 369% CPU, decode 84 t/s). Decode flat across batch at all ctx (compute-bound), so prefill is the tiebreaker.
- 64k saturation: hit ceiling (65536, 0 OOM). Math gate: **6/6 correct** on 16k.

### ornith-1.5-9b-q4-mtp-think-{64k,128k,256k} (Q4_K_M, qwen35 hybrid — new build)
- **Hybrid SSM+dense** arch (33 layers, attention every 4th, 4 KV heads, kv 256) with **MTP baked in** (`nextn_predict_layers=1`) — same GGUF architecture as qwen3.5-9b-mtp. Native ctx 262144.
- **Always reasoning** — `reasoning = on` puts CoT in `reasoning_content`.
- Q4_K_M (5.78 GB). Hybrid arch → tiny KV (only ~8 attention layers carry KV): 64k VRAM 7097 MiB, 128k 8375 MiB, 256k 10155 MiB. All three fit 100% GPU.
- Batch bisects (max full-GPU): **64k = 8192** (12288 spills), **128k = 4736** (4800 spills), **256k = 960** (992 spills). Prefill ~1523–1530 t/s at all three (batch-driven).
- **MTP n_max differs per entry. Rigorous reasoning-workload bench (math/CoT, 3–5× averaged):** no-MTP **44.1** → n_max 2=**51.7**, **3=52.5 (peak)**, 4=52.0, 5=49.9 on 64k @ batch 8192. Deeper than 3 wastes draft compute on reasoning tokens (lower acceptance). n_max=3's ~1.3 t/s edge over n_max=2 is small but consistent (5× avg: 52.6 vs 51.3).
- **The batch↔n_max tradeoff was re-tested on 128k/256k (the part previously skipped):** at n_max=3 the draft fits a smaller batch (128k max 4608, 256k max 832 — draft buffer scales with `n_max × batch`), but the resulting decode **does NOT beat** n_max=2 at the full batch: 128k n_max2@4736 = 52.7 vs n_max3@4608 = 52.2 (equal within noise, and n_max2 keeps higher batch → better prefill); 256k n_max2@960 = 53.9 vs n_max3@832 = ~53.0 (worse). **Final: 64k n_max=3 @ 8192, 128k/256k n_max=2 @ 4736/960**, p_min 0.7 everywhere. (The committed config from the first fix round was confirmed correct by this full re-test.)
- **Gotcha (caused a real regression):** tuning n_max on one entry and copy-pasting to others WITHOUT re-running the CPU placement check. At 128k n_max=5, the draft spilled to CPU → 12 t/s + 680% CPU on a 77K-ctx reasoning request. Re-verify placement per entry after ANY n_max change. Also: tune MTP on the real workload (reasoning/CoT), NOT a prose essay — prose acceptance overstates the benefit.
- Saturation: 64k hit ceiling (65536, 0 OOM), 128k hit ceiling (131070, 0 OOM), 256k reached ~258K/262144 (98%, 0 OOM, ~22.8 t/s at full ctx).
- Math gate: **6/6 correct**. Essay: 0 repeats, coherent.
- Gen params per model card: temp 1.0, top_p 0.95, top_k 20, presence_penalty 1.5.
- **Coder variants** (`ornith-1.5-9b-q4-mtp-coder-{64k,128k,256k}`): identical tuning (same weights/VRAM → same n_max/batch), but the model card's **coding recipe**: temp 0.6, presence_penalty 0.0 (code needs token reuse — variable names, API identifiers repeat; the general recipe's 1.5 presence penalty degrades code). Use these for coding tasks, the think variants for general/creative work. Note: ornith's coding CoT is long (~4.5 chars/token) — budget `max_tokens` generously (≥1500) or the reasoning is cut off before the final answer.

### zamai-llama3-pashto-q8-8k (Q8_0, Qwen2.5-7B base — new build)
- **Base**: Meta-Llama-3-8B fine-tuned on Pashto (Peshawari/KPK dialect) by Junaid Khan, GGUF by hasnainayaz.
- **n_ctx_train = 8192** — the 16384 request was silently capped to 8192 by llama.cpp. Renamed entry to `8k`.
- **No MTP** (Qwen2.5 base, no drafter), no reasoning/CoT capability.
- Q8_0 = 8.54 GB. VRAM flat at **9897 MiB** (9.9 GB) regardless of batch — the 8B compute graph is small enough that batch doesn't affect VRAM.
- **Batch ceiling**: tested 4096 → 8192 → 16384 → 32768 → 65536 → 131072 → 262144 — **all PASS** with no OOM. VRAM identical at every value. Batch 8192 chosen (matches ctx, practical).
- Decode: **34 t/s** (flat across all batch values). Prefill: ~2012–2700 t/s.
- Saturation: 5770 prompt + 2422 completion = 8192 full ctx, `finish_reason: length`, **0 OOM**.
- Long-decode: 6000 tokens, 0 consecutive repeats, coherent output, **0 OOM**.
- **Pashto quality**: genuine Pashto script (ښ, څ, ډ, ږ), correct grammar, proper gender agreement, accurate translations. Works with both Pashto and English prompts. Significantly better Pashto than the LFM2.5-1.2B attempt (which produced Dari/Arabic).

## MTP spec sweeps (new build, essay bench 4000 tokens)

### gemma-4-12b-q4-qat-mtp-16k (non-think)
| n_max (p_min 0.7) | t/s | acceptance |
|---|---|---|
| 1 | 53.9 | 0.932 |
| 2 | 67.4 | 0.893 |
| 3 | 72.8 | 0.838 |
| 4 | 76.8 | 0.793 |
| **5** | **79.4** | 0.791 |
| 6 | 78.7 | 0.768 |

| p_min (n_max 5) | t/s | acceptance |
|---|---|---|
| 0.5 | 75.7 | 0.659 |
| **0.7** | **79.3** | 0.791 |
| 0.9 | 74.4 | 0.868 |

Winner: **n_max 5, p_min 0.7** (n_max=4 produced repeated-output degradation; 5 clean).

### gemma-4-12b-q4-qat-mtp-think-16k
| n_max (p_min 0.7) | t/s | acceptance |
|---|---|---|
| 1 | 49.5 | 0.835 |
| 2 | 61.2 | 0.817 |
| 3 | 55.7 | 0.661 |
| 4 | 70.2 avg | 0.731 |
| 5 | 70.2 | 0.709 |
| 6 | 55.4 | 0.553 |

| p_min (n_max 5) | t/s |
|---|---|
| 0.5 | 66.0 A/B |
| 0.7 | 56.6–70.1 (high variance) |

Winner: **n_max 5, p_min 0.5** (math gate 6/6 correct, faster A/B; acceptance unchanged at n_max=5).

### Qwen3.5-9B-MTP (old build)
- Non-think: flat ~58 t/s across n_max 1–5 & p_min 0.5–0.9.
- Think: p_min monotonic (0.9→52.7, 0.7→56.3, 0.5→58.9, 0.3→58.9 plateau), acceptance 0.98→0.69; kept 0.7.

### Qwen3.6-35B-MTP (old build)
- ±10–15% run-to-run decode variance exceeded config deltas — defaults retained (n_max 2, p_min 0.7).

## Hard-task quality gates (6 math/logic questions, max_tokens 2048)

| Model | config A | result | config B | result |
|---|---|---|---|---|
| qwen3.5-9b-q4-mtp-think-16k | p_min 0.5 | **6/6 correct** | p_min 0.7 | 6/6 correct |
| gemma-4-12b-q4-qat-mtp-think-16k | p_min 0.5 | **6/6 correct** | p_min 0.7 | 6/6 correct |
| lfm2.5-8b-a1b-q8-think-16k | temp 0.2 | **6/6 correct** | — | — |
| lfm2.5-8b-a1b-q4-think-16k | temp 0.2 | **6/6 correct** | — | — |
| ornith-1.5-9b-q4-mtp-think-64k | temp 1.0, n_max 3 | **6/6 correct** | — | — |

Both p_min=0.5 decisions validated: no quality degradation on hard reasoning. LFM2.5 CoT: all 6 answers correct (11:24 AM, invalid syllogism, x=5, 31 apples, 5%, 42). Essay: 0 consecutive-sentence repeats, coherent, no degeneration.

## Q4-QAT vs Q6 (non-QAT) head-to-head @ 16K

- **Math gate: both 6/6** (trains 11:24, syllogism invalid, x=5, 31 apples, 5% increase, sequence 42).
- **Essay coherence: both clean bodies, both degenerate at the forced 4000-token tail** (`.mount…` vs `_**…` — the ignore_eos artifact, not a model difference).
- **Conclusion: Q6's extra precision buys no measurable quality** — Q4 QAT is 2.3× faster (86 vs 38 t/s) and smaller. Q4 QAT wins on this GPU.

## Q8 drafter test (gemma-4-12b-qat, new build)

- Q8_0 drafter (`MTP/mtp-gemma-4-12B-it-Q8_0.gguf`) wired via `spec-draft-model` (router accepts the key).
- Result: **no benefit** — non-think ~74.2 t/s / acceptance ~0.785 vs Q4_0 79.4 / 0.791; think 63.8 / 0.58 (within Q4 variance).
- Acceptance bottleneck = n_max=5 speculative positions (draft precision doesn't move it). **Q4_0 (root, auto-discovered) stays.**
- `hf = repo:Q8_0` does NOT work: llama.cpp's resolver finds no main Q8_0 GGUF (only the MTP/ drafter) → "failed to load model".

## CPU note

Batch extremes are CPU-bound: batch 16384 on the 9B pegged ~17 cores (1693% CPU) and slowed decode below 18 t/s. Practical batch = where prefill maxes with sane CPU, never the VRAM max.
