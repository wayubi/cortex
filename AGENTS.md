# AGENTS.md

## Architecture

- **OpenResty** routes `:11434` → ollama, `:8080` → llama-cpp, `:5002` → nllb (HF translation). All three backends run alongside openresty (no profiles).
- `coordinator.lua` runs in the access phase. It tracks both the active backend AND the last requested model name. On every POST request (inference), it extracts the `model` field from the request body. If either the backend OR the model differs from the current state, the coordinator unloads all models from the current backend via its API, then updates state. This prevents llama.cpp's leaky self-unload (which leaves residual VRAM) because all unloads are triggered externally by the coordinator.
- **Only POST requests (inference) can trigger unload or state changes.** GET/HEAD/OPTIONS probes pass through without any action — this prevents Open WebUI polling from bouncing the state or reading bodies unnecessarily.
- Unload flow: `POST /api/generate` with `keep_alive: 0` (ollama), `POST /models/unload` (llama-cpp), or `GET /v1/models` + `POST /v1/models/unload` (nllb). All three backends are queried first to find exactly which model(s) are loaded. When switching away from nllb, a `/shutdown` is also sent.
- The shared `backend_state` dict stores two keys: `"backend"` (which backend last handled inference) and `"model"` (which model name was last requested). Both are used to decide whether an unload is needed.
- Before unloading on cross-backend switches, coordinator drains active POST requests on the current backend (polls `request_counts` up to 30s at 500ms intervals). Same-backend model changes skip drain (only one backend involved).
- Active requests are counted at access phase and decremented via `log_by_lua_block` in each nginx server block.

## Critical naming

The compose service is `llama-cpp` (hyphen), but the Lua internal key is `llama_cpp` (underscore). Use the `HOST` lookup table in `coordinator.lua` to map:
- `HOST["llama_cpp"]` → `"llama-cpp"` (DNS hostname)
- `HOST["nllb"]` → `"nllb"` (DNS hostname)

If adding a new backend, update:
- `HOST` table (DNS hostname for TCP calls)
- `get_target()` in `coordinator.lua` (port → key mapping)
- `log_by_lua_block` in `nginx.conf` (matching decrement key)
- Unload function (API call to free VRAM on that backend)

## Docker compose commands

- `docker compose up -d` — start the entire stack
- `docker compose build openresty` — rebuild OpenResty after Lua/nginx changes
- `docker compose build nllb` — rebuild nllb translation service after changes
- `docker compose --profile build build llama-build` — rebuild llama.cpp image from source
- The internal network is `cortex_network` (compose-managed bridge). External `enhasa_network` must exist before `up`.

## File layout

```
 cortex/
├── compose.yml
├── README.md
├── LICENSE
├── full-metrics.md        # full table of all models.ini entries (regenerate via tools/gen_metrics.sh)
├── CPU_POLLING.md         # correct bench methodology (CPU/GPU placement verification)
├── tools/                 # ALL scripts go here (bench, metrics)
│   ├── bench.sh               # unified pipeline: mtpcheck → bisect → mtp → bench (canonical)
│   └── gen_metrics.sh         # regenerate full-metrics.md from llama-cpp/models/*.json
├── llama-cpp/
│   ├── models.ini          # llama.cpp models preset file
│   ├── models/             # per-model benchmark JSONs (written by bench.sh)
│   └── Dockerfile          # CUDA build from source
├── nllb/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── server.py           # HF translation (NLLB) FastAPI service
├── md/                     # internal planning docs
├── .opencode/              # opencode config
└── openresty/
    ├── Dockerfile           # FROM openresty/openresty:bookworm-fat, sed patches error_log
    ├── nginx.conf           # lua_shared_dict directives, 3 server blocks (11434/5002/8080)
    └── coordinator.lua      # VRAM coordinator — API-based model unload
```

**Rule: All scripts, tools, and utility files go in the `tools/` folder.**

## Pre-flight checklist (BEFORE benchmarking ANY model)

