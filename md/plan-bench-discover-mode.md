# Plan: `bench.sh` discover mode — find practical settings with ~1/4 of the runs

**Status:** 2026-09-07 — designed; step 0 (`mtpverify`) implemented and run, premise confirmed on re-analysis (§16); §6 un-halted; remaining steps not implemented.
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

No separate warm-up request: `tiny_probe` already ran on this server instance immediately before, so the model is loaded and the CUDA graphs are warm. (`prefill_probe`'s untimed warm-up request stays for `--thorough`, which calls the old function.)

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
    WIN_NMAX = best mean; if runner-up mean ≥ best × (1 - MTP_TIE): WIN_NMAX = the smaller of the two
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

General checks at every step: `bash -n tools/bench.sh` clean; a killed run (Ctrl-C during the ladder) leaves `models.ini` at its pre-run values (existing EXIT traps must still fire; the discover functions must use the same `trap ... EXIT` pattern as `cmd_bisect` and `cmd_mtp` today); `git diff llama-cpp/models.ini` after a successful run shows only the intended keys for the intended section.

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
