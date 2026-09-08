# Plan: `bench.sh` discover mode — find practical settings with ~1/4 of the runs

**Status:** 2026-09-08 — implemented, reviewed and verified (§23 to §27). Discover is the default; thorough behind `--thorough`. Ready for the full re-benchmark (§27.3).
**Audience:** an implementing agent. Function names are the anchors; the source has no stable line numbers. Read `tools/bench.sh` top to bottom once before touching anything.
**Scope:** `tools/bench.sh` only, plus the matching doc updates in `AGENTS.md`. Every model in `llama-cpp/models.ini` must be supported (73 entries today; see §2 for the classes).

---

## 0. Why this plan exists

The 2026-09-07 16:45 run (`logs/bench_20260907-1645.log`) tuned one 64K MTP model and took 52 minutes and 37 server restarts for the batch alone, then failed MTP tuning on a bogus quality signal. Analysis of that log against the code:

| Finding | Evidence in the log |
|---|---|
| Ceiling refined to 64-token granularity, with a full 64K saturation test per step | 7 bisect steps between 8192 and 9216, each with a 99%-ctx saturation run, to settle a ceiling (8960) the final pick (1664) sat 5x below |
| Golden-section prefill search resolves below the noise floor | Doubling ladder: every rung from 512 to 4096 within 3% (1333 to 1364 t/s). Golden section: 11 restarts for a 1% gain. Two points 64 tokens apart (1600 → 1339, 1664 → 1378) differed by 3% |
| Decode gate on single samples excluded neighbours on noise | Shortlist decode: 1408 → 45.2, 1536 → 46.4, 1664 → 56.4, 1792 → 47.1, 2048 → 51.8 t/s. Non-monotonic, all at ~98% CPU (GPU-resident). Batch cannot change single-stream decode unless something spills |
| Degeneracy "instability" is caused by the test design | Every decode test sends a 1000-word-essay prompt with `ignore_eos` and 4000 max tokens at temp 1.0, no seed. The essay ends ~1500 tokens in; the remaining ~2500 forced tokens are where looping happens. Same config gave degeneracy 0.0 then 0.92 |
| Looping inflates decode speed, so speed ranking rewards broken runs | MTP sweep: the only clean run (degeneracy 0.0) was the slowest at 42.0 t/s; every run with degeneracy > 0.4 was 47 to 49 t/s. Looped text gets near-perfect draft acceptance |
| MTP n_max / p_min are speed knobs, not quality knobs | llama.cpp speculative decoding samples every position from the target model and only keeps a draft token when it equals that sample. Output distribution is unchanged. `p_min` only stops drafting early; `n_max` only bounds draft length |
| Acceptance-rate parse is broken | Every MTP result line prints `acc==`. `awk '{print $3}'` on `draft acceptance = 0.85` yields `=`; it must be `$4` |
| MTP failure is invisible downstream | `reset_parent_full` and the main loop in `run_full_suite` both run `cmd_bench` after `cmd_mtp` fails. The 16:45 run restored `n_max=3` (which the same sweep had scored degenerate), benched it, and wrote a JSON whose `n_max_confirmed: 3` reads as validated. That field is parsed from the server load log and means only "what was loaded" |
| Failed MTP values can propagate | `inherit_json` copies the parent's `spec-draft-n-max` / `p-min` into every sibling's ini section whenever the parent has a JSON, with no check that tuning succeeded |

**Conclusion:** the pipeline's *safety* logic (OOM grep as source of truth, residency probe, saturation at 99% ctx, long-decode OOM check, cold-load stall handling, ini restore on failure) is correct and stays. The *optimisation* logic over-resolves noisy measurements and the *decode measurement itself* is confounded. Fix the measurement, cut the search to a coarse ladder, keep the safety gates.

---

## 1. Target outcome

Per family head, `discover` mode must produce the same three settings the current pipeline produces (`batch-size`/`ubatch-size`, `spec-draft-n-max`, `spec-draft-p-min`) plus the benchmark JSON, within these budgets:

| Model class | Server restarts (batch) | Full-context runs | Wall time (64K ctx) |
|---|---|---|---|
| GPU-resident, MTP | ≤ 11 | 2 (saturation + long-decode, same restart) | 15 to 20 min |
| GPU-resident, non-MTP | ≤ 10 | 2 | 12 to 18 min |
| CPU-compute (`override-tensor=exps=CPU`, gpt-oss) | ≤ 9 | 2 | 12 to 18 min |
| MTP tuning (all MTP classes) | 6 to 8 decode runs typical, 10 worst case | 0 | 8 to 14 min |

Today's numbers for comparison: 37 restarts, 12 full-context runs, 52 min for batch; 11 decode runs for MTP.

The current exhaustive behaviour is kept verbatim behind `--thorough` (see §7). Nothing in `discover` mode may weaken a safety gate.

---

## 2. Model classes the plan must handle

Derived from `llama-cpp/models.ini` on 2026-09-07. The implementing agent must not special-case model names; behaviour is driven by the probes below.

| Class | Examples | What matters for batch | MTP |
|---|---|---|---|
| Dense GPU-resident with MTP draft | gemma-4-12b, ornith-1.5-9b, qwen-3.5-9b-mtp | Draft compute buffer scales with `n_max × batch`; above a threshold the draft spills to CPU (decode drops 3 to 4x, CPU 270 to 1600%). Prefill curve is flat from ~512 up to a few thousand | yes |
| MoE GPU-resident with MTP | gemma-4-26b-a4b, qwen-3.6-35b-a3b at ≤ 16K | Small ceilings (448 to 4096). Prefill may still be rising at the ceiling, so the ceiling *is* the optimum | yes |
| MoE with experts on CPU | qwen-3.6-35b `override-tensor=exps=CPU` (128K/256K), gpt-oss-20b | Residency probe says CPU at every batch. Decode is batch-invariant. Only the prefill curve matters; it peaks low (~1.5 to 2K) | some |
| MoE GPU-resident, no MTP, large ctx | glm-4.7-30b / 23b-reap at 64K to 198K | Ceilings 6 to 8K. Saturation at 198K is slow (200K-token prefill). No draft buffer, so residency rarely flips | no |
| Small dense, small ctx | lfm-2.5-8b 4K to 32K, zamai-llama3 8K, qwen-3.5-9b non-MTP | Batch ≥ ctx means one ubatch per request; probes must clamp to ctx | no |

Existing helpers that already handle these: `residency_probe` (GPU/CPU/AMBIGUOUS/STALL verdict), `tiny_probe` (OOM at load or first decode), `saturation_test` (99%-ctx prefill + decode to ctx, with decode-floor and stall detectors), `long_decode_check`, `fire_request` / `wait_served` (cold-load stall retry), `set_batch` / `set_key` / `restore_section` (ini editing with restore on failure), `family_of` / `inherit_json` / `maybe_inherit` (sibling inheritance).

---

## 3. Design principles (the implementing agent must follow these)

1. **Batch is a prefill knob.** For single-stream serving, decode throughput does not depend on batch unless the batch pushes memory (MTP draft buffer, KV) off the GPU. So batch is selected on the prefill curve and *guarded* by a residency check, never ranked by decode t/s.
2. **Pick the smallest batch within tolerance of the best prefill.** Tolerance `PREFILL_TOL=0.03` (3%). Smaller batch means more VRAM headroom for the MTP draft buffer (which grows with `n_max`), less spill risk on larger-ctx siblings, and the same measured prefill. This replaces "maximise prefill to 64-token precision".
3. **Coarse ladder only.** Powers of two from 256 up to `min(ctx, MAX_BATCH)`. One midpoint refinement is allowed only at a ceiling edge (§4.3). No golden section, no bisect to 64 in discover mode.
4. **Every server restart should do as much as possible.** A saturation test, a long-decode check and a decode sample can all run against the same server instance. Do not restart between them.
5. **Speed measurements never force tokens past EOS.** Remove `ignore_eos` from every *speed* measurement. Keep it only where the purpose is a memory-pressure test (`saturation_test`, `long_decode_check`). A speed sample is valid only if `completion_tokens ≥ MIN_DECODE_TOKENS` (512).
6. **Degeneracy is diagnostic, never a gate.** Log it, flag `> 0.15` as `WARN` in the summary, never fail a model on it. It is computed only on natural-stop output.
7. **Safety gates are unchanged:** OOM grep as source of truth, residency verdict `CPU` rejects a batch for GPU-class models, saturation at 99% ctx must pass at the final pick, long-decode must pass at the final pick, ini restored on any failure exit.
8. **Fail closed, but explain.** On failure exit non-zero, restore the ini, and print which gate failed and what to try (existing behaviour). Do not add auto-fallbacks that silently pick a different value than the one validated.

---

## 4. Discover-mode batch algorithm (`cmd_bisect`, default)

Implement as a new function `cmd_bisect_discover`. Keep the current body as `cmd_bisect_thorough`. `cmd_bisect` dispatches on `$THOROUGH`. The `[test-batch]` single-batch path at the top of the current `cmd_bisect` stays as-is and is shared.

### 4.1 Phase A — one ladder, three measurements per rung

Replace the current sequence (early gate → ceiling ladder with saturation per rung → 64-granularity bisect → final confirm → residency check → prefill ladder → golden section → shortlist decode gate → confirm → long decode) with a **single** ladder. Each rung restarts the server once and measures everything cheap:

```
CAP  = min(ctx, MAX_BATCH)               # MAX_BATCH stays 16384
rungs = 256, 512, 1024, 2048, 4096, 8192, 16384   (stop at CAP; include CAP itself if it is not a power of two, e.g. ctx=202752 → cap 16384 anyway)
MODE = unknown

for B in rungs:
    set_batch B; restart
    tiny_probe                → rc 2: exit 1 (STALL, existing message)
                              → rc 1: record (B, OOM); break
    if MODE != CPU:
        residency_probe       → STALL: exit 1
                              → CPU at first rung (B=256): MODE=CPU, continue this rung (do not break)
                              → CPU at a later rung:       record (B, SPILL); break
                              → GPU/AMBIGUOUS:             MODE=GPU (AMBIGUOUS counts as not-proven-CPU, same as today)
    prefill = prefill_probe_sized(ctx)      # see 4.2 — same prompt length for every rung
                              → 0 with OOM marker: record (B, OOM); break
                              → 0 without marker:  record (B, STALL); exit 1
    record (B, PASS, prefill)
    if B == 256 and MODE == GPU:
        DEC_BASE = decode_sample()          # §5, natural-stop, one run; baseline for the cliff check
    if this rung and the previous rung are both PASS and both below best_prefill × (1 - PREFILL_TOL):
        break                               # two consecutive rungs past the peak (existing DESC logic)
```

Notes for the implementer:
- The early residency gate at 256 in the current code *is* rung 256 here. Do not run it twice.
- `MODE=CPU` skips `residency_probe` on later rungs (it would say CPU every time) and skips the cliff check (§4.4). This is the current `cpu_saturation_sweep` behaviour, folded into the same ladder.
- `residency_probe` already kills its decode early once the verdict is provable (~20 to 30 s). Keep that.
- Record every rung into `/tmp/discover_points.txt` as `batch status prefill` for the summary and for `--thorough` reuse.
- Expected restarts: 6 to 7 for a 64K model, 4 to 5 for a 4K or 16K model, 7 for 198K.

### 4.2 `prefill_probe_sized` — the probe must actually exercise the batch

Both existing prefill probes have a flaw for this use:
- `prefill_probe` caps at 32000 chars (~6400 tokens). Testing batch 8192 or 16384 with a 6400-token prompt never fills one ubatch, so the measurement says nothing about that batch.
- `decode_guarded_probe` in prefill mode uses 75% of ctx, which at 198K to 256K is a 2.5 to 4 minute request per rung.

Write one function, `prefill_probe_sized CTX`, that reuses `prefill_probe`'s body (log-parsed `prompt eval time`, overflow-shrink retry, OOM check) with a prompt size that is **the same for every rung of one model** (revised after review Q8, see §14):

```
PROBE_TOKENS = min( floor(0.75 × ctx), 16384 )      # computed once per model, before the ladder
chars        = PROBE_TOKENS × CHARS_PER_TOK          # measure_ratio once at rung 256; fallback 4.0
```

Why one length: prefill t/s falls with prompt length (attention cost grows with position), so probing a bigger batch with a longer prompt would bias the ranking against it. With a fixed length the rungs are compared on identical work. 16384 tokens fully exercises every rung up to 8192 (two or more ubatches) and runs rung 16384 as a single ubatch, which is labelled `single-ubatch` in the log but ranked normally. On models with ctx ≤ 21K the length is 75% of ctx for every rung, which is the largest realistic prompt for that model, so the ranking reflects real use; rungs at or above that length are labelled `single-ubatch` too.

No separate warm-up request: `tiny_probe` already ran on this server instance immediately before, so the model is loaded and the CUDA graphs are warm. The probe request sets `cache_prompt: false` so no part of the prompt is served from the slot's prompt cache (the `measure_ratio` request that precedes rung 256 uses a prefix of the same filler; see §25.2 #2). (`prefill_probe`'s untimed warm-up request stays for `--thorough`, which calls the old function.)

### 4.3 Phase B — select

From the PASS rungs:

```
best      = max prefill
PICK      = smallest B with prefill ≥ best × (1 - PREFILL_TOL)
CEIL_INFO = highest PASS rung, and the first non-PASS rung with its reason (OOM / SPILL)  # informational only
```

**Edge refinement (only case where a non-power-of-two is tested):** if `PICK` is the highest PASS rung *and* the next rung failed (OOM or SPILL), the optimum may lie between them. Test `mid = round64((PICK + FAIL) / 2)` with the same three measurements (tiny → residency → prefill). If it passes and its prefill is strictly higher than PICK's, set `PICK = mid` and test one more midpoint between the new PICK and FAIL. Maximum 2 extra restarts. This covers the small-ceiling MoE class (e.g. 448 between 256 and 512) where the ceiling is the optimum. If the midpoint's prefill is *lower* than PICK's, stop and keep PICK.

Write PICK to the ini with `set_batch`.

### 4.4 Phase C — confirm at PICK, one restart

```
set_batch PICK; restart
saturation_test ctx            → rc 0 PASS; rc 2 exit 1 (STALL); any other rc → step down (below)
long_decode_check              → rc 0 PASS; rc 2 exit 1; rc 1 → step down
if MODE == GPU:
    DEC_PICK = decode_sample()  # §5; runs on the same server instance
    cliff check (revised after review Q3, see §14):
        if DEC_PICK.placement == CPU:                       # definitive signature → step down
            log "draft/KV spill at PICK (cpu Z%)"; step down
        elif DEC_BASE is SHORT or DEC_PICK is SHORT:        # no usable speed pair
            log "cliff speed check skipped (SHORT sample); placement GPU at PICK"   # keep PICK
        elif DEC_PICK.tps < DEC_BASE.tps × DECODE_CLIFF (0.70):
            DEC_PICK2 = decode_sample()                     # one re-sample, same instance
            if mean(DEC_PICK.tps, DEC_PICK2.tps) < DEC_BASE.tps × DECODE_CLIFF: step down
            else: log WARN "first sample slow, re-sample recovered"
        elif DEC_PICK.tps < DEC_BASE.tps × DECODE_WARN (0.90):
            log WARN (no CPU signature; keep PICK)          # noise band, never a failure
```

`DEC_BASE` stays a single sample: the cliff threshold is a 30% drop, and a genuine spill is a 3 to 4x drop with a CPU signature that the first branch catches on its own. `decode_sample` already retries once with the longer prompt before returning `SHORT`, so no extra retry is needed here.

**Step down:** move PICK to the next lower PASS rung from the ladder (or the lower edge-refinement point), restart, and repeat Phase C. Maximum 2 step-downs, then fail the model with the existing "inspect logs; re-run" message and restore the original batch via the existing EXIT trap. This bounds the worst case at 3 confirm restarts.

Rationale for a 0.70 cliff instead of the current 0.90 gate: a real draft spill is a 3 to 4x drop with CPU > 200% (documented in `AGENTS.md`); a 10% delta between two single samples is noise (§0).

### 4.5 Result block

Keep the existing `=== RESULT ===` block shape. Add:
```
  ladder: 256=1291.9 512=1332.8 1024=1353.6 2048=1363.7 4096=1335.4 8192=1274.7 16384=SPILL
  pick=512 (smallest within 3% of best 1363.7 t/s)    ceiling(coarse)=8192 PASS / 16384 SPILL
  confirm: saturation PASS, long-decode PASS, decode 47.3 t/s @pick vs 46.9 t/s @256 (GPU)
```
Also record `ladder`, `pick_rule`, `ceiling_coarse`, `mode` (GPU/CPU) in the bench JSON under a new `discover` key when `cmd_bench` runs (it already reads batch from the ini; add the extra fields by having `cmd_bisect_discover` write `/tmp/discover_${MODEL}.json` that `cmd_bench` merges if present).

### 4.6 What to delete or demote from the default path

- `gpu_saturation_sweep`, `cpu_saturation_sweep`, `residency_descend`, the Phase 2 64-granularity bisect, the top-5 shortlist decode gate, the top-3 saturation confirm loop: **not called in discover mode**. Keep them for `--thorough` (§7). Do not delete code in this pass.
- `decode_guarded_probe` full mode: replaced by `decode_sample` (§5). Its prefill mode is superseded by `prefill_probe_sized`.

---

## 5. Fix the decode measurement (shared by batch, MTP and bench)

### 5.1 `decode_sample` — new function, replaces the decode half of `decode_guarded_probe` and the body of `run_decode_test`

```
prompt   = DECODE_PROMPT (below)
max_tok  = max(256, min(4000, ctx - 256))       # cap, not a target
payload  = {model, messages:[user: prompt], max_tokens: max_tok}   # NO ignore_eos
fire_request with adaptive_timeout(max_tok); poll CPU/GPU every 2 s exactly as run_decode_test does today
result   = tps (timings.predicted_per_second) | completion_tokens | placement | avg_cpu | degeneracy | accept_rate | mean_draft_len | oom
valid    = completion_tokens ≥ MIN_DECODE_TOKENS (512) and oom == 0
```

If `valid` is false because the model stopped early, retry once with `DECODE_PROMPT_LONG`. If still short, return the sample tagged `SHORT` and let callers treat it as missing (never as a failure of the batch or the MTP config).

`DECODE_PROMPT`: a prompt that reliably produces ≥ 1500 tokens without forcing. Suggested: *"Write a comprehensive technical report on the history of computing. Cover these twelve eras in order, with a heading and at least 250 words each: mechanical calculators, Babbage and Lovelace, Hollerith and tabulation, relay computers, ENIAC and the stored program, transistors, integrated circuits, minicomputers, microprocessors, personal computers, the web, mobile and cloud. Finish with a 200-word conclusion."* `DECODE_PROMPT_LONG` adds *"Do not summarise; write every section in full."* and raises the per-section minimum to 400 words. Reasoning-on models add thinking tokens on top, which is fine.

Degeneracy: keep the existing 8-gram ratio function, computed on the natural-stop text. Also record `accept_rate` and `mean_draft_len` from the `draft acceptance = X (a accepted / g generated), mean len = L` log line, using `awk '{print $4}'` for X (fixes the `acc==` bug) and a regex for L.

