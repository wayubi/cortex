# `bench.sh` — Code Audit & Handoff Notes

**Scope:** full read-through of the benchmarking pipeline (`mtpcheck` → `bisect` → `mtp` → `bench`, plus the full-suite orchestrator and inheritance logic).
**Goal of this doc:** give a follow-up agent a prioritized, actionable list of bugs, dead code, and performance opportunities. Function names are used as anchors since the source has no stable line numbers.

---

## 0. How to use this doc

Items are grouped by severity, not file order. Each item names the function(s) involved, describes the problem, and suggests a fix. Start with **Section 1 (Critical)** — these can produce wrong benchmark data or crash mid-run. Sections 2–3 are correctness/reliability. Sections 4–6 are code-health and speed improvements that don't change behavior. Section 7 is a suggested execution order.

---

## 1. Critical bugs (fix first)

### 1.1 `bracketed_halve_down` can silently return batch `0` (or a stale value)
If the halving loop never finds a batch that passes `saturation_test` all the way down to 64 (i.e., even `batch=64` fails), the function's first `while` loop exits with `LO=0` and no batch has ever passed. The second (bisection) loop only runs `while [ $((HI - LO)) -gt 64 ]`, so with `LO=0` and `HI=64` it never executes, and `BHD_RESULT` is **never assigned in this call**. Since `BHD_RESULT` is a global, callers (`cmd_bisect`'s final-confirm fallback and the "RE-CONFIRM" step-down loop) will read whatever `BHD_RESULT` happened to hold from a *previous* call (or an unset/empty value), then do `VALIDATED=$BHD_RESULT; set_batch "$VALIDATED"` — potentially calling `set_batch ""` or `set_batch 0` and restarting the server in a broken state.

**Fix:** `bracketed_halve_down` should detect "no passing batch found at all" explicitly and return a distinct failure code (e.g. `return 3`), and callers must check for it rather than assuming `BHD_RESULT` is always valid after a `0`/`2` return.

### 1.2 `cpu_saturation_sweep`'s `test_rung` never signals OOM/STALL — the caller's check for it is dead
In `cpu_saturation_sweep`, `test_rung()` calls `prefill_probe`, which returns the string `"0"` on both OOM and STALL (it has no way to distinguish, see 1.3). `test_rung` then unconditionally does `echo "$TB $TPS" >> "$PTS"` and returns `"$TPS"` — it never emits the literal strings `"OOM"` or `"STALL"`.

Meanwhile, the doubling-ladder loop in `cpu_saturation_sweep` does:
```bash
if [ "$TPS" = "STALL" ]; then log "  STALL — aborting sweep" >&2; break; fi
if [ "$TPS" = "OOM" ]; then log "  OOM at batch=$B — can't use this level" >&2; break; fi
```
These checks can **never match**, because `test_rung` only ever returns numeric values (including `"0"` for failure). A real OOM or cold-load stall gets silently recorded as a legitimate `0 t/s` data point in `$PTS`, polluting the golden-section search (it can affect bracket reconstruction and the "best batch" selection) and the sweep never aborts on STALL as intended.

Contrast with `gpu_saturation_sweep`'s `test_rung`, which correctly distinguishes OOM vs STALL via `oom_count_since_mark` and echoes the literal strings. `cpu_saturation_sweep` diverged from this pattern.

**Fix:** make `cpu_saturation_sweep`'s `test_rung` classify failures the same way `gpu_saturation_sweep`'s does (check `oom_count_since_mark`, distinguish STALL, and only append to `$PTS` on genuine success). Better: extract one shared `test_rung`/ladder/golden-section implementation both sweeps call (see §5).

### 1.3 `prefill_probe` ignores its own `$1` (ctx) argument and uses a fixed prompt size regardless of context window
`prefill_probe` is called as `prefill_probe "$CTX"`, but its body never references `$1`. It always builds a fixed `PROBE_CHARS=32000` (~10K tokens) prompt. For any model with `ctx-size` smaller than that (a very plausible case — plenty of models run at 4K–8K ctx), the request will be rejected as "exceeds the available context." `prefill_probe` has no handling for that rejection message (unlike `saturation_test`, which explicitly checks for it) — it will simply fail to find a "prompt eval time" log line and return `"0"`, which (per 1.2) gets misclassified as a legitimate zero-throughput data point rather than a context-size configuration error.

**Fix:** size `PROBE_CHARS` off the passed-in `$1` (ctx), e.g. `min(fixed_target, ctx * 0.5 * chars_per_tok)`, and explicitly detect/handle the "exceeds context" rejection the same way `saturation_test` does.