1. **Verify batch-size/ubatch-size is EXPLICITLY set** in `models.ini` for the target `[model]` entry
2. **If not set, it inherits 4096 from `[*]` — this is WRONG** and must be tuned first
3. **Run batch tuning** (`./tools/bench.sh bisect <model>`, discover mode by default) before any benchmark — one pass sets the batch and runs the residency / saturation / long-decode gates
4. **THEN run the full bench:** `./tools/bench.sh bench <model>`

**Coder variants are independent models and are benched separately.** No values are copied between entries — run tuning + bench on each coder variant like any other model.

## Batch tuning (discover mode, default)

`bench.sh bisect <model>` finds a practical `batch-size`/`ubatch-size` in roughly a quarter of the runs of the old exhaustive search. It treats **batch as a prefill knob**: for single-stream serving (`parallel = 1`), decode throughput does not depend on batch unless the batch pushes memory (the MTP draft buffer, KV) off the GPU. So batch is picked on the **prefill curve** and *guarded* by a residency check — never ranked by decode t/s.

Why the old search over-resolved: llama.cpp `-fit on` (default, `ngl = -1`) packs weights into VRAM leaving ~zero headroom, and the prefill curve is flat from ~512 up to a few thousand (on the 35B Qwen every rung 512→4096 scored within 3%; two points 64 tokens apart differed by 3%). Refining a ceiling to 64-token granularity, or running golden-section prefill searches, only resolved measurement noise. The ceiling is real but coarse — a model either fits a batch or it does not, and decode only changes where something spills.

