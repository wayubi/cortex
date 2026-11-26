# llama.cpp: version gap and untried performance knobs

**Date:** 2026-11-22
**Status:** Research note (2026-11-22). Update 2026-11-26: the `llama-cpp` router was moved from
`b10622` to `b12785`; see `md/llama-cpp-b12785-quick-ab.md` for the quick A/B, smoke test and
which other routers the new build can replace. The rest of this note is as written on 2026-11-22.
**Audience:** a future agent or maintainer picking this up.

This note records what upstream llama.cpp has added since the pinned build, which
of those additions could affect throughput on this host, which knobs the current
build already supports but no `models.ini` uses, and what a follow-up worker would
need to know. Potential improvements are estimates and are labelled as such; they
are not measurements on this hardware.

It intentionally contains no personal names, client/project identifiers, hostnames
or filesystem paths, because `md/` is committed to a public repository.

---

## 0. Short version

- The `llama-cpp` router is on `b10622` (2026-08-25). Upstream is now `v1.0.0`
  (`b12359`, 2026-11-13), nightly `b12633` (2026-11-22). About 2,000 builds and
  three months of changes behind.
- **Biggest untapped feature:** the MoE expert cache (`--moe-cache-mib`,
  `--moe-cache-cpu-share`), introduced in `v0.7.0` and matured through `v0.8.0` and
  `v1.0.0`. It targets exactly the CPU-resident MoE entries and the verify cost
  that makes MTP lose on them. It requires a newer binary.
- **Biggest no-build lever:** explicit MoE expert placement (`-cmoe` /
  `--n-cpu-moe N`) instead of letting `-fit` move whole layers. Needs an A/B and a
  full re-tune.
- **MTP on MoE:** the draft KV type (`spec-draft-type-k/v = q4_0`) will not flip
  any of the current MTP-off decisions. The expert cache is the only plausible
  lever, mainly for the near-parity entries (A/B `0.98` and `1.01`); the
  `0.91–0.92` group is a longer shot. See §7.
- **Do not enable** `--models-memory-margin`: it is router-initiated unloading and
  races the coordinator, the same reason `models-max` is banned.
- The `inkling-llama-cpp` router already runs a newer binary than `v1.0.0`, so it
  can be used to inspect or trial a flag without building anything. Caveat: it is
  a vendor build, not neutral upstream; use it for availability checks, not as the
  final word on an upstream A/B.

---

## 1. Version gap

Upstream changed its release naming during this window. The pinned binary reports
`0.3.0-dev`; releases now use semantic versions (`v0.4.0` … `v1.0.0`) alongside the
nightly `bNNNNN` tags.

| Item | Version | Date |
|---|---|---|
| llama-cpp pin | `b10622` | 2026-08-25 |
| release after the pin | `v0.4.0` | 2026-09-04 |
| release after the pin | `v0.5.0` | 2026-09-23 |
| release after the pin | `v0.6.0` | 2026-10-05 |
| release after the pin | `v0.7.0` | 2026-10-15 |
| release after the pin | `v0.8.0` | 2026-10-28 |
| release after the pin | `v0.9.0` = `b12110` | 2026-11-04 |
| current stable | `v1.0.0` = `b12359` | 2026-11-13 |
| current nightly | `b12633` | 2026-11-22 |

The most relevant releases for this work:

- **`v0.6.0` (2026-10-05):** extended batch API; MTP support for another model
  family. No direct effect on the catalogue here.
- **`v0.7.0` (2026-10-15):** introduced the GPU cache for MoE experts kept in host
  memory (`--moe-cache-mib`), with a release note claiming **up to ~2.2x decode
  speed-up when experts are offloaded**. Also added LiliCorr speculation and MTP
  for another family.
- **`v0.8.0` (2026-10-28):** 50/50 SLRU replacement for the host-resident MoE
  expert cache; router memory-management and tool-calling work; backend
  performance work.
- **`v0.9.0` (2026-11-04):** FP8 E4M3, `flash_attn_ext_rows`, Gemma 4 prefill
  graph work, MTP checkpoint fixes.