### 1.4 Hardcoded `max_tokens` in several probes doesn't scale to small-context models
The following places hardcode a decode length that is not checked against the model's actual `ctx-size`:
- `long_decode_check`: `max_tokens=6000` (essay prompt) regardless of ctx.
- `decode_guarded_probe`: decode probe uses `max_tokens=4000` unconditionally.
- `residency_probe`: same, `max_tokens=4000`.
- `run_decode_test` (used by `cmd_mtp`'s n_max/p_min sweeps): `max_tokens=4000` on the essay prompt.

For any model configured with `ctx-size` below roughly 4–6K tokens (plus prompt), these requests can be rejected outright ("exceeds available context"), and the calling code has no special handling for that case — it will read as a generic failure (OOM-like, or a `0`/`?` result), producing misleading verdicts (e.g., "MTP tuning FAILED" or "not GPU-resident") that are actually just a request-sizing bug, not a real finding about the model.

`cmd_bench` already does this correctly — it computes `DECODE_MAX_TOKENS = min(4000, ctx - prompt_tokens)`. The same pattern should be applied everywhere else that fires a fixed-length decode request.

**Fix:** thread `ctx` into all four functions above and clamp `max_tokens` the same way `cmd_bench` does.

### 1.5 `detect_mtp` never scales `SERVED_GRACE` to the model's context size
Every other subcommand (`cmd_bisect`, `cmd_mtp`, `cmd_bench`) sets `SERVED_GRACE=$((60 + CTX / 65536 * 40))` before running, to give large-context models more time to cold-load before `wait_served` gives up and treats it as a stall. `detect_mtp` (used by `mtpcheck`) never reads `ctx-size` and never adjusts `SERVED_GRACE`, so it uses the bare default of 60s. For large-context models this risks a false "STALL during MTP detection" abort on a model that would have loaded fine given more time.

**Fix:** add `local CTX=$(read_ctx); SERVED_GRACE=$((60 + CTX / 65536 * 40))` near the top of `detect_mtp`, matching the other subcommands.

---

## 2. Correctness / reliability issues

### 2.1 `cmd_mtp`'s n_max/p_min winner selection is "last passing," not "best passing"
In both the n_max sweep and the p_min sweep, the winner variable is overwritten every time a candidate passes the OOM/placement/quality filter:
```bash
if [ "$OOM" -eq 0 ] && [ "$PLACEMENT" != "CPU" ] && [ "${QUALITY:-0}" -lt 2 ] 2>/dev/null; then
  WIN_NMAX=$N
fi
```
This means the final winner is simply the *last* value in the sweep order that satisfies the filter — not the fastest one. If `n_max=2` and `n_max=4` both pass but `n_max=3` is actually fastest, `n_max=3` is never selected purely because of iteration order, and if `n_max=4` is a later, slightly-slower-but-still-passing candidate, it wins over a faster earlier one.

**Fix (or confirm intent):** track `SPEED` for each passing candidate and select `argmax(SPEED)` among filter-passing candidates, rather than "last one seen." If the current behavior (bias toward the highest tested n_max) is intentional, add a comment explaining why, since it reads as a bug otherwise.

### 2.2 `saturation_test` failure-mode filter comparisons rely on `2>/dev/null` to mask bad numeric comparisons
Several places filter on `[ "${QUALITY:-0}" -lt 2 ]` where `$QUALITY` can be the string `"?"` if extraction failed. Bash's `-lt` on a non-integer prints an error to stderr and evaluates false — which happens to be safe here (`2>/dev/null` swallows the message and treats the candidate as failing), but it's an accidental correctness property, not a deliberate one. A more defensive numeric check (e.g. `[[ "$QUALITY" =~ ^[0-9]+$ ]] && (( QUALITY < 2 ))`) would make the intended behavior explicit and avoid depending on stderr-suppression.

### 2.3 `SAT_PREFILL_TPS` is computed but never consumed
`saturation_test` sets a global `SAT_PREFILL_TPS` with a comment saying "caller reads" it, but no caller (`ceiling_probe`, `cmd_bisect`, `bracketed_halve_down`) ever reads it after calling `saturation_test`. It's only used in `saturation_test`'s own log line. Either wire it into the bisect summary/JSON output (seems like the intent — capturing a real cold-load prefill number), or remove the dead variable and misleading comment.

### 2.4 `cmd_bench`'s `PROMPT_TOKENS` override parameter is unreachable from the CLI
`cmd_bench` supports `local PROMPT_TOKENS=${2:-0}`, defaulting to 75% of ctx if not given. However, every call site (`bench` subcommand dispatch, `run_full_suite`, the reset-parent pre-pass) invokes `cmd_bench` with no second argument and there's no CLI plumbing (`bench.sh bench <model> <prompt_tokens>`) to pass one through. This is a half-implemented feature — either expose it via the `bench` subcommand's argument parsing, or remove the parameter and hardcode the 75%-of-ctx default.

### 2.5 Misleading "inheriting from X" log line when a model is actually just being skipped as already-benched
In `maybe_inherit`, when `MODEL == PARENT` (the model is its own family head) and it already has a JSON file, the function returns `0` (handled/skip) **without calling `inherit_json`** — there's nothing to inherit, it's already the source of truth. But both call sites (`run_full_suite`'s main loop, and the `bench` subcommand's direct dispatch) print a generic `"$NAME: inheriting from $PARENT_NAME"` message in this case, even though `$NAME == $PARENT_NAME` and no inheritance actually occurred. Cosmetic but confusing for anyone reading the log/verdict table.

**Fix:** have `maybe_inherit` return a distinguishable status (or have the call sites re-derive "is this model its own parent" before choosing the log message) so "already benched, skipping" and "inheriting from sibling" print different text.

### 2.6 Suspicious token in `OMG_GREP`
```
OMG_GREP="cudaMalloc failed|failed to allocate compute pp buffers|terminate called after throwing|failed to create MTP context|exiting due to model loading error|CUDA error: out of memory|cuMemCreate|GGML_ASSERT|nbytes_shared|smpbo"
```
`smpbo` doesn't read like a real log-message fragment (the others are all clearly excerpted from actual llama.cpp/CUDA error strings). Worth double-checking this wasn't a typo or a leftover from a truncated/garbled paste — if it's not matching anything in practice it's harmless, but if it was meant to catch a real error signature, it's currently not doing so.

---

## 3. Fragility / environment-coupling notes (not bugs, but worth documenting or hardening)

- **Process-name matching.** `top -bn1 | grep llama-s` is used throughout (`decode_guarded_probe`, `residency_probe`, `run_decode_test`, `cmd_bench`) to find the server process's CPU%. This is a loose substring match; on a host with any other process named similarly it would silently pick the wrong row. Consider matching on a more specific pattern or PID.
- **`cmd_bench`'s model-file-size lookup** assumes a specific on-disk cache layout (`$ROOT/.local/llama-cpp_data/hub/models--<repo>/snapshots/*/*.gguf`). If the HF cache lives elsewhere (custom `HF_HOME`, symlinked volume, etc.), this silently returns an empty size rather than erroring.
- **`cmd_bench`'s RSS extraction** does `ps aux | grep llama-server | grep -v grep | grep -v models-preset` — the `-v models-preset` exclusion isn't explained anywhere. A one-line comment on why that pattern is excluded would save the next person a debugging session.
- **`inherit_json`'s config-rebuilding python block** duplicates the same `kv()`-based config-extraction logic that lives in `cmd_bench`'s `META` block. If the benchmark JSON schema changes, both places need to be updated in lockstep or inherited records will silently drift from freshly-benched ones.

---

## 4. Dead code / unused code

| Location | Issue |
|---|---|
| `prefill_probe` | Accepts a `$1` (ctx) parameter that is never referenced in the body (see 1.3 — this is both dead code *and* a bug). |
| `SAT_PREFILL_TPS` (in `saturation_test`) | Set and commented as "caller reads," but no caller reads it (see 2.3). |
| `cmd_bench`'s `PROMPT_TOKENS` / `$2` | Unreachable from any current call site (see 2.4). |
| `run_decode_test`'s poll loop | Hardcodes `seq 1 80` instead of using the existing `$POLL_MAX_SAMPLES` global (currently also `80`, so behavior matches today, but the duplication means the two will silently drift if one is tuned without the other). |

---

## 5. Duplication / DRY opportunities (code-health, indirectly reduces bug surface)

The bugs in §1.1–1.3 exist specifically *because* nearly-identical logic was implemented multiple times and diverged. Consolidating would both shrink the file and prevent this class of bug:

1. **Three separate "bisect toward a pass/fail boundary" implementations:** the ceiling-search+bisect logic inside `cmd_bisect`, `bracketed_halve_down`, and `residency_descend` all reimplement "halve/bisect until you find the boundary between pass and fail," each with its own edge-case handling (and, per §1.1, not all of them handle the "nothing ever passes" case). Consider extracting one generic `find_pass_fail_boundary(test_fn, lo, hi, granularity)` helper.
2. **`cpu_saturation_sweep` and `gpu_saturation_sweep` are ~90% identical** (doubling ladder with peak-detection/descent-counter, golden-section refinement to 64-granularity, `lookup_tps()` helper defined identically in both). The only real difference is the `test_rung` probe used (full saturation-style prefill vs. decode-guarded prefill) and the final confirmation step. Recommend extracting the shared ladder + golden-section logic into one function parameterized by a `test_rung` callback, and keep only the CPU-specific vs GPU-specific parts (decode gating, shortlist confirm) separate. This directly would have prevented the bug in §1.2.
3. **`set_batch` vs `set_batch_for`** — identical logic except one is hardcoded to `$MODEL` and the other takes an explicit section name. `set_batch` could simply call `set_batch_for "$MODEL" "$1"`.

---

## 6. Performance optimization opportunities (without sacrificing reliability)

These target wall-clock time, since the dominant cost in this pipeline is `docker compose restart` + cold-load wait (tens of seconds each), repeated many times per model.

1. **Adaptive/golden-section search for `cmd_mtp`'s n_max/p_min tuning.** Currently this is a full 5×5 grid = 10 restarts + 10 full 4000-token essay decodes, always testing every value regardless of what earlier results show. The batch-size search elsewhere already uses golden-section search to avoid this kind of exhaustive sweep — applying the same technique to n_max/p_min (test 3 points, refine toward whichever direction improves speed while staying within the OOM/placement/quality filter) could cut this phase from ~10 restarts to ~5–6 with no loss of solution quality.
2. **Fast-path / "trust but verify" when a known-good batch already exists.** `cmd_bisect` always starts its ceiling search from scratch (ctx probe → 2048 ladder → bisect → final confirm → 3× re-confirm → residency check → full sweep), even if `models.ini` already has a `batch-size` from a previous successful run. Consider: if a prior batch value exists, first do a cheap tiny-probe + single saturation-test at that exact value; if it still passes, skip straight to the "RE-CONFIRM" step (or even trust it outright with a `--fast` flag) instead of re-running the entire ceiling search and full sweep. This is the single biggest lever for reducing total re-bench time, especially for `--reset-parent` re-runs.
3. **Shorten timeouts on cheap, small-payload probes.** `tiny_probe` and `measure_ratio` both fall back to `adaptive_timeout`'s 600s floor even though they're `max_tokens=1` or `max_tokens=8` requests that should return in seconds. A stalled/hung request on these probes currently has to wait the full 600s before `curl`'s own timeout would even fire (though `wait_served`'s `SERVED_GRACE` window catches most hangs earlier via the proxy-line check — but once `wait_served` returns 0 because curl already exited, or once we're past `wait_served` and just doing `wait $PID`, a hang would ride out the full 600s). A dedicated shorter timeout (e.g. 60–90s) for these specific probes would fail faster without weakening the actual saturation/decode tests, which legitimately need the longer adaptive timeout.
4. **`bracketed_halve_down` calls full `saturation_test` at every halving step instead of gating with a cheap `tiny_probe` first**, unlike `ceiling_probe` elsewhere (tiny probe → saturation only if tiny probe passes). Since `bracketed_halve_down` is invoked when a batch is already suspected to be near/at an OOM boundary, most of its early halving iterations are probably OOM and would be caught faster/cheaper by a tiny probe than by running the full saturation flow. Adding the same tiny-probe gate here would save time on the (likely common) case where the first halved value still OOMs.
5. **Re-confirm cycle count (currently fixed at 3) could be made configurable**, e.g. via an environment variable, so iterative development/debugging runs don't have to pay for the full reliability sweep every time, while production runs keep the current (safer) default of 3.

None of the above should be done at the expense of the actual pass/fail correctness gates (saturation test, OOM detection, decode-gate) — they only target redundant or over-long *waiting*, not weakening what's being verified.

---

## 7. Minor / cosmetic

- Verdict-summary table header uses `%-9s` for the `mtpcheck` column but the row-builder loop uses a uniform `%-8s` for every column — slightly misaligns the `mtpcheck` column vs. its header.
- `fire_request`'s retry log line says `"restarting + retry $ATTEMPT"` where `$ATTEMPT` is actually the attempt number that just *failed* (about to retry as attempt N+1) — the wording could be clearer (e.g. "retrying as attempt N+1").
- Comment/behavior mismatch: nothing documents that `decode_guarded_probe`'s CPU-average loop intentionally skips the first sample as warm-up (`for idx in $(seq 1 ...)` starting at index 1) — it's the same pattern used (and documented) elsewhere (`run_decode_test`, `cmd_bench`), but undocumented here.

---

## 8. Suggested order of work for the next agent

1. Fix §1.1–1.5 (critical correctness bugs) — these can silently corrupt results or crash a run today.
2. Fix §2.1 and §2.4–2.5 (winner-selection logic, dead parameter, misleading logs) — cheap, high-value correctness/clarity fixes.
3. Do the §5 duplication refactor (unify the three bisection implementations, merge the two saturation sweeps) — this both resolves remaining risk from §1.2/1.1-style divergence and shrinks the codebase significantly.
4. Layer in the §6 performance improvements (adaptive mtp tuning search, fast-path for known-good batches, shorter probe timeouts) once the correctness/refactor work is done, so speed gains are measured against a known-correct baseline.
5. Sweep up §3/§4/§7 items (fragility notes, dead code, cosmetic fixes) opportunistically while touching the relevant functions above.