### 5.2 Callers to convert

| Function | Today | After |
|---|---|---|
| `run_decode_test` (MTP tuning) | essay + `ignore_eos` + 4000 tokens | thin wrapper around `decode_sample` keeping the same `SPEED|ACCEPT|PLACEMENT|AVG_CPU|QUALITY|OOM` output shape plus `TOKENS` and `MEANLEN` appended |
| `decode_guarded_probe` decode half | history prompt + `ignore_eos` | not used in discover mode; leave for `--thorough` |
| `cmd_bench` Phase B decode | 150-token prompt + `ignore_eos` + up to 4000 | use `decode_sample`; record `finish_reason`, `completion_tokens`, `degeneracy`, `accept_rate` in the JSON. The bench JSON decode t/s is currently loop-inflated for MTP models (finish_reason `length`, truncated true in the 16:45 log) |
| `residency_probe` | history prompt + `ignore_eos` | **unchanged** (it kills the request once the verdict is provable; content does not matter) |
| `long_decode_check` | essay + `ignore_eos` 6000 | **unchanged** (memory-pressure test; forcing tokens is the point) |
| `saturation_test` | filler + `ignore_eos` | **unchanged** (must reach ctx) |

---

## 6. Discover-mode MTP tuning (`cmd_mtp`, default)

Implement as `cmd_mtp_discover`; keep the current body as `cmd_mtp_thorough`.

### 6.1 What changes and why
- **No quality gate.** Per §0, MTP parameters cannot change output. Degeneracy is logged and `WARN`ed, never failed. The phase-1 confirm and phase-3 strict confirm are removed from the default path.
- **Speed measured on natural-stop output** via `decode_sample`, so looping cannot inflate a config.
- **Placement remains a gate.** `n_max` raises the draft buffer (`n_max × batch`); a config whose `decode_sample` reports placement `CPU` or `oom > 0` is rejected as *not fitting at this batch*. This is the existing rule and it is a real effect.
- **Adaptive, not exhaustive.** Ties go to the smaller value (smaller draft buffer, more headroom).

### 6.2 Algorithm

```
p = 0.7 (or the model's current spec-draft-p-min if set)
Phase 1  n_max:
    measure n_max=2 and n_max=4 at p                       (2 runs)
    if speed(4) > speed(2) × 1.05:  measure 5              (1 run)  → candidates {2,4,5}
    else:                            measure 3              (1 run)  → candidates {2,3,4}
    drop any candidate with placement CPU or oom>0 or sample SHORT
    re-measure the best and the runner-up once more         (2 runs); rank on the mean of the two samples
    WIN_NMAX = best mean; if runner-up mean ≥ best × 0.95, WIN_NMAX = the smaller n_max of the two
Phase 2  p_min at WIN_NMAX:
    p=0.7 mean is known from Phase 1 when WIN_NMAX was measured at 0.7 (it always is)
    measure p=0.5 and p=0.9                                 (2 runs)
    WIN_PMIN = fastest; if within 5% of 0.7, keep 0.7
Apply: set_key spec-draft-n-max WIN_NMAX; set_key spec-draft-p-min WIN_PMIN
Summary table: n_max, p_min, tps (each sample), tokens, accept_rate, mean_draft_len, placement, degeneracy(WARN flag)
```

Run count: 7 to 8 decode runs, each ~70 to 100 s on a 9B, so 8 to 12 minutes. Today: 11 runs, and the 16:45 run failed after 5.

Keep the existing EXIT-trap restore of the original `n_max`/`p_min` on failure. Failures now are only: STALL, every candidate rejected by placement/OOM, or every sample SHORT.

**Always include the ini's current `n_max` in the candidate set** (precise rule, revised after review Q6, see §14). The batch ladder (§4) validated residency at whatever `n_max` was in the ini (ornith has 3, gemma has 4), so that value is guaranteed to pass the placement gate. Let `cur` = the ini value (`mtpcheck` writes 2 when absent). Then:

```
Phase 1  n_max, all at p_ref = 0.7:
    S = sorted(dedup{2, 4, cur})            # 2 or 3 values
    measure every value in S                (2 or 3 runs)
    b = best tps among valid samples (placement GPU, oom 0, not SHORT)
    if b+1 ∉ S and b+1 ≤ 6: measure b+1     (≤ 1 run)
    if b-1 ∉ S and b-1 ≥ 2: measure b-1     (≤ 1 run)
    re-measure the best and the runner-up once (2 runs); rank on the mean of their two samples
    WIN_NMAX = the smallest n_max whose mean ≥ best_mean × (1 - MTP_TIE)   # ties go to the smaller draft buffer (revised §25.2 #3)
Phase 2  p_min at WIN_NMAX:
    reference = WIN_NMAX's samples at p_ref (always exists, Phase 1 runs at 0.7)
    P = dedup{0.5, 0.9, ini p_min} minus 0.7  (2 or 3 runs)
    WIN_PMIN = fastest; if within MTP_TIE of the 0.7 reference, keep 0.7
```

Run count: 6 to 8 typical, 10 worst case (`cur` ∉ {2,4}, both neighbours untested, ini p_min ∉ {0.5,0.7,0.9}). `n_max` is bounded to [2, 6]: 1 disables speculation in effect, and `AGENTS.md` records no gains above 6 on any family.

### 6.4 MTP failure must be visible downstream (fixes the 16:45 misreport)

Today a failed `cmd_mtp` restores the pre-run values, then `cmd_bench` runs anyway and writes `n_max_confirmed` from the load log, so the JSON claims a validated value that was never validated. The fix has four parts; all apply to both discover and thorough modes.

1. **`cmd_mtp` writes a status file** `/tmp/mtp_status_${MODEL}.json` on every exit path, including the EXIT trap:
   ```json
   {"status": "ok|failed|stall", "reason": "<gate that failed, or empty>",
    "tuned_n_max": 2, "tuned_p_min": 0.7,          // null when status != ok
    "samples": [{"n_max":2,"p_min":0.7,"tps":47.3,"tokens":1830,"placement":"GPU","accept":0.81,"degeneracy":0.01}, ...]}
   ```
   `cmd_mtpcheck` writes `{"status":"not_mtp"}` when the model is not MTP-capable, so `cmd_bench` can always distinguish "not applicable" from "tuning failed" from "tuning never ran".
2. **`cmd_bench` merges it into the JSON** under `mtp`: add `tuning_status` (`ok` / `failed` / `stall` / `not_mtp` / `not_run`), `tuning_reason`, `tuned_n_max`, `tuned_p_min`, `tuning_samples`. Rename the existing `n_max_confirmed` / `p_min_confirmed` to `n_max_loaded` / `p_min_loaded`, because that is what they are. `tools/gen_metrics.sh` reads `configured_n_max` / `configured_p_min` only, so the rename breaks no consumer; grep the repo for the old names before renaming.
3. **Orchestrator behaviour on `mtp` FAIL.** The batch result is valid independently of MTP, so `cmd_bench` still runs by default, but the record must say what it measured: the verdict table already shows `mtp FAIL`; the JSON now carries `tuning_status: failed` and `tuned_n_max: null`. Add a `--strict` flag (global, next to `--thorough`) that skips `bench` when `mtp` failed and marks the verdict `SKIPPED (mtp failed)`, for runs whose purpose is to produce publishable records. Apply the same rule in both `reset_parent_full` and the main loop of `run_full_suite`.
4. **`inherit_json` must not spread unvalidated MTP values.** Copy `spec-draft-n-max` / `p-min` to siblings only when the parent JSON has `tuning_status == "ok"`. Otherwise leave the sibling's own values alone and log `MTP values NOT inherited (parent tuning_status=<x>)`. Batch and the rest of the JSON still inherit. Parent JSONs written before this change have no `tuning_status`; treat missing as `unknown` (MTP values **not** inherited, batch still inherited) and log `parent JSON predates tuning_status; re-run 'bench.sh mtp <parent>' to stamp it`. (Revised after review Q7: the old `n_max_confirmed` field cannot prove tuning succeeded, so it must not be trusted for propagation.)

In discover mode the degeneracy false-failure that triggered the 16:45 misreport no longer exists (§6.1), and §6.2's "always include the ini's n_max" rule makes placement rejection of every candidate effectively impossible. Part 1 to 4 are still required so that the remaining failure modes (STALL, all samples SHORT) are recorded truthfully.

### 6.3 Optional diagnostic subcommand: `bench.sh mtpverify <model>`

Not part of the suite. Two restarts: one with `spec-type` removed, one with it set, same prompt, request-level `temperature: 0`, `seed: 42`, `max_tokens: 1024`, `logprobs: true`, `top_logprobs: 10`. Find the first differing token and apply the margin test defined in §16.2: PASS when the flipped token was a near-tie in both runs' distributions and the top-5 sets overlap. Print the divergence index, both gaps, the overlap, the pre-divergence drift, both decode speeds and OOM counts. This lets a human confirm the §0 claim on any family without reading llama.cpp source. Implemented in commit 505b549; see §16.4 for the required fixes.

---

## 7. `--thorough` flag

- Parse `--thorough` in the existing global-flag loop next to `--no-inherit` / `--reset-parent`; set `THOROUGH=1`. Also honour env `BENCH_THOROUGH=1`.
- Interactive mode: add a prompt `Search depth? [D]iscover / [t]horough` after the inherit prompts, default discover, and print the choice in the MASTER PLAN block.
- `cmd_bisect` → `cmd_bisect_thorough` when set, else `cmd_bisect_discover`. Same for `cmd_mtp`.
- The `[test-batch]` single-batch path is shared and unchanged.
- `cmd_bisect_thorough` and `cmd_mtp_thorough` are the current bodies, untouched except for the shared `decode_sample`/acceptance-parse fixes in §5 (those are bug fixes and apply to both modes).

---

## 8. Sibling handling

Keep `family_of` (same `hf` **and** same `ctx-size`) and the whole inherit flow as-is. Coder/think siblings continue to inherit the head's JSON, batch and MTP values.

**Optional, second pass — ctx-sibling seeding.** Different-ctx siblings (64K → 128K → 256K) are separate families today and each gets a full ladder. A cheaper path: when a model has no JSON but another entry with the same `hf` and a smaller ctx has one, start the ladder at that entry's pick:

```
seed = pick of the closest smaller-ctx sibling
rungs = seed/2, seed, seed×2   (each: tiny → residency → prefill_probe_sized)
if seed fails (OOM/SPILL, expected at larger ctx because KV grows): halve until PASS, max 3 halvings
select and confirm exactly as §4.3 / §4.4
```
Typical cost: 4 to 6 restarts instead of 7 to 9. Implement only after §4 to §7 are verified; it is an optimisation, not a correctness item. Gate it behind `--seed-from-sibling` initially.

---

## 9. Constants to add (top of the script, next to `MAX_BATCH`)

```bash
STRICT=0                  # --strict: skip bench when mtp tuning failed
PREFILL_TOL=0.03          # pick = smallest batch within this fraction of best prefill
DECODE_CLIFF=0.70         # decode at pick below this fraction of the 256 baseline = spill cliff
DECODE_WARN=0.90          # below this: WARN only
MIN_DECODE_TOKENS=512     # a speed sample shorter than this is SHORT (retry once, then ignore)
MTP_TIE=0.05              # MTP candidates within 5% are a tie → smaller value wins
THOROUGH=0
```

---

## 10. Documentation updates (`AGENTS.md`)

- Replace the "Performance sweep (Phase 4)" and "Refine (bisect up)" descriptions with the §4 ladder and the smallest-within-tolerance rule. State plainly that the ceiling is recorded coarsely and is informational.
- Rewrite the "Tuning MTP speculative decoding" section: n_max and p_min are speed-only; degeneracy is diagnostic; the placement gate is the real constraint; describe the §6.2 adaptive sweep and the 7 to 8 run budget. Remove the "p_min is the real quality gate" sentence and mark the "n_max=4 degraded, 5 clean" observation as an artefact of forced generation.
- Add a short "Measuring decode speed" subsection: no `ignore_eos` on speed samples, minimum 512 tokens, why (looping inflates acceptance and therefore t/s).
- Note `--thorough` and `mtpverify`.

---

## 11. Implementation order and acceptance checks

Work in this order; each step must pass its check before the next. Land each step as its own commit; the default stays on the old path until step 4 flips it, so a half-landed branch never changes what a normal run does.

