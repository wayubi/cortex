# MoE GPU Underutilization and CPU-MoE Optimization Plan

**Date:** 2026-09-10 (revised 2026-09-10 — see Revision Notes)
**Purpose:** Determine whether targeted CPU-MoE offloading can improve inference performance for large MoE models on an RTX 3060 12 GB, and determine how this should fit into the existing `bench.sh` optimization process.

## Revision Notes (2026-09-10)

This plan was reviewed against the actual repo state before implementation. Three corrections
changed the plan materially; everything else below was left as originally written (or lightly
reworded for consistency).

1. **The mechanism already exists in llama.cpp — don't hand-roll it.** The installed build
   (checked via `llama-server --help` on `cortex-llama-cpp-1`) already ships:
   ```
   -cmoe,  --cpu-moe            keep ALL MoE weights in CPU
   -ncmoe, --n-cpu-moe N        keep the MoE weights of the first N layers in CPU
   ```
   `--n-cpu-moe N` **is** the "layer-selective CPU-MoE" originally described in §9 as a
   hand-rolled `-ot` regex boundary — except it's a single integer already validated by
   llama.cpp against the real architecture, with no risk of a wrong tensor-name regex. §4, §8,
   and §9 below were rewritten around this flag. The original §4 sub-tensor regex idea
   (`-ot ".ffn_(up)_exps.=CPU"`) is demoted to an optional, lower-priority refinement — it's a
   real, different axis (which projection within an expert, across *all* layers) but not the
   primary mechanism.

