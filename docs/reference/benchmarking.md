# Benchmarking: method and evidence

How `tools/bench.sh` tunes and records llama.cpp router entries, and the measurements behind each
choice. The rules an agent must not break are in `AGENTS.md` ("Benchmarking"); usage is in
`bench.sh`'s header and the README. This file explains why the pipeline works the way it does.

## Backends and one run

`bench.sh` benches a llama.cpp router: `llama-cpp`, `prism-llama-cpp`, `raon-llama-cpp` or
`inkling-llama-cpp` (`BENCH_BACKENDS`). Selecting one sets `INI` (`<backend>/models.ini`),
`MODELS_DIR` (`<backend>/models/`), `SERVICE` (the compose service `restart()` restarts) and
`DOCKER_LOG` (the container whose log the OOM and served greps read). A subcommand picks the backend
from the model names it is given (one backend per run); the interactive menu asks first;
`--backend=<name>` / `BENCH_BACKEND` forces it. `ollama` and `nllb` are stubs ("no benchmark support
yet").

- Requests go to openresty `:8080`, which routes the model to its router and unloads the others, so a
  bench never shares the GPU with another backend.
- Bench JSONs record `backend` and the router's `llama-server --version` as `build_info`.
- The router reads `models.ini` only at start, so on exit `bench.sh` restarts `SERVICE` if the ini
  changed since its last restart (e.g. `inherit_json` removing a sibling's spec-* keys). Without it
  the siblings kept serving MTP after the A/B decided off.
- **One run at a time, on any backend:** after the backend is chosen `bench.sh` takes `flock` on
  `/tmp/cortex-bench.lock` (the file names the holder); a second run exits with an error, without its
  EXIT-trap router restart. Two runs fight even on different routers: each restarts its router and
  edits its ini, and openresty unloads one's model for the other's. On 2026-10-22 that killed both a
  background fetch and an interactive suite mid-download.
- Full suite order per family head: `mtpcheck` → `bisect` → `mtp` → `bench`.

## Families

A family is every entry sharing the same `hf`, the same `ctx-size` and the same value for every key
that can change memory or speed. Only `FAMILY_FREE` keys may differ (`family_scan`): sampling,
reasoning and chat-template keys, plus the tuning outputs inheritance copies from the head
(`batch-size`/`ubatch-size`, `spec-type`/`spec-draft-n-max`/`spec-draft-p-min`). So `-coder`, `-think`
and `-think-coder` siblings of one weights/context pair form one family. A `-vision` entry
(`no-mmproj = false` loads the projector, ~0.9 GB on the 35B) is its own head, as is an entry that
differs on `override-tensor`, cache types, draft KV types or any key not in the list. Values fall back
to `[*]`.

`bench.sh` benches the head (the family's first section in models.ini) and copies its record to the
siblings in seconds, rebuilding each sibling's `config` block from its own section. Cost scales with
distinct weight-and-context pairs, not with the number of entries. Sampling, the reasoning toggle and
the chat template do not change prefill or decode rate, so the head's measurements transfer.

**Caveat near the memory ceiling:** `reasoning = on` has sustained a slightly larger batch than
`reasoning = off` on the same GGUF and ctx (Qwen3.5-9B-MTP @ 16K: 2048 vs 1984). When a pick sits
within a factor of two of the spill ceiling, bench the think sibling separately with `--no-inherit`.
A head whose bench fails feeds nothing to its siblings: they are reported `SKIPPED (parent bench
failed)`.

## Batch tuning (`bisect`, discover mode)

**Batch is a prefill knob.** For single-stream serving (`parallel = 1`), decode throughput does not
depend on batch unless the batch pushes memory (the MTP draft buffer, KV) off the GPU. So batch is
picked on the prefill curve and guarded by a residency check, never ranked by decode t/s. llama.cpp
`-fit on` (`ngl = -1`) packs weights into VRAM with ~zero headroom, and the prefill curve is flat from
~512 to a few thousand (on the 35B Qwen every rung 512→4096 scored within 3%), so the ceiling is real
but coarse.

Procedure (`cmd_bisect_discover`):

1. **Ladder.** `CAP = min(ctx-size, 16384)`. Powers of two from 256 up to CAP (if 256 fails at load,
   the ladder restarts at 128, then 64, and that rung takes 256's role), stopping once two consecutive
   rungs measure below the running best prefill × `PREFILL_TOL`.
   - **Simple non-MTP models** (no `spec-type=draft-mtp`, no `override-tensor`): residency runs on the
     ladder only at rung 256, and the decode baseline and pick decode-sample are skipped. Residency
     **is** re-run once at the pick: `-fit` also budgets the compute buffer, and past its 1 GiB
     free-memory target it moves a whole layer to CPU with no OOM (dirk-qwen3.8-27b @ 90112: GPU at
     256, 65/66 layers at the pick 512, ~600% CPU, decode −18%).
2. **Each rung, on one server instance:** `tiny_probe` (OOM at load or first decode) →
   `residency_probe` (binary GPU/CPU verdict via `classify_placement`: GPU if CPU < 150 and GPU > 25%,
   else decided on GPU alone, else CPU; a `CPU` at rung 256 marks the model CPU-compute and residency
   is skipped thereafter) → `prefill_probe_sized`, the same ~`min(0.75 × ctx, 16384)`-token prompt on
   every rung. A rung that OOMs or spills ends the ladder.
3. **Pick** the best-measured PASS point (`PREFILL_TOL` 0; `0.03` prefers a smaller batch within 3%
   for draft-buffer headroom). Then golden-section refinement of prefill inside the bracket around
   it, candidates rounded to 64, until the bracket is ≤ 64 wide (≤ ~14 steps). At a ceiling edge the
   upper bound is the failed rung; when the pick is the top rung the search refines downward, unless
   the whole bracket is a single ubatch (measures identically). Residency is skipped inside a
   PASS/PASS bracket (memory is monotonic in batch). Every sized-prefill probe runs an untimed warm-up,
   and a probe finishing in < 5 s is re-sampled to the median of three, so every point in the JSON is
   measured the same way. Refinement points are recorded with `status: REFINE`.
4. **Confirm at the pick, one restart:** pick residency (simple non-MTP GPU models) →
   `saturation_test` (~99% ctx) → `long_decode_check` → on MTP GPU models a `decode_sample` against the
   batch-256 baseline (re-sampled once below `DECODE_CLIFF`, 0.70×; a CPU placement signature steps
   down; 0.90–0.70 is a WARN). At most two step-downs to the next lower measured PASS point, then the
   model fails with the ini restored.
5. The ini line carries the result: `ubatch-size = N ; discover pick (coarse ceiling M PASS)`. The
   coarse ceiling is informational only; nothing downstream reads it, and it does not mean `N` can be
   raised.

**Settings:**
- `--refine=64|coarse|off` (`BENCH_REFINE`): `64` (default) refines fully (~3.5 min per model on
  lfm-class); `coarse` refines only while a step beats the pre-step best by `PREFILL_NOISE` (one to
  three probes, ~1 min); `off` takes the best rung. Warm-up and median-of-three stay on in every mode.
  Each discover JSON records `refine_mode`.
- `--thorough` (`BENCH_THOROUGH=1`): the older exhaustive search (`cmd_bisect_thorough`: golden-section
  prefill sweep, 64-token ceiling bisect, top-5 shortlist decode gate, saturation-confirm loop).
- **Batch-only** (`bench.sh batch <models…>`, or `bisect --no-confirm`): ladder, refinement and the
  cheap residency checks, then the pick is applied; no decode baseline, saturation, long-decode or
  cliff check. The discover JSON records `confirm: skipped`. A prefill pick, not full-context
  validation. Discover-only (`--thorough` and `bisect <model> <batch>` reject it).

## Safety gates (evidence)

- **OOM signatures.** OOM markers appear seconds after a request: `cudaMalloc failed`, `failed to
  allocate compute pp buffers`, `terminate called after throwing`, child `exited with status 1`. MTP
  models can OOM **at load** instead (`failed to create MTP context`, `exiting due to model loading
  error`): the draft context builds its compute buffers eagerly. A decode-time signature appears only
  in sustained generation: `CUDA error: out of memory ... cuMemCreate(...)` from `ggml_cuda_pool_vmm`
  (the flash-attn workspace growing the VMM pool). A failed child triggers the router's 10 s
  force-kill, then `model ... failed to load` (HTTP 500), itself an OOM signal. The first request after
  a restart can take > 20 s (fit + MTP context + warm-up) and time out (`http=000`) while the model
  loads fine: verify with a follow-up request.
- **Silent spills.** A spill shows decode dropping 3–4× with CPU at 270–1600% (Gemma 12B Q6: 59.8 t/s
  with the draft on GPU, 36 t/s with it on CPU). A 600-token decode with 50 s polling is not enough:
  models show ~100% CPU for the first 50 s, then spike to 1300%+. Use 4000+ tokens and 160 s polling.
  On CPU-compute models every batch is CPU-resident, so only the prefill curve matters; it peaks low
  (~1.5–2K).
- **Saturation at ~99% ctx.** The tiny probe only proves the decode graph fits at near-empty context.
  The true peak is near full context (KV-compaction temp buffers, hybrid/SSM state re-derivation), and
  the prefill graph is far larger. On hybrid/SSM models the server truncates at the ceiling
  (`truncated = 1`, `finish_reason = length`) rather than shifting KV; full context is still reached.
- **Long decode.** Repetitive saturation filler gets high draft acceptance and can mask a decode-time
  OOM: `qwen-3.5-9b-q4-mtp-16k-think` passed saturation at batch 2048 and OOM'd at `n_decoded ≈ 5.4K`
  on real text.
- **ini restore.** Both tuners snapshot the section and restore it on a non-zero exit (Ctrl-C included).

Observed while tuning:
- Lowering `ctx-size` does not reliably free batch headroom: `-fit` repacks more weights into the
  freed VRAM.
- If even tiny batches OOM, free VRAM: `override-tensor = exps=CPU` (experts to system RAM).
- The dense Gemma 4 12B has a small per-unit compute graph, so its batch ceiling is far higher than
  the MoE models' (~8.6K vs 576).

## MTP speculative decoding

Applies to entries with `spec-type = draft-mtp`. **`spec-draft-n-max` and `spec-draft-p-min` are
speed-only.** llama.cpp's `common_sampler_sample_and_accept_n` samples every position from the target
and keeps a draft token only when it equals the target's own sample, so MTP never emits a token the
target would not. Token differences between MTP on and off are near-tie flips under ~0.1-nat kernel
logit noise, the same class as changing `batch-size`. `bench.sh mtpverify <model>` checks this per
model: MTP off then on at `temperature 0`, `seed 42`, with `logprobs`; PASS when the on-run's token at
the first divergence is in the off-run's top-10 with `gap_off < MTP_TIE_NATS` (0.25).

- `spec-draft-n-max`: draft tokens per step (default 2). Raises the draft-context buffer
  (`n_max × batch`), so **a batch tuned at n_max 2 may not fit at 3+**: re-check placement at the
  same batch after any n_max change. On a 9B MTP model at 128k/256k, n_max 2 at the full batch decoded
  as fast as or faster than n_max 3 at its lower ceiling.
- `spec-draft-p-min`: stop drafting below this probability; a yield lever, not a quality gate.
- **Draft VRAM:** `-fit` never budgets the draft (`failed to measure the memory of the extra model,
  fitting without it`), so on a model whose weights nearly fill VRAM the draft lands on CPU even when
  the main model fits (Gemma 12B Q6 @ 16K: batch 3584 survived OOM with the draft on CPU, ~730% CPU,
  35 t/s; batch 1088 kept it on GPU, ~81% CPU, 60 t/s; 1152+ spilled again). Shrink it with
  `spec-draft-type-k/v = q4_0` (default f16) and a smaller batch. `spec-draft-ngl` forces the draft
  onto the GPU by pushing main-model layers to CPU instead, which is worse.
- **Gemma 4 QAT** ships its drafter as a separate GGUF (`mtp-gemma-4-12B-it.gguf`), auto-discovered
  from `-hf` by builds that know the `gemma4-assistant` arch. `failed to initialize the context:
  Gemma4Assistant requires ctx_other to be set` at load is benign.

**mtpcheck placement gate (`detect_mtp`).** After the draft engages, `residency_probe` at batch 256 with
MTP on; if `CPU`, again with MTP off; if the model is GPU without MTP, MTP is rejected: spec-* deleted,
status `not_mtp`, reason `mtp_spills`, and the model is benched without MTP (dirk-qwen3.8-27b IQ2_S @
64K: 20.9 t/s GPU without MTP, ~13 t/s CPU with it, even with `q4_0` draft KV). A model CPU-resident
either way keeps MTP here; the A/B decides.

**Tuner (`cmd_mtp_discover`, ~6–8 decode runs).** The placement gate is the constraint: a config whose
`decode_sample` shows `CPU` or `oom > 0` does not fit at this batch.
1. n_max ladder at p_min 0.7: `{2, 4, ini's n_max}` (the ini value passed residency in the batch
   ladder), extended to untested neighbours of the best within [2,6]. Best and runner-up are measured
   twice and ranked on the mean; ties within `MTP_TIE` (2%) go to the smaller n_max.
2. p_min at the winner: `{0.5, 0.9, ini's p_min}` against the 0.7 reference; 0.7 kept within tie.
3. Failure is only STALL, every candidate rejected, or every sample SHORT; the ini's values are restored.
`--thorough` runs the older fixed sweep (`cmd_mtp_thorough`: n_max {2..5}, p_min {0.5..0.9}) with the
same natural-stop measurement.

**Early A/B (`mtp_early_ab`, full suite, before the bisect).** One decode with MTP at n_max 2 / p_min
0.7 and one with MTP off, at the section's batch (256 if none). If MTP is slower by more than
`MTP_AB_CLEAR` (5%), MTP is dropped there (spec-* removed, tuning skipped, `tuning_status: skipped`,
`ab.decision: off`, `ab.on_source: early`). Reason: on a CPU-resident MoE the tuning costs 15–25 min
only to be thrown away, and n_max 2 is the cheapest draft (reasoning, not measured). Costs ~4–5 min;
`--no-early-ab` / `BENCH_EARLY_AB=0` skips it.

**Final A/B (`mtp_ab_decide`).** Supporting MTP does not mean gaining from it: on a CPU-resident MoE the
verify pass routes each drafted token to its own experts, reading several times the expert weights
over the RAM bus (`tiel-coder-35b-a3b-q4` @ 64K: 33.5 t/s with MTP, 36.1 without, at 0.82 acceptance).
- The MTP-on side reuses the tuner's valid samples at the winning config; `mtpab` measures it.
- One MTP-off sample first; a gap beyond `MTP_AB_CLEAR` (5%) decides at once (one sample varies ~2–4%:
  30.3 vs 30.5, 28.9 vs 28.0, 24.1 vs 25.0 t/s). Otherwise up to `MTP_AB_SAMPLES` (2) per side, on means.
- **MTP is kept only if it beats off by more than `MTP_AB_TIE` (2%)**; a tie goes to off, which deletes
  the spec-* keys. A side with no valid sample, or a STALL, keeps the tuned config (`inconclusive`).
- `-mtp` in a name marks an MTP-capable GGUF, not MTP on; names never change.
- After `off` the batch stays valid (it was validated with the draft present). The bisect re-runs
  without MTP only when the pick was memory-bound (`mtp_off_rebisect_needed`).
- Cost ~2.5–3 min per head on a clear result, ~5–6 min close. `bench.sh mtpab <heads…>` runs only the
  A/B on a tuned entry, then the conditional re-bisect, `bench` and re-inheritance.

## Measuring decode speed (`decode_sample`)

Speed samples never force tokens past EOS. `decode_sample` uses a prompt that reliably produces ≥ 1500
tokens naturally and needs `MIN_DECODE_TOKENS` (512) to be valid (retried once with a longer prompt,
else `SHORT`, treated as missing). Forcing past EOS makes a model loop, and looped text gets
near-perfect draft acceptance, so a config degrading to repetition looked fastest. `ignore_eos` is used
only for memory-pressure tests (`saturation_test`, `long_decode_check`). Degeneracy (8-gram ratio,
heading lines stripped) is diagnostic only: `WARN` above 0.15, never a gate. Draft acceptance is a
rough signal, never a gate.

## Max context (`bench.sh ctxmax <model>`)

Finds the largest `ctx-size` at which an entry stays GPU-resident at its own batch and MTP settings. It
copies the section to `[<src>-ctxmax]` (the source is never modified) and bisects the copy's
`ctx-size` in 1024-token steps between the source's ctx (which must itself be GPU) and the trained
context (`<arch>.context_length` from the GGUF header, tried first). Each step: `tiny_probe` → a check
that the child logged `n_ctx_slot` equal to the request (a silent clamp fails) → `residency_probe`. No
saturation or long-decode: the full suite validates the new entry. On success the copy is renamed by
its `-NNk` suffix (`saluki-27b-iq2-mtp-64k` → `-112k`), `ctx-size` carries `; ctxmax pick`, and it is a
new family head needing the full suite. Batch is not re-tuned. On failure the copy is removed.

## Vision entries (`bench.sh vision <models…>`)

Adds `[<entry>-vision]` when the entry's `hf` repo ships an `mmproj-*.gguf` (else `no vision`). The
section is copied with `no-mmproj = false` (the `[*]` default is `true`), the projector fetched, and one
real image request (a solid red PNG) sent; the entry is kept only if it is answered. A load OOM at the
source's batch is retried once at 256. `batch-size`, `ubatch-size`, `spec-draft-n-max` and
`spec-draft-p-min` are the source's, tuned without the projector, and carry `; from [<src>], untuned
with the projector — run bench.sh all <entry>` until tuned. A `-vision` entry is its own family head.

## Result recording

Records are `<backend>/models/<model>.json`; `tools/gen_metrics.sh` builds `full-metrics.md` from all
backends. The tuners write `/tmp/mtp_status_<model>.json` and `/tmp/discover_<model>.json`, which
`cmd_bench` merges under `mtp` and `discover`. Both carry `written_at` (copied to
`mtp.tuning_written_at`), so a stale file merged into a later bench is visible.

- `mtp.tuning_status`: `ok` / `failed` / `stall` / `not_mtp` / `not_run` / `skipped`; `tuned_n_max` /
  `tuned_p_min` are null unless `ok`. `n_max_loaded` / `p_min_loaded` mean only what the server loaded.
  MTP values are not inherited from a parent with `not_run` or no `tuning_status`.
- `mtp.ab`: `decision` (`on` / `off` / `inconclusive`), `on_tps`, `off_tps`, `speedup`, `tie`, `clear`,
  `rounds`, `on_source` (`tuner` / `measured` / `tuner+measured` / `early`) and the raw `samples`.
  `full-metrics.md` shows it as e.g. `off ×0.93`. `tuning_status: ok` with `decision: off` means
  tuned, then measured slower than no MTP; a sibling of such a parent has its spec-* keys removed.
- `discover.confirm`: `passed` (normal bisect) or `skipped` (batch-only); a bench merged from a
  skipped discover carries it.
- A failed `cmd_mtp` still lets `cmd_bench` run (recording `failed`); `--strict` skips the bench and
  marks `SKIPPED (mtp failed)`, for publishable records.
- A bench whose decode comes back `CPU` for a model the bisect classified `GPU` gets `WARN (placement
  CPU at bench)`: the pick did not hold at the bench's long context.

CPU and GPU polling method behind the placement verdicts: `CPU_POLLING.md`.
