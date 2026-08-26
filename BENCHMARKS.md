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
| `qwen3.5-9b-mtp-16k` | 16k | 2048 | 2 / 0.7 | in-model | 70.4 | ~66 | **1545** | ~0.95 |
| `qwen3.5-9b-mtp-think-16k` | 16k | 2048 | 2 / 0.5 | in-model | 67.4 | 63.6 | ~1545 | ~0.84 |
| `qwen3.6-35b-mtp-16k` | 16k | 3584 | 2 / 0.7 | in-model | 45.9 | — | **1192** | ~0.96 |
| `qwen3.6-35b-mtp-think-16k` | 16k | 3584 | 2 / 0.7 | in-model | 44.4 | — | ~1192 | ~0.94 |
| `gemma-4-12b-qat-16k` | 16k | 8640 | 5 / 0.7 | **Q4_0 (root)** | **86.1** | 79.3 | — | ~0.79 |
| `gemma-4-12b-qat-think-16k` | 16k | 8576 | 5 / 0.5 | **Q4_0 (root)** | 76.7 | ~70 | — | ~0.56–0.71 |
| `gemma-4-12b-qat-q8-16k` | 16k | 8640 | 5 / 0.7 | Q8_0 (MTP/) | — | 74.2 | — | ~0.785 |
| `gemma-4-12b-qat-q8-think-16k` | 16k | 8576 | 5 / 0.5 | Q8_0 (MTP/) | — | 63.8 | — | ~0.58 |
| `gemma-4-12b-q6-16k` (non-QAT) | 16k | 1088 | 7 / 0.7 | Q4_0 (root, q4_0 KV) | ~60 | ~46 | ~1065 | ~0.75 |
| `gemma-4-12b-q6-think-16k` (non-QAT) | 16k | 1088 | 7 / 0.7 | Q4_0 (root, q4_0 KV) | 59.8 | ~46 | ~1065 | ~0.69 |
| `lfm2.5-8b-a1b-16k` | 16k | 8192 | — | none (no MTP) | 110.2 | — | 376 | — |
| `ornith-1.5-9b-q4-think-16k` | 16k | 16384 | — | none | 44.1 | — | 224 | — |

## Old-build references (stale)

| Model | decode t/s | prefill t/s |
|---|---|---|
| qwen3.5-9b-mtp-16k | ~58 (MTP flat) | ~370 |
| qwen3.5-9b-mtp-think-16k | 52.7–58.9 (p_min sweep) | ~370 |
| qwen3.6-35b-mtp-16k | ~38 | ~410 |
| qwen3.6-35b-mtp-think-16k | ~36.5 | ~410 |

## Batch tuning results

### qwen3.5-9b-mtp-16k (new build)
- Practical sweet spot **2048**: prefill already maxed (1545 t/s at both 2048 and 4096), decode flat (~66) across 1024–4096.
- VRAM ceiling ~16384 but **CPU-pegged** there (1693%, decode drops to <18 t/s) — never use.

### qwen3.6-35b-mtp-16k (new build)
- Practical sweet spot **3584** (prefill peak): 950@2048 → 1054@3072 → **1192@3584** → 1142@4096.
- Old ceiling 576 (640 OOM on old build) → new fit allows 3584+.

### gemma-4-12b-qat (new build)
- Non-think **8640** (8704 OOM), think **8576** (8640 marginal) — dense 12B small per-unit graph.
- Long-decode + full-16K saturation validated.

### gemma-4-12b (non-QAT, UD-Q6_K_XL — new build)
- **100% GPU @ 16K requires `spec-draft-type-k/v = q4_0` + batch 1088** (10 GB main + 0.7 GB draft + KV + compute ≈ 11.5 GB). Batch bisect: **1024 PASS, 1088 PASS, 1152 FAIL, 1280 FAIL, 1536 FAIL, 2048 FAIL** — at 1152+ the **MTP draft falls to CPU** (300%+ CPU, decode 36–38 t/s); at 1088 it stays on GPU (~81% CPU, **59.8 t/s** long-decode, prefill ~1065 t/s). `spec-draft-ngl` forcing the draft to GPU backfired (main layer dropped to CPU, 17.7 t/s).
- Q8 main (UD-Q8_K_XL 13 GB / Q8_0 12 GB) does NOT fit 100% GPU at any ctx (4K/8K/16K all offload ~0.6–1 GB to CPU) — dead end without CPU offload.
- n_max sweep (essay, p_min 0.7): 5=22, 6=27, **7=33** (peak), 8=25. p_min @ 7: 0.5=30, **0.7=33**, 0.9=33.6.
- Think: n_max **7** (6=28.5, 7=29.6, 8=27.8); p_min **0.7** (0.5=19/acc 0.39 — bad; 0.9=23.3); math gate 6/6.
- Q6 decode (~50 t/s) is still slower than the QAT Q4 (~86/77) — ~1.5× the weight bytes.

### lfm2.5-8b-a1b-16k (UD-Q8_K_XL — new build)
- **No MTP** (Liquid doesn't ship a drafter), no reasoning toggle (always CoT). 8.3B total / 1.5B active params.
- 1.5B active → tiny compute → always fits on GPU regardless of batch. CPU stays ~96% (host orchestration only, no spill). VRAM: 10863 MiB (9.34 GB model + ~1.5 GB KV + graph).
- Batch sweep (decode t/s): 4096=111.8, **8192=111.1** (best), 12288=110.6, 16384=86.9, 20480=77.1, 32768=88.5, 65536=88.8.
- **Batch 8192** chosen (best decode + prefill 352 t/s). Saturation + long-decode validated.
- Decode 110.2 t/s (long-decode), prefill 376 t/s — fastest model in the stack.

### ornith-1.5-9b-q4-think-16k (Q4_K_M, qwen35 arch — new build)
- Dense 9B model (no MTP, always reasoning — `reasoning = on` puts CoT in `reasoning_content`).
- Q4_K_M (5.78 GB) fits easily at 16K; VRAM 8487 MiB. Batch ceiling effectively unlimited (no CPU spill at 65536). Best prefill at 16384 (232 t/s).
- Decode 44 t/s — 1.4x faster than Q8_0 (31 t/s). Gen params per model card: temp 1.0, top_p 0.95, top_k 20, presence_penalty 1.5.
- Math gate: **6/6 correct**. Essay: 0 repeats, coherent.

## MTP spec sweeps (new build, essay bench 4000 tokens)

### gemma-4-12b-qat-16k (non-think)
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

### gemma-4-12b-qat-think-16k
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
| qwen3.5-9b-mtp-think-16k | p_min 0.5 | **6/6 correct** | p_min 0.7 | 6/6 correct |
| gemma-4-12b-qat-think-16k | p_min 0.5 | **6/6 correct** | p_min 0.7 | 6/6 correct |
| lfm2.5-8b-a1b-16k | temp 0.2 | **6/6 correct** | — | — |
| ornith-1.5-9b-q4-think-16k | temp 1.0 | **6/6 correct** | — | — |

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
