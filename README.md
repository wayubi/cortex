# Cortex

An OpenResty-based VRAM coordinator that lets several LLM backends (**Ollama**, four **llama.cpp**
builds and **NLLB**) share a single GPU. Before a request for another model goes through, the
coordinator unloads the resident model through its backend's API. No container is stopped or started.

## How it works

| Service | Port | Role |
|---------|------|------|
| **openresty** | 11434, 8080, 5002, 80 | Reverse proxy and VRAM coordinator (`:80` serves `/availability`, `/v1/models` and the client scripts) |
| **ollama** | 11434 | Ollama |
| **llama-cpp** | 8080 | Upstream llama.cpp, router mode (`llama-cpp/models.ini`) |
| **prism-llama-cpp** | 8080 | PrismML's fork, for the ternary Bonsai models |
| **raon-llama-cpp** | 8080 | KRAFTON's fork, for Raon-1 mini |
| **inkling-llama-cpp** | 8080 | Unsloth's build, for Inkling 2 Mini |
| **nllb** | 5002 | Hugging Face NLLB translation (FastAPI) |
| **model-cache** | — | Keeps NVMe copies of the models loaded most |
| **pi**, **opencode** | — | Coding agents whose model lists are generated from Cortex |

- **One port for every llama.cpp build.** A request for a model named in a router's `models.ini` goes
  to that router; `GET /v1/models` on `:8080` lists them all. Model names are unique across the files.
  A model that needs a build the others lack gets its own router, so the other routers' builds never
  move for it.
- **Switching.** Every inference POST is checked against the resident backend and model; polling GETs
  pass through. A switch drains the requests running on the current backend (up to 600 s, else 503),
  unloads its model through the backend's API, and lets the new request through. One switch runs at a
  time.
- **People first.** Requests marked `X-Cortex-Client: bot` yield to everything else: while a person's
  request waits, new bot requests are held, and a bot that would evict the resident model waits until
  no person's request has finished for 120 s. `GET /availability`, on every port, reports whether the
  GPU is busy, how long it has been idle and which model is resident, so a scheduler can wait for a
  quiet GPU instead of forcing a switch.
- **Prompts survive swaps.** When a llama.cpp model is unloaded, its last conversation's processed
  prompt is saved (one per model, kept about two hours) and restored when the model is loaded again,
  so that conversation resumes without reprocessing it.
- **Fast loads.** `model-cache` copies a model to NVMe on its third load within seven days, up to
  128 GB, evicting the copies used least recently and least often, and serves loads from there. The
  original file is never touched; `CORTEX_NVME_CACHE=off` undoes everything.

Design, invariants and how to change things: [`AGENTS.md`](AGENTS.md).

## Requirements

- Docker Compose V2
- An NVIDIA GPU with `nvidia-container-toolkit`

## Quick start

```bash
git clone <url> && cd cortex
docker compose --profile build build     # build the images (llama.cpp builds pinned in compose.yml)
docker compose up -d

curl http://localhost:8080/v1/models     # llama.cpp models, every router
curl http://localhost:11434/api/tags     # Ollama models
curl http://localhost:5002/v1/models     # NLLB models
curl http://localhost/availability       # coordinator state
```

Model pickers populate without triggering a switch; inference requests switch as needed.
Machine-specific settings (model cache paths, `HF_TOKEN`, shared networks) go in a
`compose.override.yml`, which git ignores.

## Client agents

`pi` and `opencode` run as containers on the same network, and either can be installed on any
Debian/Ubuntu or Alpine client from Cortex itself:

```bash
# Inside a container on cortex_network (the scripts are served on every openresty port):
curl -fsSL http://openresty/install-pi.sh | sh
curl -fsSL http://openresty/install-pi.sh | sh -s -- --all
curl -fsSL http://openresty/install-opencode.sh | sh

# From another machine, point both URLs at the Cortex host; the defaults
# (openresty:8080 and openresty:11434) only resolve on cortex_network:
curl -fsSL http://<cortex-host>/install-pi.sh \
  | CORTEX_URL=http://<cortex-host>:8080 OLLAMA_URL=http://<cortex-host>:11434 sh
```

With no flags each installer adds the agent and generates its model list from `:8080` and `:11434`.
`--all` adds every language toolkit, `--models-only` only refreshes the list, `--strict` stops at the
first failure, and `--help` lists the rest.

