# Cortex

An OpenResty-based VRAM coordinator that lets you hot-swap between **Ollama** and **llama.cpp** on a single GPU without Docker container lifecycle management — just API-level model unloads.

## How it works

OpenResty sits in front of both backends and proxies requests. When a request targets a different backend than the currently active one, `coordinator.lua` tells the active backend to unload its model from VRAM via its own API, then lets the request through.

| Backend | Unload via | VRAM freed |
|---|---|---|
| Ollama | `POST /api/generate` with `keep_alive: 0` | Immediately after unload call |
| llama.cpp | `POST /models/unload` for each loaded model | Immediately after unload call |

**Only POST requests (inference) trigger a switch.** GET metadata probes (`/api/tags`, `/v1/models`) pass through freely — no state bouncing from Open WebUI polling.

Active inference requests on the current backend are drained before unloading (polls up to 30s at 500ms intervals).

Both backends run side-by-side at all times. No containers are started or stopped. Only the loaded model is evicted from VRAM.

## Requirements

- Docker Compose V2
- NVIDIA GPU with `nvidia-container-toolkit` installed

## Quick start

```bash
# Clone and start
git clone <url> && cd cortex
docker compose up -d

# Verify
curl http://localhost:8080/v1/models          # llama.cpp models
curl http://localhost:11434/api/tags           # Ollama models
```

Both model pickers populate without triggering a backend switch. Inference requests automatically switch as needed.

## Rebuilding llama.cpp from source

Cortex builds llama.cpp from source with CUDA + flash attention. To rebuild:

```bash
docker compose --profile build build llama-build
docker compose up -d
```

Rebuild the OpenResty image after Lua or nginx changes:

```bash
docker compose build openresty
docker compose up -d
```

## File layout

```
├── compose.yml               # Docker Compose — all three services
├── llama-cpp/
│   ├── Dockerfile             # Multi-stage CUDA build from source
│   └── models.ini             # Model presets for llama.cpp server
├── openresty/
│   ├── Dockerfile             # Patches error_log level for coordinator logging
│   ├── nginx.conf             # Shared dicts, two server blocks, log_by_lua
│   └── coordinator.lua        # VRAM coordinator — API-based model unload
├── AGENTS.md                  # Developer instructions for AI agents
├── LICENSE
└── README.md
```

## Debugging

View coordinator decisions in real time:

```bash
docker logs -f cortex-openresty-1 | grep -E "request:|skip:|switch:|drain|state:|ollama:|llama-cpp:"
```

Example output:

```
request: POST llama_cpp current=ollama
drain ollama (1 active)
drain: ollama waited 3.2s
ollama: unloading gemma3:4b
ollama: unloaded gemma3:4b
state: backend=llama_cpp
request: GET llama_cpp current=llama_cpp
request: GET ollama current=llama_cpp
skip: GET ollama — only POST triggers switch
```

## Known VRAM considerations

- Both containers run simultaneously but no model is loaded at boot
- Models only consume VRAM during active inference
- Ollama's `OLLAMA_KEEP_ALIVE` controls how long a model stays resident after the last request (default 5m)
- llama.cpp keeps one model loaded at a time (configured via `models-max`)
- If a backend switch happens mid-inference, the request counter drain waits up to 30s for completion before unloading
