# Plan: Add Gemma 4 QAT 12B (16K, think + non-think) + batch/ubatch & MTP tuning

## Goal

Add `unsloth/gemma-4-12B-it-qat-GGUF:UD-Q4_K_XL` (6.72 GB, dense 12B, hybrid attention) at 16K ctx in two entries — think and non-think — then optimize batch/ubatch and MTP (Gemma 4 ships a separate MTP drafter that "recent llama.cpp auto-discovers").

## Key facts

- Repo/quant: `unsloth/gemma-4-12B-it-qat-GGUF:UD-Q4_K_XL` (only quant). Recommended sampling: temp 1.0, top-p 0.95, top-k 64.
- Think control (unsloth method): `chat-template-kwargs = {"enable_thinking": true/false}`. Note: non-E2B/E4B variants emit an EMPTY thought block even when disabled (cosmetic).
- MTP: separate drafter GGUF `mtp-gemma-4-12B-it.gguf` (254 MB), auto-discovered from `-hf` by "recent llama.cpp" (~Jun 9 feature). Installed build = May 22 (`1acee6b`) — knows `gemma4` arch + has `--spec-draft-model` plumbing, but auto-discovery may be missing. Unsloth recommends `--spec-draft-n-max 4`.
- Installed build lacks `--reasoning-effort` (rebuild would fix).

## Step 1 — Add entries (new "Gemma 4 QAT" section)

```
[gemma-4-12b-qat-16k]
hf               = unsloth/gemma-4-12B-it-qat-GGUF:UD-Q4_K_XL
temp             = 1.0
top-p            = 0.95
top-k            = 64
min-p            = 0.00
repeat-penalty   = 1.0
ctx-size         = 16384
chat-template-kwargs = {"enable_thinking": false}
spec-type        = draft-mtp
spec-draft-n-max = 4
spec-draft-p-min = 0.7
batch-size       = 4096
ubatch-size      = 4096 ; tuning start

[gemma-4-12b-qat-think-16k]
(identical, except chat-template-kwargs = {"enable_thinking": true})
```

## Step 2 — Probe (MTP + think toggle) on the installed build

1. Restart llama-cpp; verify both register at `/v1/models`.
2. Fire a probe request on each; watch `docker logs -f cortex-llama-cpp-1`:
   - Model loads (gemma4 arch recognized)?
   - `enable_thinking` toggle works (think → thought block; non-think → none/empty)?
   - **MTP**: child logs "creating MTP draft context" (works) vs `failed to create MTP context` / missing drafter (fails)?
3. **Report the MTP result → user decides**: rebuild llama.cpp from master (gets Gemma 4 MTP + reasoning-effort; invalidates prior tuning) or ship without MTP (remove spec-type).

## Step 3 — Batch/ubatch tuning (both entries, benched separately)

Per AGENTS.md procedure: coarse-to-fine from 4096 → bracket → bisect to 64 → Phase-2 full-context saturation (16K) → real-prompt long-decode. The think/non-think ceilings may differ (as seen on Qwen).

## Step 4 — MTP spec tuning (if MTP is live)

n-max sweep (1–5) then p-min sweep (0.5–0.9), quality-gated via output inspection + acceptance rate.

## Step 5 — Finalize

- Tuned comments (`; optimized (...)`), final restart, verify registration.
- AGENTS.md: note the Gemma 4 setup (gemma4 arch, separate auto-discovered MTP drafter, enable_thinking control, unsloth sampling).

## Tradeoffs

- If a rebuild is chosen, this session's batch/spec tuning (measured against `1acee6b`) is invalidated and the 4 tuned `-16k` entries may need re-validation.
- Non-think Gemma output may include an empty `<|channel>thought` block (model behavior, not config error).
