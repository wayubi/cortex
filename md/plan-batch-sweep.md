# Plan: Batch sweep optimization for CPU-compute models

## Status: 2026-09-02 — Implementation paused, pending live testing

## Context

For **GPU-resident models**, the existing pipeline finds the largest batch before OOM (ceiling search), then boundary = optimum (prefill monotonic, decode constant). That path is complete and working.

For **CPU-compute models** (e.g. gpt-oss: spills to CPU, ~1000% CPU), decode is batch-invariant and **only prefill t/s varies with batch**. The VRAM ceiling (~24K) is irrelevant — the fastest prefill batch is low (~1.5K–2K), where prefill is fastest. The pipeline needed a **separate sweep** to find that prefill-t/s peak, which led to all the work below.

## Implemented (this session)

### 1. Early 256 residency gate
Resident `cpu_saturation_sweep` call bypasses the entire ceiling search + bisect for CPU-compute models.
- Probe residency at batch 256 early in `cmd_bisect`.
- If CPU → skip ceiling search entirely, run prefill sweep → done.
- If GPU → old ceiling path, unchanged.
- **Saved ~20 min per CPU model** (eliminates the wasted 4096/8192/16384 saturation runs).

### 2. Saturation sweep architecture (cpu_saturation_sweep)
- **Ladder**: doubling from 256, each rung measured via `prefill_probe`.
- **Peak detection**: stops when 2 consecutive rungs above the best are below it (noise-tolerant, anchors on the established peak).
- **Bracket reconstruction**: recontructs bracket `[lo, hi]` from the tested rungs immediately flanking the peak — not gated on a >15% drop.
- **Golden-section refinement** to 64 granularity (max-search over bracket), reuses already-measured points, OOM counts as losing (-1).
- Winner = highest-t/s batch tested anywhere (ladder + golden). Guaranteed to catch non-power-of-2 peaks (e.g. 1536 between 1024/2048).

### 3. Short prefill_probe (prefill_probe)
- Fixed 32K-char prompt (~10K tokens), `max_tokens=1` (no decode tail).
- Warm-up (untimed) then timed fire_request; parses streaming `prompt processing` lines from the log, skips first 2, averages lines 3-7.
- ~4-5s per rung. Whole sweep ~6-10 min.

### 4. Ranked confirm step
After sweep finds winner via short probes, walks top-3 by prefill t/s, runs `saturation_test` on each until one passes. Expected to pass first try. If all fail, keeps the short-probe best-effort.

### 5. stdout pollution fix
`cpu_saturation_sweep` now emits `BATCH|TPS` to stdout; all progress `log` calls redirected to `>&2`. Early gate parses with `cut -d'|'`. models.ini set to winner before returning. No more WIN-garbage / unknown-t/s / wrong-batch bugs.

### 6. Prefill t/s capture in saturation_test
Captured from the **first accepted sizing probe** (from-scratch, no LCP cache reuse). The `prompt eval time` line's t/s is parsed and stored in `SAT_PREFILL_TPS`. Fixes the earlier Phase-2 cache-reuse bug that grabbed decode speed (28 t/s) instead of prefill.

### 7. RESUME code removed
All `resume` / `RESUME` / `RESUME_LO` / `RESUME_HI` / `RESUME_BATCH` removed from arg parsing, `cmd_bisect`, the residency gate, and usage text. Simplified `bisect` to `bench.sh bisect <model> [test-batch]`.

### 8. Dead code removed
- `R256` probe + CPU-sweep branch in the residency gate tail (unreachable since early gate catches CPU-first).
- `IS_CPU_ONLY` / `USE_STANDARD_FLOW` / `DISABLE_CPU_ONLY_CHECK` / `override-tensor` floor-check machinery.

## Designed (not yet implemented)

### 9. Propagate batch/ubatch to hf+ctx siblings
**Trigger**: after every successful `cmd_bench`.
**Grouping key**: `hf` + `ctx-size` (ignore reasoning/temp).
**Logic**:
1. Read benched model's `hf` + `ctx-size` + winning `batch`/`ubatch`.
2. Find sibling models with same `hf`+`ctx` that have NO `batch-size`.
3. Write `batch-size`/`ubatch-size` to each sibling's models.ini section.
4. Copy benched JSON → sibling JSON; rewrite `model` + sampling config (`temp`/`reasoning`/etc.) from the sibling's own models.ini entry; add `"propagated": true, "propagated_from": "<source>"`.

### 10. Sibling skip dedup (auto-inference)
When running `bench.sh all` or interactive full suite, **skip a model if `models/<MODEL>.json` already exists** (benched OR inferred).
- Dedup checked per-model, inside the loop (order-independent).
- Applied to: mtpcheck / bisect / mtp / bench (all steps skipped).
- Not applied to standalone `cmd_bisect` / `cmd_bench` (user force-overrides allowed).
- Propagation creates the sibling JSON → sibling is auto-skipped on the next run.

## One confirmed edge to flag
`reasoning=on` can sustain a slightly different batch than `reasoning=off` (observed: 2048 vs 1984 for Qwen3.5-9B-MTP-16K). The current grouping ignores reasoning. If a think sibling ever needs a different batch, it would need a separate explicit bench (delete JSON to force).

## Future consideration: pre-defined entries for fast batch switching
The user proposed: pre-declare N sibling entries in models.ini with different batch values, switch between them via model-name (coordinator unload/load) instead of container restart. This avoids `docker compose restart` overhead but doesn't avoid the ~30-60s model reload (batch is load-time). Feasibility depends on:
- Whether llama.cpp preset mode re-applies batch from the new preset entry (yes, different preset = fresh context).
- Whether model-level load is faster than container restart (probably modest savings, not transformative).

Deferred until the sweep optimization is validated live.
