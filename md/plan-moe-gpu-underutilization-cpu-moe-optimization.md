# MoE GPU Underutilization and CPU-MoE Optimization Plan

**Date:** 2026-09-10
**Purpose:** Determine whether targeted CPU-MoE offloading can improve inference performance for large MoE models on an RTX 3060 12 GB, and determine how this should fit into the existing `bench.sh` optimization process.

## 1. Problem

The current benchmark results show a substantial difference between models that fit primarily on the GPU and larger MoE models that do not.

The 9B-class models are generally GPU-resident. For example, Qwen 3.5 9B at 64K context achieves approximately 57.1 tok/s decode with 84% GPU utilization and only about 7.5 GiB of VRAM usage.

The larger MoE models show a very different pattern. Qwen 3.6 35B-A3B at 64K achieves approximately 34.5 tok/s, but reports only 34% GPU utilization while consuming approximately 1,565% CPU. GLM-4.7 30B-A3B at 64K similarly achieves 34.0 tok/s with only 35% GPU utilization and approximately 1,567% CPU. TIEL Coder 35B-A3B reaches only 21.8 tok/s with 21% GPU utilization and approximately 1,460% CPU.

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

The benchmark data provides strong evidence that this is worth investigating for the large MoE models.

Qwen 3.6 35B-A3B at 64K:

* Decode: 34.5 tok/s
* GPU utilization: 34%
* CPU utilization: ~1,565%
* VRAM: ~10.9 GiB
* Placement: CPU

GLM-4.7 30B-A3B at 64K:

* Decode: 34.0 tok/s
* GPU utilization: 35%
* CPU utilization: ~1,567%
* VRAM: ~11.0 GiB
* Placement: CPU

TIEL Coder 35B-A3B at 128K:

* Decode: 21.8 tok/s
* GPU utilization: 21%
* CPU utilization: ~1,460%
* VRAM: ~10.8 GiB
* Placement: CPU

These models are using almost all available VRAM while nevertheless keeping the GPU relatively underutilized.

This suggests that simply increasing GPU layer count is not necessarily the correct optimization strategy.

## 4. What CPU-MoE Is Intended to Accomplish

The purpose of CPU-MoE testing should be to determine whether moving selected MoE expert tensors to CPU allows the remainder of the model to become more GPU-resident.

For example, llama.cpp supports tensor overrides such as:

```
-ot ".ffn_.*_exps.=CPU"
```

This can move MoE expert tensors to CPU.

More selective patterns can be used, such as:

```
-ot ".ffn_(up|down)_exps.=CPU"
```

or:

```
-ot ".ffn_(up)_exps.=CPU"
```

The exact tensor names and resulting placement need to be verified against the actual model architecture and llama.cpp behavior rather than assumed.

The desired outcome is not maximum CPU-MoE offloading.

The desired outcome is the configuration that maximizes useful inference performance.

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

The current benchmark data suggests the following priority.

Qwen 3.6 35B-A3B is an especially strong candidate. Its 64K configuration produces 34.5 tok/s while using only 34% GPU and approximately 1,565% CPU.

GLM-4.7 30B-A3B is another strong candidate. Its 64K configuration produces 34.0 tok/s with only 35% GPU and approximately 1,567% CPU.

TIEL Coder 35B-A3B is also a candidate, although its lower decode speed and 128K context make it a somewhat different workload.

The 9B models should not automatically undergo CPU-MoE optimization.

Qwen 3.5 9B is already GPU-resident with approximately 84% GPU utilization at 64K. Ornith 1.5 9B is also GPU-resident. There is no evidence from the current data that deliberately moving their MoE experts to CPU would improve performance.

CPU-MoE testing should therefore be conditional rather than universal.

## 7. Avoiding a Combinatorial Benchmark Explosion

CPU-MoE should not be tested across every combination of:

```
model × context × batch × CPU-MoE configuration × MTP configuration × reasoning mode
```

That would create a large and mostly unnecessary benchmark matrix.

The existing benchmark should first establish a baseline configuration for each model.

Only models that meet a CPU-bound criterion should enter CPU-MoE optimization.

For example, a model could become a CPU-MoE candidate when:

```
placement == CPU
```

and GPU utilization is substantially below saturation.

A precise threshold should be selected based on the existing benchmark behavior rather than arbitrarily hard-coded.

