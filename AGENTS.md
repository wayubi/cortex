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
├── llama-cpp/
│   ├── models.ini          # llama.cpp models preset file
│   └── Dockerfile          # CUDA build from source
└── openresty/
    ├── Dockerfile           # FROM openresty/openresty:bookworm-fat, sed patches error_log
    ├── nginx.conf           # lua_shared_dict directives, 2 server blocks
    └── coordinator.lua      # VRAM coordinator — API-based model unload
```

## Stress-testing batch/ubatch (proven procedure)

Finding the max `batch-size`/`ubatch-size` a model fits in VRAM. Goal: the highest value that survives a real decode.

Why: llama.cpp `-fit on` (default, `ngl = -1`) packs weights into VRAM leaving ~zero headroom. The compute graph (PP/prefill buffers) is allocated lazily on the **first decode**, not at load — a model can load fine and then crash on the first request with `failed to allocate compute pp buffers`. The PP buffer scales ~linearly with ubatch (~2 MiB per unit on the 35B Qwen), so bigger batch = faster prefill up to the OOM ceiling.

Procedure (per candidate value):
1. Edit `llama-cpp/models.ini` for the target `[model]` entry: set `batch-size` and `ubatch-size` to the **same** value (`batch-size` must equal `ubatch-size`). Keep the target `ctx-size`.
2. `docker compose restart llama-cpp` — the router reads models.ini only at startup, so every value change needs a restart.
3. Wait for readiness: `curl -sf http://localhost:8080/v1/models` (through openresty) until it returns 200.
4. Fire one tiny inference request so the model loads and decodes:
   `curl -s -X POST http://localhost:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"<model>","messages":[{"role":"user","content":"Say hello"}],"max_tokens":8}'`
5. Watch the log: `docker logs -f cortex-llama-cpp-1`. OOM markers appear **seconds** after the request — `cudaMalloc failed` / `failed to allocate compute pp buffers` / `terminate called after throwing` / child `exited with status 1`. Fast OOM grep: `docker logs --since 10s cortex-llama-cpp-1 | grep -E "cudaMalloc failed|failed to allocate compute pp buffers|terminate called after throwing"` (<1s).
6. **OOM** → step down and repeat using a **coarse-to-fine sweep** (start from the preset default 4096):
   - **Bracket (down-sweep):** step down by 1024 or halve (`4096 → 2048 → 1024`) until the first **PASS**. This brackets the ceiling: `lo` = highest PASS, `hi` = lowest OOM. (At 4096 the tiny probe crashes on the first decode almost instantly — expected; the coarse sweep's job is to bracket, not to pass.)
   - **Refine (bisect up):** with `lo` = highest confirmed PASS and `hi` = lowest OOM, test midpoints rounded to 64 (`(lo + hi) / 2`): PASS → `lo = mid`, OOM → `hi = mid`. Increments shrink naturally (`512 → 256 → 128 → 64`). Repeat until `hi − lo ≤ 64`; the final `lo` is the max. Example: `1024 PASS, 2048 OOM → 1536 OOM → 1280 OOM → 1152 PASS → 1216 OOM → answer 1152`.
   - **No floor** — if the down-sweep never passes, keep going until it does.
7. **PASS** on the tiny probe → confirm with 2 more requests (expect `http=200`). This is only a **quick filter** — it does NOT prove the value is good (see Phase 2).
8. **Phase 2 — TRUE test: full-context saturation + compaction.** The tiny probe only proves the compute graph fits at near-empty context. `-fit` leaves ~zero headroom, so memory peaks near full context (KV compaction temp buffers, hybrid/SSM state re-derivation) — a value can still OOM once the context fills and compacts.
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
   - Saturation runs are ~2 min at 16K, growing roughly linearly with ctx — only run them on values that pass the quick filter. For 128K+ ctx, the body nears nginx's default 1MB `client_max_body_size`; raise it or use a tighter prompt if the request returns 413.
9. Leave the config at the winning value with a comment: `ubatch-size = N ; optimized (max, N+64 OOM)`.

Proven gotchas:
- The OOM happens on first **decode**, not at load. A load-only probe (GET `/v1/models`, or waiting for `model loaded`) will NOT reveal it — you must send a real inference request.
- The tiny 20-token probe is necessary but **not sufficient**. `-fit` leaves ~zero headroom, so the true peak is near full context: a value that survives a 20-token decode can still OOM at full ctx once compaction triggers. Only a successful full-context saturation run (compaction where the model supports it, ceiling truncation on hybrid/SSM) validates the value.
- Use the OOM log grep as the source of truth, **NOT** the curl http code. The first request after a restart can take >20s (fit + MTP context + warmup) and time out (`http=000`) while the model actually loads and serves fine — verify with a follow-up request.
- A failed child triggers the router's 10s force-kill, then `model ... failed to load` (HTTP 500). That 500 is also an OOM signal.
- Lowering `ctx-size` does NOT reliably create batch headroom — `-fit` simply repacks more weights into the freed VRAM (e.g. a 1024 batch that OOMs at 64K ctx also OOMs at 16K).
- If even tiny batches OOM, the only real fix is freeing VRAM: `override-tensor = exps=CPU` (experts to system RAM).
- The `[*]` preset default `batch-size`/`ubatch-size = 4096` is a deliberate over-sized **tuning starting point** — it OOMs almost immediately on this GPU and is meant to be overridden per `[model]` entry. Never run an untuned entry at 4096.

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
