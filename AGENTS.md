# AGENTS.md

## Architecture

- **OpenResty** routes `:11434` → ollama, `:8080` → llama-cpp. Both backends run alongside openresty (no profiles).
- `coordinator.lua` runs in the access phase. It tracks both the active backend AND the last requested model name. On every POST request (inference), it extracts the `model` field from the request body. If either the backend OR the model differs from the current state, the coordinator unloads all models from the current backend via its API, then updates state. This prevents llama.cpp's leaky self-unload (which leaves residual VRAM) because all unloads are triggered externally by the coordinator.
- **Only POST requests (inference) can trigger unload or state changes.** GET/HEAD/OPTIONS probes pass through without any action — this prevents Open WebUI polling from bouncing the state or reading bodies unnecessarily.
- Unload flow: `POST /api/generate` with `keep_alive: 0` (ollama), or `POST /models/unload` (llama-cpp). Both backends are queried first (ollama: `/api/ps`, llama-cpp: `/v1/models`) to find exactly which model(s) are loaded.
- The shared `backend_state` dict stores two keys: `"backend"` (which backend last handled inference) and `"model"` (which model name was last requested). Both are used to decide whether an unload is needed.
- Before unloading on cross-backend switches, coordinator drains active POST requests on the current backend (polls `request_counts` up to 30s at 500ms intervals). Same-backend model changes skip drain (only one backend involved).
- Active requests are counted at access phase and decremented via `log_by_lua_block` in each nginx server block.

## Critical naming

The compose service is `llama-cpp` (hyphen), but the Lua internal key is `llama_cpp` (underscore). Use the `HOST` lookup table in `coordinator.lua` to map:
- `HOST["llama_cpp"]` → `"llama-cpp"` (DNS hostname)

If adding a new backend, update:
- `HOST` table (DNS hostname for TCP calls)
- `get_target()` in `coordinator.lua` (port → key mapping)
- `log_by_lua_block` in `nginx.conf` (matching decrement key)
- Unload function (API call to free VRAM on that backend)

## Docker compose commands

- `docker compose up -d` — start the entire stack
- `docker compose build openresty` — rebuild OpenResty after Lua/nginx changes
- `docker compose --profile build build llama-build` — rebuild llama.cpp image from source
- The internal network is `cortex_network` (compose-managed bridge). External `enhasa_network` must exist before `up`.

## File layout

```
cortex/
├── compose.yml
├── README.md
├── LICENSE
├── BENCHMARKS.md          # all batch/MTP/quality bench results (configs, t/s, acceptance)
├── llama-cpp/
│   ├── models.ini          # llama.cpp models preset file
│   └── Dockerfile          # CUDA build from source
└── openresty/
    ├── Dockerfile           # FROM openresty/openresty:bookworm-fat, sed patches error_log
    ├── nginx.conf           # lua_shared_dict directives, 2 server blocks
    └── coordinator.lua      # VRAM coordinator — API-based model unload
```

## Stress-testing batch/ubatch (proven procedure)

Finding the max `batch-size`/`ubatch-size` a model fits in VRAM. Goal: the highest value that survives a real decode **with the compute actually on GPU** — the ceiling is two-sided: too high OOMs, and just below the OOM ceiling the **MTP draft can silently spill to CPU** (slow decode + heavy CPU). See the placement check in step 8.

Why: llama.cpp `-fit on` (default, `ngl = -1`) packs weights into VRAM leaving ~zero headroom. The compute graph (PP/prefill buffers) is allocated lazily on the **first decode**, not at load — a model can load fine and then crash on the first request with `failed to allocate compute pp buffers`. The PP buffer scales ~linearly with ubatch (~2 MiB per unit on the 35B Qwen), so bigger batch = faster prefill up to the OOM ceiling.

Procedure (per candidate value):
1. Edit `llama-cpp/models.ini` for the target `[model]` entry: set `batch-size` and `ubatch-size` to the **same** value (`batch-size` must equal `ubatch-size`). Keep the target `ctx-size`.
2. `docker compose restart llama-cpp` — the router reads models.ini only at startup, so every value change needs a restart.
3. Wait for readiness: `curl -sf http://localhost:8080/v1/models` (through openresty) until it returns 200.
4. Fire one tiny inference request so the model loads and decodes:
   `curl -s -X POST http://localhost:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"<model>","messages":[{"role":"user","content":"Say hello"}],"max_tokens":8}'`