- **`v1.0.0` (2026-11-13):** MoE cache CPU-share for misses and LRFU/ClassLRU
  replacement; FP8 KV caches; CUDA few-row MMQ for batch sizes 2–24; MTP
  device-buffer and fit changes; server hardening.

Because the cache changed replacement policy across three releases, do not assume
one build's cache benchmark transfers to another build.

For comparison, the router pins at the time of writing:

| Router | Pin / build |
|---|---|
| llama-cpp | `b10622` (2026-08-25) |
| prism-llama-cpp | `prism-b10777-e3de715` (image built 2026-10-16) |
| raon-llama-cpp | commit `fb89566` (image built 2026-10-23) |
| inkling-llama-cpp | `b12588` (image built 2026-11-21) |

`b12588` is newer than `v1.0.0`, which is why a newer binary is already available
to test flag availability quickly.

---

## 2. Method

- Diffed `llama-server --help` from the running pinned binary against the running
  newer binary. This separates "flag exists but is unused" from "flag is newer than
  the pin".
- Read release notes back to `v0.4.0` and checked `merged_at` dates for the
  performance-related pull requests.
- Compared the `models.ini` key set against the flags both builds expose.
- Cross-checked placement, CPU%, MTP A/B ratios and speeds in `full-metrics.md`.

All potential figures are derived from upstream release data plus the existing
records; none is an A/B result on this host.

---

## 3. Flags added after the pin

### 3.1 Present in newer builds, absent from `b10622`