The purpose is to distinguish models where CPU-MoE could plausibly recover GPU utilization from models that are already performing appropriately.

## 8. Recommended Search Strategy

CPU-MoE testing should be hierarchical.

First benchmark the existing configuration.

If the model is already GPU-resident and performing well, stop.

If the model is CPU-bound, test a small number of progressively less aggressive CPU-MoE configurations.

Conceptually:

```
baseline
    ↓
all MoE experts on CPU
    ↓
up/down experts on CPU
    ↓
up experts on CPU
```

The exact order may need to be reversed depending on the current tensor placement and how much VRAM each configuration frees.

The important point is that the search should be coarse-to-fine rather than exhaustive.

If one configuration clearly performs worse than the baseline, there is little reason to explore increasingly similar configurations in that direction.

If a CPU-MoE configuration produces a substantial improvement, the search can then investigate more granular placement.

## 9. Layer-Selective CPU-MoE

The next optimization level is layer-selective placement.

For example, an override conceptually equivalent to:

```
layers 0–5: GPU
layers 6+: CPU-MoE
```

allows the benchmark to keep some layers completely GPU-resident while moving expert tensors from later layers to CPU.

This may be particularly useful if the amount of VRAM required to keep the entire model's ordinary/shared layers on GPU is only slightly greater than the available VRAM.

The search should therefore potentially include:

```
all layers
later layers only
progressively earlier/later boundaries
```

However, this should be a second-stage search.

There is little value in testing dozens of layer boundaries until it has been established that CPU-MoE itself improves performance.

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
2. Determine appropriate batch size.
3. Benchmark baseline inference.
4. Inspect GPU/CPU utilization and placement.
5. If clearly GPU-resident, finish.
6. If clearly CPU-bound MoE, enter CPU-MoE search.
7. Select the best CPU-MoE configuration based primarily on decode tok/s.
8. Optionally retest batch size around the winning CPU-MoE configuration.
9. Record the resulting configuration.
```

The important point is that CPU-MoE should not necessarily be another dimension blindly multiplied into the existing benchmark matrix.

It should be a conditional optimization pass triggered by evidence.

## 12. Why the Retest of Batch Size Matters

Changing CPU-MoE placement changes available GPU memory and potentially changes the computational bottleneck.

Therefore a batch size that was optimal before CPU-MoE optimization may not remain optimal afterward.

The efficient strategy is not:

```
CPU-MoE × every batch size
```

Instead:

```
establish baseline batch
    ↓
optimize CPU-MoE
    ↓
perform a small batch-size refinement around the winning CPU-MoE configuration
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

## 14. Potential Success Criterion

A CPU-MoE optimization should be considered worthwhile only if it produces a meaningful performance improvement over the baseline.

A small improvement that falls within normal benchmark noise should not cause the configuration to be permanently adopted.

The benchmark should therefore perform repeated measurements when two configurations are close.

For example, if:

```
baseline = 34.5 tok/s
CPU-MoE = 34.8 tok/s
```

the result should not automatically be considered meaningful.

If:

```
baseline = 34.5 tok/s
CPU-MoE = 40.2 tok/s
```

that is clearly worth adopting.

The exact significance threshold can be determined from the benchmark's existing run-to-run variability.

## 15. Important Architectural Question

Before implementing the search, the benchmark code should establish exactly what the current "CPU" placement represents.

The existing metrics table reports:

```
placement = CPU
```

but this does not by itself identify which tensors are CPU-resident.

The implementation should therefore inspect llama.cpp's actual tensor placement or startup output where necessary.

The optimization should answer:

"Which tensors are currently causing the model to become CPU-bound?"

rather than assuming that all CPU placement is caused by MoE experts.

This distinction is important because moving MoE tensors to CPU only helps if doing so allows more valuable tensors to remain on the GPU.

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

The first target should therefore be a model such as Qwen 3.6 35B-A3B at 64K, where the existing benchmark provides unusually strong evidence of CPU-bound execution.

Once the search logic works and demonstrates measurable benefit, it can be generalized to other CPU-bound MoE models.

## 18. Key Principle

The central principle for the implementation is:

"Do not optimize for maximum GPU residency. Optimize for maximum inference throughput given the available VRAM."

For dense models, these objectives are often closely aligned.

For large MoE models on a 12 GB GPU, they may not be.

That is the reason CPU-MoE placement deserves a conditional optimization stage in the benchmark.