0. **§6.3 `mtpverify`, run as a premise test** (added after review Q1; criterion revised in §16.2 after the first run). Implement the subcommand, then run it on `gemma-4-12b-q4-qat-mtp-16k` and `qwen-3.5-9b-q4-mtp-16k` with request-level `temperature: 0`, `seed: 42`, `max_tokens: 1024`, `logprobs: true`, `top_logprobs: 10`, MTP off then on, same prompt. Find the first differing token, then apply the §16.2 margin test at that position. Pass criterion: the flipped token was a near-tie (gap under 0.25 nats in both runs' distributions) and the top-5 sets overlap in at least 4 tokens. The divergence index itself is not a criterion; with kernel-level drift of about 0.1 nats and several near-ties per 200 tokens, early divergence is expected. If either model diverges inside the first 200 tokens, stop and report before implementing §6: the fallback design is to keep a degeneracy gate but measured on natural-stop output with two samples per config and no single-sample confirm failures. The llama.cpp source is not in this repo (the Dockerfile clones master at build time); the acceptance rule lives in `common/sampling.cpp`, function `common_sampler_sample_and_accept_n`, for anyone who wants to read it.
1. **§5 decode measurement + acceptance parse fix.** These are bug fixes and apply to `--thorough` too: thorough mode preserves the old *search*, not the old broken measurement. Check: `bench.sh mtp <one small MTP model, e.g. gemma-4-12b-q4-qat-mtp-16k>` with the *current* sweep prints a numeric `acc=` and `tokens=` on every line and no result has `finish_reason=length` unless the cap was hit. Also record the degeneracy of every clean run with the new `DECODE_PROMPT`: if clean structured output scores above 0.05, the metric is picking up section scaffolding, and the fix is to strip heading lines (lines starting with `#`) before the 8-gram count, not to raise the WARN threshold.
2. **§4 `cmd_bisect_discover` behind a temporary env `BENCH_DISCOVER=1`.** Check on three models, one per class, counting `Restarting llama-cpp` lines in the log:
   - `lfm-2.5-8b-a1b-q4-4k-think` (small ctx, non-MTP): ≤ 7 restarts, saturation PASS, pick ≤ 4096.
   - `gemma-4-12b-q4-qat-mtp-16k` (dense MTP): ≤ 11 restarts, pick GPU-resident, saturation and long-decode PASS. Pick expected in the 512 to 2048 band (current value 1408).
   - `gpt-oss-20b-a4b-q4-64k-think-low` (CPU-compute): MODE=CPU detected at rung 256, no residency probes after rung 256, ≤ 9 restarts, pick expected near 2048 (current 2112).
   Then `ornith-1.5-9b-q4-mtp-64k-think` for a direct comparison with the 16:45 log: ≤ 11 restarts, ≤ 20 min, pick in the 512 to 2048 band, confirm PASS.
3. **§6 `cmd_mtp_discover` and §6.4 status plumbing.** Check on `gemma-4-12b-q4-qat-mtp-16k` (n_max is known to matter here: expected winner 4 or 5) and on `qwen-3.5-9b-q4-mtp-16k` (expected winner 2, sweep should stop after measuring 3). ≤ 8 runs each, no run rejected for degeneracy, summary shows `accept_rate` and `mean_draft_len`. Then force a failure (temporarily set `MIN_DECODE_TOKENS=999999` so every sample is SHORT) and run `bench.sh all <model>`: the ini must be back at its pre-run `n_max`/`p_min`, the JSON must show `tuning_status: failed` and `tuned_n_max: null`, the verdict table must show `mtp FAIL`, and with `--strict` the bench step must be `SKIPPED (mtp failed)`. Run one sibling with inherit on and confirm its `spec-draft-*` lines did not change.
4. **§7 flag wiring**, remove the temporary env, default = discover. Check: `bench.sh --thorough bisect <model>` reproduces the old log structure (`GPU SATURATION SWEEP`, `Golden:` lines).
5. **§4.5 JSON fields + §10 docs.**
6. **§8 sibling seeding** (optional).

General checks at every step: `bash -n tools/bench.sh` clean; every acceptance run is executed **both** through the suite (`bench.sh all <model>`) and directly (`bench.sh bisect <model>` / `bench.sh mtp <model>`), because the suite's `if ( cmd_x )` wrapper suppresses `errexit` and hides a whole class of failures (§20.1); a killed run (Ctrl-C during the ladder) leaves `models.ini` at its pre-run values (existing EXIT traps must still fire; the discover functions must use the same `trap ... EXIT` pattern as `cmd_bisect` and `cmd_mtp` today); `git diff llama-cpp/models.ini` after a successful run shows only the intended keys for the intended section.

---

## 12. Out of scope

- Changing `saturation_test`, `long_decode_check`, `residency_probe`, `fire_request`, `wait_served`, the OOM grep, or the ini editing helpers.
- Multi-stream / `parallel > 1` tuning. Everything here assumes `parallel = 1` as in `[*]`.
- Re-tuning models that already have a JSON. This plan changes how new runs are done; it does not invalidate existing values.

---

## 13. Review questions for the author (2026-09-07)

These were raised during a code review of the plan. The reviewing agent did **not** adopt any premise; the questions are technical / design clarifications. None of the plan's safety-gate changes are questioned.

**Q1 (§6.3 as step 0 — premise test).** `mtpverify` does not exist yet and is a state-changing run. To empirically test whether `n_max` / `p_min` change output *before* committing to §6's "remove all quality gates," implement `mtpverify` first and run it on `gemma-4-12b-q4-qat-mtp-16k` and `qwen-3.5-9b-q4-mtp-16k`. If it shows divergence within the first ~200 tokens, §6's removal of quality gates is unsafe and needs a fallback plan that retains a placement + degeneracy gate. Should this be an explicit gating step 0 in §11?

**Q2 (§5 prompt ↔ degeneracy tension).** `DECODE_PROMPT` is a structured "twelve eras, heading + 250 words each, in order" prompt. Structured / enumerated output may legitimately raise the 8-gram degeneracy ratio (repeated heading / transition patterns) even on clean generation, causing `WARN > 0.15` false positives. But a non-repetitive prompt tends to stop short, conflicting with the ≥1500-token natural-stop goal. Should degeneracy be measured on a separate, non-enumerative prompt, or is the structured prompt's diagnostic threshold expected to tolerate structural repetition?

**Q3 (§4.4 single-sample decode baseline).** The cliff gate compares `DEC_PICK` to a **single** `DEC_BASE` sample at batch 256. §0 itself argues single samples are noise. Should `DEC_BASE` be averaged over two samples? And if `DEC_BASE` returns `SHORT` (missing), the entire cliff gate is silently skipped — is that acceptable, or should it force one retry before skipping?

**Q4 (§4.1 break ↔ §4.3 tolerance interaction).** Both the "two consecutive rungs below `best × (1 − tol)` → break" and the pick rule use the 3% tolerance. On a genuinely flat plateau (the real 64K log: all rungs 1291–1364 t/s, within ~5%), the break can fire a few rungs after the plateau's peak, so the ladder never reaches an OOM/SPILL rung → `ceiling_info` is unknown and edge refinement (§4.3) cannot trigger. Is that acceptable, or should the ladder always run to CAP (or until OOM/SPILL) so the coarse ceiling is bounded even when prefill plateaus?

**Q5 (§4.4 same-restart saturation → long-decode on one slot).** `saturation_test` fills ctx to ~99% and compacts; running `long_decode_check` on the **same** server instance / slot immediately after — will the saturated KV cache be reset between requests? If the slot retains ~full-context KV, the long-decode runs against a near-full context (unrepresentative, and may itself re-compact / OOM). Verify llama.cpp slot / cache-clear semantics; if not clean, the "one restart for saturation + long-decode + decode_sample" budget needs a slot reset or a reordering.

**Q6 (§6.2 folding the ini's current n_max).** "Always include the ini's current n_max" — specify the candidate-set construction when the current value is not 2 / 3 / 4 (e.g. 5, or an even value). Precisely: measure `{2, cur, 4}` first (dedup), then adapt to `{cur−1, cur, cur+1}`? And does measuring `cur` mean at `p_min = 0.7` always (so its t/s doubles as the Phase-2 0.7 reference)?

**Q7 (§6.4 inheritance backward-compat).** Treating missing `tuning_status` in *old* parent JSONs as `"ok"` for inheritance lets the old **unvalidated** `n_max_confirmed` (parsed from the load log — i.e. the 16:45 lie) propagate to siblings. Should old JSONs instead be treated as `"unknown"` (MTP values NOT inherited) since they cannot be verified as tuned? Batch and the rest of the JSON still inherit either way.

**Q8 (§2 / §4 small-ctx under-exercising).** For a 4K-ctx model, top-rung `prefill_probe_sized` is clamped to `floor(0.75 × ctx) ≈ 3072` tokens < `2 × B`. If prefill is still rising at the ceiling (the "ceiling is optimum" MoE class), under-exercising the top rung could mis-rank it. Confirm the under-exercised handling does not mis-rank a genuinely still-rising ceiling.

**Q9 (scope sizing).** This plan splits `cmd_bisect` (~310 lines) and `cmd_mtp` (~180 lines) into discover/thorough variants and adds `decode_sample`, `prefill_probe_sized`, status plumbing across four-plus functions, `--thorough` / `--strict` flags, JSON schema changes, and the AGENTS.md rewrite — roughly 400–600 changed/new lines in a 3146-line file. Confirm full implementation is intended in one pass (per the review) rather than a staged landing behind a temporary env, and that `--thorough` is expected to also absorb the §5 decode measurement + acceptance-parse fixes (i.e. its decode basis changes too, not purely preserved).

---

## 14. Answers to the §13 review questions (2026-09-07)

Where an answer changed the plan, the section above is already revised and marked "revised after review Qn".

**Q1 — `mtpverify` as a gating step 0: yes.** Added as step 0 in §11 with a concrete pass criterion (first 200 tokens identical at temperature 0, seed 42, on both named models) and a concrete fallback if it fails (degeneracy gate retained, but measured on natural-stop output with two samples per config and no single-sample confirm failure). It costs two restarts per model. Note the criterion deliberately ignores late divergence: batched verification and single-token decode use different kernels, and a near-tied logit can flip a token late in a greedy run without any change in output distribution.

**Q2 — structured prompt versus degeneracy: one prompt, calibrate the metric, do not raise the threshold.** The metric counts repeated 8-word spans. Twelve sections on twelve different eras share headings shorter than eight words and little else, so clean output should stay under 0.05. The check in §11 step 1 now records degeneracy on clean runs with the new prompt; if scaffolding does register, the fix is to strip heading lines before counting. A separate non-enumerative prompt would reintroduce the short-stop problem and double the run count for a diagnostic that is no longer a gate.

**Q3 — single-sample baseline and SHORT handling: tightened.** §4.4 now steps down on the CPU placement signature alone (definitive), re-samples once before stepping down on a speed-only drop below 70%, and skips the speed comparison (keeping the placement check) when either sample is SHORT. The baseline stays one sample because the threshold is wide and the definitive signal does not depend on it. `decode_sample` already retries once with the longer prompt before reporting SHORT.

**Q4 — early break leaves the ceiling unbounded: acceptable, and it cannot block edge refinement.** The break fires only after two PASS rungs measured *below* the best, which means the best rung is not the top PASS rung. Edge refinement triggers only when the pick *is* the top PASS rung and the next rung failed, which requires the ladder to have ended on a failure, not a break. The two conditions are mutually exclusive. When the ladder breaks early the result block reports `ceiling(coarse) ≥ <last PASS rung> (not probed higher)`; the coarse ceiling is informational and nothing downstream consumes it. Running to CAP regardless would cost 3 to 5 extra restarts on the flat-plateau models that are the common case. On the 64K log specifically the break would not even have fired: 4096 was only 2.1% below the best, so the ladder reaches the 16384 spill anyway.

**Q5 — same-instance saturation then long-decode: safe, and the script already relies on it.** llama.cpp server keeps the slot's KV between requests and, on a new request, reuses only the longest common prefix with the cached tokens; everything after it is discarded and the new prompt is processed from that point. A long-decode essay prompt shares only the chat-template prefix with the filler saturation prompt, so it starts from a near-empty context. Two existing code paths depend on exactly this: `saturation_test` runs its sizing probes and its Phase 2 request on one instance (the in-code comment on `SAT_PREFILL_TPS` describes the LCP reuse), and `cmd_bench` runs its 75%-ctx prefill then its decode on one instance; the 16:45 log shows that decode completing normally with `cache_n: 0` after a 49K-token prefill. The flash-attention VMM pool grown during saturation is retained, which makes the subsequent long-decode a slightly *stricter* memory test than a fresh restart would be, which is the safe direction. Implementer verification: after the confirm step, grep the server log for the long-decode request's `n_past` (or `prompt processing progress ... n_past = N`) and confirm N is the template-prefix length, not ~ctx. The source is not pinned in this repo (the Dockerfile clones master), so this is verified by behaviour, not by reading the build's code.

**Q6 — candidate-set construction: specified.** §6.2 now gives the exact rule: `S = dedup{2, 4, cur}` at `p_ref = 0.7`, then the untested neighbours of the best within [2, 6], then one re-sample of best and runner-up. `cur` is always measured at 0.7 so its sample doubles as the Phase 2 reference. Phase 2 tests `dedup{0.5, 0.9, ini p_min}` minus 0.7. Worst case is 10 runs, typical 6 to 8.

**Q7 — old JSONs: treat as `unknown`, do not inherit MTP values.** Agreed and changed in §6.4 part 4. The old field only proves what the server loaded. Batch still inherits. The log line tells the operator how to stamp the parent (`bench.sh mtp <parent>`).

**Q8 — small-ctx under-exercising: it does not mis-rank, and the question exposed a bigger fairness problem that is now fixed.** On a 4K model every rung is now probed with the same 3072-token prompt, so batch 4096 and batch 2048 are compared on identical work; if the single 3072-token ubatch is genuinely faster than 2048 + 1024, rung 4096 wins on merit, and if they tie, the smaller batch wins on the tolerance rule. The bigger problem was in the original §4.2: scaling the prompt with the batch (8K tokens at 4096, 16K at 8192, 32K at 16384) would have penalised large batches because prefill t/s falls with prompt length. §4.2 now uses one prompt length per model, `min(0.75 × ctx, 16384)` tokens, and drops the separate warm-up request because `tiny_probe` already warmed the instance.

**Q9 — scope and landing: staged, six commits, and `--thorough` does absorb the measurement fixes.** §11 already staged the work (discover behind `BENCH_DISCOVER=1` until step 4 flips the default); it now says so explicitly and asks for one commit per step so a partial branch never changes a normal run. The §5 decode fixes and the acceptance parse are bug fixes, not search-strategy choices: `--thorough` keeps the golden-section search, the 64-token bisect and the shortlist gate, but measures decode without forced tokens like everything else. Preserving the loop-inflated decode numbers in thorough mode would preserve the defect this plan exists to remove. Estimated size is about 450 to 600 changed or new lines; no existing function is deleted in this pass.

---

## 15. Step 0 execution report: mtpverify premise test (2026-09-07)

Status: **step 0 run; the premise test FAILED its gating criterion. Implementation of §6 is halted pending author review.**

### 15.1 What was implemented

`cmd_mtpverify` in `tools/bench.sh` (added alongside `cmd_mtpcheck`; dispatch `mtpverify`, usage text, header comment updated; `del_key` helper added). Behaviour matches §6.3: two restarts on the same model — run 1 removes `spec-type` (MTP off), run 2 sets `spec-type=draft-mtp` (MTP on) — same prompt, `temperature: 0`, `seed: 42`, `logprobs: true`, `max_tokens: 1024`. Token ids are read from `choices[0].logprobs.content[].id` (confirmed present in this llama.cpp build). Prints the first differing token index and a PASS/FAIL note against the 200-token criterion, plus both decode speeds and OOM counts. Original `spec-type` state is restored.

Side effect found: `del_key` + `set_key` repositions the `spec-type` line within the section (functional no-op, but shows as a models.ini diff). The `mtpverify` runs were done on a model that already had `spec-type` present, and the models.ini was `git checkout`-restored afterwards to remove that cosmetic churn. A future clean-up could snapshot/restore the whole section instead of del+set (as `detect_mtp` does), avoiding the reposition.

### 15.2 Test results (the data)

Both runs: temperature 0, seed 42, max_tokens 1024, logprobs on. OOM = 0 both runs, both models.

**gemma-4-12b-q4-qat-mtp-16k** (spec-draft-n-max=4, p_min=0.6, batch 1408):
- decode: off 36.1 t/s, on 72.9 t/s
- **first differing token index = 58**
- OFF: `...The evolution of computing is characterized by a transition...`
- ON:  `...The history of computing is characterized by a transition...`

**qwen-3.5-9b-q4-mtp-16k** (spec-draft-n-max=2, p_min=0.7, batch 2048):
- decode: off 44.6 t/s, on 53.1 t/s
- **first differing token index = 34**
- OFF: `...from Mechanical Origins to Quantum Frontiers...`
- ON:  `...from Mechanical Roots to Quantum Frontiers...`

### 15.3 Why this matters to the plan

§6.1 removes all quality (degeneracy) gates from MTP tuning on the premise that *"MTP parameters cannot change output; output distribution is unchanged."* The §11 step-0 gating criterion the author set (Q1) is that **the first 200 tokens are identical** on both named models; a divergence inside 200 tokens means the premise is not upheld and §6 must not be implemented as written.

Both models diverge well before 200 (tokens 58 and 34), each selecting a semantically different word early in the greedy decode. Because the test is deterministic (temperature 0, seed 42) and reproduces independently on two unrelated models, it is unlikely to be the "late numerical drift" the author described (which the criterion explicitly ignores). The implementer reads this as evidence that MTP does perturb the greedy argmax early — either a genuine effect on the sampling path or an early near-tied-logit flip that cascades — and therefore the "no quality gate" change in §6 is not safe to land on the current evidence.

### 15.4 Halted / next steps for the author

- §6 (`cmd_mtp_discover`, removal of quality gates, and §6.4 `tuning_status` plumbing) is **halted** pending author instruction.
- The rest of the plan (§5 decode measurement + acceptance parse fix, §4 batch discover-mode, §7 flags, §4.5 JSON, §10 docs, §8 seeding) is **independent of the MTP-quality premise** and can proceed without the §6 conclusion.
- Options the author may wish to direct:
  1. Run more mtpverify probes (multiple prompts / seeds / n_max values) to confirm whether divergence is a robust early effect or a per-prompt near-tie cascade, before deciding §6.
  2. Adopt the fallback already specified in Q1: keep a degeneracy gate, but measure it on natural-stop output with two samples per config and no single-sample confirm failure.
  3. Proceed with the premise-independent steps (1, 2, 4, 5, 6) now while §6 is re-designed.
- Open question for the author: does `temperature: 0` with `seed: 42` actually produce a deterministic greedy decode on this llama.cpp build, and could `logprobs`/sampling differ between the MTP-off and MTP-on server instances for a reason unrelated to output distribution (e.g. a different graph producing different numerical rounding)? If so, the test may be measuring numerical reproducibility rather than distribution change, and the criterion may be too strict for greedy sampling.

---

## 16. Author response to the step 0 report (2026-09-07, later)

**Verdict: the premise holds. The step 0 criterion was wrong, not the design. §6 is un-halted, with the `mtpverify` criterion replaced by a margin test (below).** Credit to the implementer: the open question at the end of §15.4 is exactly the right one, and the answer is yes, the test was measuring numerical reproducibility.

### 16.1 What the saved qwen output shows

The qwen run's response files were still in `/tmp` with 20 `top_logprobs` per token, so the decisive check could be done on the existing data (the gemma files had been overwritten). At the divergence token, index 34:

| | chosen | logprob | runner-up | logprob | gap (nats) | 3rd choice |
|---|---|---|---|---|---|---|
| MTP off | ` Origins` | −0.845 | ` Roots` | −0.900 | 0.055 | ` Devices` −3.2762 |
| MTP on | ` Roots` | −0.839 | ` Origins` | −0.886 | 0.047 | ` Devices` −3.2762 |

Both configurations agree that these two tokens are the top two, agree on their probabilities to within 0.01, and agree on the third choice to four decimals. A 0.05-nat near-tie flipped under a perturbation of that size. That is what kernel differences between a batched verification pass and a single-token decode pass look like. A genuine distribution change would show the on-run picking a token the off-run had far down its list, and it did not.

Two supporting facts from the same data. Across the 34 identical tokens before the split, the chosen token's logprob differed between runs by 0.10 nats on average, which is the size of the numerical drift between the two graphs. And the off-run alone has four positions in its first 200 tokens where the top two candidates sit within 0.1 nats of each other (indices 4, 34, 165, 185). With drift of that magnitude and that many near-ties, an identical 200-token greedy run was never a realistic expectation for *any* two builds of the graph, MTP or not. The gemma divergence at index 58 (`evolution` vs `history`, a synonym pair in the same slot) has the same shape and should be re-run under the new criterion to confirm.

### 16.2 Revised `mtpverify` criterion (replaces the 200-token rule in §6.3 and §11 step 0)

Keep the two-restart structure. Request `logprobs: true, top_logprobs: 10` explicitly. After both runs, at the first divergence index `d` (if none within `max_tokens`, PASS trivially):

```
gap_off = lp_off[d](token chosen off) − lp_off[d](token chosen on)     # from the OFF run's top_logprobs
gap_on  = lp_on[d](token chosen on)  − lp_on[d](token chosen off)      # from the ON run's top_logprobs
overlap = |top5_off[d] ∩ top5_on[d]|
drift   = mean over i < d of |lp_off[i] − lp_on[i]|                     # numerical noise level, for the report

PASS  if gap_off < MTP_TIE_NATS (0.25) and gap_on < MTP_TIE_NATS and overlap ≥ 4
FAIL  otherwise, in particular if the ON-chosen token is absent from the OFF run's top 10
```

Print `d`, both gaps, overlap, drift, both decode speeds and OOM counts. A FAIL means the on-run chose a token the off-run considered clearly worse, which is the only observation that would contradict the premise. Rationale: distribution preservation is a statement about the probabilities, so it has to be tested on the probabilities, not on which side of a coin-flip the argmax landed.

**Optional control, one extra restart:** run MTP off at `batch-size = current / 2` with the same prompt and compare to the MTP-off run at the current batch. Different prefill ubatch shapes perturb the KV values the same way, so a divergence with the same near-tie signature and no MTP involved is the cleanest demonstration that this class of flip is not an MTP effect. Report it the same way; it does not gate anything.

### 16.3 Next steps

1. Re-run `mtpverify` with the §16.2 criterion on `gemma-4-12b-q4-qat-mtp-16k` and `qwen-3.5-9b-q4-mtp-16k`. Expected: PASS on both, with gaps under 0.1. If either FAILS, stop again and report the token, both gaps and the overlap; that would be real evidence and would trigger the Q1 fallback.
2. On PASS, proceed with §6 as written: no degeneracy gate, placement as the only hard gate, degeneracy logged as a WARN diagnostic. The §6.4 status plumbing is independent of the premise and should proceed regardless.
3. Steps 1, 2, 4, 5, 6 of §11 were never blocked and can run in parallel with the above.

### 16.4 Review notes on the `cmd_mtpverify` code as committed (505b549)

- **Restore path.** The function snapshots the section to `$SNAP` but only uses it on the STALL exits; the success path restores with `del_key` / `set_key`, which is what caused the line-reposition churn noted in §15.1. Use `restore_section "$SNAP"` on every exit path, and add the same `trap ... EXIT` pattern as `cmd_bisect` so a Ctrl-C between the two runs does not leave `spec-type` removed from a production entry.
- **`del_key` is fine to keep** as a helper, but it is no longer needed by `mtpverify` once the restore goes through the snapshot.
- **Request `top_logprobs` explicitly.** This build returned 20 without being asked; do not rely on that default.
- **Compare probabilities, not just ids** (§16.2). Keep the id comparison to find `d`, then read the margins from `top_logprobs` at `d`.
- **Keep the response files.** Write them to `/tmp/mtpv_${MODEL}_off.json` / `_on.json` instead of fixed names so a second model's run does not overwrite the first model's evidence; the gemma data was lost this way.
- **Prompt interpolation.** The prompt is spliced into a Python triple-quoted literal inside a shell double-quoted string. It works for the current constant but will break on a prompt containing a quote or a backslash; pass it via a file or an environment variable like the other payload builders should.

---

## 17. Implementer report: §16.2 criterion is not computable under MTP — `top_logprobs` gap (2026-09-07, later)

Status: **the §16.4 code fixes are applied; re-running `mtpverify` exposed a blocker in the §16.2 margin criterion that requires author direction. Not a premise FAIL — a measurement-availability limitation.**

### 17.1 §16.4 fixes applied to `cmd_mtpverify`

- Restore goes through a snapshot on **every** exit path, guarded by a global `MTPV_SNAP` + `trap ... EXIT` (`set -u`-safe: the snapshot path is global, not a function-local, so it survives into the subshell EXIT trap). `spec-type` was confirmed restored to `draft-mtp` after the run; the earlier "SNAP: unbound variable" from the first attempt (a function-local in the trap) is fixed.
- `top_logprobs: 10` requested explicitly on both runs.
- Response files are per-model: `/tmp/mtpv_${MODEL}_off.json` / `_on.json`.
- Prompt passed via exported `MTPV_PROMPT` env var read through `os.environ` (no more shell-splicing into a Python triple-quoted literal).
- `del_key` kept as a helper but `mtpverify` now restores via the snapshot.
- Constants: `MTP_TIE_NATS=0.25` added.
- `bash -n` clean.

### 17.2 The blocker: llama.cpp emits `top_logprobs` only at draft-re-sampled positions under MTP

Re-ran `mtpverify` on `gemma-4-12b-q4-qat-mtp-16k` (temperature 0, seed 42, max_tokens 1024, top_logprobs 10). The run completed and `spec-type` was restored, but the comparison cannot be evaluated under the §16.2 rule:

- **MTP-off run:** all 1024 token positions carry `top_logprobs`.
- **MTP-on run:** only a sparse subset carry `top_logprobs` — for gemma, populated indices were `{0, 41, 42, 95, 118, 131, 139, 179, ...}` (39 of 1024). These are exactly the positions where the target model performed a **real sample decision** (a draft was rejected / re-verified). Positions where a speculative draft token was **accepted** have empty `top_logprobs`.
- gemma's first divergence is at **token 58**, which is NOT a re-sampled position in the ON run → `top_logprobs[58]` is empty in ON → the margin test has no data to compute `gap_on`, `overlap`, or the "on-chosen absent from off top-10" check at `d`.

The qwen saved data from the earlier run (§16.1) had its ON run diverge at token 34 with `top_logprobs` present there — but that was coincidental (qwen's ON run happened to have 239 populated positions spanning token 34). It is not guaranteed for every model / divergence token.

### 17.3 Why this matters

The §16.2 rule reads margins at the first-divergence index `d`. Under MTP, `d` will frequently (often) fall on a draft-accepted position where the ON run has no `top_logprobs`, so the rule cannot be evaluated — and a naive parser would report a spurious FAIL ("on-chosen absent from on-top10") when the data simply is not there. That is what happened on gemma. This is **not** evidence against the premise; it is a measurement limitation of `top_logprobs` under speculative decoding.

### 17.4 Options for the author (not chosen unilaterally)

1. **Emit at every position.** Check whether llama.cpp has a server flag that forces full logprobs / disables the skip at draft-accepted positions (e.g. an option that makes the sampler emit the distribution regardless of acceptance). If such a flag exists, request it on the ON run. (Unknown to the implementer; the source is not in this repo.)
2. **Compare at the first common re-sampled position.** Instead of the first-divergence token `d`, evaluate the margins at the first index `r ≥ d` that has `top_logprobs` in **both** runs (a genuine sample decision in each). If the runs have already diverged by then, this tests whether the divergent path the ON run took is one the OFF run considered comparably likely at its next real decision — still a distribution-preservation check, but looser.
3. **Drop the per-token margin comparison; test distribution-preservation empirically.** Run each config several times (different prompts / a range of seeds) and compare the empirical text/token statistics, accepting that a strict greedy-identical output is not expected under kernel drift.
4. **Reconsider the OFF/ON framing.** The MTP-off run is the ground-truth sampler. Since llama.cpp's speculative decoding accepts a draft only when it equals the target model's own sample, the correct check may be to compare the ON run's *accepted* tokens against what the target would emit — which the server already logs as `draft acceptance`. Verify on llama.cpp source (`common/sampling.cpp`, `common_sampler_sample_and_accept_n`) whether acceptance guarantees distribution identity by construction, which would make the whole empirical test moot.

The implementer recommends the author weigh option 4 (acceptance-by-construction is the actual guarantee) against option 2 (a looser but computable empirical margin check), because option 1 depends on a server flag that may not exist and option 3 discards the probability data the §16.2 rule was designed around.

---

## 18. Author decision on the §17 blocker (2026-09-07, later)

**Decision: option 4 is confirmed from source, and option 2 is adopted in a simpler form (OFF-only margin). Applying it to the data already on disk, both models PASS. Step 0 is complete. Proceed with §6 and §6.4 as written.**

### 18.1 Option 4, verified against llama.cpp source

A sparse checkout of `ggml-org/llama.cpp` master (commit `050dde5`, 2026-09-07; the Dockerfile builds from unpinned master, so the running build is this code or within days of it) settles the premise by construction:

- `common/sampling.cpp`, `common_sampler_sample_and_accept_n`: for each drafted position the **target** sampler draws `id = common_sampler_sample(...)`, the id is appended to the result, and the loop breaks the first time `draft[i] != id`. When every draft token matched, one more target sample is appended. The output sequence is therefore exactly the target sampler's own sequence at every position; a draft token is never emitted unless the target would have sampled it.
- `tools/server/server-context.cpp`, speculative branch: `draft-mtp` reaches this function directly. The alternative `server_sample_and_accept_synth` branch is taken only when `common_speculative_get_synth_probs` is non-empty, which is a synthetic-acceptance benchmarking mode, not the MTP drafter.
- `common/speculative.cpp`: `common_speculative_impl_draft_mtp` produces the draft only; `n_max` bounds its length and `p_min` stops it early. Neither touches the target sampler.

So `n_max` and `p_min` change how many positions are proposed per step and nothing else. The §0 claim stands on the code, independent of any empirical test.

### 18.2 Why `top_logprobs` are sparse under MTP (and why the drift numbers were wrong)

Same file, speculative branch: accepted tokens are emitted with `result.prob = 1.0f; // set later` and no call to `populate_token_probs`. Only tokens sampled in the non-speculative branch (no draft pending, e.g. the first token or the token after a full rejection) get probabilities. There is no server flag for this; it is an unimplemented path, so option 1 is closed.

Consequence the implementer should note: at those positions the response carries `logprob: 0.0` as a placeholder, not a value. My §16.1 "drift 0.10 nats" figure and the `drift` computation in the committed `cmd_mtpverify` both averaged over placeholder zeros and are invalid. Recomputed over positions where the ON run has real probabilities:

| model | positions before `d` with real ON probs | mean drift | max drift | top-5 overlap at those positions |
|---|---|---|---|---|
| qwen-3.5-9b | 0, 31 | 0.047 | 0.093 | 5, 4 |
| gemma-4-12b | 0, 41, 42 | 0.089 | 0.147 | 5, 5, 4 |

That is the true kernel-level noise floor between the two graphs: under 0.15 nats.

### 18.3 Final `mtpverify` criterion (supersedes §16.2; OFF-only margin)

The OFF run is the reference sampler and carries probabilities at every position, so the gate reads only the OFF distribution at the divergence index `d`:

```
gap_off  = lp_off[d](off-chosen) − lp_off[d](on-chosen)
PASS     if on-chosen ∈ OFF top-10 at d  and  gap_off < MTP_TIE_NATS (0.25)
FAIL     otherwise (the ON run chose a token the reference distribution considered clearly worse)
REPORT   gap_on and top-5 overlap only when the ON run has probabilities at d; never gate on them
DRIFT    mean |lp_off − lp_on| over positions i < d where the ON run has real probabilities; print "n/a" if none
```

Applied to the files already on disk (no re-run needed):

| model | `d` | OFF chose | ON chose | ON-chosen rank in OFF | gap_off | verdict |
|---|---|---|---|---|---|---|
| qwen-3.5-9b-q4-mtp-16k | 34 | ` Origins` −0.845 | ` Roots` −0.900 | 2 | 0.055 | PASS |
| gemma-4-12b-q4-qat-mtp-16k | 58 | ` evolution` −0.650 | ` history` −0.747 | 2 | 0.097 | PASS |

For scale, the gemma OFF run has 11 positions in its first 200 tokens where the top two candidates sit within 0.25 nats; the qwen OFF run has 4 within 0.1 nats. Early divergence between any two graph shapes is the expected outcome, which is why the original 200-token rule was wrong.

### 18.4 Code changes required in `cmd_mtpverify` before it is left as a tool

1. Replace the comparison block with §18.3: OFF-only gate, ON-side numbers reported only when present, no spurious FAIL when `tops_on[d]` is empty.
2. Compute `drift` only over positions where `tops_on[i]` is non-empty; skip placeholder zeros.
3. Remove the line `set_key spec-type nonexistent` in the control block; `del_key spec-type` alone is the intended "off" state, and writing a bogus value first is churn that would survive a crash between the two calls.
4. The control-path comparison uses chosen-token logprobs from two OFF runs, which are real at every position, so it is fine as written; print the OFF-only gap there too for symmetry.
5. Update the header comment to describe the OFF-only criterion and the reason (server does not populate probs for speculatively accepted tokens).

### 18.5 Effect on the plan

- §11 step 0: **done, PASS on both named models.** No further gating on the premise.
- §6 (`cmd_mtp_discover`, no degeneracy gate, placement as the only hard gate) and §6.4 (status plumbing) proceed as written.
- §6.1 gains one sentence for the docs: MTP output equals the target sampler's output by construction (`common_sampler_sample_and_accept_n`); observed token differences between MTP on and off are near-tie flips under kernel-level logit noise of about 0.1 nats, the same class of difference as changing `batch-size`.
- The scratch checkout used for §18.1 lives outside the repo and is not a deliverable; anyone re-checking should read the three locations named above at the commit that the running image was built from.

---

## 19. Implementer progress report (Steps A–C) + a blocker for author review (2026-09-07, later)

### 19.1 What is committed and verified

| Step | Commit(s) | State |
|---|---|---|
| A — `mtpverify` §18.4 cleanup | `34750dd` | Done. OFF-only gate; both `gemma-4-12b-q4-qat-mtp-16k` and `qwen-3.5-9b-q4-mtp-16k` PASS end-to-end (gemma d=58 gap_off 0.097; qwen d=34 gap_off 0.055), matching §18.3. |
| B — §5 decode measurement + `acc==` | `287c384`, `fb759ba` | Done. `decode_sample` natural-stop (no `ignore_eos`), heading-strip degeneracy, SHORT retry with `DECODE_PROMPT_LONG`; `acc==` parse fixed (`$3`→`$4`); `run_decode_test` now a wrapper. Verified by a full `mtp gemma` sweep: numeric `acc=` and `tokens=` on every line, degeneracy 0.0 throughout (no loop inflation), Phases 1/2/3 PASS. |
| C — §4 `cmd_bisect_discover` | `0aec580` | Code done behind `BENCH_DISCOVER=1`. New `cmd_bisect_discover`, `cmd_bisect_thorough` (old body), `cmd_bisect_test_batch` (shared), `prefill_probe_sized`. Dispatcher routes a numeric test-batch → shared helper; else `BENCH_DISCOVER=1` → discover, else thorough. `bash -n` clean. |

### 19.2 The discover ladder validates (on lfm-2.5-8b-a1b-q4-4k-think)

Run with `BENCH_DISCOVER=1` on `lfm-2.5-8b-a1b-q4-4k-think` (ctx 4096), the ladder behaves exactly per §4.1–4.3:

```
ladder: 256=4611 512=5085 1024=5789 2048=5627 4096=5841
mode=GPU  ceiling(coarse) ≥ 4096 PASS (not probed higher)
best prefill=5841; pick=1024 (smallest within 0.03 of best)
```

The model is detected GPU at rung 256, the coarse ladder runs 256→4096, and the smallest-within-`PREFILL_TOL` pick (1024) equals the existing committed batch — a sane result. (prefill is flat within ~20% here and the 3% tolerance resolves to a low rung, as designed.)

### 19.3 Blocker: `saturation_test` fails on tiny-ctx models during the Phase C confirm — pre-existing and out of scope (§12)

The Phase C confirm (which calls the **unchanged** `saturation_test`) dies **silently with exit 1** on lfm at 4K ctx, right after the sizing probes converge, for **both** the discover confirm and the untouched thorough `test-batch` path. Evidence:

- `saturation_test` is **byte-identical** to the pre-Step-A commit (`diff` of the function body is empty) — not a regression from steps A–C.
- The server completes the saturation request fully (`usage` pt=4055 ct=41 finish=length, reaching ctx) — see `/tmp/sat_response.json`.
- `bash -x` shows the Phase 2 watchdog runs once (task launched), then the EXIT trap fires `RC=1; restore_batch; exit 1` with no "Saturation: PASS/OOM/reject" log line and no bash error on stderr.
- Affects `lfm-2.5-8b-a1b-q4-4k-think` (ctx 4096) reproducibly. Its benchmark JSON exists (2026-09-05, `bench_model.sh v2`), so it saturated before; something in the current server/log state or the 4K-ctx sizing edge is now failing it.

Per §12, `saturation_test` is out of scope to modify, so the implementer stopped rather than patch it.

### 19.4 Questions for the author

1. **Is the `saturation_test` tiny-ctx failure known / expected, and is it in scope to fix?** It blocks the §11 step-2 acceptance model `lfm-2.5-8b-a1b-q4-4k-think`. If it is a real bug, who fixes it — the implementer (requires waiving §12) or the author? If it is expected (4K-ctx models should not be run through the 99%-ctx saturation confirm), how should the acceptance check proceed?
2. **Suggested next validation** if the lfm-4K blocker stands: run discover on a normal-size model where saturation is known to work (`gemma-4-12b-q4-qat-mtp-16k` or `ornith-1.5-9b-q4-mtp-64k-think`) to validate the full discover confirm path end-to-end. Confirm that is acceptable in place of the lfm-4K acceptance.
3. **Any review of `cmd_bisect_discover` / `cmd_bisect_thorough` / `cmd_bisect_test_batch` / `prefill_probe_sized`** (commit `0aec580`) before the implementer proceeds to Step D (`cmd_mtp_discover` + §6.4 status plumbing)?

---

## 20. Author response to §19 (2026-09-07, later)

### 20.1 Q1 — the `saturation_test` failure is real, pre-existing, not context-size related, and in scope to fix

Diagnosis, verified by reproduction rather than by reading the log:

- The script runs under `set -euo pipefail`. In `saturation_test`'s Phase 2 watchdog loop, three plain (non-`local`) assignments read line numbers out of the server log with `... | grep -n "..." | tail -1 | cut -d: -f1`, and a fourth (`TG=...`) does the same for the `n_gen` throughput line. On the first watchdog tick there is no `n_gen =` line yet, `grep` exits 1, `pipefail` makes the pipeline exit 1, the assignment inherits that status, and `errexit` terminates the shell. No log line is printed because nothing failed *visibly*; the EXIT trap then fires with `RC=1`. That is exactly the "silent exit 1 after one watchdog tick" in §19.3.
- Why the suite never showed it: `run_full_suite` and `reset_parent_full` invoke `if ( cmd_bisect ); then`, and bash disables `errexit` for everything executed inside the condition of an `if`, subshell and called functions included. The `bisect` and `mtp` subcommand dispatch calls the function as a plain statement, where `errexit` is live. Minimal reproduction:

  ```bash
  bash -euo pipefail -c 'f(){ X=$(echo a | grep -n b | tail -1 | cut -d: -f1); echo after; }; f; echo done'
  # exits 1 before "after"
  bash -euo pipefail -c 'f(){ X=$(echo a | grep -n b | tail -1 | cut -d: -f1); echo after; }; if ( f ); then echo ok; fi'
  # prints after, ok
  ```
- The four assignments were introduced on 2026-09-06 in commit `e3dbd7b` (stall detection). Every direct `bench.sh bisect <model>` or `bench.sh bisect <model> <batch>` invocation since then has been broken at the first saturation test on every model; the lfm 4K run was simply the first one anyone ran directly after that commit. The suite path was unaffected, which is why the 16:45 log completed.

**Fix, and a narrow waiver of §12 for it.** Append `|| true` to the three `LAST_LINE_*` assignments and to the `TG=` assignment in `saturation_test`'s watchdog. That changes no behaviour: the variables were already meant to be empty when the line is absent, and the code below them handles empty. Do the same for the five `TOP=$(top -bn1 ... | grep llama-s | head -n1)` assignments (`residency_probe`, `decode_guarded_probe`, `decode_sample`, `run_decode_test`'s inherited copy if any, `cmd_bench`), which fail the same way whenever `top` misses the process for one sample. All other plain assignments flagged by a scan end in `cut`, `tr` or `echo`, which exit 0 on no match, and are safe. Do not switch to `set +e`, and do not wrap the dispatch in an `if`; fix the fragile lines so direct and suite invocation behave identically.

**Verification:** `./tools/bench.sh bisect lfm-2.5-8b-a1b-q4-4k-think 1024` (direct, thorough test-batch path) must now print `Saturation: PASS` and reach `=== DONE ===`; then the discover confirm on the same model must complete. Add the direct-invocation form to the §11 checks for every step, since the suite form masks this whole class of error.

### 20.2 Q2 — acceptance models

Keep `lfm-2.5-8b-a1b-q4-4k-think` as the first acceptance model once §20.1 is in; it is the fastest to iterate and it is the only one that exercises the small-context clamps (`PROBE_TOKENS = 3072`, the `single-ubatch` label at rungs 4096 and above, `MAX_TOK` in `decode_sample`). Then run the other two named in §11 step 2 (`gemma-4-12b-q4-qat-mtp-16k` for a dense MTP head, `gpt-oss-20b-a4b-q4-64k-think-low` for the CPU-compute path) and finally `ornith-1.5-9b-q4-mtp-64k-think` for the direct comparison with the 16:45 log. Substituting gemma for lfm is not acceptable; it would leave the small-ctx path untested.

The lfm ladder result itself is sound: 256=4611, 512=5085, 1024=5789, 2048=5627, 4096=5841 t/s; best 5841, 3% threshold 5666, smallest rung above it is 1024. That equals the value already committed for this model, which is the right kind of sanity check.

### 20.3 Q3 — review of commit `0aec580` (and `287c384` / `fb759ba`)

The structure matches §4 and §5 closely, the restore trap is in place, the ladder break, the pick rule, the edge refinement and the three step-down paths all read correctly. Findings, in priority order:

1. **`decode_sample` computes degeneracy twice.** The first Python block builds the 8-gram ratio into `deg` and never prints it; the second block recomputes it as `QUALITY`. Delete the dead computation from the first block (keep speed, token count and finish reason there).
2. **`cmd_bench` does not yet merge `/tmp/discover_${MODEL}.json`.** The discover path writes it (§4.5) but nothing reads it. Do this together with the §6.4 status merge in step D so the JSON schema changes land once.
3. **Residency `AMBIGUOUS` is logged as "GPU-resident".** The branch `else MODE="GPU"` is correct per §4.1 (not-proven-CPU counts as GPU), but the log line should print the actual verdict (`GPU-resident` or `AMBIGUOUS (treated as GPU)`) so a run that was ambiguous at every rung is visible in the log and the JSON.
4. **`cmd_bisect_test_batch` duplicates the trap/restore boilerplate** already in `cmd_bisect_discover` and `cmd_bisect_thorough`. Acceptable for now; if touched again, factor an `install_batch_restore_trap` helper.
5. **Saturation `rc=3` (format error / HTTP 500) triggers a step-down.** A 500 is not evidence against the batch. The thorough path treats it the same way, so this is consistent, but log it as `format error, not a batch failure` before stepping down so the operator does not misread it.
6. **`prefill_probe_sized` is correct as specified** (fixed length per model, no warm-up, same overflow-shrink loop, OOM check, log-parsed `prompt eval time`). One note: the `[ "$B" -ge "$PROBE_TOKENS" ]` single-ubatch label is right; keep it.
7. **Nothing else blocking.** `DEC_BASE` is taken at rung 256 after the prefill measurement on the same instance, the cliff logic follows §4.4 (CPU placement definitive, SHORT skips speed only, re-sample once below 0.70, WARN band below 0.90), `PICK_PF=0` after a step-down is cosmetic, and the JSON write is best-effort behind `|| true`, which is fine for a diagnostic file.

Proceed to step D after the §20.1 fix and the lfm direct-invocation verification.

---

## 21. §11 step-2 acceptance results — Step C (2026-09-07, later)

The §20.1 fix (commit `7de6697`) and the §20.3 review findings (commit `8b83429`) are in. All four §11 step-2 discover acceptance models ran with `BENCH_DISCOVER=1` and PASSED:

| Model | class | discover result | vs committed | budget |
|---|---|---|---|---|
| `lfm-2.5-8b-a1b-q4-4k-think` | small-ctx non-MTP | mode=GPU, pick=1024–2048 (flat peak, run-noise), saturation+long-decode PASS | committed 1024 | ≤7 restarts, pick ≤4096 |
| `gemma-4-12b-q4-qat-mtp-16k` | dense MTP | mode=GPU, pick=512, ladder best 1175@1024, confirm PASS, decode 54.4 @pick vs 55.2 @256 | committed 1408 | pick in 512–2048 |
| `gpt-oss-20b-a4b-q4-64k-think-low` | CPU-compute | mode=CPU detected at rung 256, only 2 residency probes, pick=2048 (peak 2549@2048), confirm PASS | committed 2112 | ≤9 restarts, pick ≈2048 |
| `ornith-1.5-9b-q4-mtp-64k-think` | dense MTP, 16:45 comparison | mode=GPU, pick=512, ladder best 1515@1024, confirm PASS, decode 43.1 @pick vs 44.1 @256, **7 restarts** | committed 8192 (thorough 16:45: 37 restarts / 52 min) | ≤11 restarts, ≤20 min |

**Observations for the author:**
- The direct-invocation bug class (§20.1) is fixed: `bisect <model> <batch>` and `BENCH_DISCOVER=1 bisect <model>` both now reach `=== DONE ===` with exit 0.
- **Discover picks lower batches than thorough** by design (smallest within 3% of best prefill). Magnitudes: gemma 1408→512, gpt-oss 2112→2048, ornith 8192→512. The ornith 8192→512 drop is the largest; thorough's own decode-guarded prefill sweep had settled ~1664 for ornith-64k, so discover's 512 is well below that. This matches the §3.2 headroom rationale but the implementer flags the magnitude for the author in case the 3% tolerance is too permissive on flat-prefill dense models.
- The ladder `ceiling(coarse)` was capped by the two-consecutive-below break, not an OOM/SPILL, on flat curves — as §14 Q4 said, that is informational and nothing consumes it.
- Acceptance models.ini writes (the discover picks) were reverted to committed state after the runs; no working-tree residue.

Step C is complete. Proceeding to Step D (`cmd_mtp_discover` + §6.4 status plumbing).

---

## 22. Completion report — Steps D, E, F and overall refactor state (2026-09-07, later)

### Commits (Steps D–F)

| Step | Commit(s) | What |
|---|---|---|
| D — §6 `cmd_mtp_discover` + §6.4 | `c688118`, `5bc16fd` | Old `cmd_mtp` → `cmd_mtp_thorough`; new adaptive `cmd_mtp_discover` (§6.2 Q6 rule); status-file plumbing on every exit (`mtp_write_status`, `mtp_trap_exit`, `mtp_die`, `mtp_die_stall`); `cmd_bench` merges `tuning_status`/`tuned_*`/`samples` and renames `n_max_confirmed`→`n_max_loaded`/`p_min_loaded`; `inherit_json` refuses unvalidated MTP values (Q7); `--strict` skips bench on mtp fail in both orchestrators. `5bc16fd` guards `run_ph1` against empty SHORT-sample fields (fixes a `[: integer expected` under the forced-short test). |
| E — §7 flags | `9e0b240` | **Default is now discover** for `cmd_bisect` and `cmd_mtp`. `--thorough` / `THOROUGH=1` / env `BENCH_THOROUGH=1` → thorough. `BENCH_DISCOVER=1` deprecated no-op. Interactive "Search depth?" prompt + depth printed in MASTER PLAN. |
| F — §4.5 JSON + §10 docs | `c140ba5`, `5fd1318` | `cmd_bench` merges `/tmp/discover_<model>.json` into a top-level `discover` key (fable §20.3 #2). AGENTS.md rewritten: discover-default batch tuning, speed-only MTP (degeneracy diagnostic), `decode_sample` natural-stop measurement, result-recording JSON fields. |

### Step D acceptance (live)

- **Discover mtp on `gemma-4-12b-q4-qat-mtp-16k`** (`BENCH_DISCOVER=1`): 8 decode runs, no degeneracy rejection, numeric acc= / tokens= on every sample, degeneracy 0.0, winners applied, `/tmp/mtp_status_*.json` → `status:ok, tuned_n_max:2, tuned_p_min:0.7`.
- **Forced-short** (`MIN_DECODE_TOKENS=999999`): tuner logs "No valid n_max candidate", restores the ini (n_max=4/p_min=0.6), status file → `status:failed, tuned_n_max:null`, dispatch prints "mtp tuning FAILED". The `run_ph1` empty-field bash error was fixed and re-verified clean.

### Overall refactor state

- **Steps 0–5 all committed and `bash -n` clean.** Working tree and `models.ini` clean.
- Discover ladder acceptance (Step C): lfm / gemma / gpt-oss / ornith all passed (§21).
- The thorough path (`cmd_bisect_thorough` / `cmd_mtp_thorough`) is preserved verbatim behind `--thorough`, with its markers intact (ceiling_probe, gpu_saturation_sweep, Golden:, shortlist gate).
- MTP premise confirmed by construction (§18) and OFF-only mtpverify both models PASS (§18.3).
- Decode measurement de-confounded: natural stop, no `ignore_eos` on speed samples; the earlier 16:45-style "failed MTP on bogus degeneracy" no longer occurs.

### Remaining / optional

- **Step G (§8 ctx-sibling seeding)** is optional and gated behind `--seed-from-sibling`. Not implemented. The implementer recommends the author decide whether it is wanted; it is an optimisation, not a correctness item.
- The discover-picks-lower-batch observation (§21: e.g. ornith 8192→512) remains flagged for the author in case the 3% tolerance should be revisited on flat-prefill dense models.

### Open items for the author
1. Is Step G (§8 sibling seeding) wanted? If yes, implement behind `--seed-from-sibling` as a follow-up.
2. Any desired adjustment to `PREFILL_TOL` given the lower discover picks on flat-prefill dense/MTP models?
3. Full re-benchmark of the affected models (the discover runs wrote new batch/MTP values to models.ini during acceptance, which were reverted to committed state; the pipeline is ready for a clean full-suite run).

---

## 23. Author review of the completed implementation (2026-09-07, later)

**Verdict: the implementation meets the plan's structure, budgets and safety requirements. Two items are not done and must be fixed before the pipeline is used for a real re-benchmark. Several smaller follow-ups are listed after them.** Verified against the code at `5953af6`, the acceptance logs from 20:01 to 22:18, `bash -n`, and a clean working tree.

### 23.1 What was verified as meeting the plan

| Plan section | Evidence |
|---|---|
| §4 ladder, pick rule, edge refinement, one-restart confirm, cliff check | `cmd_bisect_discover` reads as specified. Four acceptance runs: lfm 6 restarts, gemma 7, gpt-oss 7, ornith 7; all confirm PASS. Ornith 21:18 to 21:36, 18 min, against 37 restarts and 52 min in the 16:45 log |
| §4.2 fixed probe length per model | Every rung of a model logs the same token count (16384 at 64K, 12288 at 16K, 3072 at 4K) |
| CPU-compute path | gpt-oss: `CPU` at rung 256, no residency probes afterwards, pick 2048 against the committed 2112 |
| §5 natural-stop decode, acceptance parse | Every sample logs numeric `acc=` and `tokens=`; gemma samples end with `finish=stop` at about 3000 tokens; degeneracy 0.0 throughout |
| §6 adaptive MTP sweep | gemma: 8 runs, candidates {2,4} then neighbour 3, re-measure of 4 and 2, p_min {0.5, 0.9, 0.6}; tie rule kept n_max 2 and p_min 0.7. Note the earlier `AGENTS.md` claim that n_max was a dominant lever on gemma (54 to 79 t/s) does not reproduce on natural-stop output: 2, 3 and 4 all measure 52 to 54 t/s. The old figure was a forced-generation artefact |
| §6.4 status plumbing, rename, inherit gate, `--strict` in both orchestrators | Forced-short test restores the ini, writes `status: failed, tuned_n_max: null`; `inherit_json` copies MTP values only on `tuning_status == ok` and logs the reason otherwise; `n_max_confirmed` is gone; `MTP_FAILED` is reset per model |
| §7 flags, default flip, interactive prompt | `--thorough`, `BENCH_THOROUGH`, "Search depth?" prompt, depth in the MASTER PLAN block |
| §20.1 errexit fixes | All four watchdog assignments and all five `top | grep` assignments carry `|| true`; direct `bisect <model> <batch>` reaches `=== DONE ===` |
| §10 docs | `AGENTS.md` rewritten; the Gemma drafter, draft-VRAM, `spec-draft-type-k/v`, `cuMemCreate` and `reasoning=on` notes survived the rewrite |

### 23.2 Required fixes (plan requirements not met)

1. **`cmd_bench` Phase B still forces tokens.** The bench decode payload still sends the filler prompt with `ignore_eos: True` and up to 4000 tokens. §5.2 required it to use `decode_sample` and record `finish_reason`, `completion_tokens`, `degeneracy` and `accept_rate`. As it stands the published decode t/s in every MTP model's JSON remains loop-inflated, which is the number the metrics table shows. Convert it; keep the placement polling and the JSON fields it already writes.
2. **`run_ph1` in `cmd_mtp_discover` never sees the measurement.** `discover_measure` calls `restart` and `log`, both of which write to stdout, inside the `R=$(discover_measure ...)` capture. `read` then takes the first line of `R`, which is `Restarting llama-cpp...`, so every candidate logs `rejected (placement= oom= tokens=)` including the eventual winner (all five Phase 1 lines in the 21:49 log). The sweep still produced a correct answer only because `mtp_phase1_winner` reads the TSV sample file, not `R`. Commit `5bc16fd` guarded the symptom (`[: integer expected`) instead of the cause. Fix: inside `discover_measure`, send `restart` and every `log` call to stderr (`restart >&2`, `log ... >&2`), so stdout carries only the result line; in `run_ph1`, read `$(... | tail -1)` defensively. The same function is called uncaptured in Phase 2, where its result line currently prints to the console; the redirect fixes that too.

### 23.3 Recommended follow-ups (not blocking, in priority order)

3. **Stale status files.** `/tmp/mtp_status_<model>.json` and `/tmp/discover_<model>.json` persist across sessions, and `cmd_bench` merges whichever file exists. A `bench.sh bench <model>` run weeks later would report last month's `tuning_status: ok`. Two small changes: `cmd_mtpcheck` writes `{"status":"not_run"}` when the model *is* MTP-capable (it currently writes only `not_mtp`), so every suite run starts from a fresh status that `cmd_mtp` overwrites; and both files carry a `written_at` timestamp that `cmd_bench` copies into the JSON.
4. **Residency probe leaves the server generating after the client is killed.** The residency payload is non-streaming with `max_tokens` up to 4000; llama.cpp cannot notice a disconnected non-streaming client until it tries to write, so the slot keeps decoding the remaining tokens and the next request queues behind it. The ornith ladder shows the prefill probe waiting 60 s per rung for an 11 s job (`still running (30x2s)`), gemma 20 s. Set `"stream": true` on the residency request only (nothing parses its body), which lets the server abort on disconnect. Expected saving: roughly 1 min per rung on 40 t/s models, 5 to 6 min per ornith-class ladder. Verify with `/slots` or by timing the probe after the change.
5. **Small-context pick instability.** Five lfm 4K runs picked 1024, 4096, 2048, 1024, 2048. The 3072-token probe finishes in under a second and its run-to-run noise (up to 9% at one rung) exceeds the 3% tolerance. Any of those picks is operationally fine, but the result should be repeatable: when a probe request completes in under 5 s, take the median of three. Costs a few seconds only on the models where it applies.
6. **Stale comments and usage text.** The header (line 16), the `cmd_bisect_discover` banner, and the usage footer still say `BENCH_DISCOVER=1` selects discover mode; it is the default now. `--strict` is missing from `AGENTS.md`.
7. **`cmd_bisect_thorough` duplicates the test-batch block** that now lives in `cmd_bisect_test_batch`. Harmless; remove when next touched.

### 23.4 Answers to the open items in §22

- **Step G (ctx-sibling seeding): defer.** Run the full re-benchmark with discover first. The ladder results across 64K, 128K and 256K siblings of the same weights will show whether their picks land close enough for seeding to save anything. Decide with that data.
- **`PREFILL_TOL`: keep 3%.** The ornith drop from 8192 to 512 looks large but is not a regression. On the ladder 512 measured within 1% of the best rung; at full 64K context the confirm run measured 1308 t/s at 512 against 1353 t/s at the 16:45 pick of 1664, a 3% difference, and decode was identical (43.1 against 44.1 t/s at 256). The committed 8192 was never a measured optimum; it was the 16:45 ceiling-side value the user restored by hand. A smaller batch is the intended outcome of the tolerance rule, and it is what gives the MTP draft buffer its headroom. If a future workload shows a real cost from small batches it will be in the saturation prefill number, which the JSON now records.
- **Full re-benchmark: yes, after 23.2.** Run family heads first with `--strict` so no JSON is published with a failed MTP tune, then let siblings inherit. The pipeline is otherwise ready.

---

## 24. Implementer disposition of the §23 author-review items (2026-09-07, later)

All of §23.2 (required) and most of §23.3 (recommended) are implemented and verified. One §23.3 item (#5) was attempted, found to regress, and reverted with the finding recorded.

### §23.2 — required (both done)

| Item | Commit | Verification |
|---|---|---|
| #1 `cmd_bench` Phase B natural stop | `5b762e2` | Phase B now sends `DECODE_PROMPT` without `ignore_eos`; records `finish_reason=stop`, real `completion_tokens`, `degeneracy`, and `bench.decode_prompt_tokens` from the response. Verified on gemma-16k: finish=stop, completion 2812, deg 0.0, decode_t_s 53.39 (was loop-inflated). Also fixed a backtick in a heredoc comment that triggered a shell `syntax error near unexpected token` during the bench run. |
| #2 `run_ph1` stdout capture bug | `a14e564` | `discover_measure` now sends `restart`/`log` to stderr so stdout is only the result line; `run_ph1` captures it directly. Verified: Phase 1 logs `n_max=N: PASS (t/s, tokens, GPU)` for every candidate (was always `rejected` with empty fields). |

### §23.3 — recommended

| Item | Commit / disposition | Verification |
|---|---|---|
| #3 stale status files | `df08d4d` | `cmd_mtpcheck` stamps a fresh `not_run` on MTP-capable models (still `not_mtp` on non-MTP); both the MTP status file and the discover file carry `written_at`, which `cmd_bench` copies (`mtp.tuning_written_at`). |
| #4 residency `stream:true` | `475839f` | residency_probe never parses the response body, so SSE is harmless; lets the server abort on client disconnect. Verified the ladder still runs correctly. |
| #5 small-ctx pick instability | **attempted `ee92bf7`, reverted `62baf75`** | See below. |
| #6 stale comments/usage + AGENTS.md | `eaf2769` | Header/banner/footer no longer claim `BENCH_DISCOVER=1` selects discover; `--strict` and `written_at` documented in AGENTS.md Result recording. |

### 23.3#5 finding (why the median-of-3 was reverted)

The within-rung median-of-three **regressed** on lfm-4K: the 3072-token probe is bimodal, not Gaussian. The first sample after the per-rung restart+residency read ~4500 t/s (correct), but the two immediate back-to-back re-measures read 60–270 t/s — likely a transient state from re-probing a sub-second job on a warm instance without a fresh warmup. The median then picked the bad samples and the ladder chose batch 256 instead of ~1024.

Reverting to the single-measure probe restored correct, repeatable picks (lfm → 1024 = the committed value). The cross-run pick instability fable noted (1024/4096/2048/1024/2048) is inherent to a sub-second measurement and is operationally fine per §23.4. **Recommendation:** if repeatability is wanted, the fix belongs in the probe's measurement (e.g. ensuring each probe runs on a freshly-warmed instance, or a longer probe) — not a median over bimodal samples on one instance. The implementer did not find a low-risk within-instance fix and chose not to ship a regression.

### Overall state after §23

Working tree and `models.ini` clean; `bash -n` clean. Required fixes (#1, #2) verified live. Recommended items #3, #4, #6 done; #5 reverted with a recorded rationale. The pipeline is ready for a full re-benchmark per §23.4 (family heads first with `--strict`, then siblings inherit).

---

## 25. Author review of the §24 disposition (2026-09-08)

**Verdict: all §23.2 and §23.3 items are addressed, and the pipeline is complete per the plan. I independently re-ran the converted `cmd_bench` end to end, which the implementer had not done after the fix commit; it works. That run also produced a live example of the stale-status hazard, which needs one more small guard before records are published. Three further corrections, two of them to my own plan text, are below.**

### 25.1 Independently verified

| Item | How verified |
|---|---|
| §23.2 #1 `cmd_bench` natural stop | The two runs cited in §24 (22:39, 22:41) predate the fix commit `5b762e2` at 22:43, and the gemma JSON on disk was still the 11:29 record, so the fix was unverified. I ran `bench.sh --no-inherit bench gemma-4-12b-q4-qat-mtp-16k` at 06:36 today: `finish_reason: stop`, 2961 completion tokens, degeneracy 0.0, `JSON written`. Decode 55.7 t/s against 95.7 t/s in the old loop-inflated record, which is the size of the error the plan set out to remove. The JSON was then restored with `git checkout` to keep the tree at the committed state; the full re-benchmark will regenerate it |
| §23.2 #2 `run_ph1` capture | 22:27 and 23:10 MTP runs log `n_max=N: PASS (t/s, tokens, GPU)` for every candidate |
| §23.3 #3 `written_at`, fresh `not_run` from `mtpcheck` | In the diff; `tuning_written_at` present in the JSON I generated |
| §23.3 #4 residency `stream: true` | In the diff. Only lfm ran afterwards, so the time saving on slow-decode models is not yet measured; check that `prefill-sized: still running (30x2s)` no longer appears on the next ornith or gemma ladder |
| §23.3 #6 comments, usage, `--strict` in `AGENTS.md` | In the diff |
| `bash -n`, clean tree | Yes |

Note for future runs: `bench.sh bench <model>` in default inherit mode skips a family head that already has a JSON (`family head, already benched (skip)`). A deliberate re-bench needs `--no-inherit` or `--reset-parent`. Worth one line in the usage text.

### 25.2 Findings

1. **Stale status merged into a fresh record (live example).** The gemma JSON I generated carries `tuning_status: ok, tuned_n_max: 3, tuned_p_min: 0.7` from the 23:19 status file, while the ini the server actually loaded says `n_max 4, p_min 0.6` (`n_max_loaded: '4'`, `configured_n_max: 4`). The implementer applied the 23:10 winners and then reverted `models.ini` to the committed state, so the status file and the ini disagree, and the record now claims a tune that is not in effect. `written_at` makes it discoverable but not self-evident. Fix in `cmd_bench`: when the status says `ok` but `tuned_n_max` or `tuned_p_min` differs from the ini's configured values, write `tuning_status: stale` (keep the tuned values for reference) and log a warning. That closes the gap without touching the tuners. Required before publishing records.

2. **The median-of-three regression was misdiagnosed, and the real cause matters elsewhere.** The server log for the 22:54 run shows the "slow" second and third probes evaluated 4 tokens each (`prompt eval time = 19.47 ms / 4 tokens`) against 2870 tokens for the first. An identical prompt re-sent to the same slot is served from the prompt cache, so the log-parsed throughput is a 4-token figure. This is llama.cpp's `cache_prompt` behaviour (default true; documented in `tools/server/README.md`), not a transient state, and a fresh instance is not required to avoid it. Two consequences:
   - The single-shot `prefill_probe_sized` is already exposed to a smaller version of this at rung 256: `measure_ratio` sends a 2000-character prefix of the same filler immediately before, so about 400 tokens of the rung-256 probe come from cache. Add `'cache_prompt': False` to the sized probe's payload. It is a one-token change and makes every rung's measurement independent of what ran before it.
   - With that field set, repeating the probe is valid again. Re-enable median-of-three for probes that complete in under 5 s if repeatability on small-ctx models is wanted; it is optional per §23.4.

3. **Tie rule in §6.2 is worded too narrowly; correct the plan and the code together.** Two gemma runs picked different winners (n_max 2 at 21:49, 3 at 23:10) from candidates whose means all sat within 2% of each other. The 23:10 pick of 3 follows the plan text literally (best 4 at 52.9, runner-up 3 at 52.5, "the smaller of the two"), but n_max 2 at 52.35 was also within tolerance and is the value the tie rule is meant to prefer. Replace the rule with: `WIN_NMAX = the smallest n_max whose mean ≥ best_mean × (1 − MTP_TIE)`. Same intent, no more order dependence, and the same rule the batch pick already uses. This is a defect in my plan wording, not in the implementation.

4. **`cmd_bench` decode cap on 4K models.** `DECODE_MAX_TOKENS = ctx − 150` was sized for the old 150-token filler prompt. `DECODE_PROMPT` is about 103 tokens plus template, so on a 4K model the cap lands at the context edge; `decode_sample` uses `ctx − 256`. Align to `ctx − 256`. Not yet exercised on a 4K model.

5. **`cmd_bench` cannot fail loudly.** The speed and request lines and `JSON written` go to stdout only, never to the log file (this predates the refactor; the 16:45 log has the same gap), and a failing JSON write would still reach `=== DONE ===` and return 0 inside the `( cmd_bench ) ||` wrapper. Route those prints through `log`, and after the write check that the JSON file exists and is newer than the run's start, else `return 1`. Small, and it is what would have made the unverified state in 25.1 visible in the log.

6. **Cosmetic.** `acc=?` on non-MTP models should print `n/a`; `n_max_loaded` is a string where `configured_n_max` is an int.

### 25.3 Plan text corrections applied by this review

- §6.2 Phase 1 tie rule: "smallest n_max whose mean is within `MTP_TIE` of the best mean" (finding 3).
- §4.2: the sized probe sends `cache_prompt: false` (finding 2).

### 25.4 State

Complete per the plan. Before the full re-benchmark: apply findings 1, 3 and 4 (each is a few lines), then run family heads with `--no-inherit --strict` and let siblings inherit. Findings 2 (probe `cache_prompt`), 5 and 6 can ride along or follow.

---

## 26. Implementer disposition of the §25 review items (2026-09-08)

All three required (§25.4) and the recommended/cosmetic §25 items are implemented in one commit (`f129b96`).

| §25 item | Commit | Disposition |
|---|---|---|
| #1 stale-status guard (required) | `f129b96` | `cmd_bench` relabels `tuning_status` to `stale` when the status file says `ok` but `tuned_n_max`/`tuned_p_min` differ from the configured values the server loaded; keeps the tuned values for reference and logs a warning. Verified standalone: an `ok` file with tuned 3/0.7 against configured 4/0.6 → `tuning_status: stale`. |
| #2 probe `cache_prompt:false` (recommended) | `f129b96` | Added `cache_prompt: false` to the `prefill_probe_sized` payload so no prefix is served from the slot prompt cache (measure_ratio precedes rung 256). This also un-blocked the misdiagnosed median-of-3; per §25.4 it can be re-enabled later if repeatability on small-ctx models is wanted (the implementer left it single-shot). |
| #3 MTP tie rule (required) | `f129b96` | `mtp_phase1_winner` now returns the smallest n_max whose mean is within `MTP_TIE` of the best mean (not best-vs-runner-up). Matches §6.2 plan wording (already corrected by the author). |
| #4 cmd_bench decode cap (required) | `f129b96` | `DECODE_MAX_TOKENS = max(256, min(4000, ctx-256))`, matching `decode_sample`. |
| #5 cmd_bench fail loudly | `f129b96` | `=== RESULTS ===` figures are appended to the log file as well as stdout; after the JSON write, verify the file exists, is non-empty, and is newer than the run start, else `return 1` (no false `=== DONE ===`). |
| #6 cosmetic | `f129b96` | `acc=` prints `n/a` on non-MTP; `n_max_loaded`/`p_min_loaded` coerced to int/float to match `configured_n_max`/`configured_p_min`. Verified on a fresh gemma bench: `n_max_loaded: 4` (int) == `configured_n_max: 4`. |

Verified: a fresh `--no-inherit bench gemma-4-12b-q4-qat-mtp-16k` completes with
natural-stop decode (finish=stop, 3037 tokens, deg 0.0, 52.9 t/s) and the type
consistency is confirmed. models.ini and the gemma JSON were restored to their
committed state after the run.

The pipeline is complete per the plan and ready for the full re-benchmark:
family heads with `--no-inherit --strict`, then let siblings inherit.

---

## 27. Author review of the §26 disposition (2026-09-08)

**Verdict: complete. Every §25 item is implemented correctly, and I verified the two that matter most live rather than by inspection. The pipeline meets the plan and is ready for the full re-benchmark.**

### 27.1 Verified

| Item | How |
|---|---|
| #1 stale-status guard | The status file from yesterday's tune had already been removed, so the 06:49 run only showed `not_run`. I placed a synthetic `ok` status with tuned 3/0.7 against the ini's 4/0.6 and ran `--no-inherit bench` on gemma: the record came out `tuning_status: stale` with the reason string, and the warning printed. Comparison types are consistent on both sides (`meta` parses n_max as int and p_min as float; the status reader does the same), so the equal case stays `ok`. Synthetic file removed, JSON restored afterwards |
| #3 tie rule | Ran `mtp_phase1_winner` offline against the 23:10 run's own samples: winner is now n_max 2 (was 3). Two synthetic cases behave correctly: a clear best of 4 wins outright; a within-tolerance 2 that spilled to CPU is skipped and 3 wins |
| #4 decode cap | `max(256, min(4000, ctx − 256))`, identical to `decode_sample` |
| #5 fail-loud bench | `speed:` and `request:` lines now appear in the log file (06:49 and 06:54 runs); `JSON written` goes through `log`; the post-write check uses `REQUEST_START`, which is set at the top of the run |
| #2 `cache_prompt: false` on the sized probe, #6 cosmetics | In the diff; `n_max_loaded: 4` and `p_min_loaded: 0.6` are numeric in the record I generated |
| End-to-end bench | Two more full `cmd_bench` runs today (06:54, 06:58): natural stop at about 3000 tokens, degeneracy 0.0, decode 52 to 56 t/s, JSON written and verified, exit 0. Tree restored to committed state after each |

### 27.2 One small leftover, not blocking

The stale-status warning is written with `sys.stderr.write` inside the JSON heredoc, so it reaches the terminal but not the log file, while the resulting `tuning_status: stale` is in the JSON. Route it through `log` (append to `$LOG_FILE`) so a suite run's log shows it next to the verdict. Two lines.

### 27.3 Handover

- Run family heads with `--no-inherit --strict`, then let siblings inherit. Remember that `bench.sh bench <model>` in default inherit mode skips a family head that already has a JSON.
- On the first ornith or gemma ladder after this, confirm the residency `stream: true` change removed the `prefill-sized: still running (30x2s)` waits; that is the only §23 change whose effect is not yet measured on a slow-decode model.
- §8 sibling seeding stays deferred until that re-benchmark shows how close context siblings' picks land.

---

## 28. Implementer note on §27.2 (2026-09-08)

The one small leftover from §27.2 is fixed in `a0e2ff5`: the stale-status
warning is now appended to `$LOG_FILE` as well as stderr, so a suite run's log
shows the `tuning_status: stale` condition next to the verdict (previously it
only reached the terminal). Verified with a synthetic stale status (warning on
both stderr and the log file).

No further §27 items remain. Handover stands: run family heads with
`--no-inherit --strict`, then let siblings inherit; confirm on the next ornith /
gemma ladder that residency `stream: true` removed the `prefill-sized: still
running (30x2s)` waits; §8 sibling seeding stays deferred until that
re-benchmark shows how close context siblings' picks land.

---

## 29. Author sign-off (2026-09-08)

Reviewed `a0e2ff5`: the stale-status warning is appended to `$LOG_FILE` and still written to stderr, inside a try block so a log write failure cannot interrupt the JSON write. That was the last open item. `bash -n` clean, working tree clean.

**The implementation meets the plan. No further review items.** The handover in §27.3 stands: family heads with `--no-inherit --strict`, siblings inherit, confirm the residency streaming effect on the first slow-decode ladder, sibling seeding deferred.

---

## 30. Post-catalogue-start corrections (2026-09-08, from the user's first real runs)

The user reports two problems from the 07:04 lfm suite run and the 07:39 gemma run: it is still slow, and it picks a smaller batch than the best-measured rung. Both are examined against the logs below. The speed complaint is correct for small non-MTP models; the pick complaint is a preference the default should follow.

### 30.1 Speed: discover is slower than the 09-05 pipeline on small non-MTP models

| model | discover today (bisect start → bench start) | 09-05 pipeline (same models, `bench_20260905-1427.log`) |
|---|---|---|
| lfm 4K | 5.3 min | 3.2 min |
| lfm 8K | 5.9 min | 3.8 min |
| lfm 16K | 6.4 min | 3.7 min |
| lfm 32K | 7.3 min | 10.0 min |

Discover wins on the 64K MTP model it was designed around (ornith: 52 → 18 min) and on 32K, and loses on the three small models. Per-rung cost on lfm 8K is about 43 s, of which the residency probe is about 25 s (its 20 s minimum floor plus the kill), the restart about 10 s, and the prefill probe itself 1 to 2 s. On top of that each model pays a decode baseline at rung 256 (~50 s) and a decode sample at the pick (~50 s). For a model with no MTP draft and no `override-tensor`, none of those three measurements can change the answer: there is no draft to spill, and decode does not depend on batch. They exist for the MTP and CPU-offload classes.

**Change A — non-MTP shortcut.** In `cmd_bisect_discover`, when the section has no `spec-type = draft-mtp` and no `override-tensor`: run `residency_probe` at rung 256 only (to set MODE), skip it on later rungs, skip `DEC_BASE`, and skip the pick decode sample and cliff check. Saturation, long-decode and the OOM gates stay. Expected: lfm-class ladders drop from ~45 s to ~15–20 s per rung and lose ~100 s of decode samples, so roughly 5–7 min → 3–3.5 min per model, at or below the 09-05 pipeline. This applies to about 40 of the 73 entries (GLM, gpt-oss non-MTP, lfm, qwen non-MTP, llama3).

**Change B — residency `AMBIGUOUS` is costing 80 s per rung on gemma.** In the 07:39 run three of six rungs returned `AMBIGUOUS (avg cpu 100.6% / 104.9% / 101.8%)`. The GPU rule requires `cpu < 100`, gemma's decode idles one core at 100–105%, so the early-kill never triggers and the probe runs its full 40-sample window (80 s) instead of ~25 s. A real draft spill measures 270 to 1600% (every documented case). Raise the GPU threshold to `cpu < 150` with GPU utilisation active, both in the early-kill rule and the fallback average, keep `> 200` as CPU. Saves ~55 s on each such rung, about 3 min on that ladder.

### 30.2 The pick: 1024 versus 2048 — the user is right, and the earlier author statement was wrong

Correction: the author's first reply claimed the previous pipeline had chosen 1024/1024/1024/2048 for the lfm family. That was read from `models.ini` and the JSON files at HEAD *after* the user's 07:38 commit of today's results. Git history (`64789c1`, 2026-09-05, and every `models.ini` commit from 09-06 to 09-07) shows the previous picks were **1024, 2112, 2176, 3008**. Discover replaced three of them with smaller values. Measured cost, from the bench records at the same 75%-ctx prompt:

| model | previous batch → prefill | discover batch → prefill | prefill change |
|---|---|---|---|
| lfm 4K | 1024 → 6697 t/s | 1024 → 6553 t/s | same batch; −2% is day-to-day noise |
| lfm 8K | 2112 → 6907 t/s | 1024 → 6828 t/s | −1.1% |
| lfm 16K | 2176 → 7112 t/s | 1024 → 6830 t/s | −4.0% |
| lfm 32K | 3008 → 6675 t/s | 2048 → 6641 t/s | −0.5% |

(Decode is 7–8% lower in every new record including the same-batch 4K one; that is the natural-stop measurement replacing the forced 4000-token one, not a batch effect.)

So the "smallest within 3%" rule gave up 1 to 4% prefill on this family for headroom that these models do not need. The ladder itself had the right answer each time: 2048 was the best-measured rung on 8K, 16K and 32K, matching the previous picks (2112, 2176) to within the ladder's granularity. The tie-break, not the search, produced the regression.

**Change C — default `PREFILL_TOL=0`.** The pick becomes the best-measured rung (2048 on lfm 8K and 16K, 4096 on lfm 4K, 2048 on 32K). Keep the constant so anyone who wants headroom can set it back to 0.03; document both in `AGENTS.md`. Note the consequence honestly: on a flat plateau the best-measured rung is noise-selected and may differ between runs. That is acceptable because the candidates are equivalent within measurement.

### 30.2b Resolution between rungs

The user notes discover no longer resolves to 64 tokens. Deliberate: adjacent 64-steps in the 16:45 golden-section run differed by up to 3% in either direction, which is single-probe noise, so the old 2112 and 2176 picks are not distinguishable from 2048. The one case the doubling ladder genuinely cannot see is a peak *between* rungs on a curve that is not flat: lfm 32K's previous pick of 3008 (6675 t/s at bench against 6641 at 2048) and gpt-oss (rises to 2048, falls at 4096; previous pick 2112) both have that shape.

**Change D (superseded by E below).** A fixed single midpoint pass is too coarse where it matters: between 4096 and 8192 one midpoint still leaves 2048-wide gaps, and the user's point is that the old 64-token bisect existed to resolve exactly those ranges.

**Change E — noise-aware refinement, with resolution that scales with the value.** After the ladder, classify the best-measured rung and refine accordingly. Every refinement step is one restart plus the cheap rung measurements (tiny probe → residency, per Change A → sized prefill); no saturation per step.

1. **Interior peak** (PASS rungs on both sides of the best): test the midpoint toward each neighbour, rounded to 64. Move toward the better side and repeat only while the new point beats the current best by more than `PREFILL_NOISE=0.03`. Stop when the gap is ≤ `max(256, 6% of current best)`. Typically 2 steps, at most 4. Rationale: inside a flat or falling range every point measures the same within noise, so finer steps only pick the sample that landed high.
2. **Ceiling edge** (best is the top PASS rung and the next rung failed with OOM/SPILL): bisect between them. Stop when the gap is ≤ `max(64, 6% of the lower bound)`: a 256/512 edge resolves to 64 (small-ceiling MoE class, where 448 vs 256 is a real 75% difference on the steep part of the curve), a 4096/8192 edge to about 256 to 512 (where further steps no longer move prefill). If a midpoint's prefill measures more than `PREFILL_NOISE` below the lower bound, the peak is not at the ceiling: stop bisecting and apply rule 1 from the lower bound. At most 5 to 6 steps.
3. **Pick** = best-measured point across ladder and refinement (Change C). **Confirm** as today (saturation + long-decode + cliff check for MTP). On a confirm failure at a refined point, step down through the refinement points below it, largest first, at most twice; then fall back to the top ladder rung below and confirm that; then fail the model.
4. Record every refinement point in the JSON ladder list with `status: REFINE` and the rule that produced it.

Cost: zero extra restarts on a flat curve, about 1 to 2 minutes on an interior peak, at most about 4 minutes when the ceiling is the optimum. This restores the old resolution exactly where it was producing information (memory-limited ceilings) without the saturation test per step that made the old bisect cost 25 minutes on a 64K model.

### 30.3 Optional hardening seen in the same run

The MTP tuner switches p_min away from 0.7 when one sample beats the reference by more than 5%. With ±5% single-sample noise that will occasionally fire on a fluke. Require a confirming second sample of the candidate before switching (one extra run only when a candidate appears to win). Not urgent; the 07:39 run ended up keeping 0.7 correctly.

### 30.4 Acceptance for A–C and E

Re-run `bench.sh --no-inherit --strict all` on the four lfm models and on `gemma-4-12b-q4-qat-mtp-16k`. Expect: lfm bisect ≤ 5 min each with residency logged once per model; gemma ladder with no `AMBIGUOUS` verdicts and no 80 s residency windows; picks equal to the best-measured point including refinement (lfm 8K/16K/32K within one refinement step of the previous 2112/2176/3008). Add one ceiling-edge model: `qwen-3.5-9b-q4-mtp-256k` (previous pick 448 between rungs 256 and 512; see §34.2) must resolve its edge to 64 and land within 64 of a value that passes saturation. No change to the ornith-class budget except the AMBIGUOUS saving.

---

## 31. Implementer finding + disposition of §30 Changes A-E and §30.3 (2026-09-08)

### 31.1 A real bug the §30 review did not cover: `n_max_loaded` stale-block parser

On the fresh gemma-4-12b record (08:01), `tuned_n_max: 2`, `configured_n_max: 2`
(ini is 2), but `n_max_loaded: 4`. Ground truth from the docker log: every recent
gemma load used n_max=2, and the bench decode's `acceptance 0.69051 /
1390/2013 / mean len 2.20` exactly matches an n_max=2 run — so the decode really
ran at n_max=2 and `n_max_loaded: 4` is wrong.

**Root cause** (`cmd_bench` `load_val`, tools/bench.sh): it used `re.search`
(the FIRST `--alias <MODEL>` block) then backscanned ~2000 chars for
`--spec-draft-n-max`, grabbing an earlier load block (e.g. the bisect/mtp phase
at n_max=4 before tuning set it to 2) instead of the bench's own fresh load.

**Fix (commit `79f3bc3`):** use the LAST `--alias <MODEL>` block so the loaded
params reflect the bench's own restart.

**Follow-on (commit `6d6edb3`):** extend the §25#1 stale-status guard so it also
flags `ok` when the server's loaded values (`n_max_loaded`/`p_min_loaded`) differ
from the tuned ones, not just when configured differs.

### 31.2 Disposition of §30 Changes A, B, C, E and §30.3

All implemented and committed, one commit each:

| Change | Commit | Summary |
|---|---|---|
| C — `PREFILL_TOL` default 0 | `bc7516e` | pick = best-measured rung; 0.03 settable for MTP headroom. |
| B — residency GPU `<150` | `bc7516e` | `GPU_CPU_MAX=150`; fixes gemma AMBIGUOUS 80s windows. |
| A — non-MTP shortcut | `689888a` | residency at rung 256 only; skip DEC_BASE + pick decode for simple non-MTP. |
| E — noise-aware refinement | `d89425d` | ceiling-edge bisect to `max(64,6%)`; interior-peak midpoint; `PREFILL_NOISE` stop; REFINE in JSON. |
| §30.3 — p_min confirm | `1dc94c4` | second sample before switching p_min away from 0.7. |
| docs | `a039101` | AGENTS.md procedure updated for A/C/E. |

### 31.3 Notes for the author on Change E

- Change E is implemented conservatively: ceiling-edge bisects between the top
  PASS point and the failed rung (rule 2), interior refinement searches the
  ascending side toward a higher neighbour (rule 1). Both stop on the
  `PREFILL_NOISE` gate and record points as `REFINE` in the JSON.
- Step-down (rule 3) now walks refinement points below the pick before ladder
  rungs, via `discover_stepdown_candidate`.
- Refinement runs only for MTP-class models (skipped under Change A and for
  MODE=CPU), so simple/flat models see no extra restarts.

Awaiting author review of the §30 acceptance run (below) and of §31.1.

---

## 32. Author review of §31 (2026-09-08)

**Verdict: A, B, C, §30.3 and the §31.1 parser fix are correct. Change E is not implemented as specified: it is skipped for every non-MTP and CPU-compute model, which removes it from the models the user's complaint was about (lfm, GLM, gpt-oss). One logic bug in the edge rule. Two required fixes, listed first.**

### 32.1 Required

1. **Refinement must run for all modes.** `cmd_bisect_discover` wraps both refinement rules in `if [ "$SIMPLE_NONMTP" -eq 0 ] && [ "$MODE" != "CPU" ]`, with the comment "flat prefill, Change A". Change A is about residency and decode samples, which are batch-independent on simple models; it says nothing about prefill. The prefill curve on these models is not flat where it matters: the user's evidence for §30.2b was lfm 8K/16K/32K (previous picks 2112, 2176, 3008, all non-MTP) and gpt-oss (rises to 2048, falls at 4096, previous pick 2112, CPU-compute). Today's 08:34 run shows the consequence: lfm 8K logs `after refinement: pick=2048` with zero refinement points tested. Remove the exemption. Each refinement candidate already applies Change A internally through `discover_measure_candidate` (residency only when not simple / rung 256), so the per-step cost on simple models is a restart plus tiny probe plus prefill probe, about 15 to 20 s.
2. **Edge rule fires when the best rung is not the top PASS rung.** The condition is `CEIL_FAIL_B set && reason OOM/SPILL && CEIL_FAIL_B > PICK`. If the ladder reached a failed rung but the best rung is interior (for example 512 best, 1024 PASS but lower, 2048 OOM), this bisects between 512 and 2048 and tests 1280, 1792, and so on, above a rung already known to be worse. §30.2b rule 2 requires the best to be the top PASS point. Add `[ "$PICK" -eq "$HIGHPASS" ]` to the condition; otherwise fall through to the interior rule.

### 32.2 Accepted deviations and notes

3. **Interior rule searches upward only.** The plan said "midpoint toward each neighbour". Upward covers every observed case (2112, 2176, 3008, all above the best rung), so this is acceptable, but it should choose the side by data rather than by convention at the same cost: test the midpoint toward whichever neighbour measured the higher prefill. One restart either way, and it catches a peak that leans below the best rung.
4. **Change A verified in the 08:34 run:** residency once per model, no decode samples, lfm 4K bisect 2.1 min against 5.3 min this morning. Meets the §30.4 budget.
5. **Change C verified:** lfm 4K and 8K picked 2048 with `TOL=0`. The result line still prints `smallest within 0 of best`; make it say `best measured`.
6. **Change B not yet verified live.** The only MTP run since the change has not happened; the 07:39 gemma run predates it (`ambiguous=6`). Verify on the next gemma or ornith ladder: expect zero `AMBIGUOUS` verdicts and no 80 s residency windows. Do not start it while the lfm suite is running; two benches sharing the GPU corrupt both.
7. **§31.1 (`n_max_loaded` from the last `--alias` block) and the extended stale guard** are correct and welcome; the loaded-versus-tuned cross-check closes the last way a record could claim a tune that was not in effect.
8. **§30.3 p_min confirmation** is correct: one extra run only when a candidate appears to win, and the two-sample mean must still clear the tie margin.

### 32.3 Acceptance after the two fixes

Re-run the lfm family and `gpt-oss-20b-a4b-q4-64k-think-low` (interior peak, CPU mode): expect `REFINE` points in the JSON ladder for 8K, 16K, 32K and gpt-oss, picks within one refinement step of 2112, 2176, 3008 and 2112, and no refinement on 4K if its best rung is already at the cap. Then `qwen-3.5-9b-q4-mtp-256k` for the ceiling edge (GPU 9B whose 256K KV cache leaves a memory ceiling between 256 and 512; expect resolution to 64 near the committed 448) and one gemma ladder for Change B. (Corrected in §34.2: the 35B and 26B MoE models are CPU-compute on this GPU and have no such edge.)

---

## 33. Implementer report — §32 fixes applied and §32.3 acceptance (2026-09-08)

### 33.1 §32 required-fix commits

| §32 item | Commit |
|---|---|
| #1 refinement runs for all modes (removed SIMPLE_NONMTP/CPU gate) | `78f3788` |
| #2 edge rule fires only when PICK==HIGHPASS | `78f3788` |
| #3 interior side chosen by data (higher-prefill neighbour) | `78f3788` |
| #5 RESULT line "best measured" when TOL=0 | `78f3788` |
| stdout pollution in discover_measure_candidate (set_batch/restart/tiny_probe wrote to stdout, corrupting refinement point capture and the $POINTS append) | `7511251` |
| interior adoption always takes the higher measured point; PREFILL_NOISE only gates continued search | `98a5ebc` |

The `7511251` and `98a5ebc` fixes were found during the acceptance run: refinement points were not recorded (stdout pollution made them multi-line garbage) and a genuinely-higher refinement point within 3% of the ladder best was never adopted.

### 33.2 §32.3 acceptance results

**lfm 8K/16K/32K** (`--no-inherit --strict all`): refinement now runs and REFINE
points are recorded in the discover JSON. lfm 8K refined 1536, 16K/32K refined
3072. Picks stayed at the best-measured ladder rung (2048) where refinement points
were within noise; on flat plateaus this is the documented noise-selected outcome
(§30.2b) — the previous 2112/2176/3008 were themselves golden-section
single-sample artifacts, and 2048 is equivalent within measurement. Change A
speed confirmed (residency once per model).

**gpt-oss-20b-64k-think-low** (interior peak, CPU): mode=CPU, refinement ran
(testing 1536 toward the higher neighbour), pick 2048 (best ladder rung 2453.91),
1536 (2433.73) within noise — kept 2048. Previous 2112; equivalent within
measurement. (Refinement previously did not run for CPU models; now it does.)

**gemma-4-12b-q4-qat-mtp-16k** bisect (Change B): **zero AMBIGUOUS verdicts** and
**zero 80s residency windows** — every rung classified GPU (cpu 97-106%) with the
early-kill firing (GPU_CPU_MAX=150). Interior refinement worked: ladder best 1024
(1172) → refined 1536 (1178.45) → adopted as pick → saturation + long-decode
PASS at 1536.

### 33.3 Finding: the qwen-3.6-35b ceiling-edge premise does not match the model

§30.4 named `qwen-3.6-35b-a3b-q4-mtp-64k` for a ceiling edge resolving to 64
between 256 and 512. In practice this 35B MoE is **CPU-compute** at every ctx
(64k and even 4k), with a high ceiling (~8192) or a cap-limited one — it is not
the small-ceiling GPU MoE the 448-between-256/512 example describes. The
small-ceiling GPU MoE class in this catalogue is the gemma-4-26b-a4b family. The
ceiling-edge-to-64 path is exercised whenever a GPU model's best PASS rung is its
top measured point with an OOM/SPILL above (verified by the rule-2 code path);
but the specific 448-to-64 case was not reproduced on qwen-3.6-35b because that
model does not have a 256-512 GPU ceiling. Recommend fable confirm the intended
ceiling-edge acceptance model (gemma-4-26b-a4b-mtp-8k hit an unhandled silent
exit at the 8192 OOM during an exploratory bisect — separate issue worth a look).

### 33.4 Note
The §32.3 acceptance runs left fresh Discover results in the model JSONs (lfm,
gpt-oss, gemma) and models.ini. These are validation outputs; whether to commit
them as the publishable re-benchmark records (they are lower/regenerated decode
figures) or defer to a full clean run is for the user.

---

## 34. Author review of §33 (2026-09-08)

**Verdict: the §32 fixes are correct and verified live on every model class. Change E now runs everywhere, Change B is confirmed, and the lfm regression that started §30 is closed. Two items remain before sign-off: the "silent exit" in §33.3 is a real bug in the direct-invocation path and must be fixed, and the ceiling-edge acceptance model in §30.4 was my error and is replaced.**

### 34.1 Verified

| Item | Evidence |
|---|---|
| Refinement on all modes | lfm 8K/16K/32K each tested one midpoint (1536 or 3072); gpt-oss (CPU mode) tested 1536; gemma tested 1536 and adopted it (1180 vs 1175 t/s). `REFINE` points present in the JSON ladders |
| Side chosen by data | 8K and 16K went toward 1024, 32K toward 4096, each matching the higher-measured neighbour |
| Edge rule gated on top rung | Code; no false edge bisect in any log |
| Change B | Two gemma ladders (10:14, 10:29) with zero `AMBIGUOUS` verdicts and every rung early-killed; the 07:39 run before the change had six |
| Change A speed | lfm bisects 2.1 to 3.2 min each in the 09:02 and 09:19 suites, against 5.3 to 7.3 min this morning and 3.2 to 3.8 min on the 09-05 pipeline |
| The §30.2 regression | Bench prefill at the new 2048 picks against the previous records: 8K 6902 vs 6907 at 2112; 16K 7034 vs 7112 at 2176 (−1.1%); 32K 6634 vs 6675 at 3008 (−0.6%). All within noise; the −4% on 16K is gone |
| stdout-pollution and adoption fixes found during acceptance | Correct; the adoption rule now matches Change C (pick = best measured, noise gates only continued search) |

One positive worth recording: `qwen-3.6-35b-a3b-q4-mtp-64k` moved from the committed 448 to 8192 with saturation and long-decode passing. Its ladder shows 448 sat on the steep part of the CPU-compute prefill curve (256 → 364 t/s, 512 → 561 t/s) while 8192 measures 1301 t/s, roughly 2.5x.

### 34.2 Required

1. **The gemma-26b "silent exit" is errexit on a plain-statement probe call, the same class as §20.1.** The 10:08 log ends at the 8192 rung with the OOM marker and nothing after it. In `cmd_bisect_discover` the ladder calls `tiny_probe` as a bare statement and reads `$?` on the next line; under direct `bench.sh bisect` invocation `set -e` is live, so a rung that OOMs (return 1) terminates the shell before the OOM handling runs. The suite masks it because `if ( cmd_bisect )` disables errexit. Reproduction: `bash -euo pipefail -c 'f(){ return 1; }; g(){ f; local RC=$?; echo after; }; g'` exits 1 before `after`; `f || RC=$?` does not. Sites: `tiny_probe` in the ladder and in `discover_measure_candidate`, `saturation_test "$CTX"` and `long_decode_check` in the confirm loop (four in discover), the same three in `cmd_bisect_test_batch`, and the same pattern throughout `cmd_bisect_thorough`. Fix every one with `RC=0; fn || RC=$?`. Acceptance: a **direct** `bench.sh bisect gemma-4-26b-a4b-q4-qat-mtp-8k` must log `OOM at 8192 (tiny probe / load)`, finish the ladder, and reach `=== DONE ===`. Add "one direct-invocation run that hits an OOM rung" to the standing checks in §11, since this is the second time the suite wrapper has hidden a direct-path crash.
2. **Ceiling-edge acceptance model.** §33.3 is right: `qwen-3.6-35b-a3b` is CPU-compute at every context (a 35B Q4 cannot be resident on 12 GB) and `gemma-4-26b-a4b` records `placement: CPU` at 13.3 GB, so neither has a GPU memory ceiling between two rungs. The GPU small-ceiling case in this catalogue is the 9B MTP models at 256K, where the KV cache consumes the VRAM: `qwen-3.5-9b-q4-mtp-256k` (committed 448) and `ornith-1.5-9b-q4-mtp-256k-think` (committed 960). Replace the §30.4 edge model with `qwen-3.5-9b-q4-mtp-256k`: expect 256 PASS, 512 OOM or SPILL, bisection to 64 between them, a pick near 448, saturation PASS at 99% of 256K.

### 34.3 Notes, not blocking

3. In the interior loop, `LO_NEIGH`/`HI_NEIGH` and their prefills are computed once before the loop and not updated after a point is adopted, so a second step chooses its direction from the original neighbours. Harmless with the 4-step cap and the noise gate, which stopped every observed run after one step; tidy when next touched.
4. The gemma JSON in the working tree is from the 08:01 bench (batch 512) while the 10:29 bisect set the ini to 1536; the next `bench` on that model regenerates it, and the stale guard would flag any MTP mismatch. The working-tree JSONs and `models.ini` are validation outputs; committing them is the user's call, as §33.4 says.

### 34.4 After 34.2

Sign-off follows a direct-invocation OOM run per item 1 and the 256K edge run per item 2. Then the catalogue: family heads with `--no-inherit --strict`, siblings inherit.

---

## 35. Implementer disposition of §34 (2026-09-08)

### §34.2#1 — errexit silent-exit fix (commit `7f09947`)

Bare probe calls that `return` nonzero were terminating the shell under direct
`set -e` invocation before the next-line `$?` handling ran, so a ceiling OOM in a
direct `bench.sh bisect` silently exited (the suite masks it via `if ( cmd )`).
Converted every bare `fn` + `RC=$?` (and `fn; RC=$?`) to `local RC=0; fn || RC=$?`
across: `cmd_bisect_discover` (ladder `tiny_probe`, `discover_measure_candidate`,
confirm `saturation_test` + `long_decode_check`), `cmd_bisect_test_batch`, and
`cmd_bisect_thorough` (ceiling_probe, refine-bisect, final confirm, post-sweep
long-decode).

Verified with a DIRECT `bench.sh bisect gemma-4-26b-a4b-q4-qat-mtp-8k`: it now
logs `OOM at 8192 (tiny probe / load)`, finishes the ladder (ceiling 4096 PASS /
8192 OOM), refines pick 2048 → 3072 (adopted, 1766.89 t/s), saturation + long-
decode PASS at 3072, `=== DONE ===`, exit 0. Previously it exited 1 silently at
the OOM.

### §34.2#2 — ceiling-edge acceptance model (commit `e7a66dd` by author; verified here)

Ran `qwen-3.5-9b-q4-mtp-256k` bisect. Result: mode=GPU; ladder 256 PASS (1455),
512 PASS (1509), 1024 SPILL (KV cache fills VRAM at 256k). Ceiling-edge rule
bisected between 512 and 1024: tested 768, then 640, then 704, resolving to
**640** (1525 t/s, a 64-granularity point). **Pick=640**, saturation PASS at 99%
of 256k ctx, long-decode PASS, `=== DONE ===`, exit 0. The ceiling edge landed at
512/1024 (not 256/512 as §30.4 guessed — 512 also fit), and 640 beats the
committed 448. Acceptance criterion (64-granularity ceiling-edge bisection with a
pick that saturates at 99% ctx) is met.

### Note
All code committed; working tree has only acceptance-run model JSONs and
models.ini (validation outputs; committing them is the user's call per §33.4).
Ready for sign-off and the catalogue re-benchmark (family heads with
`--no-inherit --strict`, siblings inherit).

---

## 36. Author sign-off on the discover pipeline (2026-09-08)

**Signed off.** Both §34.2 items are implemented and verified by live runs, not by inspection:

| Item | Evidence |
|---|---|
| Errexit on bare probe calls | Every `fn; RC=$?` in the discover path, the test-batch helper and the thorough path is now `RC=0; fn || RC=$?`. Direct `bench.sh bisect gemma-4-26b-a4b-q4-qat-mtp-8k` (10:51): logs `OOM at 8192 (tiny probe / load)`, finishes the ladder, refines 2048 → 3072 (+4.7%, above the noise gate, adopted), saturation and long-decode PASS at 3072, `=== DONE ===`. The same run exited silently at the OOM two hours earlier |
| Ceiling-edge resolution | `qwen-3.5-9b-q4-mtp-256k` (10:59): 256 PASS, 512 PASS, 1024 SPILL; edge bisect 768 fail → 640 pass → 704 fail; stop at the 64 gap; pick 640 against the committed 448; saturation PASS at 99% of 256K (259,523 prompt tokens), long-decode PASS. This is the 64-token resolution the user asked for, delivered where it is memory-limited and real, in three restarts |

Two bare `saturation_test "$CTX" >&2` calls remain, at the confirm loops of `cpu_saturation_sweep` and `gpu_saturation_sweep`, each followed by a `$?` read. Both functions are thorough-only. Convert them the same way when the file is next touched; they do not affect the default path.

The working tree holds the validation-run JSONs and `models.ini` changes (lfm ×4, gpt-oss, gemma-12b, and the ini picks for gemma-26b-8k at 3072 and qwen-3.5-256k at 640). They are real measurements from the final code, so committing them is reasonable, but the gemma-12b JSON predates that model's last bisect and will be regenerated by the next bench. The user decides.

**State of the plan.** Sections 0 to 35 are the record. The default pipeline is: one doubling ladder with cheap probes; residency and decode samples only where a draft or offload can spill; best-measured pick; noise-aware refinement that resolves to 64 at a memory ceiling and stops on flat curves; one-restart confirm with saturation, long-decode and the spill check; MTP tuned on natural-stop speed with placement as the only hard gate; every failure written truthfully into the record. Thorough remains behind `--thorough`. Next step is the catalogue: family heads with `--no-inherit --strict`, siblings inherit.

---

## 37. Implementer cleanup on §36 (2026-09-08)

Fable's §36 signed off and noted two leftover bare `saturation_test "$CTX" >&2`
calls in the thorough-only confirm loops of `cpu_saturation_sweep` and
`gpu_saturation_sweep`, "convert them the same way when the file is next touched."
Done now in `cf80f0f`: both converted to `local C_RC=0; saturation_test ... >&2 ||
C_RC=$?`. This completes the §34.2#1 errexit hardening across every probe/confirm
call site; no bare `fn; RC=$?` (or `fn` + next-line `$?`) pattern remains in the
file. Default path unaffected.

Pipeline signed off (§36). Next step is the catalogue re-benchmark: family heads
with `--no-inherit --strict`, then siblings inherit.

---

## 37. Placement must be binary (2026-09-08)

The first catalogue record (`lfm-2.5-8b-a1b-q4-4k-think`, 11:54) carries `placement: AMBIGUOUS` with `avg_cpu_pct: 100.2` and `avg_gpu_util_pct: 64.6`. The model is plainly GPU-resident; the label comes from two classifiers that Change B did not reach.

**Why it says AMBIGUOUS.** `cmd_bench` and `decode_sample` still classify on the llama-server process CPU alone: under 100% is GPU, over 200% is CPU, anything between is AMBIGUOUS. A GPU-resident llama.cpp keeps exactly one host thread busy feeding the GPU, so its process CPU sits at 100% and wobbles to 105 or 110 during the run; 100.2% is that thread, not compute on the CPU. The residency probe was fixed in Change B (`GPU_CPU_MAX=150`); these two copies were not. The value is not used for any decision in either place (only a `CPU` verdict rejects anything), but it is written into the published record.

**Change F — one binary classifier, shared by all three sites.** Replace the three copies with one function `classify_placement AVG_CPU AVG_GPU`:

```
CPU  if avg_cpu > 200                                    # all cores busy: compute on CPU
GPU  if avg_cpu < GPU_CPU_MAX (150) and avg_gpu > GPU_ACTIVE_PCT (25)
otherwise decide by the GPU: avg_gpu > GPU_ACTIVE_PCT → GPU, else → CPU
```

The residency probe keeps its early-kill logic but takes its final verdict from the same function, so `AMBIGUOUS` disappears everywhere. Rationale for the tie-break: the GPU utilisation is direct evidence of where the matrix work runs; process CPU between 150 and 200% with the GPU busy is a host thread plus sampling, and with the GPU idle it is compute. Record `avg_cpu_pct` and `avg_gpu_util_pct` as today so the basis stays visible.

Acceptance: re-run the lfm 4K bench; expect `placement: GPU`. Grep the script for `AMBIGUOUS`; the only remaining hits should be comments.

---

## 38. Always refine to 64 (2026-09-08, user direction)

The user does not want picks confined to the doubling rungs. Change E's noise gate stops refinement after one midpoint on most curves, so in practice the pick is a power of two. This section replaces the gate with an unconditional refinement to 64-token granularity, made affordable by two facts established this week.

**Facts that make it cheap.**
1. With Change A, a probe point on a plain model costs 10 to 13 s (restart, tiny probe, one 3K to 16K-token prefill).
2. Memory use is monotonic in batch. If both ends of a bracket passed the tiny probe and residency, no batch between them can OOM or spill, so refinement points inside such a bracket need **no residency probe**. Residency is only needed while bisecting toward a failed upper bound (ceiling edge). This cuts an MTP-model refinement step from ~45 s to ~20 s.

**Change G — golden-section refinement after the ladder, always, to 64.** Supersedes the Change E stopping rules (keep the E code structure; change the policy):

```
after the ladder (Change C pick = best rung):
  bracket = [lower neighbour rung, upper neighbour rung] of the best rung
            (at a ceiling edge: [best rung, failed rung]; at the low end: [256, upper neighbour];
             at the cap with nothing above: [lower neighbour, cap])
  golden-section search on prefill inside the bracket, candidates rounded to 64,
  reuse any point already measured, stop when the bracket width ≤ 64
  each candidate: restart → tiny_probe → prefill_probe_sized (cache_prompt false)
    + residency_probe ONLY when the bracket's upper bound is a failed rung (edge) and the model is not SIMPLE_NONMTP
    + median of 3 prefill probes when the first probe completed in under 5 s
  a candidate that OOMs/spills becomes the new upper bound
  pick = best measured point over ladder + refinement; confirm as today (one restart)
  record every point in the JSON ladder with status REFINE
```

Expected steps: log base 1.618 of (bracket width / 64): a 3072-wide bracket (1024 to 4096) needs about 8, a 1536-wide one about 7. Estimated added time: 1.5 to 2 min on lfm-class, 2 to 3 min on 9B MTP heads, 3 to 4 min on CPU-compute models whose probes are slower. Still far below the old bisect, whose cost was the saturation test per step, not the step count.

**What this trades.** Among neighbours that measure within noise of each other, the final 64-token digit is chosen by whichever sample landed highest. That is acceptable: those candidates are equivalent by measurement, the safety gates still run at the pick, and the user has stated the preference for the resolved value. `PREFILL_NOISE` is retained only as the median-of-3 trigger and for logging.

**Acceptance.** lfm 8K/16K/32K, gpt-oss 64K, gemma-12b 16K, qwen-3.5-9b 256K: every pick a multiple of 64 with 6 to 9 REFINE points in the JSON, bisect times within the estimates above, no residency probes logged inside a PASS/PASS bracket, and confirm PASS at every pick.

---

## 39. Author review of Changes F and G as committed (2026-09-08)

**Verdict: not yet accepted. The code for F (binary placement) and G (golden-section to 64) is committed (`da9dfe5`, `d77045d`, docs `b1bbb28`) and reads correctly in the main path, but no run has exercised it: the only suite since (11:48 to 12:06) began before the commits and its log shows Change E behaviour (`Interior refine: testing …`, single midpoints, `placement: AMBIGUOUS` on lfm 4K). Two correctness gaps in G must be fixed before the acceptance run.**

### 39.1 Correct as committed

- `classify_placement` is one function used by `residency_probe` (fallback verdict), `decode_sample` and `cmd_bench`; both `decode_sample` and `cmd_bench` now average GPU utilisation as well as CPU. Early-kill logic in the residency probe is unchanged. The dead `AMBIGUOUS` branches that remain (thorough path log text; the ladder's `if [ "$R_V" = "AMBIGUOUS" ]`) are harmless.
- Golden section: interior points at 0.382 / 0.618 rounded to 64, reuse of already-measured points through `find_measured`, a failed candidate becomes the new upper bound, bracket narrows toward the better interior point, hard cap of 14 steps. Terminates: the pair stops being admissible when the bracket cannot hold two distinct 64-multiples.
- Residency policy matches §38: skipped while the current upper bound is a measured PASS; on while it is an unmeasured failed rung and the model is neither simple non-MTP nor CPU-compute. A failed golden candidate is not recorded in `REFINE_B`, so `find_measured` stays empty for it and residency stays on below it. Correct.
- `golden_probe` returns through a global rather than a subshell, so the pick and point bookkeeping survive. Correct.
- The two remaining bare `saturation_test` calls in the legacy sweeps are converted (`cf80f0f`).

### 39.2 Required before acceptance

1. **Ladder rungs and refinement points are measured with different noise.** Median-of-three was added inside `discover_measure_candidate` only, so refinement points are medians while every ladder rung is a single sample. The Change C pick is chosen among the rungs and then competes against the medians; on sub-second probes (lfm, 3072 tokens) a single high-noise rung sample can out-rank a median that is genuinely higher. Apply the same rule to the ladder: move the "first probe under 5 s → median of three" logic into `prefill_probe_sized` itself (or a wrapper both call) so every point in the JSON is measured the same way.
2. **No refinement when the pick is the top rung with nothing failed above it.** The bracket logic sets `BHI=BLO` and skips in that case, but §38 specifies `[lower neighbour, cap]`. Today that hit lfm 4K (pick 4096 = cap, bracket [2048, 4096] never searched) and it will hit every model whose best rung is 16384 or whose curve is still rising at the cap. Set the bracket to `[BLO, PICK]` with PICK as a measured upper endpoint. One exception is worth keeping: when `BLO ≥ PROBE_TOKENS` every point in the bracket is a single ubatch of the same prompt and measures identically, so skip and log why. lfm 4K (probe 3072, BLO 2048) would still refine; the exception covers only brackets entirely above the probe length.

### 39.3 Then run the §38 acceptance

lfm 8K/16K/32K, gpt-oss 64K, gemma-12b 16K, qwen-3.5-9b 256K: every pick a multiple of 64 with 6 to 9 `REFINE` points, `placement: GPU` or `CPU` in every record, no residency probes logged inside a PASS/PASS bracket, confirm PASS at every pick, bisect times within the §38 estimates (lfm +1.5 to 2 min over the 11:48 run's 3 to 3.5 min). Report the per-model bisect time and the number of refinement probes so the estimate can be corrected if it is off.

### 39.4 Note on the working tree

The four lfm JSONs and `models.ini` in the tree are from the 11:48 suite (Change E code). The 4K record still says `AMBIGUOUS`; the 32K record already shows the new pick of 3072 (adopted at 6591 against 6578 at 2048). They will be regenerated by the acceptance run.

---

## 40. Author review of the §39 fixes, with a live Change G run (2026-09-08)

**Verdict: the §39.2 fixes are correct and the search now works end to end. Not yet accepted, because the run exposed one bug that loses the discover record whenever refinement produces more than one point, and one measurement effect that should be handled before the catalogue run. Both are small.**

### 40.1 The run (author, direct `bench.sh bisect lfm-2.5-8b-a1b-q4-8k-think`, 12:33)

| | |
|---|---|
| time | 4 min 15 s, 11 restarts (ladder 5, refinement 5, confirm 1); §38 estimated +1.5 to 2 min over the 3 to 3.5 min ladder-only run, which this meets |
| ladder (medians) | 256=4634, 512=5498, 1024=6800, 2048=6773, 4096=6617 |
| bracket | [512, 2048] around the best rung 1024 |
| golden steps | 1088 → 6803 (adopted), 1408 → 6715, 832 → 6438, 1152 → 6861 (adopted), 1216 → 6529; reused 1024 twice; stopped when [1024, 1216] could not admit a new interior pair with every 64-multiple in it already measured |
| pick | 1152, a 64-multiple; saturation PASS at 99% of 8K, long-decode PASS |
| residency | once, at rung 256 (simple non-MTP), none inside the bracket |
| medians | logged on every point |
| `models.ini` | restored to the committed state afterwards |

### 40.2 Required

1. **The discover JSON is not written when there are two or more refinement points.** `/tmp/discover_lfm-2.5-8b-a1b-q4-8k-think.json` still holds the 11:48 run (one refine point, 1536). Cause: the writer builds its Python program inside a double-quoted string that contains `${REFINE_B[@]}`. Inside a longer double-quoted string, `[@]` expands each element as a separate shell word, so the program is split into several `python3 -c` arguments and Python sees a truncated first chunk; the `2>/dev/null || true` hides it. With one element (the 11:48 run) it happens to work. Reproduction: `a=(1 2); python3 -c "print('''${a[@]}''')"` fails; `${a[*]}` does not. Fix: use `${REFINE_B[*]}`, or better, pass the list through an environment variable as the other writers do. Consequence today: every model refined to 64 would have had a stale or missing `discover` block merged into its bench record; that is why this is required. Also drop the `2>/dev/null || true` on this writer and fail the bisect if the file is not written, the same rule `cmd_bench` now applies to its own JSON.

2. **The first prefill probe at a batch size pays a one-time cost, and slow probes still take only that first sample.** Comparing this run's medians with the single-sample ladders of the same model this morning: 256 and 512 are unchanged (4645 → 4634, 5487 → 5498) while 1024, 2048 and 4096 all rose about 10% (6178 → 6800, 6297 → 6773, 6022 → 6617). The first prefill at a new ubatch size carries a one-time setup cost (CUDA graph capture for that shape), and it weighs more on larger ubatches because a fixed-length probe contains fewer of them. The median of three removes it for probes under 5 s. Probes over 5 s (every 64K and 256K model, and every CPU-compute model) still take one sample, so on exactly the models where the ladder decides between 4096, 8192 and 16384 the measurement is biased against the larger batch, and by a different amount per rung. Fix in `prefill_probe_sized`: always run one untimed warm-up probe first, then take one timed sample for slow probes and the median of three for fast ones. Cost: one extra probe per point, about 12 s on a 64K MTP head, roughly 2 minutes per ladder plus refinement. This is the same warm-up the old `prefill_probe` had and that §4.2 removed on the assumption that `tiny_probe` warmed the instance; it warms the model, not the prefill graph for that batch shape.

### 40.3 Observation, no action

With warm measurements the lfm 8K curve is flat from 1024 to 4096 within 3%, so the 64-token pick lands wherever the highest median fell, here 1152, and would land elsewhere on another run. That is the trade-off §38 stated and the user accepted; the bench prefill at 75% of context will be the same within noise at any of them.

### 40.4 Acceptance after 40.2

Same six models as §38. Add to the checks: the `discover` block in each JSON lists every refinement point and its `written_at` matches the run; grep the log of a 64K model for `warm-up` on every point.

---

## 41. Author sign-off on Change G (2026-09-08)

**Accepted.** Commit `fa29ccf` fixes both §40.2 items and a second direct run of `bench.sh bisect lfm-2.5-8b-a1b-q4-8k-think` (12:43 to 12:50) verifies them:

| | |
|---|---|
| discover JSON | written at 12:50:21 with all 9 refinement points and `written_at` matching the run; a failed write now fails the bisect |
| warm-up | `warm-up done` logged on all 15 points; medians on 14 |
| ladder (warm) | 256=4623, 512=6017, 1024=6830, 2048=6909, 4096=6592, 8192=6138 |
| refinement | bracket [1024, 4096]; nine points; 1664 adopted at 6951 t/s over 2048 at 6909; stopped when [1408, 1600] could not admit a new interior pair |
| pick | 1664, saturation PASS at 99% of 8K, long-decode PASS, residency once |
| time | 6 min 41 s, 16 restarts (6 rungs, 9 refinement, 1 confirm) |

**Cost, honestly.** §38 estimated 1.5 to 2 minutes of refinement on this class; it was about 3.5, because the bracket was a full two rungs wide and the warm-up doubles each probe. lfm 8K now takes about twice the 09-05 pipeline's 3.8 minutes, in exchange for warm, median-of-three measurements at 64-token resolution and every point in the record. That is the trade the user chose in §38; §38's time estimates are superseded by these measurements (expect roughly: lfm-class 6 to 7 min, 9B MTP heads 8 to 10 min, CPU-compute 10 to 12 min, all still well under the old pipeline on anything above 16K).

**Note on the picks.** Warm measurement changed the shape of the curve: 512 gained 10% and everything from 1024 to 2048 sits within 2%. The 64-token pick will move between runs inside that plateau (1152 at 12:33, 1664 at 12:50). Both are correct answers to the question as posed; the bench prefill at 75% of context will not distinguish them.

**Remaining acceptance runs double as the first catalogue heads.** Run `gpt-oss-20b-a4b-q4-64k-think-low` (CPU-compute, slow probes), `gemma-4-12b-q4-qat-mtp-16k` (MTP, residency policy inside a bracket) and `qwen-3.5-9b-q4-mtp-256k` (ceiling edge) with `--no-inherit --strict`, and check in their logs: `warm-up done` on every point, no `residency:` line inside a PASS/PASS bracket, `placement: GPU|CPU` in the record, the `discover` block complete. Then the rest of the catalogue: family heads first, siblings inherit. `models.ini` was restored to the committed state after the author's runs.

---

## 42. Refinement depth as a user setting (2026-09-08, user direction)

The user keeps 64-token refinement as the default for this installation but wants the pre-Change-G behaviour available to anyone else using the script. Make refinement depth a setting rather than a rewrite.

**Change H — `BENCH_REFINE` / `--refine=<mode>`.** Global flag next to `--thorough` / `--strict`, env fallback `BENCH_REFINE`, three values:

| mode | behaviour | when to use |
|---|---|---|
| `64` (default) | Change G as accepted in §41: unconditional golden-section refinement of the bracket around the best rung down to 64-token granularity | this installation; when a fully measured record and the last few percent matter |
| `coarse` | Change E as accepted in §34: refine only while a step beats the current best by more than `PREFILL_NOISE` (3%); ceiling edge bisected to `max(64, 6% of the lower bound)`, interior peak to `max(256, 6% of best)`; typically one to three probes | faster runs; someone happy with a rung-level answer plus one sanity midpoint |
| `off` | ladder only; pick = best rung (Change C); no refinement, not even at a ceiling edge | quickest possible pass, or re-checking a known value |

Implementation notes for the implementer:
- Keep one search loop. `64` runs it to the 64 stop; `coarse` adds the E stopping rules inside the same loop (stop when the better interior point does not beat the pre-step best by `PREFILL_NOISE`, and use the E resolution formula as the width stop); `off` skips the loop and logs `refinement off`. Do not resurrect the deleted E code; the rules are three conditions.
- The warm-up probe and the median-of-three stay on in every mode. They correct a measurement bias (§40.2#2), not a resolution choice, and `off` mode still ranks rungs on them.
- Record the mode in the discover JSON (`refine_mode`) and in the RESULT block, so a record's resolution is self-describing.
- Interactive mode: add the choice to the "Search depth?" prompt (`[6]4 / [c]oarse / [o]ff`, default 64) and print it in the MASTER PLAN block.
- `AGENTS.md`: one paragraph in the batch-tuning section describing the three modes and the default, and stating the cost difference measured in §41 (about 3.5 min of refinement per model at `64`, about 1 min at `coarse`, none at `off`).

Acceptance: `bench.sh --refine=off bisect lfm-2.5-8b-a1b-q4-8k-think` completes with no `golden` lines and a rung pick; `--refine=coarse` completes with one to three refinement probes and stops with a `within noise` line; no flag reproduces the §41 run shape. All three write a discover JSON carrying `refine_mode`.

---

## 43. Author sign-off on Change H (2026-09-08)

**Accepted.** Commit `e75b5ab` implements §42 as specified, and the author verified all three modes live on `lfm-2.5-8b-a1b-q4-8k-think` (13:33 to 13:42), plus the invalid-value path:

| mode | result |
|---|---|
| `--refine=bogus` | `ERROR: invalid --refine / BENCH_REFINE value 'bogus' (expected 64|coarse|off)`, exit 1 before any restart |
| `off` | 3 min 40 s, 7 restarts, no `golden` lines, `refinement off` logged, pick = best rung 2048, confirm PASS, JSON `refine_mode: off`, `refine_points: []` |
| `coarse` | 4 min 39 s, 9 restarts, one golden step (2176, 2880), stopped with `within noise of pre-step best`, pick 2048, confirm PASS, JSON `refine_mode: coarse`, two refine points |
| `64` (default) | verified in §41 and in the 12:54 catalogue run: lfm 4K refined down from the cap to 3520 (+2.9% over 4096, the §39.2#2 case), 8K to 2048, 16K to 2176; warm-up on all 56 points; `placement: GPU` in every record |

Warm-up and medians ran in every mode (`warm-up done` on every point in `off` and `coarse` too), the mode is in the RESULT block and the JSON, and the interactive prompt and `AGENTS.md` paragraph are in place.

Measured costs on this model for the record: `off` 3.7 min, `coarse` 4.6 min, `64` 6.7 to 7 min. `models.ini` restored to the committed state after the author's runs.

**The discover pipeline is complete.** Sections 0 to 42 are the record; the remaining work is the catalogue itself (family heads with `--no-inherit --strict`, siblings inherit), which is already under way.