5. Watch the log: `docker logs -f cortex-llama-cpp-1`. OOM markers appear **seconds** after the request — `cudaMalloc failed` / `failed to allocate compute pp buffers` / `terminate called after throwing` / child `exited with status 1`. **MTP models can OOM at LOAD instead** (`failed to create MTP context` / `failed to initialize the context: failed to allocate compute pp buffers` / `exiting due to model loading error`) because the draft context builds its compute buffers eagerly at load — large batches fail there before any request. A **third, decode-time signature** appears only during sustained generation: `CUDA error: out of memory ... cuMemCreate(...)` from `ggml_cuda_pool_vmm` (flash-attn workspace growing the VMM pool). Fast OOM grep: `docker logs --since 10s cortex-llama-cpp-1 | grep -E "cudaMalloc failed|failed to allocate compute pp buffers|terminate called after throwing|failed to create MTP context|exiting due to model loading error|CUDA error: out of memory|cuMemCreate"` (<1s).
6. **OOM** → step down and repeat using a **coarse-to-fine sweep** (start from the preset default 4096):
   - **Bracket (down-sweep):** step down by 1024 or halve (`4096 → 2048 → 1024`) until the first **PASS**. This brackets the ceiling: `lo` = highest PASS, `hi` = lowest OOM. (At 4096 the tiny probe crashes on the first decode almost instantly — expected; the coarse sweep's job is to bracket, not to pass.)
   - **Refine (bisect up):** with `lo` = highest confirmed PASS and `hi` = lowest OOM, test midpoints rounded to 64 (`(lo + hi) / 2`): PASS → `lo = mid`, OOM → `hi = mid`. Increments shrink naturally (`512 → 256 → 128 → 64`). Repeat until `hi − lo ≤ 64`; the final `lo` is the max. Example: `1024 PASS, 2048 OOM → 1536 OOM → 1280 OOM → 1152 PASS → 1216 OOM → answer 1152`.
   - **No floor** — if the down-sweep never passes, keep going until it does.
7. **PASS** on the tiny probe → confirm with 2 more requests (expect `http=200`). This is only a **quick filter** — it does NOT prove the value is good (see Phase 2).
8. **Placement check — is the compute actually on GPU?** `-fit` never budgets the **MTP draft's** memory (`failed to measure the memory of the extra model, fitting without it`), so on tight models the draft silently lands on CPU even when the main model fits — a batch can pass every OOM test yet decode slowly with heavy CPU. Verify placement on any quick-filter PASS:
   - Fire a ~600-token decode (`max_tokens` ~600, `ignore_eos`) and, ~10s in, sample the child CPU: `ps -p $(pgrep -f "llama-server --host 127.0.0.1") -o %cpu=`.
   - **On GPU:** CPU ~50–150% and decode t/s at the model's expected speed.
   - **Draft on CPU:** CPU ~300%+ and decode t/s drops sharply (observed Gemma 12B Q6: 59.8 t/s on GPU vs 36 t/s with the draft on CPU).
   - If the draft is on CPU → **step the batch down** (this is a separate, usually lower ceiling than the OOM max). First shrink the draft's footprint with `spec-draft-type-k/v = q4_0` (draft KV cache, default f16), then re-bisect. Do NOT use `spec-draft-ngl` to force it — that drops main-model layers to CPU instead (worse).
9. **Phase 2 — TRUE test: full-context saturation + compaction.** The tiny probe only proves the compute graph fits at near-empty context. `-fit` leaves ~zero headroom, so memory peaks near full context (KV compaction temp buffers, hybrid/SSM state re-derivation) — a value can still OOM once the context fills and compacts. Note the prefill (PP) graph buffer scales ~2 MiB/unit and is **far larger than the tiny probe's decode graph**, so a value that passes the tiny probe can still OOM on a long-prompt prefill — the saturation run re-brackets the winner downward (observed on both the 35B and 9B models).
   - The saturation prompt is sized to the target entry's `ctx-size` (**NOT** a fixed 16K): for `ctx-size = 16384` saturate to ~14.5K tokens; for `ctx-size = 131072` saturate to ~115K tokens. Target ~90% of that ctx.
   - Send one request with a prompt filling ~90% of that ctx and `max_tokens` large enough to overflow it and force KV compaction (~20% of ctx):
     ```
     SAT=$(python3 -c "print(('Qwen3.6-35B-A3B is a hybrid MoE with attention and SSM layers. '*N)[:SIZE])")
     # SIZE ≈ ctx-size * 2.5 chars — measured ~0.35 tokens/char (≈2.8 chars/token) on repeated English.
     # Aim for ≤85% of ctx and verify with usage.prompt_tokens; if the request 400s with
     # "exceeds the available context size", shrink SIZE. Cap below nginx body limit (default 1MB).
     curl -s -X POST http://localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
       -d "{\"model\":\"<model>\",\"messages\":[{\"role\":\"user\",\"content\":\"$SAT\"}],\"max_tokens\":<~20% of ctx>}"
     ```
   - **TRUE PASS** = no OOM markers **AND** `n_past` reaches the ctx limit **AND** the request completes HTTP 200 with the full generation. On pure-attention models a compaction/sequence-removal event appears in the log; on **hybrid/SSM models** (e.g. Qwen3.6) the server instead truncates at the ceiling (`truncated = 1`, `finish_reason = length`) because SSM state can't be KV-shifted — full-context saturation is still reached and that is the point of the test. (You cannot force `ctx-shift` here: the router rejects unknown preset keys with `option 'ctx-shift' not recognized in preset`.)
   - **FAIL** = any OOM marker during prefill/decode/compaction, or a crash before compaction completes → step down by 64 and re-run the whole candidate loop (Phases 1 + 2).
   - **Long-decode check** — the saturation prompt uses repetitive filler, which yields high draft acceptance and can MASK a decode-time OOM (low acceptance → more target recomputes → the flash-attn VMM pool grows until `CUDA error: out of memory ... cuMemCreate`). Observed: `qwen3.5-9b-q4-mtp-think-16k` passed full-context saturation at batch 2048 but OOM'd at `n_decoded ≈ 5.4K` on a real long generation. After the filler saturation passes, also run a **real-prompt, sustained-generation test** (`max_tokens` ~6000, `ignore_eos`) to confirm the value survives long decode:
     `curl -s -X POST http://localhost:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"<model>","messages":[{"role":"user","content":"Write a detailed essay explaining the history of computing."}],"max_tokens":6000,"ignore_eos":true}'`
   - Saturation runs are ~2 min at 16K, growing roughly linearly with ctx — only run them on values that pass the quick filter. For 128K+ ctx, the body nears nginx's default 1MB `client_max_body_size`; raise it or use a tighter prompt if the request returns 413.
10. Leave the config at the winning value with a comment: `ubatch-size = N ; optimized (max, N+64 OOM)`.

Proven gotchas:
- The OOM happens on first **decode**, not at load — **unless the model uses MTP spec decoding**, in which case large batches can OOM at LOAD during draft-context creation (`failed to create MTP context`) before any request arrives. Either way a load-only probe (GET `/v1/models`, or waiting for `model loaded`) is insufficient — you must send a real inference request.
- **`reasoning=on` can sustain a larger batch than `reasoning=off`** on the same GGUF/ctx (observed: Qwen3.5-9B-MTP @ 16K sat-max 2048 with `reasoning=on` vs 1984 with `reasoning=off`). Don't assume the non-think tuned value transfers to the think sibling — bench them separately.
- The tiny 20-token probe is necessary but **not sufficient**. `-fit` leaves ~zero headroom, so the true peak is near full context: a value that survives a 20-token decode can still OOM at full ctx once compaction triggers. Only a successful full-context saturation run (compaction where the model supports it, ceiling truncation on hybrid/SSM) validates the value.
- The **filler saturation prompt can mask a decode-time OOM**: repetitive filler yields high draft acceptance (few target recomputes), so the flash-attn VMM workspace stays small. A real workload with lower acceptance churns that workspace until `CUDA error: out of memory ... cuMemCreate` — a signature that a filler-saturation pass won't reveal. Always run the real-prompt long-decode test on the final value.
- **Gemma 4 QAT (gemma4 / gemma4-assistant arch):** the MTP drafter is a **separate GGUF** (`mtp-gemma-4-12B-it.gguf`) that recent llama.cpp auto-discovers from `-hf` — requires a build that knows the `gemma4-assistant` architecture (the installed May-22 build didn't; a rebuild did). At load it logs a **benign** `failed to initialize the context: Gemma4Assistant requires ctx_other to be set (this warning is normal during memory fitting)` plus `failed to measure the memory of the extra model, fitting without it` — the fit excludes the draft, so the real VRAM peak exceeds fit's estimate (watch for OOMs the fit didn't budget). The dense 12B has a small per-unit compute graph, so batch ceilings are far higher than MoE models (~8.6K vs 576). Think toggle via `reasoning = on/off` (enable_thinking via chat-template-kwargs is deprecated). Also observed: `spec-draft-n-max = 4` produced repeated-output degradation on a long essay while 5 was clean.
- **The MTP draft has its own VRAM that `-fit` never budgets** (`failed to measure the memory of the extra model, fitting without it`). On a model whose main weights nearly fill VRAM, the draft lands on CPU even when the main fits — a batch can pass every OOM test yet decode slowly with high CPU (step 8 placement check). Fix: shrink the draft KV to `spec-draft-type-k/v = q4_0` (default f16) and reduce the batch so both fit. Observed: Gemma 12B Q6 @ 16K — batch 3584 survived OOM but ran the draft on CPU (~730% CPU, 35 t/s); batch 1088 keeps it on GPU (~81% CPU, 60 t/s); 1152+ spills it again. `spec-draft-ngl` forcing the draft to GPU backfires (main layers drop to CPU instead).
- Use the OOM log grep as the source of truth, **NOT** the curl http code. The first request after a restart can take >20s (fit + MTP context + warmup) and time out (`http=000`) while the model actually loads and serves fine — verify with a follow-up request.
- A failed child triggers the router's 10s force-kill, then `model ... failed to load` (HTTP 500). That 500 is also an OOM signal.
- Lowering `ctx-size` does NOT reliably create batch headroom — `-fit` simply repacks more weights into the freed VRAM (e.g. a 1024 batch that OOMs at 64K ctx also OOMs at 16K).
- If even tiny batches OOM, the only real fix is freeing VRAM: `override-tensor = exps=CPU` (experts to system RAM).
- The `[*]` preset default `batch-size`/`ubatch-size = 4096` is a deliberate over-sized **tuning starting point** — it OOMs almost immediately on this GPU and is meant to be overridden per `[model]` entry. Never run an untuned entry at 4096.

## Tuning MTP speculative decoding (spec-draft-n-max / spec-draft-p-min)

Only applies to MTP models (`spec-type = draft-mtp`). Tuning these can improve decode throughput, but quality is the tradeoff — pick the best t/s config that still produces clean output.

Params:
- `spec-draft-n-max` — draft tokens predicted ahead per decode step (repo default 2). Higher = more speed IF accepted, but later draft tokens drop in acceptance → wasted target re-verification.
- `spec-draft-p-min` — **quality guard**: draft tokens below this probability are rejected (target recomputes). Lower = more acceptance but riskier quality; higher = safer but slower.
- (`spec-draft-n-min` shows as `n_min=0` at load and is not preset-controlled.)

Benchmark method (per candidate — same edit/restart/watch style as batch tuning, but the metric is speed + quality, not OOM):
1. Edit the target `[model]` entry's `spec-draft-n-max` / `spec-draft-p-min` in `models.ini`.
2. `docker compose restart llama-cpp`; wait for `/v1/models` 200.
3. Fire a **decode-heavy** request — a real generation task (an essay prompt, NOT filler, so quality is assessable), `max_tokens` ~4000, `ignore_eos: true` to force a stable long decode:
   `curl -s -X POST http://localhost:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"<model>","messages":[{"role":"user","content":"Write a detailed 1000-word essay explaining transformers and MoE"}],"max_tokens":4000,"ignore_eos":true}'`
4. Read the log (`docker logs --since 3m cortex-llama-cpp-1`): grep for `tokens per second` (the speed metric), `draft acceptance = X (a / g)`, and `n_max=…, p_min=…` (confirms params applied).
5. Assess output quality from the saved response — degradation shows as repetition loops, incoherence, or drift (check consecutive-sentence repeats; clean if <~2). `ignore_eos` makes the model ramble past natural endings (`**Revised Final Version…**` / `(End of Thought Process)` restarts) — that is an artifact of forced generation, NOT speculation degradation.
6. Sweep order: n-max first (`{1,2,3,4,5}` at `p_min=0.7`), then p-min (`{0.5,0.6,0.7,0.8,0.9}` at the winning n-max).

Proven observation (Qwen3.5-9B-MTP @ 16K): the **non-think** variant was **flat at ~58 t/s (57.6–58.8)** across the whole n_max×p_min space — neither param moved the needle, quality clean everywhere. The **think** variant differed: p_min showed a monotonic speed trend (lower=faster: 0.9→52.7, 0.7→56.3, 0.5→58.9, 0.3→58.9 plateau), but acceptance collapsed (0.98→0.69), so 0.7 was kept as the safe default; n_max=3+ **OOMs at load** (the draft-context compute buffer scales with `n_max × batch` and batch 2048 was already near the ceiling). Don't assume one variant's tuning transfers to the other — bench think/non-think separately. On dense 9B MTP models the defaults (`n_max=2, p_min=0.7`) are as good as anything.

On the **35B MoE** the picture is different and harder: decode shows **±10–15% run-to-run variance** (identical configs measured 36.5→42.1 t/s across repeat runs), which **exceeds the config deltas** (n_max 1–5 and p_min 0.5–0.9 moved t/s by less than the noise). Single-sample sweeps are therefore unreliable on compute-bound MoE models; defaults were retained and further tuning would require multi-sample averaging (3× per config) to be statistically meaningful.

On the **Gemma 4 QAT 12B** (separate Q4_0 MTP drafter) deeper speculation helps a lot: n_max swept 1–6 rose 54→79 t/s to a peak at **5** (non-think) / tied at 4–5 (think), with acceptance dropping to ~0.79 — yet quality stayed clean and the low acceptance is a speed cost (marginal drafts rejected), not a quality problem, because p_min still gates what is accepted.

**Acceptance-rate principle (read this before judging a config by `draft acceptance`):** the acceptance number is NOT a universal quality gate — it depends on the drafter (in-model full-precision head vs a separate Q4 GGUF) and on n_max (deeper speculation generates more marginal drafts that get rejected, dragging the ratio down). The same-looking number can mean opposite things:
- Acceptance dropping because **p_min was lowered** = the quality bar is being relaxed (low-confidence drafts accepted) — genuine risk.
- Acceptance dropping because **n_max was raised** = only wasted draft compute (rejected drafts are recomputed by the target) — quality preserved.

So the Qwen-era habit of targeting ~0.9 acceptance was just the natural operating point of Qwen's in-model head at n_max=2, NOT a rule. The durable principle: **protect p_min** (the real quality gate) and treat `draft acceptance` as a rough signal, never a gate. Judging a config by the acceptance number alone will falsely condemn a good deep-speculation config (e.g. Gemma n_max=5 @ 0.79) while blessing a risky low-p_min one (Qwen think p_min=0.5 @ 0.82). Verify quality directly on the output instead.

## Gotchas

- `coordinator.lua` uses `ngx.socket.tcp` for HTTP calls to the backends. If those calls fail (e.g., backend not ready), the request still proceeds — the user may get an OOM if VRAM wasn't freed. The unload is best-effort.
- Variable-based `proxy_pass` (`set $upstream "http://host:port"`) is required because backends resolve at request time (not config load). The `resolver 127.0.0.11` directive enables runtime DNS re-resolution.
- Two `lua_shared_dict` directives in `nginx.conf`: `backend_state` and `request_counts`. Both live in the conf.d file which is included inside the `http {}` block — valid by default in the `bookworm-fat` image config.
- ollama unload uses `keep_alive: 0` on a generate request. This evicts the model and KV cache immediately. Without this flag, ollama keeps the model resident per its configured `OLLAMA_KEEP_ALIVE`.
- llama-cpp unload uses `POST /models/unload` with the model ID. Only models with `status.value == "loaded"` are targeted (queried from `/v1/models`).
- `coordinator.lua` logs every request, switch decision, and unload result via `ngx.log`. View with `docker logs -f cortex-openresty-1 | grep -E "request:|skip:|switch:|drain|state:|ollama:|llama-cpp:"`. The `error_log /proc/self/fd/2 info;` directive is patched into the main nginx.conf via `sed` in the Dockerfile — INFO-level messages appear in `docker logs`.
- The drain loop calls `ngx.sleep(0.5)` in the access phase, blocking the nginx worker for up to 30s during a switch. Switches are rare, so this is acceptable — but do not increase the timeout without understanding the concurrency impact.
- `get_model()` reads the request body via `ngx.req.read_body()` in the access phase. This does not consume the body — nginx still forwards it to the upstream. If body parsing fails (malformed JSON, no `model` field), `get_model()` returns nil and the coordinator proceeds conservatively (unloads on backend mismatch, skips on same-backend model change).
- `models-max` must NOT be set on llama.cpp. If the router limits concurrent children, it auto-unloads models when the limit is exceeded, which races against the coordinator's explicit `/models/unload` and leaves residual VRAM (orphan child process). The coordinator is the sole source of truth for unloads — remove `models-max` entirely to disable router-initiated teardown.
- `OLLAMA_MAX_LOADED_MODELS=1` is set in compose.yml. `OLLAMA_KEEP_ALIVE` is NOT set — defaults to 5m.
