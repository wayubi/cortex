# Plan: `bench.sh` discover mode — find practical settings with ~1/4 of the runs

**Status:** 2026-09-07 — designed, not implemented.
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
| MTP tuning (all MTP classes) | ≤ 8 decode runs | 0 | 8 to 12 min |

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
    prefill = prefill_probe_sized(B, ctx)   # see 4.2
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

Write one function, `prefill_probe_sized B CTX`, that reuses `prefill_probe`'s body (log-parsed `prompt eval time`, overflow-shrink retry, OOM check) with prompt size:

```
tokens = clamp( max(8192, 2 × B),  lower = 1024,  upper = floor(0.75 × ctx) )
chars  = tokens × CHARS_PER_TOK   (call measure_ratio once at rung 256; fallback 4.0)
```

At least two full ubatches are processed whenever ctx allows it. When `2 × B > 0.75 × ctx` (small-ctx models at their top rungs) log `under-exercised` next to the measurement; the smallest-within-tolerance rule (§4.3) resolves those ties toward the smaller batch, which is the right answer there anyway.

`prefill_probe`'s existing warm-up (one untimed request, then the timed one) must be preserved: the first request after a restart includes model load and would otherwise dominate.

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
    cliff check:
        if DEC_PICK.placement == CPU  or  DEC_PICK.tps < DEC_BASE.tps × DECODE_CLIFF (0.70):
            log "decode cliff at PICK (base X t/s @256, pick Y t/s, cpu Z%)" ; step down
        elif DEC_PICK.tps < DEC_BASE.tps × 0.90:
            log WARN (no CPU signature; keep PICK)     # noise band, never a failure
```

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

**Always include the ini's current `n_max` in the candidate set.** The batch ladder (§4) validated residency at whatever `n_max` was in the ini (ornith has 3, gemma has 4). Measuring that value guarantees at least one candidate passes the placement gate, so "every candidate rejected" cannot happen except through noise. If the ini value is 3, Phase 1 measures {2, 3, 4} and skips the 5-vs-3 branch unless 4 beats 3 by more than 5%.

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
4. **`inherit_json` must not spread unvalidated MTP values.** Copy `spec-draft-n-max` / `p-min` to siblings only when the parent JSON has `tuning_status == "ok"`. Otherwise leave the sibling's own values alone and log `MTP values NOT inherited (parent tuning_status=<x>)`. Batch and the rest of the JSON still inherit. Parent JSONs written before this change have no `tuning_status`; treat missing as `ok` for backward compatibility and log that assumption.

In discover mode the degeneracy false-failure that triggered the 16:45 misreport no longer exists (§6.1), and §6.2's "always include the ini's n_max" rule makes placement rejection of every candidate effectively impossible. Part 1 to 4 are still required so that the remaining failure modes (STALL, all samples SHORT) are recorded truthfully.

### 6.3 Optional diagnostic subcommand: `bench.sh mtpverify <model>`

Not part of the suite. Two restarts: one with `spec-type` removed, one with it set, same prompt, request-level `temperature: 0`, `seed: 42`, `max_tokens: 1024`. Print the index of the first differing token (or "identical"), both decode speeds, both degeneracy values. This lets a human confirm the §0 claim on any family without reading llama.cpp source. Small numerical drift between batched verification and single-token decode can produce a late divergence; identical first 200+ tokens is the expected result.

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

Work in this order; each step must pass its check before the next.

1. **§5 decode measurement + acceptance parse fix.** Check: `bench.sh mtp <one small MTP model, e.g. gemma-4-12b-q4-qat-mtp-16k>` with the *current* sweep prints a numeric `acc=` and `tokens=` on every line and no result has `finish_reason=length` unless the cap was hit.
2. **§4 `cmd_bisect_discover` behind a temporary env `BENCH_DISCOVER=1`.** Check on three models, one per class, counting `Restarting llama-cpp` lines in the log:
   - `lfm-2.5-8b-a1b-q4-4k-think` (small ctx, non-MTP): ≤ 7 restarts, saturation PASS, pick ≤ 4096.
   - `gemma-4-12b-q4-qat-mtp-16k` (dense MTP): ≤ 11 restarts, pick GPU-resident, saturation and long-decode PASS. Pick expected in the 512 to 2048 band (current value 1408).
   - `gpt-oss-20b-a4b-q4-64k-think-low` (CPU-compute): MODE=CPU detected at rung 256, no residency probes after rung 256, ≤ 9 restarts, pick expected near 2048 (current 2112).
   Then `ornith-1.5-9b-q4-mtp-64k-think` for a direct comparison with the 16:45 log: ≤ 11 restarts, ≤ 20 min, pick in the 512 to 2048 band, confirm PASS.
3. **§6 `cmd_mtp_discover` and §6.4 status plumbing.** Check on `gemma-4-12b-q4-qat-mtp-16k` (n_max is known to matter here: expected winner 4 or 5) and on `qwen-3.5-9b-q4-mtp-16k` (expected winner 2, sweep should stop after measuring 3). ≤ 8 runs each, no run rejected for degeneracy, summary shows `accept_rate` and `mean_draft_len`. Then force a failure (temporarily set `MIN_DECODE_TOKENS=999999` so every sample is SHORT) and run `bench.sh all <model>`: the ini must be back at its pre-run `n_max`/`p_min`, the JSON must show `tuning_status: failed` and `tuned_n_max: null`, the verdict table must show `mtp FAIL`, and with `--strict` the bench step must be `SKIPPED (mtp failed)`. Run one sibling with inherit on and confirm its `spec-draft-*` lines did not change.
4. **§7 flag wiring**, remove the temporary env, default = discover. Check: `bench.sh --thorough bisect <model>` reproduces the old log structure (`GPU SATURATION SWEEP`, `Golden:` lines).
5. **§4.5 JSON fields + §10 docs.**
6. **§8 sibling seeding** (optional).

General checks at every step: `bash -n tools/bench.sh` clean; a killed run (Ctrl-C during the ladder) leaves `models.ini` at its pre-run values (existing EXIT traps must still fire; the discover functions must use the same `trap ... EXIT` pattern as `cmd_bisect` and `cmd_mtp` today); `git diff llama-cpp/models.ini` after a successful run shows only the intended keys for the intended section.

---

## 12. Out of scope

- Changing `saturation_test`, `long_decode_check`, `residency_probe`, `fire_request`, `wait_served`, the OOM grep, or the ini editing helpers.
- Multi-stream / `parallel > 1` tuning. Everything here assumes `parallel = 1` as in `[*]`.
- Re-tuning models that already have a JSON. This plan changes how new runs are done; it does not invalidate existing values.
