# Plan: Add qwen3.5-9b-mtp-16k entries + bench ideal batch/ubatch

## Goal

Add two new 16K-context entries for Qwen3.5-9B-MTP (dense 9B, unsloth UD-Q4_K_XL), then bench each one-at-a-time starting from batch/ubatch 4096 to find the ideal value via the coarse-to-fine sweep + Phase-2 saturation.

## Step 1 — Add entries to `models.ini`

In the "Qwen3.5-9B MTP — unsloth" section, before the existing `-64k` siblings:

```
[qwen3.5-9b-mtp-16k]
hf               = unsloth/Qwen3.5-9B-MTP-GGUF:UD-Q4_K_XL
temp             = 0.7
top-p            = 0.8
top-k            = 20
min-p            = 0.00
presence-penalty = 0.0
repeat-penalty   = 1.0
spec-type        = draft-mtp
spec-draft-n-max = 2
spec-draft-p-min = 0.7
ctx-size         = 16384
reasoning        = off
batch-size       = 4096
ubatch-size      = 4096 ; tuning start

[qwen3.5-9b-mtp-think-16k]
hf               = unsloth/Qwen3.5-9B-MTP-GGUF:UD-Q4_K_XL
temp             = 0.6
top-p            = 0.95
top-k            = 20
min-p            = 0.00
presence-penalty = 0.0
repeat-penalty   = 1.0
spec-type        = draft-mtp
spec-draft-n-max = 2
spec-draft-p-min = 0.7
ctx-size         = 16384
reasoning        = on
batch-size       = 4096
ubatch-size      = 4096 ; tuning start
```

Placement: `[qwen3.5-9b-mtp-16k]` before `[qwen3.5-9b-mtp-64k]`; `[qwen3.5-9b-mtp-think-16k]` before `[qwen3.5-9b-mtp-think-64k]` (ctx-ascending, mirrors the qwen3.6 pattern).

## Step 2 — Bench model 1: `qwen3.5-9b-mtp-16k` (non-think)

Per AGENTS.md procedure, one probe at a time (parametrize the existing `/tmp/opencode/probe_once.sh` to take model + ctx):
1. Restart `llama-cpp`; wait for `/v1/models` 200.
2. Fire tiny probe; grep logs for OOM markers.
3. **Coarse-to-fine sweep** from 4096:
   - Down-sweep (halve / -1024) until first PASS → bracket `lo`=highest PASS, `hi`=lowest OOM.
   - Bisect up `(lo+hi)/2` rounded to 64 (PASS→lo=mid, OOM→hi=mid) until `hi−lo ≤ 64`; final `lo` = max.
   - Note: Qwen3.5-9B is a small dense model — 4096 may actually PASS; if so, step UP (512→256→128→64) to find the real ceiling.
4. **Phase 2 saturation** at the winner (16K ctx: ~14.5K-token prompt, `max_tokens` ~3000, `ignore_eos`) — must reach full context without OOM (hybrid caveat does not apply; Qwen3.5-9B is attention-only, so expect a real compaction/seq-removal event).
5. Leave config at winner: `ubatch-size = N ; optimized (max, N+64 OOM)`.

## Step 3 — Bench model 2: `qwen3.5-9b-mtp-think-16k`

Same sweep + saturation procedure (think=on generates reasoning tokens; probes/saturation slightly longer).

## Step 4 — Finalize

- Final restart; verify both models registered at `/v1/models`.
- Keep the existing `-64k` entries untouched.

## Notes / tradeoffs

- One model at a time; non-think first (reasoning off = faster probes).
- Qwen3.5-9B dense is far smaller than the 35B MoE (~5-6 GB), so the sweep may land well above 1664 (the 64k siblings' tuned value) — likely closer to 4096 or beyond; the sweep will find it.
- The 4096 starting value may not OOM for this model; the bisect-up handles that.