2. **`bench.sh` already half-anticipates this, checking the wrong key.** `cmd_bisect_discover`
   (as of this review, tools/bench.sh:3499–3541) already special-cases a model whose section
   has `override-tensor` set — treating it like an MTP model for batch search purposes (decode
   is not batch-independent, so residency/decode-cliff checks can't be skipped):
   ```bash
   local SIMPLE_NONMTP=0
   if ! grep -q "spec-type.*draft-mtp" <(read_section) \
      && ! grep -q "override-tensor" <(read_section); then
     SIMPLE_NONMTP=1
   fi
   ```
   Two OOM error messages (tools/bench.sh:3172, 3686) also already suggest
   `"free VRAM (override-tensor=exps=CPU)"` as a manual hint. This gate must be extended to also
   check whichever key(s) this plan introduces (`cpu-moe`, `n-cpu-moe`) — see §19.

3. **MTP interaction was missing.** Two of the plan's three candidate models
   (`qwen-3.6-35b-a3b-q4-mtp-64k`, `tiel-coder-35b-a3b-q4-mtp-128k-think`) are in-model MTP
   configs with already-tuned `n_max`/`p_min`. The same llama.cpp build also exposes
   `--spec-draft-cpu-moe` / `--spec-draft-n-cpu-moe` — a separate CPU-MoE knob for the *draft*
   model. §11 and §12 now include an MTP re-tune step after a CPU-MoE change, since moving main-
   model experts to CPU changes the VRAM/compute balance the MTP parameters were tuned against.

Two previously-deferred parameters were also pinned down rather than left as "TBD":
the §7 trigger criterion and the §14 significance threshold (see those sections).

## 1. Problem

The current benchmark results show a substantial difference between models that fit primarily on the GPU and larger MoE models that do not.

The 9B-class models are generally GPU-resident. For example, Qwen 3.5 9B at 64K context achieves approximately 57.1 tok/s decode with 84% GPU utilization and only about 7.5 GiB of VRAM usage.

The larger MoE models show a very different pattern. Qwen 3.6 35B-A3B at 64K (MTP variant, `qwen-3.6-35b-a3b-q4-mtp-64k`) achieves approximately 34.5 tok/s decode, but reports only 34% GPU utilization while consuming approximately 1,565% CPU. GLM-4.7 30B-A3B at 64K (`glm-4.7-30b-a3b-flash-q4-64k`) similarly achieves 34.0 tok/s with only 35% GPU utilization and approximately 1,567% CPU. TIEL Coder 35B-A3B at 128K (`tiel-coder-35b-a3b-q4-mtp-128k-think`) reaches only 21.8 tok/s with 21% GPU utilization and approximately 1,460% CPU.

These results indicate that these models are not effectively GPU-bound. The RTX 3060 is frequently waiting for CPU-side work rather than being continuously supplied with work.

The relevant question is therefore not simply:

"How many layers can be put on the GPU?"

It is:

"Given only 12 GB of VRAM, which tensors should reside on the GPU so that the GPU performs the largest possible fraction of the latency-sensitive computation?"

## 2. Why MoE Models Are Special

An MoE model can contain a very large total number of parameters while activating only a subset of its experts for each token.

The expert tensors can therefore consume a large amount of VRAM despite the fact that only a fraction of the expert computation is active for any particular token.

This creates an unusual optimization opportunity.

Instead of attempting to maximize the total number of model tensors placed on the GPU, it may be better to deliberately place some MoE expert tensors on the CPU.

The freed VRAM can then be used by other tensors and layers that are more beneficial to keep GPU-resident.

The important possibility is therefore:

CPU-MoE offloading can sometimes make the overall model faster even though it explicitly moves additional computation or tensor access onto the CPU.

This is not because CPU computation is faster than GPU computation. It is because the alternative may leave important parts of the model CPU-bound anyway.

## 3. Current Evidence

The benchmark data (`full-metrics.md`, generated by `tools/gen_metrics.sh`) provides strong evidence that this is worth investigating for the large MoE models. Values below were verified against that file.

`qwen-3.6-35b-a3b-q4-mtp-64k` (and its `-think` sibling):

* Decode: 34.5 tok/s
* GPU utilization: 34%
* CPU utilization: ~1,565%
* VRAM: ~10.9 GiB
* Placement: CPU
* Note: MTP-tuned (n_max=3, p_min=0.7) — see Revision Notes item 3.

`glm-4.7-30b-a3b-flash-q4-64k` (and its `-coder`/`-think`/`-think-coder` siblings):

* Decode: 34.0 tok/s
* GPU utilization: 35%
* CPU utilization: ~1,567%
* VRAM: ~11.0 GiB
* Placement: CPU
* Note: not an MTP model.

`tiel-coder-35b-a3b-q4-mtp-128k-think` (and its `-coder` sibling):

* Decode: 21.8 tok/s
* GPU utilization: 21%
* CPU utilization: ~1,460%
* VRAM: ~10.8 GiB
* Placement: CPU
* Note: MTP-tuned (n_max=3, p_min=0.7) — see Revision Notes item 3.

These models are using almost all available VRAM (~11 GiB of 12 GiB) while nevertheless keeping the GPU relatively underutilized.

This suggests that simply increasing GPU layer count is not necessarily the correct optimization strategy.

## 4. What CPU-MoE Is Intended to Accomplish

The purpose of CPU-MoE testing is to determine whether moving selected MoE expert tensors to CPU allows the remainder of the model (attention, embeddings, shared/dense layers) to become more GPU-resident.

**Primary mechanism — use the built-in flags, not a hand-rolled tensor regex.** The installed
llama.cpp build already provides:

```
-cmoe,  --cpu-moe            keep ALL MoE weights in CPU
-ncmoe, --n-cpu-moe N         keep the MoE weights of the first N layers in CPU
```

`--n-cpu-moe N` is a single integer, monotonic from `N=0` (no experts offloaded) to
`N=n_layers` (equivalent to `--cpu-moe`). It requires no verification against tensor names —
llama.cpp resolves the pattern internally against the real architecture. This replaces the
originally-proposed `-ot` layer-boundary regex entirely; use `--n-cpu-moe N` as the search
variable (§8).

For the draft model in an MTP config, the equivalent flags are `--spec-draft-cpu-moe` and
`--spec-draft-n-cpu-moe N` — a separate, independent setting (see §11).

**Secondary mechanism (optional, lower priority) — sub-tensor selective offload.** A finer,
different axis is available via `-ot`/`--override-tensor`, targeting a specific projection
within the expert FFN across *all* layers rather than a layer boundary, e.g.:

```
-ot ".ffn_(up|down)_exps.=CPU"
-ot ".ffn_(up)_exps.=CPU"
```

This axis is NOT covered by `--n-cpu-moe` (which moves a whole layer's expert set, not a
sub-tensor across all layers) and is not equivalent to it. It should only be explored after
`--n-cpu-moe` bisection (§8) has established that CPU-MoE offload helps at all, as a Phase 2
refinement — the VRAM granularity per step is much smaller (one projection per layer vs. a
whole layer's experts), so it is unlikely to matter until the coarse search is exhausted.

The desired outcome is not maximum CPU-MoE offloading. The desired outcome is the
configuration that maximizes useful inference performance.

## 5. The Optimization Objective

The benchmark should treat CPU-MoE configuration as another optimization dimension, but only for models that demonstrate evidence of CPU-bound execution.

The primary objective should remain decode throughput because interactive inference, particularly coding-agent workloads, is strongly affected by token generation latency.

The primary metric should therefore be:

```
decode_t/s
```

Secondary metrics should be used to determine why a configuration is faster or slower:

```
gpu%
cpu%
vram
ram
power_w
temp_c
```

A successful CPU-MoE configuration would ideally produce some combination of:

* higher decode tok/s;
* higher GPU utilization;
* lower CPU utilization;
* acceptable VRAM usage;
* no CPU spillover from important non-MoE layers.

GPU utilization should not itself be treated as the objective. A configuration with 90% GPU utilization but lower tok/s is not necessarily better than one with 60% GPU utilization and higher tok/s.

GPU utilization is diagnostic evidence, not the optimization target.

## 6. Candidate Models

CPU-MoE optimization should initially be restricted to models showing clear evidence of CPU-bound execution.

The current benchmark data suggests the following priority (exact `models.ini` section names):

`qwen-3.6-35b-a3b-q4-mtp-64k` (and its `-think` sibling) is an especially strong candidate: 34.5 tok/s, 34% GPU, ~1,565% CPU. **MTP model** — see §11 step 8.5.

`glm-4.7-30b-a3b-flash-q4-64k` (and its `-coder`/`-think`/`-think-coder` siblings) is another strong candidate: 34.0 tok/s, 35% GPU, ~1,567% CPU. Not an MTP model — the simplest first target since there is no draft-model interaction to account for.

`tiel-coder-35b-a3b-q4-mtp-128k-think` (and its `-coder` sibling) is also a candidate, although its lower decode speed and 128K context make it a somewhat different workload. **MTP model.**

The 9B models should not undergo CPU-MoE optimization — not merely because current data shows no benefit, but structurally: `qwen-3.5-9b-*` and `ornith-1.5-9b-*` are already GPU-resident (~84% GPU util at 7.5 GiB), and CPU-MoE flags are no-ops on any section whose architecture doesn't have MoE experts to move. The trigger criterion in §7 naturally excludes these without needing a separate size-based exception.

CPU-MoE testing should therefore be conditional rather than universal.

**Recommended implementation order:** start with `glm-4.7-30b-a3b-flash-q4-64k` (non-MTP,
simplest), confirm the search mechanics and a measurable win, then extend to the two MTP
candidates with the additional re-tune step from §11.

## 7. Avoiding a Combinatorial Benchmark Explosion

CPU-MoE should not be tested across every combination of:

```
model × context × batch × CPU-MoE configuration × MTP configuration × reasoning mode
```

That would create a large and mostly unnecessary benchmark matrix.

The existing benchmark should first establish a baseline configuration for each model.

Only models that meet a CPU-bound criterion should enter CPU-MoE optimization. **This
criterion is decided, not deferred:**

```
placement == "CPU"  AND  avg_gpu_util_pct < 50
```

Both fields already exist in every `models/<model>.json` written by `cmd_bench` (`placement`
and `hardware.run.avg_gpu_util_pct`). No new instrumentation is needed to evaluate this gate —
it can run as a check over existing JSON records before any new benchmarking starts, to build
the initial candidate list, and then again after each future `cmd_bench` run to catch newly
CPU-bound models automatically.

The purpose is to distinguish models where CPU-MoE could plausibly recover GPU utilization from models that are already performing appropriately.

## 8. Recommended Search Strategy

CPU-MoE testing should be hierarchical, and implemented as a **bisection/ladder over the single
integer `--n-cpu-moe N`**, reusing the same ladder+refine pattern `cmd_bisect_discover` already
uses for batch size (tools/bench.sh:3499 onward) rather than inventing new search machinery:

1. Benchmark the existing (baseline) configuration. If it doesn't meet the §7 trigger, stop —
   no CPU-MoE search runs.
2. `N = n_layers` (equivalent to `--cpu-moe`): all experts on CPU, maximum VRAM freed for
   attention/shared tensors. Measure decode t/s, GPU%, CPU%, VRAM.
3. `N = 0`: baseline restated for comparison (already have this from step 1).
4. Ladder/bisect `N` between 0 and `n_layers` the same way batch size is laddered: start from a
   coarse step (e.g. quarters of `n_layers`), narrow toward the `N` that maximizes decode t/s,
   stopping by the same "stop refining once inside noise" logic as the batch search (§14).

This replaces the originally-proposed regex sequence (`all experts CPU → up/down CPU → up CPU`)
— that sequence didn't have a clear monotonic relationship to VRAM freed or to decode speed,
which is why the original plan noted "the exact order may need to be reversed." `--n-cpu-moe N`
removes that ambiguity: N is directly proportional to VRAM freed and to how much expert compute
moves to CPU, so the search is a standard 1-D optimization, not a heuristic sequence.

If N=0 (baseline) is already the fastest configuration, there is nothing further to search —
this model was CPU-bound for a reason CPU-MoE offload doesn't fix (see §16, outcome 2).

If a large N clearly beats baseline, narrow around it. If nothing beats baseline, stop — do not
proceed to the sub-tensor regex refinement in §4.

## 9. Sub-Tensor-Selective CPU-MoE (Optional Phase 2)

Only relevant if §8's `--n-cpu-moe` bisection produces a clear win and the model is still VRAM-
constrained at the batch size that maximizes decode.

At that point, the sub-tensor regex from §4 (`-ot ".ffn_(up|down)_exps.="`, `-ot
".ffn_(up)_exps.="`, etc.) can be tried as a finer adjustment on top of the winning `N`. This is
a second-stage search and should not be entered until §8 has established that CPU-MoE placement
itself is worthwhile for this model — there is little value in testing multiple sub-tensor
patterns before that is established.

## 10. CPU-MoE Versus Batch Size

Batch size and CPU-MoE solve different problems.

Batch size primarily affects how efficiently the GPU processes batches of tokens, particularly during prompt processing/prefill.

CPU-MoE placement affects model residency and can materially affect decode performance.

The existing benchmark data already shows that batch size can strongly affect prefill performance. Therefore batch optimization should remain part of the normal model configuration process.

However, once a model is clearly CPU-bound, optimizing batch size alone cannot necessarily solve the underlying problem.

A larger batch cannot make CPU-resident model computation GPU-resident.

Therefore:

```
batch optimization
    = GPU workload efficiency
```

while:

```
CPU-MoE optimization
    = model/tensor placement
```

Both may be useful, but they should not be conflated.

## 11. Recommended Integration With Existing Benchmarking

The intended benchmark pipeline should conceptually become:

```
1. Determine viable context size.
2. Determine appropriate batch size (cmd_bisect_discover, existing).
3. Benchmark baseline inference (cmd_bench, existing).
4. Inspect GPU/CPU utilization and placement from the recorded JSON.
5. Apply the §7 trigger: placement=="CPU" AND avg_gpu_util_pct<50.
   If not met, finish.
6. If met, enter CPU-MoE search (§8): bisect --n-cpu-moe N against decode t/s.
7. Select the best CPU-MoE configuration based primarily on decode tok/s (§13/§14).
8. Retest batch size around the winning CPU-MoE configuration (§12) — CPU-MoE changes
   available VRAM, so the previously-optimal batch may no longer be optimal.
8.5. If the model is MTP-tuned (spec-type=draft-mtp), re-run MTP tuning (n_max/p_min) at the
     winning CPU-MoE + batch configuration. The VRAM/compute balance CPU-MoE changes is exactly
     what the MTP tuning was optimized against, so a stale n_max/p_min can no longer be assumed
     valid. If the draft model is also large enough to matter, `--spec-draft-cpu-moe` /
     `--spec-draft-n-cpu-moe` are independent settings worth a small sweep of their own —
     scope this only after the main-model CPU-MoE + batch + MTP settings are locked in.
9. Record the resulting configuration (cmd_bench, extended per §19).
```

The important point is that CPU-MoE should not necessarily be another dimension blindly multiplied into the existing benchmark matrix.

It should be a conditional optimization pass triggered by evidence.

**Existing code that must change to support this** — see §19 for exact locations.

## 12. Why the Retest of Batch Size (and MTP) Matters

Changing CPU-MoE placement changes available GPU memory and potentially changes the computational bottleneck.

Therefore a batch size that was optimal before CPU-MoE optimization may not remain optimal afterward. The same applies to MTP `n_max`/`p_min` for the two MTP candidate models (§11 step 8.5) — both were tuned against a VRAM/compute balance that CPU-MoE offload directly changes.

The efficient strategy is not:

```
CPU-MoE × every batch size × every MTP setting
```

Instead:

```
establish baseline batch
    ↓
optimize CPU-MoE (--n-cpu-moe bisection)
    ↓
perform a small batch-size refinement around the winning CPU-MoE configuration
    ↓
if MTP model: re-tune n_max/p_min at the new batch + CPU-MoE configuration
```

This dramatically reduces the number of required benchmarks.

## 13. Determining Whether a Configuration Is Actually Better

The benchmark should not select a CPU-MoE configuration merely because it increases GPU utilization.

For example:

```
Configuration A
GPU: 35%
CPU: 1565%
Decode: 34.5 tok/s

Configuration B
GPU: 70%
CPU: 1000%
Decode: 32 tok/s
```

Configuration B is not better for an interactive workload simply because GPU utilization doubled.

Conversely:

```
Configuration C
GPU: 65%
CPU: 1200%
Decode: 40 tok/s
```

would be a meaningful improvement.

The benchmark-selection criterion should therefore remain decode throughput, with GPU/CPU utilization used to explain the result.

## 14. Success Criterion (Concrete Threshold)

A CPU-MoE optimization should be considered worthwhile only if it produces a meaningful performance improvement over the baseline — one clearly outside normal benchmark noise, not just a nominally higher number.

**Threshold: require a >5% decode t/s improvement over baseline before adopting a non-baseline
`--n-cpu-moe` configuration.** When two candidates are within 5% of each other, take repeated
measurements rather than trusting a single run — `cmd_bisect_discover` already does exactly this
for batch-size rungs ("three measurements per rung," tools/bench.sh:3543) and that same
machinery should be reused here rather than building a separate repeat mechanism.

Example: `baseline = 34.5 tok/s, CPU-MoE = 34.8 tok/s` is within the noise band and should not
be adopted. `baseline = 34.5 tok/s, CPU-MoE = 40.2 tok/s` (+16.5%) clearly is.

5% is a starting point, not a fixed law — if implementation reveals the batch-search noise floor
in this pipeline is meaningfully different, adjust this threshold to match, but pick a number
before implementation rather than leaving it open-ended.

## 15. Important Architectural Question — What "CPU" Placement Currently Means

Before implementing the search, confirm exactly what today's `placement == CPU` represents for
these models, rather than assuming it already means "only expert tensors are on CPU."

With `ngl = -1` (attempt to offload all layers) and no `override-tensor`/`cpu-moe` setting, when
a model doesn't fit in 12 GiB, llama.cpp's default layer-fitting most likely leaves **entire
layers** — attention and experts together — on CPU for however many layers don't fit, rather
than selectively sparing only the cheap attention computation. If that is what's happening, it
is a stronger case for this plan than the original wording suggested: `--n-cpu-moe N` would let
every layer's attention/shared tensors stay GPU-resident while only the (much larger, but
only-fractionally-active) expert tensors move to CPU — a strictly better placement than today's
whole-layer split, not merely an alternative one.

Confirm this empirically rather than assuming it: grep a candidate model's load log for
`load_tensors: layer N assigned to` (or the equivalent line in this llama.cpp build) to see
whether attention tensors for the "spilled" layers are currently CPU- or GPU-resident. This
should be a five-minute check before writing the search code, since it changes how much benefit
to expect.

## 16. Expected Outcome

There are three possible outcomes for a CPU-MoE candidate.

The first is a clear improvement. This means CPU-MoE successfully freed VRAM in a way that increased useful GPU execution and reduced the CPU bottleneck.

The second is essentially no change. This would indicate that the current bottleneck is elsewhere, or that the saved VRAM does not translate into useful additional GPU residency.

The third is degradation. This would indicate that CPU↔GPU traffic associated with the expert tensors costs more than the GPU-residency benefit gained elsewhere.

All three outcomes are useful benchmark results.

## 17. Scope

The initial implementation should be conservative.

The objective is not to build a general-purpose optimizer for every possible llama.cpp tensor-placement pattern.

The objective is to determine whether CPU-MoE provides a meaningful performance improvement for the large MoE models that currently exhibit severe GPU underutilization.

The first target should be `glm-4.7-30b-a3b-flash-q4-64k` (non-MTP, simplest — see §6), where
the existing benchmark provides unusually strong evidence of CPU-bound execution and there is no
MTP re-tune step to build yet.

Once the search logic works and demonstrates measurable benefit, extend it to the MTP
candidates (`qwen-3.6-35b-a3b-q4-mtp-64k`, `tiel-coder-35b-a3b-q4-mtp-128k-think`) with the §11
step 8.5 re-tune, then generalize to other CPU-bound MoE models identified by the §7 gate.

## 18. Key Principle

The central principle for the implementation is:

"Do not optimize for maximum GPU residency. Optimize for maximum inference throughput given the available VRAM."

For dense models, these objectives are often closely aligned.

For large MoE models on a 12 GB GPU, they may not be.

That is the reason CPU-MoE placement deserves a conditional optimization stage in the benchmark.

## 19. Implementation Notes (for the implementer)

Concrete, file-anchored notes so this doesn't need re-deriving from the narrative above.
Line numbers are as of this review (2026-09-10) and may drift — anchor on function/variable
names first.

- **New `models.ini` key(s):** add `n-cpu-moe = N` (integer) to a model section when CPU-MoE
  offload is the winning configuration; treat `N == n_layers` as equivalent to `cpu-moe = true`
  if a boolean form is preferred for the all-experts case. Follow the existing `set_key`
  pattern already used for `spec-draft-n-max`/`spec-draft-p-min` (tools/bench.sh) for
  reading/writing this into the ini section.

- **Fix the classification gate.** `cmd_bisect_discover`'s `SIMPLE_NONMTP` check
  (tools/bench.sh:3537–3541) currently only excludes models with `spec-type=draft-mtp` or
  `override-tensor` set. Add the new key(s) to this check:
  ```bash
  if ! grep -q "spec-type.*draft-mtp" <(read_section) \
     && ! grep -q "override-tensor" <(read_section) \
     && ! grep -q "n-cpu-moe" <(read_section) \
     && ! grep -q "cpu-moe" <(read_section); then
    SIMPLE_NONMTP=1
  fi
  ```
  Without this, a CPU-MoE-configured model will be misclassified as "simple" and skip the
  residency/decode-cliff checks it actually needs (decode is not batch-independent once experts
  are offloaded).

- **Extend `cmd_bench`'s JSON schema additively.** The `config` block already reads `ngl`
  (tools/bench.sh: `kv(sec, 'ngl', kv(star, 'ngl'))`, appears twice). Add a sibling
  `n_cpu_moe` field read the same way, defaulting to `null`/absent for models that don't set it
  — this must not change the meaning of existing fields or break `gen_metrics.sh`'s parsing of
  older JSON records.

- **Add a column to `tools/gen_metrics.sh`'s table.** Without this, two configs that differ
  only in CPU-MoE placement will render identically in `full-metrics.md`, which is the document
  the §7 candidate list is (and will continue to be) read from.

- **Reuse, don't rebuild, the repeat-measurement infrastructure.** `cmd_bisect_discover`
  already takes multiple measurements per rung (tools/bench.sh:3543 comment: "three
  measurements per rung"). The §14 near-baseline repeat check should call into the same
  mechanism rather than adding a parallel one.

- **New model-family sequencing:** implement the search as a new discover-style subcommand
  (mirroring `cmd_bisect_discover` / `cmd_mtp_discover` naming) rather than folding it into
  `cmd_bisect_discover` itself — it has a different trigger condition (§7) and a different
  search variable (`n-cpu-moe`, not `batch-size`), and should be able to run independently for
  ad-hoc testing (`bench.sh cpumoe <model>`), the same way `bisect` and `mtp` are independently
  invokable today.
