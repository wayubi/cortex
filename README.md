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
1. The coordinator drains active requests on the current backend (polls the `request_counts` dict, up to `DRAIN_TIMEOUT` = 600s). If the backend is still busy when that expires, the incoming request gets a 503 rather than an unload under load.
2. It calls the active backend's unload API. All three backends are full participants:
   - ollama — `POST /api/generate` with `keep_alive=0`
   - llama.cpp — `POST /models/unload`
   - nllb — `GET /v1/models` to find loaded models, then `POST /v1/models/unload` for each
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
curl http://localhost:8080/v1/models           # llama.cpp models
curl http://localhost:11434/api/tags           # Ollama models
curl http://localhost:5002/v1/models           # NLLB models
```

All three model pickers populate without triggering a backend switch. Inference requests automatically switch as needed.

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

The benchmarking pipeline is a single script: `tools/bench.sh`. It finds and validates a practical `batch-size` / `ubatch-size` and, for MTP models, `spec-draft-n-max` / `spec-draft-p-min`, then records a benchmark for each entry in `llama-cpp/models.ini`.

### Running it

```bash
./tools/bench.sh                          # interactive: pick models, then the full suite
./tools/bench.sh all <models...>          # non-interactive full suite
./tools/bench.sh bisect <model>           # batch tuning only
./tools/bench.sh mtp <model>              # MTP tuning only
./tools/bench.sh bench <model>            # benchmark record only
./tools/bench.sh mtpcheck <model>         # MTP capability check only
./tools/bench.sh mtpverify <model>        # diagnostic: MTP-on vs off output check
```

Global flags go before the subcommand:

| Flag | Effect |
|------|--------|
| `--no-inherit` | Bench every selected model independently; no family inheritance |
| `--reset-parent` | Re-bench each family head first, so siblings inherit fresh data |
| `--strict` | Skip `bench` for a model whose MTP tuning failed (for publishable records) |
| `--refine=64\|coarse\|off` | Batch refinement depth; default `64` |
| `--thorough` | Use the legacy exhaustive search instead of discover mode |

Environment equivalents: `BENCH_THOROUGH=1`, `BENCH_REFINE=64|coarse|off`.

### Pipeline

Each family head goes through four steps in order:

| Step | What it does |
|------|-------------|
| mtpcheck | Empirically determines MTP capability; sets or clears `spec-type` in models.ini |
| bisect | Finds and validates the batch size (see below) |
| mtp | Tunes `n_max` / `p_min` (MTP-capable models only) |
| bench | Writes the benchmark record: prefill, decode, placement, hardware |

### Batch tuning (discover mode, the default)

Batch is a **prefill** knob. Single-stream decode does not change with batch unless something spills off the GPU, so the search optimises prefill and guards residency:

1. **Coarse ladder** of powers of two from 256 up to `min(ctx-size, 16384)`. Each rung restarts the server once and takes three cheap measurements: a tiny probe (OOM at load or first decode), a residency probe (binary GPU or CPU verdict), and a sized prefill probe using the same prompt length on every rung so rungs rank on identical work. Every prefill probe runs an untimed warm-up first, and fast probes take the median of three.
2. **Pick** the best-measured point, then a **golden-section refinement** down to 64-token granularity. Refinement skips residency inside a bracket where both ends passed, since memory use is monotonic in batch.
3. **Confirm at the pick, one restart**: full-context saturation at 99% of ctx, a sustained long-decode, and on MTP GPU models a decode-cliff check against a batch-256 baseline. On failure it steps down to the next lower measured point, at most twice, then fails the model with models.ini restored.

`--refine=coarse` stops refinement once a step no longer beats the noise floor; `--refine=off` picks the best ladder rung. `--thorough` restores the original exhaustive search (golden-section prefill sweep, 64-token ceiling bisect, top-5 shortlist decode gate).

### MTP tuning

`n_max` and `p_min` are **speed-only** knobs. llama.cpp's speculative decoding samples every position from the target model and keeps a draft token only when it matches, so the output distribution is unchanged. The tuner therefore ranks configurations on decode speed measured on natural-stop output, and the only hard rejections are OOM, a too-short sample, and — on GPU-resident models — a draft that spills to CPU. An 8-gram degeneracy ratio is recorded as a diagnostic and never gates anything. `bench.sh mtpverify` checks the speed-only claim empirically for a given model.

### Family inheritance

Two entries are in the same family when they share both `hf` and `ctx-size`, so coder and think variants of the same weights and context inherit from one head. The head is benched; siblings copy its record in seconds and get their own `config` block rebuilt from their own models.ini section. Cost therefore scales with distinct weight-and-context combinations, not with the number of entries. A head whose bench fails does not feed its record to siblings; they are skipped and reported.

Rough per-head times on an RTX 3060: 5 to 10 minutes for a small GPU-resident model, 25 to 30 for a dense MTP head, and 40 to 100 for a large CPU-offloaded MoE at long context. Siblings are free.

### Results

Results are written to `llama-cpp/models/<model>.json`, one file per model, with these top-level keys:

| Key | Contents |
|-----|----------|
| `config` | The model's own models.ini settings |
| `bench` | Prompt sizes, model file size, build info, wall time |
| `speed` | Prefill and decode throughput |
| `request` | Token counts, finish reason, degeneracy |
| `mtp` | Acceptance, loaded vs tuned values, `tuning_status`, every tuning sample |
| `discover` | The full batch ladder, refinement points, pick and pick rule |
| `hardware` | GPU, CPU, RAM, and the run's power, thermal and VRAM peaks |

The consolidated table lives in `full-metrics.md`:

```bash
./tools/gen_metrics.sh    # regenerates full-metrics.md from llama-cpp/models/*.json
```

Current state: 71 of the 73 models.ini entries have a record.

Full methodology, gotchas and stress-test procedures: see `AGENTS.md`. The design history and rationale behind the current pipeline: see `md/plan-bench-discover-mode.md`.

## File layout

```
├── AGENTS.md                 # developer instructions / benchmarking methodology
├── README.md
├── LICENSE
├── compose.yml               # Docker Compose — openresty, ollama, llama-cpp, nllb
├── compose.override.yml      # local volume mounts (model caches, models.ini)
├── CPU_POLLING.md            # CPU/GPU placement verification methodology
├── full-metrics.md           # benchmark table for all models (regenerate via tools/gen_metrics.sh)
├── logs/                     # bench.sh run logs, one per invocation
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
└── md/                       # planning and design docs
    ├── plan-bench-discover-mode.md   # current benchmarking pipeline: design, reviews, decisions
    ├── plan-bench-sh-audit-fixes.md  # earlier bench.sh audit
    ├── plan-batch-sweep.md           # earlier batch sweep design
    └── nllb-translation-service.md
