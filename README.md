# Cortex

An OpenResty-based VRAM coordinator that lets you hot-swap between **Ollama**, **llama.cpp**, and **NLLB** on a single GPU without Docker container lifecycle management — just API-level model unloads.

## Architecture

Cortex runs four services in a shared Docker network. An `openresty` reverse proxy sits in front of all backends and routes each incoming request to the correct one. If a request targets a different backend than the one currently active, `coordinator.lua` tells the active backend to unload its model from VRAM before letting the request through.

| Service | Port | Role |
|---------|------|------|
| **openresty** | 11434 (ollama), 8080 (llama.cpp), 5002 (nllb) | Reverse proxy + VRAM coordinator |
| **ollama** | 11434 | Ollama inference backend |
| **llama-cpp** | 8080 | llama.cpp router-mode inference backend |
| **nllb** | 5002 | Hugging Face NLLB translation (FastAPI) |

A `llama-build` profile is also available (build-only, not normally running).

### Coordinator behaviour

`coordinator.lua` runs in the access phase and tracks which backend and model are currently loaded. Every **POST** (inference) request is evaluated; GET/HEAD/OPTIONS probes (e.g. Open WebUI polling) pass through freely without triggering any state changes.

When a switch is needed:
1. The coordinator drains active requests on the current backend (polls `request_counts` dict, up to 30s).
2. It calls the active backend's unload API (`POST /api/generate keep_alive=0` for ollama, `POST /models/unload` for llama.cpp).
3. It updates `backend_state` to the new target.

No containers are stopped or started — only the loaded model is evicted from VRAM.

## Requirements

- Docker Compose V2
- NVIDIA GPU with `nvidia-container-toolkit` installed

## Quick start

```bash
# Clone and start
git clone <url> && cd cortex
docker compose up -d

# Verify the three endpoints
curl http://localhost:8080/v1/models          # llama.cpp models
curl http://localhost:11434/api/tags           # Ollama models
```

Both model pickers populate without triggering a backend switch. Inference requests automatically switch as needed.

## Rebuilding

**llama.cpp from source** (with CUDA + flash attention):

```bash
docker compose --profile build build llama-build
docker compose up -d
```

**After Lua or nginx changes** (rebuilds the openresty image):

```bash
docker compose build openresty
docker compose up -d
```

## Benchmarking

The benchmarking pipeline is a single script: `tools/bench.sh`.

### Pipeline

Each model goes through four steps in order: `mtpcheck → bisect → mtp → bench`:

| Step | Command | What it does |
|------|---------|-------------|
| mtpcheck | `bench.sh mtpcheck <model>` | Empirically determines MTP capability, sets spec-type in models.ini |
| bisect | `bench.sh bisect <model> [test-batch]` | Saturation-gated batch ceiling search (tiny probe → full-context saturation) |
| mtp | `bench.sh mtp <model>` | MTP n_max/p_min sweep (only if MTP-capable) |
| bench | `bench.sh bench <model>` | Full benchmark JSON record (prefill, decode, placement, hardware) |

**Full suite (recommended):** `./tools/bench.sh all <models...>` runs all four steps per model with inheritance for siblings. Interactive mode (`./tools/bench.sh`) prompts for model selection.

### Results

Results are written to `llama-cpp/models/<model>.json` (one file per model). The consolidated table lives in `full-metrics.md`, regenerated from the JSONs:

```bash
./tools/gen_metrics.sh    # regenerates full-metrics.md from models/*.json
```

### Methodology notes

- **Batch bisect:** `bench.sh bisect` starts at `ctx` (the hard ceiling), halves on OOM, then bisects to 64-granularity. Saturation-gated: every candidate passes both tiny probe AND full-context saturation (99% of ctx). An early-rate decode gate rejects models whose decode collapses at full context.
- **Placement check:** early residency gate (batch=256) classifies CPU vs GPU residency. GPU models proceed to a decode-guarded prefill sweep; CPU models run a pure-prefill saturation sweep.
- **Long-decode check:** after bisect, a 4000+ token essay decode verifies decode survives at the chosen batch (catches late OOM from flash-attn workspace growth).

Full methodology, gotchas, and stress-test procedures: see `AGENTS.md`.

## File layout

```
├── AGENTS.md                 # developer instructions / benchmarking methodology
├── README.md
├── LICENSE
├── compose.yml               # Docker Compose — openresty, ollama, llama-cpp, nllb
├── CPU_POLLING.md            # CPU/GPU placement verification methodology
├── full-metrics.md           # benchmark table for all models (regenerate via tools/gen_metrics.sh)
├── tools/
│   ├── bench.sh              # canonical pipeline: mtpcheck → bisect → mtp → bench
│   └── gen_metrics.sh        # regenerate full-metrics.md from llama-cpp/models/*.json
├── llama-cpp/
│   ├── models.ini            # llama.cpp model presets
│   ├── models/               # per-model benchmark JSONs
│   └── Dockerfile            # CUDA build from source
├── nllb/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── server.py             # HF translation (NLLB) FastAPI service
├── openresty/
│   ├── Dockerfile
│   ├── nginx.conf            # 3 server blocks + lua_shared_dict
│   └── coordinator.lua       # VRAM coordinator — API-based model unload
└── md/                       # internal planning docs (bench audits, fix plans)
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

- Both containers run simultaneously but no model is loaded at boot.
- Models only consume VRAM during active inference.
- Ollama's `OLLAMA_KEEP_ALIVE` controls how long a model stays resident after the last request (default 5m).
- llama.cpp keeps one model loaded at a time — the coordinator is the sole source of truth for unloads, so `models-max` must NOT be set (see `AGENTS.md`).
- If a backend switch happens mid-inference, the request counter drain waits up to 30s for completion before unloading.

## Model tuning

Each `[model]` entry in `llama-cpp/models.ini` can override `batch-size` / `ubatch-size`. The proven stress-test procedure — including the two-phase validation (tiny decode probe, then full-context saturation) needed because `-fit on` leaves ~zero VRAM headroom — is documented in `AGENTS.md`.

Results are recorded in `llama-cpp/models/<model>.json` and summarized in `full-metrics.md`. To update results after re-benching:

```bash
./tools/gen_metrics.sh
```