Procedure (`cmd_bisect_discover`):
1. `CAP = min(ctx-size, 16384)`. Walk one **coarse ladder** of powers of two from 256 up to CAP, stopping early once two consecutive rungs measure below the running best prefill × `PREFILL_TOL`. **Non-MTP shortcut (Change A):** for a model with no `spec-type=draft-mtp` and no `override-tensor` (no draft to spill, batch-independent decode), residency runs only at rung 256 (to set MODE) and the decode baseline + pick decode-sample are skipped — saturation, long-decode and OOM gates are unchanged.
2. Each rung does **three cheap measurements on the same server instance**: a `tiny_probe` (OOM at load / first decode) → a `residency_probe` (GPU / CPU / AMBIGUOUS verdict; a `CPU` at rung 256 means the model is CPU-compute and residency is skipped thereafter) → a `prefill_probe_sized` using the **same** ~`min(0.75 × ctx, 16384)`-token prompt on every rung, so rungs rank on identical work. A rung that OOMs or spills (`SPILL`) ends the ladder.
3. **Pick = the best-measured PASS point** (`PREFILL_TOL` defaults to **0** — Change C, §30.2). Set `PREFILL_TOL=0.03` if you want to prefer a smaller batch within 3% of best for MTP draft-buffer headroom. Then **noise-aware refinement** (Change E, §30.2b): a ceiling edge (best is the top PASS point, next rung above failed OOM/SPILL) is bisected to a resolution of `max(64, 6% of the lower bound)` (restoring the old 64-token resolution on small-ceiling MoE like qwen-3.6's 448 between 256/512); an interior peak (PASS points both sides of best) probes the midpoint toward the higher neighbour. Refinement keeps going only while a point beats the current best by more than `PREFILL_NOISE` (0.03), so it never chases measurement noise. Refinement points are recorded in the JSON ladder with `status: REFINE`.
4. **Confirm at pick, one restart**: `saturation_test` (~99% ctx, with compaction or ceiling truncation) → `long_decode_check` (real prompt, sustained decode) → on MTP GPU models a `decode_sample` compared against the batch-256 baseline (re-sample once below `DECODE_CLIFF` 0.70× baseline; step down on a CPU placement signature; the 0.90–0.70 band is a WARN, never a failure). Max 2 step-downs to the next lower measured PASS point (refinement points first, then ladder rungs), then fail with the ini restored.
5. Leave the config at the winning value with a comment: `ubatch-size = N ; discover pick (coarse ceiling M PASS)`.

**The coarse ceiling is informational, not authoritative.** It is logged as `ceiling(coarse)=… PASS / … OOM|SPILL` (or `≥ N PASS, not probed higher`) and recorded in the JSON, but nothing downstream consumes it. Do not read it as a guarantee that `N` can safely be raised.

**`--thorough` (or `BENCH_THOROUGH=1`) re-enables the legacy exhaustive search** (`cmd_bisect_thorough`): the golden-section prefill sweep, the 64-token ceiling bisect, the top-5 shortlist decode gate and the saturation-confirm loop. `BENCH_DISCOVER=1` is a deprecated no-op alias for the default discover mode.

### Safety gates (unchanged — never relax these)

- **The OOM log grep is the source of truth, NOT the curl http code.** OOM markers appear seconds after a request — `cudaMalloc failed` / `failed to allocate compute pp buffers` / `terminate called after throwing` / child `exited with status 1`. **MTP models can OOM at LOAD instead** (`failed to create MTP context` / `failed to initialize the context: failed to allocate compute pp buffers` / `exiting due to model loading error`) because the draft context builds its compute buffers eagerly at load. A **third, decode-time signature** appears only during sustained generation: `CUDA error: out of memory ... cuMemCreate(...)` from `ggml_cuda_pool_vmm` (flash-attn workspace growing the VMM pool). Fast grep: `docker logs --since 10s cortex-llama-cpp-1 | grep -E "cudaMalloc failed|failed to allocate compute pp buffers|terminate called after throwing|failed to create MTP context|exiting due to model loading error|CUDA error: out of memory|cuMemCreate"` (<1s). A failed child triggers the router's 10s force-kill, then `model ... failed to load` (HTTP 500) — that 500 is also an OOM signal. The first request after a restart can take >20s (fit + MTP context + warmup) and time out (`http=000`) while the model actually loads fine — verify with a follow-up request.
- **Residency / spill rejection.** A `CPU` verdict rejects a batch for GPU-class models. `-fit` never budgets the **MTP draft's** memory (`failed to measure the memory of the extra model, fitting without it`), so on tight models the draft silently lands on CPU even when the main model fits — a batch can pass every OOM test yet decode slowly with high CPU. A silent spill shows decode dropping 3–4× with CPU climbing to 270–1600% (observed Gemma 12B Q6: 59.8 t/s on GPU vs 36 t/s with the draft on CPU). **A 600-token decode with 50s polling is NOT enough** — models show ~100% CPU in the first 50s then spike to 1300%+. Use 4000+ tokens and 160s polling. On CPU-compute models every batch is CPU-resident, so only the prefill curve matters and it peaks low (~1.5–2K). To shrink a spilled draft: `spec-draft-type-k/v = q4_0` (draft KV, default f16) and a smaller batch. Do NOT use `spec-draft-ngl` to force the draft to GPU — that drops main-model layers to CPU instead (worse).
- **Saturation at ~99% ctx.** The tiny probe only proves the compute graph fits at near-empty context. `-fit` leaves ~zero headroom, so the true memory peak is near full context (KV-compaction temp buffers, hybrid/SSM state re-derivation) — a value that survives a tiny decode can still OOM once the context fills and compacts, and the PP graph is far larger than the tiny probe's decode graph. Only a successful ~99%-ctx saturation run validates the pick. On hybrid/SSM models the server truncates at the ceiling (`truncated = 1`, `finish_reason = length`) rather than KV-shifting — full-context saturation is still reached, which is the point.
- **Long-decode check.** The repetitive saturation filler yields high draft acceptance and can **mask a decode-time OOM** (real text with lower acceptance churns the flash-attn VMM workspace until `cuMemCreate`) — e.g. `qwen-3.5-9b-q4-mtp-16k-think` passed saturation at batch 2048 but OOM'd at `n_decoded ≈ 5.4K` on a real generation. Always run the real-prompt sustained-generation check on the final pick.
- **ini restore on any failure exit.** Both tuners snapshot the section and restore it on a non-zero EXIT trap (Ctrl-C included). A killed run leaves `models.ini` at its pre-run values.

Proven gotchas:
- The OOM happens on first **decode**, not at load — **unless the model uses MTP spec decoding**, in which case large batches can OOM at LOAD during draft-context creation before any request. A load-only probe (GET `/v1/models` / waiting for `model loaded`) is never sufficient — send a real inference request.
- **`reasoning=on` can sustain a larger batch than `reasoning=off`** on the same GGUF/ctx (observed: Qwen3.5-9B-MTP @ 16K sat-max 2048 with `reasoning=on` vs 1984 with `reasoning=off`). Don't assume the non-think tuned value transfers to the think sibling — tune them separately.
- **Gemma 4 QAT (gemma4 / gemma4-assistant arch):** the MTP drafter is a **separate GGUF** (`mtp-gemma-4-12B-it.gguf`) that recent llama.cpp auto-discovers from `-hf` — requires a build that knows the `gemma4-assistant` architecture. At load it logs a **benign** `failed to initialize the context: Gemma4Assistant requires ctx_other to be set` plus `failed to measure the memory of the extra model, fitting without it` — the fit excludes the draft, so the real VRAM peak exceeds fit's estimate. The dense 12B has a small per-unit compute graph, so its batch ceiling is far higher than MoE models (~8.6K vs 576). Think toggle via `reasoning = on/off` (enable_thinking via chat-template-kwargs is deprecated).
- The MTP draft's own VRAM: on a model whose main weights nearly fill VRAM the draft lands on CPU even when the main fits. Observed: Gemma 12B Q6 @ 16K — batch 3584 survived OOM but ran the draft on CPU (~730% CPU, 35 t/s); batch 1088 keeps it on GPU (~81% CPU, 60 t/s); 1152+ spills it again.
- Lowering `ctx-size` does NOT reliably create batch headroom — `-fit` simply repacks more weights into the freed VRAM.
- If even tiny batches OOM, the only real fix is freeing VRAM: `override-tensor = exps=CPU` (experts to system RAM).
- The `[*]` preset default `batch-size`/`ubatch-size = 4096` is a deliberate **fallback for untuned entries** — it is NOT a tuning starting point. It OOMs immediately on most untuned entries, which is the signal to run `bench.sh bisect` and override per `[model]`. Never run an untuned entry at 4096.

## Tuning MTP speculative decoding (spec-draft-n-max / spec-draft-p-min)

Only applies to MTP models (`spec-type = draft-mtp`). n_max and p_min are **speed-only knobs**. Speculative decoding preserves the target's output distribution by construction: llama.cpp's `common_sampler_sample_and_accept_n` samples every position from the target model and keeps a draft token only when it equals the target's own sample, so MTP never emits a token the target wouldn't. `p_min` only stops drafting early; `n_max` only bounds draft length. Observed token differences between MTP on and off are near-tie flips under ~0.1-nat kernel logit noise — the same class of difference as changing `batch-size`.

Params:
- `spec-draft-n-max` — draft tokens predicted ahead per decode step (repo default 2). Higher = more speed IF accepted, but later draft tokens drop in acceptance → wasted target re-verification. Raises the draft-context buffer (`n_max × batch`).
- `spec-draft-p-min` — stop drafting below this probability. A tuning lever for draft yield; it does not gate output quality (see above).
- (`spec-draft-n-min` shows as `n_min=0` at load and is not preset-controlled.)

### Benchmark method (`cmd_mtp_discover`, default)

**The placement gate is the real constraint, not quality.** A config whose `decode_sample` reports placement `CPU` or `oom > 0` is rejected as *not fitting at this batch*. Degeneracy is **diagnostic only** — logged, `WARN`-flagged when the 8-gram ratio exceeds 0.15, never a gate, and computed only on natural-stop output.

`cmd_mtp_discover` runs an **adaptive sweep** (~6–8 decode runs) over natural-stop samples:
1. **n_max ladder at p_min=0.7.** Start from `{2, 4, ini's n_max}` — always include the current ini value, because the batch ladder already validated residency at it and it is guaranteed to pass the placement gate. Extend to untested neighbours of the best within [2,6]. Re-measure the best and runner-up once and rank on the mean of their two samples; ties (within `MTP_TIE`, ~5%) go to the smaller n_max (smaller draft buffer, more headroom).
2. **p_min at the winning n_max.** Measure `{0.5, 0.9, ini's p_min}` minus 0.7, compare against the 0.7 reference already measured in phase 1; keep 0.7 if within tie tolerance.
3. Failure is now only STALL, every candidate rejected by placement/OOM, or every sample SHORT — never a degeneracy value. The ini's `n_max`/`p_min` are restored on failure.

**`--thorough` (or `BENCH_THOROUGH=1`) re-enables the legacy exhaustive tuner** (`cmd_mtp_thorough`): the fixed n_max sweep {2,3,4,5}, the p_min sweep {0.5,0.6,0.7,0.8,0.9}, and the strict <0.05 degeneracy confirm gates. It measures decode the same natural-stop way (see "Measuring decode speed"); only the *search* is preserved, not the old loop-inflated measurement.

**`bench.sh mtpverify <model>`** is a diagnostic subcommand that empirically checks the speed-only claim. It runs the model MTP-off then MTP-on with request-level `temperature: 0`, `seed: 42`, `logprobs`, `top_logprobs`, finds the first diverging token, and applies an **OFF-only margin test** (the MTP-off run is the reference sampler and carries probabilities at every position; MTP-on positions where a draft was accepted have none). PASS = the on-chosen token is in the off-run's top-10 at the divergence index with `gap_off < MTP_TIE_NATS` (0.25). Use it to confirm the premise on any family without reading llama.cpp source.

### Acceptance rate / degeneracy
`draft acceptance` is a rough signal, never a gate — acceptance dropping because n_max was raised is only wasted draft compute (rejected drafts are recomputed by the target, quality preserved). Degeneracy above 0.15 is a `WARN` diagnostic (it can flag a genuinely looping run worth investigating), not a model failure.

### Placement re-check
**Mandatory after any n_max change.** Draft-context compute buffer scales with `n_max × batch` — a batch tuned at n_max=2 may NOT fit the draft at n_max=3+. The spill is silent: no OOM, just decode dropping 3–4× and CPU climbing to 270–680%. Re-run placement at the SAME batch after changing n_max. **Tradeoff: raising n_max shrinks the batch ceiling (draft buffer = n_max × batch).** On ornith 128k/256k, n_max=2 at the full batch decoded equal-or-faster than n_max=3 at its reduced ceiling, so n_max=2 won.

### MTP draft VRAM
- The MTP draft has its own VRAM that `-fit` never budgets (`failed to measure the memory of the extra model, fitting without it`). On a model whose weights nearly fill VRAM the draft lands on CPU even when the main model fits. Shrink the draft KV with `spec-draft-type-k/v = q4_0` (default f16) and reduce the batch so both fit. Do NOT use `spec-draft-ngl` to force the draft to GPU — that drops main-model layers to CPU instead (worse).
- **Gemma 4 QAT:** the MTP drafter is a separate GGUF auto-discovered from `-hf`; requires a build that knows the `gemma4-assistant` arch. The `failed to initialize the context: Gemma4Assistant requires ctx_other to be set` + `failed to measure...` lines at load are benign. Older "n_max=4 degraded, 5 clean" type observations were artefacts of **forced generation** (an essay prompt run past EOS with `ignore_eos`, which loops) — the natural-stop measurement in `decode_sample` removes that confound.

## Measuring decode speed (`decode_sample`)

Speed samples never force tokens past EOS. `decode_sample` measures decode on **natural-stop output** — **no `ignore_eos`** — using a prompt that reliably produces ≥1500 tokens without forcing, and requires the sample to reach `MIN_DECODE_TOKENS` (512) to be valid (retried once with a longer prompt, else tagged `SHORT` and treated as missing, never a failure). Heading lines (starting with `#`) are stripped before the 8-gram degeneracy count so structural scaffolding does not inflate it. `ignore_eos` is kept **only** where the purpose is a memory-pressure test (`saturation_test`, `long_decode_check`). Why: forcing tokens past EOS makes a model loop, and looped text gets near-perfect draft acceptance — a config that degrades to repeating output can look like the *fastest* one. Natural-stop measurement is what makes degeneracy safe to treat as diagnostic.

## Result recording

The tuners write diagnostic JSON that `cmd_bench` merges into the model's bench JSON. `/tmp/mtp_status_<model>.json` records `tuning_status` (`ok` / `failed` / `stall` / `not_mtp` / `not_run`) plus `tuned_n_max` / `tuned_p_min` (null unless ok), merged under the JSON's `mtp` key; `/tmp/discover_<model>.json` records the discover ladder and pick, merged under the `discover` key. A failed MTP tuning no longer reads as validated downstream. The old `n_max_confirmed` / `p_min_confirmed` fields are renamed `n_max_loaded` / `p_min_loaded` — they mean only "what the server loaded", never "tuned". `mtp_status not_run` (or a missing `tuning_status`) means tuning never ran or the JSON predates the field; MTP values are not inherited from such parents. Both status files carry a `written_at` timestamp (copied to `mtp.tuning_written_at`) so a stale file merged into a later bench is visible. By default a failed `cmd_mtp` still lets `cmd_bench` run (recording `tuning_status: failed`); pass **`--strict`** to skip `cmd_bench` for that model and mark the verdict `SKIPPED (mtp failed)` — use it when producing publishable records.

## Gotchas

- `coordinator.lua` uses `ngx.socket.tcp` for HTTP calls to the backends. If those calls fail (e.g., backend not ready), the request still proceeds — the user may get an OOM if VRAM wasn't freed. The unload is best-effort.
- Variable-based `proxy_pass` (`set $upstream "http://host:port"`) is required because backends resolve at request time (not config load). The `resolver 127.0.0.11` directive enables runtime DNS re-resolution.
- Two `lua_shared_dict` directives in `nginx.conf`: `backend_state` and `request_counts`. Both live in the conf.d file which is included inside the `http {}` block — valid by default in the `bookworm-fat` image config.
- ollama unload uses `keep_alive: 0` on a generate request. This evicts the model and KV cache immediately. Without this flag, ollama keeps the model resident per its configured `OLLAMA_KEEP_ALIVE`.
- llama-cpp unload uses `POST /models/unload` with the model ID. Only models with `status.value == "loaded"` are targeted (queried from `/v1/models`).
- `coordinator.lua` logs every request, switch decision, and unload result via `ngx.log`. View with `docker logs -f cortex-openresty-1 | grep -E "request:|skip:|switch:|drain|state:|ollama:|llama-cpp:|nllb:"`. The `error_log /proc/self/fd/2 info;` directive is patched into the main nginx.conf via `sed` in the Dockerfile — INFO-level messages appear in `docker logs`.
- The drain loop calls `ngx.sleep(0.5)` in the access phase, blocking the nginx worker for up to 30s during a switch. Switches are rare, so this is acceptable — but do not increase the timeout without understanding the concurrency impact.
- `get_model()` reads the request body via `ngx.req.read_body()` in the access phase. This does not consume the body — nginx still forwards it to the upstream. If body parsing fails (malformed JSON, no `model` field), `get_model()` returns nil and the coordinator proceeds conservatively (unloads on backend mismatch, skips on same-backend model change).
- `models-max` must NOT be set on llama.cpp. If the router limits concurrent children, it auto-unloads models when the limit is exceeded, which races against the coordinator's explicit `/models/unload` and leaves residual VRAM (orphan child process). The coordinator is the sole source of truth for unloads — remove `models-max` entirely to disable router-initiated teardown.
- `OLLAMA_MAX_LOADED_MODELS=1` is set in compose.yml. `OLLAMA_KEEP_ALIVE` is NOT set — defaults to 5m.