Ollama models are listed at the context Ollama serves them with: the model's own `num_ctx` if set,
else `CORTEX_OLLAMA_CTX` (default 4096, Ollama's automatic default on a GPU under 23 GiB). If your
Ollama sets `OLLAMA_CONTEXT_LENGTH` or runs on a larger GPU, pass the same value, e.g.
`CORTEX_OLLAMA_CTX=32768 sh`.

OpenCode's config is written in OpenCode v2's format (`providers`, `package` + `settings.baseURL`);
OpenCode v1 ignores it. The `opencode` container also starts OpenCode's background server for
`opencode pair` and the app; `AGENTS.md` covers exposing it beyond the container.

## Rebuilding

```bash
# llama.cpp builds: pinned in compose.yml (tag, commit, or source archive + sha256).
# Bump a pin deliberately; the previous image stays tagged for rollback. Re-bench afterwards.
docker compose --profile build build llama-build          # upstream
docker compose --profile build build prism-llama-build    # PrismML fork
docker compose --profile build build raon-llama-build     # KRAFTON's Raon fork
docker compose --profile build build inkling-llama-build  # Unsloth's Inkling build
docker compose up -d llama-cpp prism-llama-cpp raon-llama-cpp inkling-llama-cpp

# Lua or nginx.conf edits (bind-mounted): a restart, not a rebuild
docker compose restart openresty

# Client agents (not pinned): a new CACHEBUST re-runs only the agent install
CACHEBUST=$(date +%s) docker compose build pi opencode
docker compose up -d pi opencode
```

## Benchmarking

`tools/bench.sh` tunes each llama.cpp entry (`batch-size` / `ubatch-size`, and for MTP models
`spec-draft-n-max` / `spec-draft-p-min`), validates it, and records a benchmark. Never set those values
by hand: `-fit` leaves almost no VRAM headroom, so a value that survives a short probe can still run
out of memory at full context or silently push work onto the CPU.

```bash
./tools/bench.sh                          # interactive: pick models, then the full suite
./tools/bench.sh all <models...>          # full suite: mtpcheck → bisect → mtp → bench
./tools/bench.sh bisect <model>           # batch tuning with full validation
./tools/bench.sh batch <models...>        # batch tuning only, no full-context validation
./tools/bench.sh mtpcheck <models...>     # MTP capability check
./tools/bench.sh mtp <models...>          # MTP tuning, ending in an MTP on/off A/B
./tools/bench.sh mtpab <heads...>         # MTP on/off A/B on an already-tuned entry, then bench
./tools/bench.sh mtpverify <models...>    # check that MTP leaves the output unchanged
./tools/bench.sh bench <models...>        # benchmark record only
./tools/bench.sh residency <model>        # quick GPU/CPU placement check, no record
./tools/bench.sh ctxmax <model>           # largest GPU-resident context → a new entry
./tools/bench.sh vision <models...>       # add <model>-vision when the repo ships a projector
./tools/bench.sh fetch <models...>        # download an entry's files (the routers run offline)
./tools/gen_metrics.sh                    # rebuild full-metrics.md from every record
```

Flags go before the subcommand:

| Flag | Effect |
|------|--------|
| `--backend=<name>` | Force the router (normally chosen from the model names) |
| `--no-inherit` | Bench every model on its own, without family inheritance |
| `--reset-parent` | Re-bench each family head first, so siblings inherit fresh data |
| `--strict` | Skip `bench` for a model whose MTP tuning failed |
| `--no-confirm` | `bisect` stops after the pick (as `batch`) |
| `--refine=64\|coarse\|off` | Batch refinement depth (default `64`; env `BENCH_REFINE`) |
| `--thorough` | The older exhaustive search (env `BENCH_THOROUGH=1`) |

Entries that differ only in sampling, reasoning or chat template form a family: only its head is
benched, and the others copy its record in seconds. Rough times per head on an RTX 3060: 5–10 min for
a small GPU-resident model, 25–30 for a dense MTP model, 40–100 for a large MoE with its experts on
the CPU. Only one `bench.sh` runs at a time.

Records are `<router>/models/<model>.json` (keys `config`, `bench`, `speed`, `request`, `mtp`,
`discover`, `hardware`); `full-metrics.md` is the table of all of them. The largest models run their
experts on the CPU by design and are recorded as `placement: CPU`. Method and evidence:
[`docs/reference/benchmarking.md`](docs/reference/benchmarking.md).

## Debugging

```bash
docker logs -f cortex-openresty-1 | grep '\[lua\]'      # coordinator decisions
docker logs -f cortex-model-cache-1                     # NVMe copies and evictions
ls logs/                                                # bench.sh, one log per run
```

A switch, from the coordinator's log (log prefixes and client details trimmed):

```
coordinate(): POST inkling_llama_cpp (human) backend=ollama model: gemma3:12b -> inkling-2-mini-q4-96k-think-loopgpu
switch_to(): drain ollama (0 active)
switch_to(): switch: ollama -> inkling_llama_cpp (gemma3:12b -> inkling-2-mini-q4-96k-think-loopgpu)
switch_to(): state: backend=inkling_llama_cpp model=inkling-2-mini-q4-96k-think-loopgpu
restore_slot(): slot-cache: restored inkling-2-mini-q4-96k-think-loopgpu (38522 tokens, 821 ms)
```

## License

See [`LICENSE`](LICENSE).