| Flag | First seen | What it does | Relevance here |
|---|---|---|---|
| `--moe-cache-mib N` | `v0.7.0` (2026-10-15) | GPU cache (N MiB, or `auto`) for MoE experts whose weights live in host RAM | High for CPU-resident 35B-A3B / 26B-A4B / A3B entries |
| `--moe-cache-cpu-share F` | 2026-11-07 (#30966) | Share of cache misses computed on the CPU instead of uploaded to the GPU | High, needs per-model tuning |
| `--spec-draft-n-ubatch N` | before 2026-10-23 | Physical batch cap for the draft context, to spare VRAM | Only helps a draft that spills; should be re-read as "draft-memory", not "MTP benefit" |
| `--n-cpu-ffn N` | before 2026-10-23 | Keep dense FFN of the first N layers on the CPU | Low: dense models here are GPU-resident |
| `--lazy-mode` | before 2026-10-23 | Read per-layer embedding rows on demand (auto only for tensors > 4 GiB; requires mmap) | Load/RAM only, not decode |
| `--models-memory-margin` | newer than the pin | Router unloads LRU models when free VRAM is low | Do not use: races the coordinator, like the banned `models-max` |
| `--kv-unified-per-slot N` | newer than the pin | Per-slot KV limit / shared-pool sizing | None at `parallel = 1` |
| `--spec-draft-sampling` | newer than the pin | Greedy vs probabilistic draft sampling | Low; a possible acceptance experiment, see §7 |
| `f8_e4m3` KV cache type | `v0.9.0`/`v1.0.0` | OCP FP8 KV cache | No: about twice the size of the current `q4_0` KV, and no native FP8 on this GPU generation |
| `draft-dflash2`, `draft-lilicorr` spec types | `v0.7.0`–`v1.0.0` | New draft engines | Model-specific; not for the Qwen/Gemma MTP models here |

The raon router's image (2026-10-23) already exposes `--moe-cache-mib`,
`--n-cpu-ffn`, `--lazy-mode` and `--spec-draft-n-ubatch`, but not
`--moe-cache-cpu-share`. That matches the release dates: `v0.7.0` is from
2026-10-15, and CPU-share came in November.

### 3.2 Removed or deprecated in newer builds

`-dio` / `--direct-io`, `--mmap` / `--no-mmap` / `--mlock`, and
`--defrag-thold` are removed or deprecated. The current `models.ini` does not use
any of them (`load-mode = mmap+mlock` covers the load mode), so a pin bump would
not need ini changes for these.

---

## 4. Build-level changes relevant to these workloads

These are not flags; they are improvements in the binary itself. All merged after
the current pin.

| Change | PR | Effect |
|---|---|---|
| CUDA few-row MMQ for batch sizes 2–24 | #31533 | Speeds the small verification batches used by speculative decoding |
| CUDA MoE MMQ data layout linearization | #31047 | Faster GPU MoE paths |
| MTP target hidden states from a device buffer | #31927 | Less host/device copying during MTP decode |
| `-fit` accounts for skipped NextN layers | #31569 | Better automatic placement when the MTP head is present |
| Fix on-device state copy sizes for quantized KV caches | #30541 | Correctness/robustness for quantized KV, which is used everywhere here |
| MTP hidden state saved in context checkpoints | #30141 | Better multi-turn prompt-cache reuse with MTP |
| Restore the speculative checkpoint for drafts longer than `n_rs_seq` | #31350 | Prompt-cache reliability with speculative decoding |
| Gemma 4 prefill graph optimizations | #31356 | Large prefill gains for the small Gemma 4 variants; effect on 12B/26B not established |
| Gemma 4 MTP assistant follows `ctx_other` devices and flash-attention setting | #31635 | Placement correctness for the Gemma 4 MTP drafter |
| Backend scheduler reuse and skipping unused inputs | #32009, #31419 | General per-request overhead reduction |

Cost of adopting them: a pin bump invalidates the benched baseline for every entry
on that router, so it implies re-benching the catalogue. This note does not
recommend doing that; it only records what the newer build contains.

---

## 5. Knobs available in the current build that are unused

### 5.1 MoE expert placement: `-cmoe` / `--n-cpu-moe N`

`-cmoe` keeps all MoE expert weights in system RAM while attention and the rest can
stay on the GPU. `--n-cpu-moe N` does the same for the first N layers only. Both
exist in `b10622`; `--override-tensor exps=CPU` is the tensor-pattern form of the
same idea.

Why it matters: the current CPU-resident MoE entries are placed by `-fit`, which
appears to move whole layers to the CPU, taking attention with them. An explicit
expert-only offload keeps attention on the GPU and leaves only the per-token
expert reads on the host.

- Potential: the largest no-build lever. CPU use on those entries is already
  1,200–1,700% and decode is 36–49 t/s, so there is room if CPU attention is part
  of the cost. A 10–30% improvement is plausible but unproven; it can also be
  slower if expert reads from RAM dominate.
- Cost: changes the memory layout completely. Batch and context tuning must be
  redone; the existing bisect picks do not transfer.
- Note: `-cmoe` frees whatever VRAM `-fit` was using for expert weights. That is
  the space a MoE expert cache would later reuse (§6.1), so the two decisions are
  linked.

### 5.2 Draft KV type: `spec-draft-type-k` / `spec-draft-type-v = q4_0`

The draft KV cache defaults to f16. Quantizing it to q4_0 affects only the draft's
proposals; the target still verifies every token, so output is unchanged. The main
KV is already `q4_0`.

- Potential: little or no decode gain today. Every MTP entry in `full-metrics.md`
  shows about 97–99% CPU, which indicates the draft is already on the GPU (a
  spilled draft shows hundreds to thousands of percent). The value is headroom:
  the tight IQ2 27B entries run batch 256–512 with prefill around 350–390 t/s, so a
  few hundred MB saved might allow a larger batch and therefore faster prefill.
  Whether the limit is draft KV or the draft compute buffer is unknown.
- Risk: quantizing the draft KV can lower draft acceptance. On a dense MTP model
  that trades a little decode for memory; on a MoE model where MTP already loses
  it can make the A/B worse.
- Cost: placement must be re-checked after the change; the `n_max`/batch tuning is
  only valid at the same placement.
- Scope: the keys only take effect while MTP is enabled. The MoE sections have no
  `spec-*` keys at all, so adding this alone does nothing; MTP must be re-enabled
  and the A/B re-run to see any effect.

### 5.3 Prompt reuse: `--cache-reuse N` (default 0)

Attempts to reuse cached prompt chunks via KV shifting when the new prompt
diverges from the cached one. Normal prompt caching already handles an unchanged
prefix, which covers appended chat turns.

- Potential: TTFT only, no decode change. It helps only when the system prompt,
  tool list or an earlier message changes between requests; otherwise the ordinary
  prefix cache already applies.
- Measurement: `bench.sh` sends single-shot prompts and will not show this; it
  needs a multi-turn or changing-prefix timing test.

### 5.4 `--fit-target MiB` (default 1024)

Controls how much device memory `-fit` leaves free. Lower packs more layers or
experts; higher leaves more headroom.

- Potential: small and per-model. Several entries sit at about 10.9/12 GB. A lower
  target might recover a spilled layer; a higher one might avoid a silent spill.
- Risk: invalidates the tuned batch and can push a model into a spill that only
  appears under long context. If `-cmoe` is adopted, revisit whether `-fit` still
  controls the split at all.

### 5.5 Thread count

The host exposes 28 logical CPUs (14 cores with SMT). The ini sets 20 threads for
both generation and batch, which is neither the physical-core count nor the
logical count.

- Potential: a few percent on CPU-resident models; physical-core counts often beat
  SMT in llama.cpp, but not always.
- Cost: runtime-only A/B; no ini edit is needed to measure it. `threads` and
  `threads-batch` can be tuned separately.

### 5.6 ngram speculative decoding (already in the pinned build)

`ngram-simple`, `ngram-map-k`, `ngram-map-k4v`, `ngram-mod` and `ngram-cache` are
listed by `b10622` but unused. They draft from n-gram lookups in the prompt and
need no draft model.

- Potential: none to about 2x decode when the output shares long n-grams with the
  prompt (edit-style code output, quoting, repetitive transforms); zero or
  negative when it does not.
- Measurement: needs a real workload, not the synthetic bench prompt.

### 5.7 Knobs not worth pursuing here

- `--swa-full`: quality, not speed; more KV memory.
- `--kv-unified` / `--no-kv-unified`: no effect at `parallel = 1`.
- `--no-warmup`: startup only.
- `--prio`, `--poll`, `--threads-http`: scheduling micro-tuning, no expected
  throughput change.
- KV cache types other than `q4_0`: quality/size trade-offs, not speed.

---

## 6. Newer-build-only knobs

Recorded for completeness. None of these is available without changing the pin.

### 6.1 MoE expert cache: `--moe-cache-mib` + `--moe-cache-cpu-share`

Used together with `-cmoe` / `--n-cpu-moe`, this keeps the most frequently routed
experts in spare VRAM and computes misses either on the GPU (upload) or on the CPU,
according to the share. It only caches experts that are host-resident; it is not a
general GPU offload.

Evidence:

- `v0.7.0` release note: the flag arrived with a claim of **up to ~2.2x decode
  speed-up when experts are offloaded**.
- Pull-request example (different GPU and model): 24.2 → 47.6 t/s with a 6.4 GB
  cache and `cpu-share 0.95`; 65.5 → 85.4 t/s with a 24 GB cache.
- `v0.8.0` changed the replacement policy to 50/50 SLRU; `v1.0.0` added CPU-share
  and LRFU/ClassLRU. Do not treat a benchmark from one build as valid for another.

On this host:

- The card is 12 GB and the MoE entries already use about 10.9 GB. The cache would
  be small unless `-cmoe` frees VRAM by moving expert weights out. A 10–30% gain is
  plausible, not established; the upstream 2.2x figure is not transferable.
- `--moe-cache-mib auto` sizes the cache from free VRAM after the fit and may
  reduce context to `--fit-ctx` first. Prefer an explicit MiB value for a
  controlled comparison.
- The cache lives in VRAM in the `llama-server` child. It is lost on unload and
  rebuilt cold after every coordinator switch: the first requests after a swap may
  not see steady-state speed. `bench.sh`'s warm-up hides this; a real-client test
  would not.
- It is unrelated to the `model-cache` service, which caches GGUF files on NVMe.
  Do not confuse the two in logs or docs.
- It changes the layout, so batch/context tuning must be redone. Upstream ships a
  tuning script at `scripts/moe-cache-tune.py`; it expects a standalone
  `llama-server` command, so it needs adaptation to run inside this container.

### 6.2 `--spec-draft-n-ubatch`

Caps the draft context's physical batch. Its only benefit is avoiding a draft
spill, which the current records do not show, so immediate value is low. It could
matter later if a larger context or `n_max` is attempted. It does not reduce the
target verify cost, so it will not by itself make MTP pay off on a MoE model.

### 6.3 Others

- `--n-cpu-ffn N`: dense equivalent of `--n-cpu-moe`; dense models here are
  already GPU-resident.
- `--lazy-mode`: reduces load-time readahead and RAM for very large embedding
  tensors; not a decode gain.
- `--models-memory-margin`: must not be enabled alongside the coordinator, for the
  same reason `models-max` is banned.
- `--spec-draft-sampling probabilistic`: may change draft acceptance (the target
  verifies by rejection sampling). Worth one experiment on a near-parity MoE MTP
  entry, not a default.
- `f8_e4m3` KV: larger than the current `q4_0` KV and without native FP8 support
  on this GPU generation.
- `draft-dflash2`, `draft-lilicorr`: tied to particular model families, not the
  MTP models in this catalogue.

---

## 7. MTP on MoE: why it is off, and what could change that

MTP is off for every MoE entry in the catalogue; where the model has an MTP head,
the A/B decided off. The reason is not draft quality; it is the target's verify
pass.

With `n_max = 2`, one decode step verifies up to three tokens. On an MoE each
verified token can route to different experts, so one step streams several experts'
weights. When experts are host-resident, that means several expert reads over the
RAM bus per step, which costs more than the accepted drafts save. On a
GPU-resident MoE the same effect shows up as extra compute and bandwidth
contention. This is recorded in `AGENTS.md` and in the MTP A/B results.

Measured A/B ratios (MTP-on ÷ MTP-off; the decision rule keeps MTP only above
`1.02`):

| Model class / context | Measured ratio | Gap to keeping MTP |
|---|---|---|
| 35B-A3B, 64k (four families) | 0.83–0.98 | 4–23% |
| 35B-A3B, 128k | 0.82–0.86 | ~19–24% |
| 35B-A3B, 256k | 0.91 | ~12% |
| 26B-A4B, 32k | 1.01 | ~1% (tie goes to off) |
| 19B-A3B, GPU-resident, 128k | 0.82 | ~24% |

Only the `0.98` and `1.01` entries are plausibly within reach of a cache-driven
flip; the `0.91–0.92` group is a longer shot, and the `0.82–0.86` group would need
roughly a 19–24% improvement in the verify path.

### 7.1 Why `spec-draft-type-k/v = q4_0` will not flip it

The draft KV is a small fraction of the traffic. Quantizing it changes the draft's
attention reads, not the target's expert reads or the number of target forward
passes. It also risks lowering acceptance, which makes an already-losing MTP worse.
The current MTP-off decisions were made from measured speed with the draft
resident, not from an `mtp_spills` rejection, so there is no draft-placement problem
for this knob to fix. The only exception would be a future entry whose A/B lost
because the draft itself spilled; that is not the case in the current records.

### 7.2 What could flip it

1. **MoE expert cache.** Keeping hot experts in VRAM directly cuts the RAM traffic
   the verify pass multiplies. This is the only mechanism with enough headroom to
   cover a 4% (near-parity) gap; it may also reach the ~12% group, but the
   `0.82–0.86` group is unlikely. The upstream ~2.2x is non-MTP decode, so no
   direct evidence exists yet.
2. **Acceptance.** MTP's upside is capped by acceptance. The tuner already chooses
   `n_max`/`p_min`; `--spec-draft-sampling probabilistic` is a possible experiment
   on a newer build. A near-parity entry has the best chance.
3. **Compute placement.** A GPU-resident MoE (all experts in VRAM) removes the host
   read problem, but the GPU-resident `0.82` record shows the verify still loses,
   so cache residency alone is not sufficient evidence.

### 7.3 If this is tested

- Re-enable `spec-type = draft-mtp` on one near-parity entry only, with
  `spec-draft-n-max`/`p_min` from its last tuned run and
  `spec-draft-type-k/v = q4_0`.
- Re-run placement and `bench.sh mtpab` on the same batch. Expect no flip on the
  current build; this is a cheap confirmation, not a promising experiment.
- The more informative experiment is on a newer build: `-cmoe` +
  `--moe-cache-mib <explicit>` + `--moe-cache-cpu-share` sweep, then `mtpab`.
  Re-bisect first, because placement changed.

---

## 8. Summary of expected impact

| Change | Build needed | Expected impact | Confidence |
|---|---|---|---|
| `-cmoe` / `--n-cpu-moe` on CPU MoE entries | No | Possibly +10–30% decode, with re-tuning | Low–medium; must be measured |
| `spec-draft-type-k/v = q4_0` | No | Little decode change; possible prefill gain on tight MTP entries; possible acceptance loss | Low |
| `--cache-reuse` | No | TTFT only, workload-dependent | Low |
| `--fit-target` tuning | No | Per-model, small, two-sided | Low |
| Thread count A/B | No | Few percent on CPU models | Medium for the A/B itself |
| ngram speculation | No | Up to ~2x on copy-heavy output, zero/negative otherwise | Workload-dependent |
| MoE expert cache | Yes | Potentially the largest gain on CPU MoE entries; possible MTP flip on near-parity entries | Upstream data positive; unknown here |
| `--spec-draft-n-ubatch` | Yes | Near zero until a draft spills; does not help MTP on MoE | High that current value is low |
| Build-level CUDA/MTP fixes | Yes | A few percent plus prompt-cache robustness | Medium |
| `f8_e4m3` KV | Yes | None (larger cache, no native FP8 here) | Medium |

---

## 9. Measurement caveats

- `bench.sh` benches one model at a time and one run at a time; concurrent runs
  interfere and can restart each other's router.
- Cache reuse and ngram speculation are not visible in its single-shot bench and
  need workload-shaped tests.
- Changing placement (`-cmoe`, `--n-cpu-moe`, `--fit-target`, draft KV type)
  invalidates the existing batch/context picks, so a re-bisect is mandatory.
- A pin bump changes the binary for every entry on the router and invalidates the
  benched baseline; the existing rule is to bump deliberately and re-bench.
- Potential figures above are estimates from upstream release data and from the
  existing placement/CPU figures in `full-metrics.md`; they are not A/B results on
  this machine.
- The MoE expert cache is per-child and cold after every model switch; do not
  benchmark it with a warm server and then expect the same speed for the first
  requests after a coordinator-driven swap.
- `--moe-cache-mib auto` can change context size; an explicit value is required
  for a fair comparison against a recorded bench.
- A model switch unloads and loads via the coordinator; anything that changes the
  unload API (none of the candidates here do) would need `tools/test_coordinator.py`
  and `tools/coord_mock.py` updated.

---

## 10. Context a follow-up agent needs

### 10.1 Where things live

- Router and pins: `compose.yml` (`LLAMA_REF`, `LLAMA_COMMIT`, `LLAMA_TARBALL`,
  `LLAMA_CMAKE_ARGS`). The builders share `llama-cpp/Dockerfile`.
- Model sections: `llama-cpp/models.ini` (plus the fork directories). The `[*]`
  block holds defaults; per-section keys override. Keys are the long flag names
  without the leading `--`, written as `key = value`; booleans are `true`/`false`.
- Benchmarks and records: `tools/bench.sh`, per-model JSON under
  `llama-cpp/models/`, and the root `full-metrics.md`, regenerated with
  `tools/gen_metrics.sh`.
- Coordinator, routing, `/availability`: `openresty/` and `AGENTS.md`.
- NVMe GGUF cache: `model-cache` service, `tools/model_cache.py`.
- Policy/tuning rules: `AGENTS.md` (batch pre-flight, discover mode, MTP A/B,
  family inheritance, safety gates).

### 10.2 Constraints that matter for this work

- **One `bench.sh` run at a time** on any backend; it takes a lock and a second run
  aborts.
- **Routers read `models.ini` only at start.** After a hand edit:
  `docker compose restart llama-cpp` (or the relevant router).
- **Single-file bind mounts pin the inode.** Editing an ini in place is seen when
  the router restarts. An editor that writes a new file and renames it over the old
  one leaves the container bound to the old inode; in that case recreate the
  service (`docker compose up -d <service>`), not just restart it. `bench.sh` edits
  in place.
- **Model names must be unique across all `models.ini` files**, because the
  coordinator routes by name.
- **Family inheritance:** coder/think siblings inherit from the family head. Keys
  that can change memory or speed must not be treated as family-free. Adding
  `moe-cache-*` per section would make differing values separate family heads,
  which is correct but increases the number of heads to bench; `bench.sh` has no
  tuning axis for these keys yet.
- **Pre-flight:** run `bench.sh bisect` before `bench` on any entry whose placement
  or batch changed. Never run an untuned entry at the `[*]` batch of 4096.
- **Safety gates:** OOM log grep is the source of truth, not HTTP status; run the
  residency, saturation and long-decode checks; the ini is restored on failure.
- **Sibling benches:** use `--no-inherit` on `bench.sh` when the think sibling sits
  near the spill ceiling and needs its own record; use `--strict` when producing
  publishable records, so a failed MTP tune is recorded as skipped rather than
  merged into a bench.
- **Confirm placement before changing it:** the `placement` column in
  `full-metrics.md` is a verdict, not a layout. Read the router/child load log
  (the `load_tensors` and offload lines) before assuming how `-fit` split the
  model.
- **Docs to update when adopting anything:** `AGENTS.md` (relevant section and
  Gotchas), this file (status), and the bench JSONs/`full-metrics.md`.

### 10.3 A safe way to trial a newer build

- Do not move `llama-cpp`'s pin to evaluate a flag. Build a one-off image tag from
  the desired ref and either (a) point a temporary router at it, following the
  "Adding another llama.cpp router" procedure in `AGENTS.md`, or (b) use the
  existing `inkling-llama-cpp` router as a quick availability check. A temporary
  router needs a unique name, a `models.ini`, an `openresty` mount, and the
  coordinator mock/scenario if it is added to the test suite.
- The complete temporary-router checklist is in `AGENTS.md`. The parts that are
  easy to miss: the `cortex.ROUTERS` line, the compose build and service entries,
  the ini mount into `openresty` (which needs an `openresty` recreate on first
  deploy), `BENCH_BACKENDS` / `BACKENDS` / `CORTEX_ROUTERS` in the tools, and
  `EXTRA` plus a scenario in the coordinator test.
- If a pin bump is ever justified: edit `LLAMA_REF` (and tag) in `compose.yml`,
  `docker compose --profile build build llama-build`,
  `docker compose up -d llama-cpp`, then re-bench the affected families and
  regenerate `full-metrics.md`. The previous image tag stays on disk for rollback.
- Rebuilding with a changed `LLAMA_REF` moves the `llama-cpp:latest` tag. The
  running container keeps its old image until recreated, but any later recreate
  would pick up the trial build; for a trial that must not touch the live router,
  give it a separate image tag and service, or retag `llama-cpp:latest` back to
  `llama-cpp:b10622` afterwards.
- Use a distinct model name for trial entries so the coordinator does not confuse
  them with catalogue entries.
- Compare like with like: same model, same quantization, same context, same batch,
  same sampling; only the intended flag or binary changes.
- A pin bump is the last step, after an A/B shows a win, because it invalidates the
  whole catalogue's bench baseline. The previous image tag remains available for
  rollback.

### 10.4 Reproducing the research

```sh
# Flags exposed by a running build
docker exec cortex-llama-cpp-1 llama-server --help
docker exec cortex-inkling-llama-cpp-1 llama-server --version

# Diff flag sets (pinned vs newer)
diff <(docker exec cortex-llama-cpp-1 llama-server --help 2>&1 \
        | grep -oE '(^|[[:space:]])-{1,2}[a-zA-Z0-9_.-]+' | tr -d ' ' | sort -u) \
     <(docker exec cortex-inkling-llama-cpp-1 llama-server --help 2>&1 \
        | grep -oE '(^|[[:space:]])-{1,2}[a-zA-Z0-9_.-]+' | tr -d ' ' | sort -u)

# Release dates and PR merge dates
curl -s 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=100' \
  | jq -r '.[] | "\(.tag_name)\t\(.published_at)"'
curl -s 'https://api.github.com/repos/ggml-org/llama.cpp/pulls/30966' \
  | jq -r '"\(.number)\t\(.merged_at)\t\(.title)"'

# Keys currently in use
awk '/^\[/{next} /^[a-z]/{sub(/[ \t]*=.*/,""); print}' llama-cpp/models.ini | sort -u
grep -rnE 'spec-draft-type|cache-reuse|fit-target|moe-cache|n-cpu-moe' */models.ini
```

---

## 11. Open questions

1. Does `-cmoe` / `--n-cpu-moe` alone beat `-fit` placement on the 35B-A3B entries,
   and by how much?
2. How much VRAM does `-cmoe` actually free on a 12 GB card after KV and attention
   are accounted for?
3. Does the `v0.7.0` ~2.2x MoE-cache claim survive at this model size and VRAM
   budget, and which cache size/share is best?
4. Does the expert cache flip any MoE MTP A/B over the 2% tie rule, starting with
   the `0.98` and `1.01` entries?
5. Does `spec-draft-type-k/v = q4_0` lower acceptance enough to negate its memory
   saving, even on the dense MTP entries where it is safe to try?
6. Is `--cache-reuse` worth anything for the agent clients' changing-prefix
   traffic, and what value?
7. Would `--spec-draft-sampling probabilistic` raise acceptance on a near-parity
   MoE MTP entry?
8. Does `--n-cpu-ffn` or `--lazy-mode` change anything for the vision or
   large-embedding entries (likely not, but untested)?

---

## 12. Glossary

- **MTP** — multi-token-prediction draft head; a speculative-decoding mode where
  the target verifies drafted tokens.
- **MoE** — mixture of experts; each token routes to a subset of expert weights.
  Host-resident experts are read over the RAM bus per token.
- **`-fit`** — llama.cpp's automatic placement of layers/tensors into device
  memory, leaving a target margin and moving whole layers to CPU when it runs out.
- **`-cmoe` / `--n-cpu-moe`** — explicit offload of all, or the first N layers',
  MoE expert weights to host RAM, independent of `-fit`.
- **Draft KV** — the KV cache belonging to the draft context, not the target's.
- **Placement verdict** — bench classification of decode as GPU or CPU based on
  CPU/GPU use; a silent spilled draft shows as high CPU.
- **A/B tie rule** — MTP is kept only if its measured mean beats MTP-off by more
  than 2%; a tie goes to off.
- **Family / `FAMILY_FREE`** — `bench.sh` grouping of entries that differ only in
  sampling, reasoning or chat-template keys, so one head's bench transfers to its
  siblings.
- **`model-cache`** — the NVMe GGUF file cache service; unrelated to the MoE expert
  cache.

---

## 13. References

- Release `v0.7.0` (2026-10-15): `--moe-cache-mib`, up to ~2.2x decode with experts
  offloaded; LiliCorr speculation.
- Release `v0.8.0` (2026-10-28): 50/50 SLRU host-resident MoE expert cache; router
  memory-management work.
- Release `v0.9.0` (nightly `b12110`, 2026-11-04): FP8 E4M3,
  `flash_attn_ext_rows`, Gemma 4 prefill work, MTP checkpoint fixes.
- Release `v1.0.0` (nightly `b12359`, 2026-11-13): MoE cache CPU-share and
  LRFU/ClassLRU, FP8 KV caches, CUDA few-row MMQ, MTP device-buffer and fit
  changes.
- Pull requests: #30141, #30541, #30966, #31047, #31233, #31350, #31356, #31419,
  #31533, #31569, #31635, #31888, #31927, #32009.
- `llama-server --help` from the pinned `b10622`, the newer `b12588`, and the
  raon image's intermediate build.
