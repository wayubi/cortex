# AGENTS.md

## Commit workflow

After making a change, ask the user if they want it committed. If they say yes, commit.

## Architecture

- **OpenResty** routes `:11434` → ollama, `:8080` → llama-cpp. Both backends run alongside openresty (no profiles).
- `coordinator.lua` runs in the access phase. Its only job: when a request targets a different backend than the current one, it tells the current backend to unload its model from VRAM via its own API. No Docker lifecycle — containers are never started or stopped by the coordinator.
- **Only POST requests (inference) can trigger a backend switch.** GET/HEAD/OPTIONS probes pass through without unloading anything — this prevents Open WebUI polling from bouncing the state.
- Unload flow: `POST /api/generate` with `keep_alive: 0` (ollama), or `POST /models/unload` (llama-cpp). Both backends are queried first (ollama: `/api/ps`, llama-cpp: `/v1/models`) to find exactly which model(s) are loaded.
- The shared `backend_state` dict tracks which backend is "active" to know when unloading is needed.
- Before unloading, coordinator drains active POST requests on the current backend (polls `request_counts` up to 30s at 500ms intervals). Active requests are counted at access phase and decremented via `log_by_lua_block` in each nginx server block.

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

## Gotchas

- `coordinator.lua` uses `ngx.socket.tcp` for HTTP calls to the backends. If those calls fail (e.g., backend not ready), the request still proceeds — the user may get an OOM if VRAM wasn't freed. The unload is best-effort.
- Variable-based `proxy_pass` (`set $upstream "http://host:port"`) is required because backends resolve at request time (not config load). The `resolver 127.0.0.11` directive enables runtime DNS re-resolution.
- Two `lua_shared_dict` directives in `nginx.conf`: `backend_state` and `request_counts`. Both live in the conf.d file which is included inside the `http {}` block — valid by default in the `bookworm-fat` image config.
- ollama unload uses `keep_alive: 0` on a generate request. This evicts the model and KV cache immediately. Without this flag, ollama keeps the model resident per its configured `OLLAMA_KEEP_ALIVE`.
- llama-cpp unload uses `POST /models/unload` with the model ID. Only models with `status.value == "loaded"` are targeted (queried from `/v1/models`).
- `coordinator.lua` logs every request, switch decision, and unload result via `ngx.log`. View with `docker logs -f cortex-openresty-1`. The `error_log /proc/self/fd/2 info;` directive is patched into the main nginx.conf via `sed` in the Dockerfile — INFO-level messages appear in `docker logs`.
- The drain loop calls `ngx.sleep(0.5)` in the access phase, blocking the nginx worker for up to 30s during a switch. Switches are rare, so this is acceptable — but do not increase the timeout without understanding the concurrency impact.
