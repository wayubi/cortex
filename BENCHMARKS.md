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

Both p_min=0.5 decisions validated: no quality degradation on hard reasoning.

## Q8 drafter test (gemma-4-12b-qat, new build)

- Q8_0 drafter (`MTP/mtp-gemma-4-12B-it-Q8_0.gguf`) wired via `spec-draft-model` (router accepts the key).
- Result: **no benefit** — non-think ~74.2 t/s / acceptance ~0.785 vs Q4_0 79.4 / 0.791; think 63.8 / 0.58 (within Q4 variance).
- Acceptance bottleneck = n_max=5 speculative positions (draft precision doesn't move it). **Q4_0 (root, auto-discovered) stays.**
- `hf = repo:Q8_0` does NOT work: llama.cpp's resolver finds no main Q8_0 GGUF (only the MTP/ drafter) → "failed to load model".

## CPU note

Batch extremes are CPU-bound: batch 16384 on the 9B pegged ~17 cores (1693% CPU) and slowed decode below 18 t/s. Practical batch = where prefill maxes with sane CPU, never the VRAM max.
