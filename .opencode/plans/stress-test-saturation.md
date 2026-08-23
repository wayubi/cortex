# Plan: Add Phase-2 saturation test to batch/ubatch stress procedure

## Context

The current proven stress-test procedure in `AGENTS.md` (lines 47-68) validates a batch/ubatch value with a **tiny 20-token request**. That only proves the compute graph fits at near-empty context. With `-fit on` leaving ~zero VRAM headroom, the real memory peak is near full context (KV compaction temp buffers, hybrid/SSM state re-derivation) — a value can survive the 20-token probe and still OOM at ~16K once compaction triggers.

Goal: codify the saturation + compaction phase as the TRUE pass criterion, then re-validate the current winner (576) under it and continue the sweep down if it fails.

## Step 1 — Update `AGENTS.md` stress-testing section

Restructure the "Procedure (per candidate value)" list:

- Change step 7 wording: PASS on the tiny probe is only a **quick filter** — not sufficient.
- Insert **step 8 (Phase 2 — TRUE test: full-context saturation + compaction)**:
  - The saturation prompt is sized to the target model's configured `ctx-size` (NOT a fixed 16K). For an entry with `ctx-size = 16384`, saturate to ~14.5K tokens; for `ctx-size = 131072`, saturate to ~115K tokens. The target is ~90% of that entry's `ctx-size`.
  - Build one request with a prompt filling ~90% of that ctx and `max_tokens` large enough to overflow it and force KV compaction:
    ```
    SAT=$(python3 -c "print(('Qwen3.6-35B-A3B is a hybrid MoE with attention and SSM layers. '*N)[:SIZE])")
    # SIZE ≈ ctx-size * 4.5 chars (English ≈ 0.25 token/char), capped below nginx body limit (default 1MB)
    # max_tokens ≈ 20% of ctx-size (enough to overflow and force compaction)
    curl -s -X POST http://localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
      -d "{\"model\":\"<model>\",\"messages\":[{\"role\":\"user\",\"content\":\"$SAT\"}],\"max_tokens\":<~20% of ctx>}"
    ```
  - **TRUE PASS** = no OOM markers AND a compaction event fires (`n_past` reaches the ctx limit → sequence removal/shift, e.g. `the context supports bounded partial sequence removal`) AND request completes HTTP 200 with the full generation.
  - **FAIL** = any OOM marker during prefill/decode/compaction, or crash before compaction completes → step down by 64 and re-run the whole candidate loop (Phases 1 + 2).
  - Saturation runs are ~2 min each at 16K, and grow roughly linearly with ctx (long prefill + long generation) — only run on values that pass the quick filter.
  - For very large ctx (128K+), the saturation body approaches nginx's default 1MB `client_max_body_size` — raise it in `nginx.conf` or generate a tighter prompt if the request is rejected with 413.
- Move the "leave config at winning value with `; optimized (max, N+64 OOM)` comment" to step 9.
- Add a gotcha: the tiny probe is necessary but **not sufficient** — the true peak is near full context.

## Step 2 — Validate current winner (576) under saturation

The container is already running `batch/ubatch = 576 @ 16K` (config in `models.ini`). No restart needed for the saturation test.

1. Generate ~60 KB saturation prompt, POST with `max_tokens: 3000`, `--max-time ~240`.
2. Grep `docker logs cortex-llama-cpp-1` for:
   - OOM: `cudaMalloc failed` / `failed to allocate compute pp buffers` / `terminate called after throwing`
   - Compaction markers (`n_past` → 16384, sequence removal/shift)
   - Confirmation the generation completed (prompt eval + eval time lines, HTTP 200)
3. **If 576 passes** → done; leave config as-is; report.
4. **If 576 OOMs** → continue the sweep down by 64 (512 → 448 → …), re-probing each with Phases 1 + 2 until a value truly passes saturation+compaction. Leave `models.ini` at that value with the optimized comment.

## Files touched

- `AGENTS.md` — stress-testing section restructure (Phase 2).
- `llama-cpp/models.ini` — batch/ubatch value if 576 fails saturation.

## Notes

- If a passing saturation value lands below the pre-sweep 448, that confirms ctx headroom doesn't help `-fit` (consistent with the existing gotcha) and the real fix for larger batches remains `override-tensor = exps=CPU`.
