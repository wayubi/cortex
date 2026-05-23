# AGENTS.md

## Commit workflow

After making a change, ask the user if they want it committed. If they say yes, commit.

## Architecture

- **OpenResty** routes `:11434` → ollama, `:8080` → llama-cpp. Both backends have `profiles: ["managed"]` so they don't auto-start. OpenResty controls their lifecycle via Docker socket.
- `coordinator.lua` runs in the access phase. It acquires a lock, checks `backend_state`, and starts/stops the target container via Docker API. Errors use `ngx.exit(503)` with `ngx.log` — `ngx.say` in access phase produces no response body.

## Critical naming

The compose service is `llama-cpp` (hyphen), but the Lua internal key is `llama_cpp` (underscore). Always use the `SERVICE`/`HOST` lookup tables in `coordinator.lua` to map between them:
- `SERVICE[target]` for Docker API calls (needs `"llama-cpp"`)
- `HOST[target]` for DNS hostnames (needs `"llama-cpp"`)

These tables are at `openresty/coordinator.lua:14-15`. If adding a new backend, add entries to both tables.

## Docker compose commands

- `docker compose --profile managed create` — create containers first time, or after `down -v`
- `docker compose --profile managed up -d` — start the stack
- `docker compose build openresty` — rebuild OpenResty after Lua/nginx changes
- `docker compose --profile build build llama-build` — rebuild llama.cpp image from source
- `docker compose --profile managed down` — stop backends (OpenResty stays if no profile)
- The internal network is `cortex_network` (compose-managed bridge). External `enhasa_network` must exist before `up`.

## File layout

```
cortex/
├── compose.yml
├── llama-cpp/
│   ├── models.ini          # llama.cpp models preset file
│   └── Dockerfile          # CUDA build from source
└── openresty/
    ├── Dockerfile           # FROM openresty/openresty:bookworm-fat
    ├── nginx.conf           # lua_shared_dict directives, 2 server blocks
    └── coordinator.lua      # VRAM coordinator state machine
```

## Gotchas

- The shared `backend_state` can be `"idle"` (set when a healthcheck fails). `coordinator.lua:225` guards `stop_container` with `current ~= nil and current ~= "idle"` — without the `"idle"` guard, a failed llama-cpp start would kill ollama too.
- Containers have no explicit `container_name` — Docker API calls resolve via compose label `com.docker.compose.service=<name>`.
- Variable-based `proxy_pass` (`set $upstream "http://host:port"`) is required because backends resolve at request time (not config load). Without this, nginx fails on startup when `profiles: ["managed"]` backends don't exist yet. The `resolver 127.0.0.11` directive enables runtime DNS re-resolution.
- `log_by_lua_block` decrements request counts guarded by `> 0` check to prevent negatives.
- `lua_shared_dict` directives live in `nginx.conf` which is included inside the `http {}` block — valid by default in the `bookworm-fat` image config.
