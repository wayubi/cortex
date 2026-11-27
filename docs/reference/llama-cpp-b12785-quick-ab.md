# llama.cpp b10622 → b12785: quick prefill/decode A/B

**Date:** 2026-11-26
**Status:** Measured. Not a bench: one sample per model, to decide which models need a full
`bench.sh` run on the new build.

## Builds

| | Build | Commit | Date | Image |
|---|---|---|---|---|
| Old | upstream `b10622` | `3737e41` | 2026-08-25 | `llama-cpp:b10622` (kept for rollback) |
| New | upstream `b12785` (`llama-server --version`: `1.1.0-dev`) | `55d4828` | 2026-11-26 | `llama-cpp:b12785` = `llama-cpp:latest` |

Both built from `llama-cpp/Dockerfile` (CUDA 12.4, `CUDA_ARCH` 86), same `models.ini`, same host.

## Method

- One entry per model file in `llama-cpp/models.ini` (the first section for each `hf`), vision
  entries excluded (they share the head's file). Each entry run with its own `models.ini` settings
  (batch, ctx, MTP as configured).
- One request per model through openresty `:8080`, the first after the model's load: the first
  ~21K characters of `AGENTS.md` plus "Summarise the text above." (~5.6-6.1K tokens, fits the
  smallest context, 8K), `max_tokens 256`, `ignore_eos`, `temperature 0`, `seed 42`.
- Speeds are llama.cpp's own `timings.prompt_per_second` and `timings.predicted_per_second`.
- Old build measured first, then the router was recreated on the new image and the same list run.
  Cortex idle in both runs.
- `dirk-qwen3.8-27b-gsq-iq2xs-mtp-63k` excluded: its file is not in the HF cache, so it fails to
  load offline on either build.

## Results

| Model (entry) | Prefill old | Prefill new | Δ | Decode old | Decode new | Δ |
|---|---|---|---|---|---|---|
| cyber-tiel-coder-35b-a3b-q4-mtp-64k | 869 | 1,211 | **+39%** | 37.4 | 37.4 | 0% |
| tiel-coder-35b-a3b-q4-mtp-64k | 723 | 984 | **+36%** | 37.5 | 43.5 | **+16%** |
| groot-19b-a3b-iq3m-mtp-128k | 2,084 | 2,782 | **+34%** | 59.1 | 61.5 | +4% |
| nail-qwen3.6-35b-a3b-q4-mtp-64k | 924 | 1,139 | **+23%** | 34.8 | 38.6 | **+11%** |
| qwen-3.6-35b-a3b-q4-mtp-64k | 998 | 1,144 | **+15%** | 38.3 | 42.2 | **+10%** |
| saluki-27b-iq2-mtp-72k | 473 | 528 | +12% | 28.6 | 29.3 | +2% |
| swift-1.5-qwen3.8-27b-gsq-iq2xs-114k | 480 | 540 | +12% | 20.6 | 22.0 | +7% |
| gpt-oss-20b-a4b-q4-64k-think-medium | 2,193 | 2,407 | +10% | 51.8 | 56.8 | +10% |
| swift-1.5-qwen3.8-27b-gsq-iq2xs-mtp-63k | 456 | 497 | +9% | 32.8 | 36.1 | +10% |
| lfm-2.5-8b-a1b-q4-32k-think | 6,169 | 6,749 | +9% | 138.3 | 138.1 | 0% |
| qwen-3.5-9b-q4-mtp-64k | 1,570 | 1,702 | +8% | 58.4 | 68.7 | **+18%** |
| mellum-2.1-12b-a2.5b-q4-128k-think | 3,477 | 3,726 | +7% | 109.7 | 107.6 | −2% |
| lfm-2.5-24b-a2b-q4-64k-think | 2,156 | 2,242 | +4% | 58.2 | 57.6 | −1% |
| zamai-llama3-pashto-q8-8k | 2,156 | 2,244 | +4% | 32.3 | 32.7 | +1% |
| gemma-4-26b-a4b-q4-qat-mtp-32k | 1,436 | 1,382 | −4% | 44.7 | 45.6 | +2% |
| gemma-4-12b-q4-qat-mtp-32k | 1,221 | 996 | **−18%** | 55.0 | 61.1 | **+11%** |

Prefill and decode in tokens per second. **Bold:** a change beyond ±10%.

**Caveats:** one sample each, ~6K-token prompts (bench prefill uses ~75% of ctx, so long-context
prefill can behave differently), the first request after a load. Decode varies ~2-4% run to run on
the same config; prefill on a short prompt can vary more. Treat changes under ~10% as noise.

## Why it got faster: candidate causes (not verified)

Nothing here was profiled; these are upstream changes merged between the two builds (from
`md/llama-cpp-tuning-and-version-gap.md` §4) that match the pattern, not established causes.

- **MoE models, prefill (qwen-3.6-35B family, groot):** CUDA MoE matrix-multiply data-layout work
  (#31047) and backend-scheduler reuse / skipping unused inputs (#32009, #31419). The largest gains
  are on MoE entries that run partly on the CPU (tiel, cyber-tiel, nail, qwen-3.6-35B) and on groot.
- **Placement:** `-fit` now accounts for skipped NextN (MTP head) layers (#31569). Every `-mtp` GGUF
  carries those layers even where MTP is off, so the new build may place more of the model on the
  GPU. That alone would raise both prefill and decode. Check by comparing the load log's offload
  lines and VRAM between builds during the bench.
- **MTP decode (qwen-3.5-9B +18%, swift MTP +10%, gemma-4-12B +11%):** CUDA few-row matrix multiply
  for batch sizes 2-24 (#31533), which speeds the small verification batches of speculative
  decoding, and MTP hidden states kept in a device buffer (#31927).
- **gemma-4-12B prefill −18%:** unexplained. Candidates: Gemma 4 graph changes (#31356 targets
  prefill, measured gains on smaller variants) and the Gemma 4 MTP assistant now following
  `ctx_other` devices and the flash-attention setting (#31635), either of which could change memory
  use and make its tuned batch (1792) a worse fit. Its bench will show whether the pick moved.

## Recommendation: which models to bench

- **Bench:** the qwen-3.6-35B family (tiel, cyber-tiel, nail, base qwen), groot, gemma-4-12B. Large
  changes; batch picks, placement and the MTP A/B decisions may differ on the new build.
- **Optional:** qwen-3.5-9B, gpt-oss-20B, swift MTP (decode +10-18%).
- **No rush:** mellum, lfm 8B/24B, zamai, gemma-4-26B, saluki, swift 114k (within ~10%).

Bench JSONs record `build_info`, so records from both builds stay distinguishable in
`full-metrics.md` until all are re-benched.

## Smoke test on b12785 (after the switch)

- **Every `llama-cpp/models.ini` entry except dirk (61):** one short request each through openresty.
  All 61 loaded and answered (HTTP 200, non-empty output), reasoning on/off as configured; no OOM
  or load errors in the router log.
- **Tool calls:** groot-19b 128k-think-coder and mellum-12b 128k-think each called a `read_file`
  tool with the right argument, accepted the tool result and answered from it.
- **Vision:** gemma-4-12b 64k-vision named a solid red test image "Red".
- **MTP:** drafting engages (draft acceptance 0.83 on the MTP entries).
- **Flags:** every key `models.ini` uses exists in b12785. Removed flags (`--mmap`, `--no-mmap`,
  `--mlock`, `--direct-io`, `--defrag-thold`) are unused. `models-max` still defaults to 4;
  the new `--models-memory-margin` defaults to 0 (off).

## Can b12785 replace the other llama.cpp routers?

Each router's model was added to `llama-cpp/models.ini` as a temporary `trial-<name>` copy of its
section (removed afterwards) and compared with the same entry on its own router: two short prompts
(a Python `is_prime` function; a time-difference question) at `temperature 0`, `seed 42`, and the
quick speed check above.

| Router | Own build | On b12785 | Verdict |
|---|---|---|---|
| **raon-llama-cpp** (Raon-1 mini, arch `raon1`) | KRAFTON fork `fb895662d` | Loads. Same answers as the fork (identical `is_prime` code, "155"), reasoning of near-identical length. Decode same or slightly faster (Q5 26.8 → 27.6, Q4 28.2 → 31.4 t/s). **Prefill slower: Q5 912 → 720 t/s (−21%), Q4 1,077 → 755 t/s (−30%)** (one sample each, ~5.3K-token prompt). | Can be retired once a bench on b12785 shows the prefill loss is gone with a re-tuned batch (the entries carry the fork's picks, 8064 / 8000), or is accepted. |
| **inkling-llama-cpp** (Inkling 2 Mini, Unsloth GGUF) | Unsloth b12588 mix | **Does not load:** `check_tensor_dims: tensor 'blk.24.attn_q.weight' not found`. Upstream's `inkling2` / `inkling2_loop` expect a different tensor layout from Unsloth's file. | **Keep.** |
| **prism-llama-cpp** (Bonsai, PTQ1_0) | PrismML fork b10777 | **Does not load:** `tensor 'output.weight' has invalid ggml type 143. should be in [0, 44)`. Upstream has no PTQ1_0. | **Keep.** |

**Decision (2026-11-26):** all three routers (raon, inkling, prism) stay for now, until more
benching on b12785.

Note: the `inkling-llama-cpp` container ran b12588 although `compose.yml` pinned b12651 (rebuilt,
not recreated). Recreated 2026-11-26 on b12651 (`d426a3774`): all three inkling entries load and
answer both test prompts correctly, no load or OOM errors; 64k decode 23.1 → 26.8 t/s against the
b12588 run above (one sample). The inkling rows in `full-metrics.md` were benched on b12588.