```

## Debugging

View coordinator decisions in real time:

```bash
docker logs -f cortex-openresty-1 | grep -E "request:|skip:|switch:|drain|state:|ollama:|llama-cpp:|nllb:"
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

Benchmarking runs log to `logs/bench_<timestamp>.log`, one file per invocation, containing every probe and decision.

## Known VRAM considerations

- All containers run simultaneously but no model is loaded at boot.
- Models only consume VRAM during active inference.
- Ollama's `OLLAMA_KEEP_ALIVE` controls how long a model stays resident after the last request (default 5m).
- llama.cpp keeps one model loaded at a time — the coordinator is the sole source of truth for unloads, so `models-max` must NOT be set (see `AGENTS.md`).
- If a backend switch happens mid-inference, the drain waits up to 600s for completion before unloading, and returns 503 if the backend is still busy.
- The largest models in this catalogue run their experts on the CPU rather than the GPU. That is expected and is recorded per model as `placement: CPU`; the tuner treats it as the model's baseline, not a fault.

## Model tuning

Each `[model]` entry in `llama-cpp/models.ini` can override `batch-size` / `ubatch-size` and, for MTP models, `spec-draft-n-max` / `spec-draft-p-min`. Do not set these by hand: `-fit on` leaves near-zero VRAM headroom, so a value that survives a short probe can still OOM at full context or silently push the MTP draft onto the CPU. Run the pipeline instead:

```bash
./tools/bench.sh all <model>    # tunes, validates and records in one pass
./tools/gen_metrics.sh          # refresh the consolidated table
```

The validation gates that make a value trustworthy — the OOM log grep as source of truth, the residency check, full-context saturation, and the sustained long-decode — are documented in `AGENTS.md`.
