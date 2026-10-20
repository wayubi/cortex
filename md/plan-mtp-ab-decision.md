# Plan: Decide MTP On/Off by Measurement (MTP A/B)

**Date:** 2026-10-19
**Status:** Implemented 2026-10-19 (`tools/bench.sh`, `tools/gen_metrics.sh`, `AGENTS.md`). Offline-tested
(rename sandbox, decision and re-bisect logic). Not yet run on the GPU.

**Deviations from the plan as written:**
1. **Renames are decided per entry**, from that entry's own record (newest of `/tmp/mtp_status_<name>.json`
   and the bench JSON), not family-wide from the head. Inherited siblings carry the head's `mtp.ab`, so
   families still rename together, and `--no-inherit` runs stay correct. The rename pass covers the
   run's selected models plus their family heads.
2. **Re-bisect after `off` (added at the user's request).** `mtp_off_rebisect` re-runs the bisect without
   MTP only when the pick was memory-bound: an OOM/SPILL rung exists, and the pick is at or above the
   highest PASS rung below it. With the draft buffer gone, a larger batch may fit. A pick at the prefill
   peak is unaffected.
3. **New quick path `bench.sh mtpab <heads…>`** (interactive `[a]`). It runs the A/B on an
   already-tuned entry, using the ini's n_max/p_min, with no mtpcheck, bisect or re-tune. Then it runs
   the conditional re-bisect, `bench`, re-inheritance of the family (unless `--no-inherit`), and the
   rename. Use it for the existing MTP records instead of a full `--reset-parent` suite.
4. **Adaptive, with the tuner's samples reused (replaces the fixed 2+2 interleaved design).**
   - **MTP-on side:** the tuner's valid samples at the winning n_max/p_min are reused.
   - **Round 1:** one MTP-off sample. A gap beyond `MTP_AB_CLEAR=0.05` decides at once.
   - **Round 2:** taken only when the gap is closer than that, or a side has no valid sample. It tops
     each side up to `MTP_AB_SAMPLES=2` valid samples, then decides on the means.
   - **Why:** one sample varies by about 2–4% run to run, so only close results need a second sample.
   - **Records:** `mtp.ab` carries `rounds`, `on_source` (`tuner` / `measured` / `tuner+measured`),
     `clear`, and a `source` per sample.

## Context

The suite currently assumes that a model which **supports** MTP should **use** it. `detect_mtp` turns
MTP on whenever the draft engages, and keeps it unless the model is GPU-resident without MTP and
CPU-resident with it (`mtp_spills`). After that, `cmd_mtp` only compares MTP settings
(`n_max` / `p_min`) with each other. Nothing ever measures MTP against no MTP.

That assumption is false on this card. The first same-file comparison:

| entry | MTP | decode t/s | prefill t/s |
|---|---|---|---|
| `tiel-coder-35b-a3b-q4-mtp-64k` | on (n_max 2, tuned, acceptance 0.82) | 33.52 | 1277 |
| `tiel-coder-35b-a3b-q4-64k` (smoke test) | off | **36.08** | **1408** |

The comparison used the same GGUF, ctx, batch (5568) and llama.cpp build (`3737e41`), and the router
log confirms MTP was off. All the 35B-A3B MoE entries are CPU-resident: experts sit in system RAM.
When llama.cpp checks k+1 drafted tokens, each token can route to different experts, so one step reads
several times the expert weights over the RAM bus. That costs more than the accepted drafts save,
even at 80–97% acceptance. Dense models that fit in VRAM read their weights once for all k+1
tokens, so MTP gains there. Placement alone does not predict the result. Gemma-4-26B-A4B is
"CPU" but only lightly spilled, has a separate drafter GGUF, and probably still gains. **So the only
reliable rule is to measure both settings and keep the faster one.**

## Goal

For every MTP-capable model the suite benches, measure decode with the tuned MTP config and with
MTP off on the **same** entry (same weights, ctx and batch). Keep MTP only when it is measurably
faster. Record both numbers in the bench JSON. Siblings inherit the decision. The entry's name then follows
the decision: the `mtp` token is dropped or added automatically, family-wide (Step 6).

## Model classes this must handle (all of models.ini)

| class | examples | expected outcome |
|---|---|---|
| Dense, GPU-resident, built-in MTP head | `qwen-3.5-9b-q4-mtp-*`, `ornith-1.5-9b-q4-mtp-*`, `deepseek-v4-pro-qwen3.5-9b-*`, `saluki-27b-iq2-mtp-*` | MTP kept (modest gain) |
| Dense, GPU-resident, separate drafter GGUF | `gemma-4-12b-q4-qat-mtp-*` (`mtp-gemma-4-12B-it.gguf` auto-discovered) | likely kept |
| MoE, lightly spilled, separate drafter | `gemma-4-26b-a4b-q4-qat-mtp-*` | unknown; measured |
| MoE, CPU-resident, built-in MTP head | `qwen-3.6-35b-a3b-q4-mtp-*`, `nail-qwen3.6-*`, `tiel-coder-35b-a3b-q4-mtp-*`, `cyber-tiel-coder-35b-a3b-q4-mtp-*`, `tiel-coder-35b-a3b-apex-mtp-*` | likely **off** |
| MoE, CPU-resident, separate `mtp-*.gguf` head | `cyber-tiel-coder-35b-a3b-apex-mtp-*` | likely off (with MTP off the draft file is not loaded at all) |
| prism-llama-cpp router (Bonsai PQ2/PTQ1, MTP) | `bonsai-2-27b-*-mtp-*` | measured the same way (bench.sh is backend-agnostic) |
| Model rejected at mtpcheck (`mtp_spills`, no MTP layers, MTP context OOM) | `dirk-qwen3.8-27b-*` | **unchanged**: never reaches the A/B |
| Non-MTP models | glm, lfm, mellum, gpt-oss, minicpm, … | **unchanged**: `cmd_mtp` never runs |
| `-think` / `-coder` siblings | every family | inherit the head's decision (Step 4) |

## Design

The A/B runs as the **last phase of `cmd_mtp`**, after the tuner (discover or thorough) has applied its
winning `n_max`/`p_min`. Placing it there means:

- the MTP side is the **tuned** config, so this is a fair fight;
- it runs on every path that tunes MTP: the full suite, `reset_parent_full`, and `bench.sh mtp <model>`;
- `cmd_bench` then measures whichever setting won, so the published record is the winning config;
- a later full-suite run re-decides from scratch, because mtpcheck re-adds MTP and the A/B runs again.
  No persistent "never MTP" marker is needed, and a llama.cpp bump that changes the answer is
  picked up on the next run.

### Constants (add to the constants block near `MTP_TIE`)

```bash
MTP_AB_SAMPLES=2          # decode samples per side in the MTP A/B (interleaved on/off)
MTP_AB_TIE=0.02           # MTP kept only if its mean beats MTP-off by MORE than this fraction;
                          # a tie goes to MTP off (no draft buffer, simpler config)
```

### Decision rule

- `mean_on` and `mean_off` are the means of valid samples on each side.
- **A valid sample:**
  - `oom == 0`;
  - `tokens >= MIN_DECODE_TOKENS`;
  - if the placement baseline (`MTP_BASE`) is `GPU`, placement is not `CPU`.
- **`on`:** `mean_on > mean_off * (1 + MTP_AB_TIE)`. Keep the tuned MTP keys.
- **`off`:** `mean_on <= mean_off * (1 + MTP_AB_TIE)`. Delete `spec-type`, `spec-draft-n-max` and
  `spec-draft-p-min` from the section.
- **`inconclusive`:** either side has zero valid samples, or a STALL occurs. Keep the tuned MTP keys
  (status quo) and log a WARN. This is never a failure of `cmd_mtp`.

## Steps

### Step 1: `mtp_ab_decide` (new function, place it right after `cmd_mtp_discover`)

1. Read `NMAX=$(read_ini_val spec-draft-n-max)` and `PMIN=$(read_ini_val spec-draft-p-min)`. Snapshot
   the section with `read_section > /tmp/mtp_ab_on_${MODEL}.snap`. This is the MTP-on config.
2. Loop `i` from 1 to `MTP_AB_SAMPLES`. Each iteration measures ON then OFF. Interleaving cancels
   thermal and background drift.
   - **ON:**
     - `restore_section` the ON snapshot;
     - `restart >&2`;
     - `decode_sample "mtp-ab on #$i"`.
   - **OFF:**
     - `del_key spec-type`, `del_key spec-draft-n-max` and `del_key spec-draft-p-min` (all
       `>/dev/null`);
     - `restart >&2`;
     - `decode_sample "mtp-ab off #$i"`.
   - Parse each result with the same `IFS='|' read -r SPEED ACCEPT PLACEMENT AVGCPU QUALITY OOM TOKENS
     MEANLEN FINISH` line that `discover_measure` uses.
   - Append each sample to a new TSV `/tmp/mtp_ab_${MODEL}.tsv` as
     `side|tps|tokens|placement|oom|accept`.
   - `decode_sample` returning 2 (STALL) → `inconclusive` (go to 4).
3. Compute `mean_on` / `mean_off` from the TSV with a small `python3 -c` applying the validity rule.
   Use `MTP_BASE` exactly as `mtp_mean_for` does. Apply the decision rule.
4. **Leave the ini in the decided state:**
   - **`on` or `inconclusive`:** `restore_section` the ON snapshot.
   - **`off`:** `restore_section` the ON snapshot, then `del_key` the three `spec-*` keys. Restoring
     first keeps the batch and every other key byte-identical.
   - Remove the snapshot.
5. Set the globals:
   - `MTP_AB_DECISION` = `on|off|inconclusive`;
   - `MTP_AB_ON` / `MTP_AB_OFF` = the means, or empty;
   - `MTP_AB_SPEEDUP` = `mean_on/mean_off` (4 decimals), or empty.
6. Log one summary line:
   `MTP A/B: on=<x> t/s off=<y> t/s (×<speedup>) → MTP <ON|OFF|kept (inconclusive)>`.
   For `off`, also log `removed spec-type/spec-draft-n-max/spec-draft-p-min (MTP slower on this config)`.
7. **Safety:** install a local EXIT-trap guard so that Ctrl-C mid-A/B restores the ON snapshot. Mirror
   `restore_mtp` in `cmd_mtp_discover`: the ini must never be left with MTP half-removed. A completed
   `off` decision is not a failure and must not be restored.

**Acceptance:** `bash -n tools/bench.sh` passes. Running `bench.sh mtp tiel-coder-35b-a3b-q4-mtp-64k`
ends with `MTP A/B: … → MTP OFF`, and the section has no `spec-*` lines. Expectation:
on ≈ 33.5, off ≈ 36.

### Step 2: Call it from `cmd_mtp`, and record it in the status file

1. In `cmd_mtp`, after the tuner call (`cmd_mtp_thorough` or `cmd_mtp_discover`) returns 0, call
   `mtp_ab_decide`. If the tuner failed, do not run the A/B.
   - Both tuners run inside the `( cmd_mtp )` subshell. The discover tuner's EXIT trap fires when that
     subshell exits, i.e. **after** `mtp_ab_decide`.
   - The thorough tuner clears its trap and writes `ok` explicitly **before** returning.
   - Handle both orders as follows.
2. `mtp_write_status`: pass the A/B through env (`MTP_AB_DECISION`, `MTP_AB_ON`, `MTP_AB_OFF`,
   `MTP_AB_SPEEDUP`, `MTP_AB_TSV`). Add an `"ab"` object to `out` when `MTP_AB_DECISION` is non-empty:
   ```json
   "ab": {"decision": "off", "on_tps": 33.5, "off_tps": 36.1, "speedup": 0.928,
          "tie": 0.02, "samples": [{"side": "on", "tps": ..., "tokens": ..., "placement": ...,
          "oom": 0, "accept": ...}, ...]}
   ```
   With `"ab"` absent (`null`) when the A/B never ran.
3. At the end of `mtp_ab_decide`, also call `mtp_write_status ok "" "$NMAX" "$PMIN"`. That covers the
   thorough path, whose `ok` was written before the A/B ran. On the discover path the trap writes the
   same thing again at exit, which is harmless. `tuned_n_max` / `tuned_p_min` keep the tuned values
   even when the decision is `off`; they document what MTP was compared at.

**Acceptance:** after Step 1's run, `/tmp/mtp_status_tiel-coder-35b-a3b-q4-mtp-64k.json` has
`"status":"ok"` and `"ab":{"decision":"off",…}` with two `on` and two `off` samples.

### Step 3: `cmd_bench` merges the A/B and skips the stale guard on `off`

In the python block that builds `_mtp_tuning` (the "Merge the §6.4 MTP tuning status file" section):

1. Add `'ab': status.get('ab') if status else None` to `_mtp_tuning`.
2. **Stale guard:** when `(status.get('ab') or {}).get('decision') == 'off'`, skip the
   configured-differs / loaded-differs check entirely. Missing `spec-*` keys are the expected result
   there, not staleness. Without this, every `off` record would be relabelled `stale`.
3. Nothing else changes. `meta['mtp']['is_mtp']` is derived from the ini and will be `false` for an
   `off` model, so `acceptance` etc. come out `null`, as they should.

**Acceptance:** `bench.sh bench tiel-coder-35b-a3b-q4-mtp-64k` after Steps 1–2 writes a JSON with
`mtp.tuning_status: "ok"`, `mtp.ab.decision: "off"`, `mtp.is_mtp`/`drafter` reflecting no MTP, and decode
≈ 36 t/s. It must **not** print `tuning_status stale`.

### Step 4: Inheritance carries the decision to siblings (`inherit_json`)

Currently `inherit_json` copies `spec-type`/`n_max`/`p_min` from the parent's ini section when the
parent's `tuning_status == ok`. If the parent decided `off`, its section has no `spec-*` keys, so the
current code logs "incomplete" and leaves the child untouched. A child that still carries `spec-*`
from an earlier run would then keep MTP.

1. Read the parent JSON's `mtp.ab.decision` next to `PARENT_TUNING`. Use the same `python3 -c`
   pattern, printing `''` when absent.
2. **If `ab.decision == "off"`:**
   - remove `spec-type`, `spec-draft-n-max` and `spec-draft-p-min` from the **child** section;
   - log `Inherited parent MTP decision: off (MTP slower on <parent>) — spec-* removed`.
   - `del_key` acts on `$MODEL`, so add a `del_key_for SECTION KEY` helper next to `set_key_for`, with
     the same regex and section handling as `del_key`.
3. **Otherwise:** keep the existing branch unchanged. That covers `on`, `inconclusive`, and absent
   (legacy JSON with no A/B).

**Acceptance:** with the parent `tiel-coder-35b-a3b-q4-mtp-64k` decided `off`, a full-suite run over
its siblings (`-think`, `-think-coder`) leaves those sections without `spec-*`. Their JSONs carry
`mtp.ab.decision: "off"` (copied with the parent record).

### Step 5: Verdict summary shows the decision

In `run_full_suite` (and the log lines in `reset_parent_full`), after a successful `( cmd_mtp )`, read
`ab.decision` from `$(mtp_status_file)`. Set the mtp verdict to:
- `OK (MTP on)`
- `OK (MTP off)`
- `OK (A/B inconclusive)`

The verdict column is printed `%-8s`, so widen the mtp column if the text is truncated.

**Acceptance:** the VERDICT SUMMARY row for the Tiel-Coder head reads `OK (MTP off)`.

### Step 6: Automatic rename so the `-mtp` name token matches the decision

**Policy (user decision, 2026-10-19):** an entry's name must say whether MTP is on. When the A/B
decides, the suite renames the whole family automatically, in both directions:

- `off` and the name has an `mtp` token → drop it:
  `tiel-coder-35b-a3b-q4-mtp-64k` → `tiel-coder-35b-a3b-q4-64k`.
- `on` and the name has no `mtp` token → add it.
- `inconclusive` → no rename.

The user accepts that clients (Open WebUI, opencode) must then be updated to the new names. The
suite must make that easy by listing every rename (item 6 below).

**Naming rule.**
- **Name structure:** split the name on `-`.
  - Verified on all 178 sections in both `models.ini` files: every name has **exactly one** context
    segment matching `^\d+k$`.
  - When an `mtp` segment exists, it **always immediately precedes** that context segment
    (`…-q4-mtp-64k-think`).
- **Remove:** drop the segment that is exactly `mtp`. Never touch substrings such as `mtpx`.
- **Add:** insert the segment `mtp` immediately before the context segment.
- **No unique context segment:** if a name has zero or more than one context segment, do not
  rename. Log `WARN rename skipped: <name> has no unique ctx segment`.
- **Implementation:** one `python3` helper, `mtp_target_name NAME DECISION`, that prints the new name
  or nothing.

**New function `mtp_rename_family HEAD`** (place it after `inherit_json`):

1. **Read the decision** from `$MODELS_DIR/$HEAD.json` → `mtp.ab.decision`. If it is not `on`/`off`,
   return.
2. **Family members:** every section with the head's `hf` and effective `ctx-size`. Use the same
   matching as `family_of`; factor its python out to list all members, not just the head. For each
   member compute the target name, and skip members whose name already matches.
3. **Collision check, before changing anything:** if any target name already exists as a section in
   **either** `llama-cpp/models.ini` or `prism-llama-cpp/models.ini`, abort the whole family's rename
   and log `WARN rename skipped: <target> already exists`. Names must stay unique across both files,
   because the coordinator routes on them. Never overwrite another entry.
4. **Rewrite the ini in place** with `open(p,'r+')`, seek(0), write, truncate. **Never** write a new
   file and rename it over the old one: `prism-models.ini` is a single-file bind mount into openresty,
   and replacing the file leaves the container on the old copy (AGENTS.md "Single-file bind mounts
   pin the inode").
   - Replace each old name as a whole token, in headers **and** comment lines, with
     `(?<![\w.-])OLD(?![\w.-])`. The boundary stops `…-64k` from also matching `…-64k-think`.
   - Apply all replacements for the family in one read-modify-write.
5. **Bench JSONs:**
   - move `$MODELS_DIR/OLD.json` to `NEW.json` and set its `model` field to NEW;
   - in every JSON in `$MODELS_DIR`, rewrite `propagated_from` when it equals an old name;
   - leave `/tmp` status files alone; they are per-run scratch.
6. **Record the renames:**
   - append `timestamp<TAB>backend<TAB>old<TAB>new` to `logs/mtp_renames.tsv` (create it with a header
     if absent);
   - log one line per rename: `RENAMED old → new (MTP <on|off>)`;
   - list any tracked repo files that still mention an old name, using `git grep -l -w OLD` minus
     `*/models/*.json`, so the user can fix docs by hand.
7. **Restart the router.** The router reads `models.ini` only at start, so after renaming,
   `docker compose restart "$SERVICE"` once (the suite's `restart` helper). Log
   `router restarted: renamed models now served`.

**When it runs:** never in the middle of the per-model loop. `MODEL`, `MODEL_IDXS`/`model_name`, the
`/tmp/*_${MODEL}` files and `RESET_DONE` are all keyed by the current name.

- **`run_full_suite`:** after the VERDICT SUMMARY, call `mtp_rename_family` once for each distinct
  family head that ran `cmd_mtp` successfully this run. Then print a `=== RENAMES ===` block, either
  `old → new` lines or `none`, ending with the reminder
  `update client model IDs (Open WebUI, opencode) to the new names`.
- **`bench.sh mtp <models…>`:** after the loop, call `mtp_rename_family` for each model given that
  is a family head. The same rule applies, so standalone tuning also leaves names honest.
- **New subcommand `bench.sh rename-mtp <models…>`:**
  - applies `mtp_rename_family` to each named head from its existing JSON, without re-benching;
  - is for records benched before the rename step existed, and for re-trying after resolving a
    collision;
  - must be added to the usage text and the interactive menu help.
- **Opt-out:** global flag `--no-rename`, or env `BENCH_RENAME=0`. With either, print the RENAMES
  block as `would rename old → new` and change nothing. Default is rename on.

**Acceptance:**
- **Rename off:** after the smoke-test entry is deleted (Step 9.1), a full-suite run on
  `tiel-coder-35b-a3b-q4-mtp-64k` and its siblings ends with:
  - sections `tiel-coder-35b-a3b-q4-64k`, `-64k-think` and `-64k-think-coder`, with no `spec-*` keys;
  - JSONs moved to the new names, the siblings' `propagated_from` pointing at the new head name, and
    a row per entry in `logs/mtp_renames.tsv`;
  - `GET /v1/models` on `:8080` listing the new names.
- **Collision:** run with the smoke-test entry still present and the rename is skipped with the
  collision WARN; nothing changes.
- **No mtp token on a long name:** a model decided `on` whose name lacks `mtp`, e.g. a fixture
  section `foo-q4-64k-think` pointing at an MTP GGUF, is renamed to `foo-q4-mtp-64k-think`.
- **Dry run:** `--no-rename` prints `would rename …` and leaves the files byte-identical (`git diff`
  is empty).

### Step 7: `gen_metrics.sh`: one new column

In `bench_row`, add `'mtp_ab'`:
- `"off ×0.93"`, `"on ×1.09"` or `"inconc."` from `mtp.ab` (`speedup` = on/off), `None` when absent;
- `—` for non-MTP models and legacy records.

Add the column to the header and the column legend. Wording: *MTP A/B: decision and MTP-on ÷ MTP-off
decode ratio, measured on the same entry*. The `drafter` column already shows `none` for an `off`
model, because it is derived from the ini.

**Acceptance:** `tools/gen_metrics.sh` regenerates `full-metrics.md`, and the Tiel-Coder rows show
`off ×0.93` (or similar).

### Step 8: Documentation (`AGENTS.md`)

1. **"Tuning MTP speculative decoding" → "Benchmark method":** add a step 4, *MTP A/B*. Give the
   rule, the constants and the reason (CPU-resident MoE: checking drafts reads more experts over the
   RAM bus; first evidence 33.5 vs 36.1 t/s on Tiel-Coder Q4 64K). State that a model *supporting* MTP
   does not imply *using* it.
2. **"Result recording":** document `mtp.ab` and that `tuning_status: ok` with `ab.decision: off`
   means "tuned, then measured slower than no MTP".
3. **"Placement gate at mtpcheck":** add one sentence. `mtp_spills` stays as the early cheap
   rejection; the A/B covers the case it cannot see (CPU either way).
4. **New subsection "Naming: the `-mtp` token follows the A/B":**
   - the rename rule;
   - that renames are automatic and family-wide;
   - `logs/mtp_renames.tsv`;
   - `--no-rename` and `rename-mtp`;
   - that client model IDs must then be updated.

### Step 9: Clean-up and re-bench (operational, after Steps 1–8 are merged)

1. Delete the hand-made smoke-test entry `[tiel-coder-35b-a3b-q4-64k]` and its two comment lines from
   `llama-cpp/models.ini`. Delete `llama-cpp/models/tiel-coder-35b-a3b-q4-64k.json`. The A/B replaces
   it.
   - **Do this before any re-bench.** That name is exactly the rename target of
     `tiel-coder-35b-a3b-q4-mtp-64k`, so leaving it in place triggers the collision guard and the
     head keeps its `-mtp` name.
2. Re-run the full suite with `--reset-parent` on every MTP family head, so each record gets an A/B.
   Start with these, in this order:
   1. `tiel-coder-35b-a3b-q4-mtp-64k` (known answer: off);
   2. `qwen-3.5-9b-q4-mtp-16k` (expected: on);
   3. the remaining 35B-A3B heads;
   4. `gemma-4-26b-a4b-*`;
   5. Bonsai (prism backend).

## Cost

Four extra decode samples per family head, each with a restart. A rename pass costs one router
restart per run, not per model. On a 30–55 t/s model a natural-stop
sample of ≥1500 tokens is about 0.5–1.5 min plus load, so the A/B adds roughly **5–8 min per head**.
Siblings inherit the decision and cost nothing.

## Out of scope

- **Re-tuning batch for the MTP-off config.** The batch was picked with the MTP draft buffer present.
  Without it memory only goes down, so the pick stays valid, but the prefill optimum may shift
  slightly. A later `bisect` can refine it; do not add it here.
- **Changing `detect_mtp`'s `mtp_spills` gate.** Keep it as the cheap early rejection.
- **Predicting the outcome from placement or architecture.** The evidence says measure; do not add
  heuristics that skip the A/B.
- **`cmd_mtpverify`.** It is unrelated: it checks output equivalence, not speed.
- **Updating client configs (Open WebUI, opencode).** These live outside this repo. The suite only
  lists the renames (`logs/mtp_renames.tsv` and the RENAMES block); the user updates the clients.
- **Aliases for old names.** No compatibility aliases, either router-side or in openresty. A renamed
  model is only served under its new name.
- **Request-level MTP toggles.** The A/B toggles `spec-type` in the ini and restarts, exactly as the
  real served config would be.
