# Plan: Benchmark MTP spec-decoding params on qwen3.5-9b-mtp-16k

## Goal

Tune `spec-draft-n-max` and `spec-draft-p-min` (MTP speculative decoding) on `qwen3.5-9b-mtp-16k` (non-think, 16K ctx) to maximize decode t/s without degrading output quality. Baseline: `n-max = 2`, `p-min = 0.7`.

## Param semantics

- `spec-draft-n-max`: draft tokens predicted ahead per decode step (default 2). Higher = more speed IF accepted; later draft tokens drop in acceptance → wasted target re-verification.
- `spec-draft-p-min`: quality guard — draft tokens with probability below this are rejected (target recomputes). Lower = more acceptance/faster but riskier quality; higher = safer/slower.
- Quality degradation (repetition, incoherence) is the failure mode when n-max is too high relative to p-min.

## Benchmark request (per candidate)

Decode-heavy, real task (not filler — needed for both speed AND quality):
- Prompt: a substantive instruction (e.g., "Write a detailed 1000-word essay explaining how transformers work, including attention and MoE").
- `max_tokens` ~4000, `ignore_eos: true` (force long decode for a stable t/s measurement).
- Route via `http://localhost:8080/v1/chat/completions`.

## Metrics per candidate

1. **t/s** — from log `eval time = … ms / N tokens (… ms per token, Y tokens per second)` (objective speed).
2. **draft acceptance** — `draft acceptance = X (a / g)`; cross-check against t/s. Acceptance < ~0.8 → deeper speculation is net loss.
3. **Applied params confirmed** — log line `n_max=…, n_min=0, p_min=…` at load.
4. **Quality (my determination)** — extract generated text; assess:
   - objective flags: repetition loops (n-gram repeats), truncation, gibberish, prompt echo
   - semantic read: coherence, grammar, task adherence, factual plausibility
   - grade acceptable / degraded; only acceptable candidates can win.

## Sweep

- **Phase A — n-max:** {1, 2, 3, 4, 5} at `p-min = 0.7`. Pick best t/s among acceptable-quality candidates.
- **Phase B — p-min:** {0.5, 0.6, 0.7, 0.8, 0.9} at the winning n-max. Pick best.
- Final: confirm winner vs `{2, 0.7}` baseline; if a non-baseline wins, present the difference for user sign-off.

## Method per candidate

1. Edit `[qwen3.5-9b-mtp-16k]` spec-draft params in `models.ini`.
2. `docker compose restart llama-cpp`; wait for `/v1/models` 200.
3. Fire the benchmark request; watch `docker logs -f cortex-llama-cpp-1`.
4. Record t/s + acceptance; save output for quality assessment.
5. Restore best config with a comment: `spec-draft-n-max = N ; optimized (t/s)`, `spec-draft-p-min = X ; optimized (quality gate)`.

## AGENTS.md addition

New section "Tuning MTP speculative decoding" (parallel to the batch/ubatch section):
- Param semantics (n_max = draft depth, p_min = quality guard).
- The edit → restart → decode-bench → log-read loop (same style as batch tuning, but the metric is t/s + acceptance + quality, not OOM).
- Grep targets: `tokens per second`, `draft acceptance`, `n_max=…, p_min=…`.
- Tradeoff guidance: higher n_max isn't always faster (watch acceptance); p_min gates quality; quality is graded from output text, not logs.
- One-at-a-time sweep order (n-max first, then p-min at the winner).

## Files touched

- `llama-cpp/models.ini` — spec-draft params on `[qwen3.5-9b-mtp-16k]` (restored to tuned winner).
- `AGENTS.md` — new MTP spec-decoding tuning section.
- (plan moves to `archived/` when complete)
