# AGENTS.md

Cortex runs several LLM backends on one GPU behind OpenResty. `openresty/coordinator.lua` makes sure
only one model holds VRAM at a time: before a request for another model goes through, it unloads the
resident one through the backend's API. No container is stopped or started for a switch.

## Rules

- **The GPU is in live use.** Loading a model, restarting a router or openresty, or running
  `bench.sh` changes what the people using Cortex get. Ask first.
- **Public repository.** No hostnames, IPs, accounts, personal names or private paths in tracked
  files. Machine-specific values go in the git-ignored `compose.override.yml` (or
  `openresty/local.d/`); tracked files keep neutral placeholders.
- **Scripts go in `tools/`**, except the client-facing scripts in `openresty/scripts/`.
- **Markdown goes in `docs/` or `tracker/`** (see "Docs and tracker").

## Architecture

| Service | Role |
|---|---|
| `openresty` | `:11434` → ollama, `:8080` → the llama.cpp routers, `:5002` → nllb, `:80` → `/availability`, `/v1/models` and the client scripts. Runs the coordinator. |
| `ollama` | Ollama. `OLLAMA_MAX_LOADED_MODELS=1`; `OLLAMA_KEEP_ALIVE` unset (5 min). |
| `llama-cpp` | Upstream llama.cpp in router mode, the default router. |
| `prism-llama-cpp` | PrismML's fork: the ternary `PQ2_0`/`PTQ1_0` types and Hadamard runtime Bonsai needs. |
| `raon-llama-cpp` | KRAFTON's fork for Raon-1 mini (arch `raon1`). Gated repo: `HF_TOKEN` in `compose.override.yml`. |
| `inkling-llama-cpp` | Unsloth's build for Inkling 2 Mini (arch `inkling2`), from their release tarball. |
| `nllb` | Hugging Face NLLB translation (FastAPI). |
| `model-cache` | Keeps NVMe copies of the models loaded most. Not in the request path. |
| `pi`, `opencode` | Client agents; their model lists are generated from Cortex at start. |

**Routing on `:8080`.** A request whose `model` is a section of a non-default router's `models.ini`
goes to that router; every other model goes to `llama-cpp` (`cortex.router_for`, re-reading each ini
at most every 5 s, so new entries route without a reload). **Model names must be unique across all
`models.ini` files.** A model that needs a build the others lack gets its own router, named for the
model, rather than moving another router's pin: each router's catalogue keeps the build it was benched
on. GETs are not coordinated but follow `?model=`; a GET naming no model reaches `llama-cpp`.
`GET /v1/models` on `:8080` is `models_list.lua`: every router's list merged, each id once from the
router that serves it; a router that is down only drops its own models.

**The coordinator** (`coordinator.lua`, access phase):
- **Only inference POSTs switch or count.** GET/HEAD/OPTIONS pass through (Open WebUI polls
  constantly). Ollama's management POSTs (`NON_INFERENCE`: `/api/show`, `/api/pull`, `/api/push`,
  `/api/create`, `/api/copy`, `/api/blobs/*`) also pass uncounted: counting them made a model-info
  lookup unload the resident model and kept `busy` set through a whole download. Inference-shaped
  calls stay coordinated, including an empty ollama `/api/generate` (how ollama loads a model) and the
  routers' `/models/load`, `/tokenize`, `/detokenize` (each loads the model it names).
- **State** is the shared dict `backend_state`: `backend` and `model` (the last inference request's).
  A request for a different backend or model switches.
- **One switch at a time.** The switcher takes the `switching` key (released by `log.lua` on every
  exit), drains the requests running on the current backend to zero (up to `DRAIN_TIMEOUT`, 600 s,
  then 503), unloads, and sets state. Others wait; afterwards a waiter for the new model goes through
  and one for another model becomes the next switcher. A request is counted in flight
  (`request_counts`) only once admitted, so concurrent switches never wait on each other (OpenCode
  sends requests for two or three models at once).
- **Counts are released only in the log phase** (`log.lua`, `log_by_lua_file` in every server block).
  A client that hangs up while held or draining is finished through `ngx.on_abort` → `ngx.exit(499)`.
- **Unloading** asks the backend what is loaded, then: ollama `POST /api/generate` with
  `keep_alive: 0`; every router `POST /models/unload` (`unload_llamacpp(key)`); nllb
  `POST /v1/models/unload`, plus `/shutdown` when switching away from it. With no state recorded
  (openresty just restarted), the first switch unloads whatever every backend reports loaded.
  Unloading is best-effort: if a backend does not answer, the request still proceeds and may OOM.
- **Humans first, bots never interrupted** (policy and constants in `cortex.lua`). A request with
  `X-Cortex-Client: bot` is a bot; anything else is a human, so an unmodified client gets priority.
  While a human waits, every new bot request is held, including one for the resident model. After a
  human request, a bot that would **evict** the resident model is held until no human request has
  finished for `HUMAN_HOLD` (120 s); a bot for the resident model goes through. A held bot is not
  counted and does not stamp `idle_for`; after `BOT_HOLD_CAP` (600 s) it gets 503 with
  `X-Cortex-Held: human` and `Retry-After`, which bots treat as "stand aside". Offline test:
  `python3 tools/test_coordinator.py` (throwaway openresty + `tools/coord_mock.py` on a private docker
  network, no GPU; `--ref HEAD` tests a commit).
- **`GET /availability`**, on every port (`availability.lua`, an exact-match location that never
  reaches the coordinator), reports `busy`, `idle_for`, `human_pending`, `human_idle_for`,
  `in_flight`, `slots`, `backend` and `model`, for schedulers that would rather wait than force a
  switch. `busy` is in-flight POSTs or any router slot `processing` (each server block's internal
  `/__slots/<host>`); `slots` is null when no router answers. `idle_for` is seconds since the last
  inference finished (`0` while one runs, `null` before the first).
- **Slot cache: a model keeps its processed prompt across swaps.** Before unloading a router model the
  coordinator saves slot 0 (`POST /slots/0?action=save`, KV cache and context checkpoints) to the
  router's `/slot-cache`; after loading the target (`POST /models/load`, `wait_until_loaded`) it
  restores that model's file while still holding the switch key, so the first request processes only
  its new tokens (measured: 30 tokens instead of 51K; save/restore 0.1–0.4 s). The router takes the
  model from the JSON body (`{"model","filename"}`) and answers chunked. Any failure only logs
  `slot-cache: …` and the request processes its full prompt. Settings in `cortex.lua`: `SLOT_CACHE`,
  the timeouts, and `slot_cache = true` per router, only for a build that writes context checkpoints
  into slot files (without them a restored slot is not reused). `bench.sh` sends
  `X-Cortex-No-Slot-Cache` so a measurement never reads a restored cache. Each router has a capped
  tmpfs at `/slot-cache` (emptied on every container start, so a file never outlives a `models.ini`
  change) and `slot-save-path = /slot-cache` in its `[*]`; `llama-cpp/slot-cache-entrypoint.sh`
  prunes by age (`SLOT_CACHE_TTL_MIN`) and size (`SLOT_CACHE_KEEP_GB`), then `exec`s `llama-server`.

**Naming.** Compose services use hyphens (`prism-llama-cpp`), Lua keys underscores
(`prism_llama_cpp`). A router's name is one word before `-llama-cpp`: nginx's internal locations
match `(?:[a-z0-9]+-)?llama-cpp`. `cortex.ROUTERS` holds each router's key, host and ini;
`coordinator.lua` builds its `HOST` table from it, plus `ollama` and `nllb`.

**Adding a llama.cpp router** (a model whose provider needs its own build):
- one line in `cortex.ROUTERS` (`key`, `host`, `ini = "/etc/nginx/<name>-models.ini"`); routing,
  `BACKENDS`, `HOST`, the unload sweep, `/availability` slots and the `/v1/models` merge follow from it
- compose: a `<name>-llama-build` (profile `build`) and a `<name>-llama-cpp` service (copy inkling's),
  the ini mount into openresty, and the HF-cache volume in `compose.override.yml`
- `<name>-llama-cpp/models.ini` and `models/`; `BENCH_BACKENDS` in `tools/bench.sh`, `BACKENDS` in
  `tools/gen_metrics.sh`, the `CORTEX_ROUTERS` default in `tools/model_cache.py`
- `EXTRA` in `tools/test_coordinator.py` (a mock and its models) and a scenario
- slot cache: `slot_cache = true` only if the build writes checkpoints into slot files (look for
  `restored from a slot file` in `libllama-server-impl.so`); then the tmpfs, entrypoint and
  `SLOT_CACHE_*` environment (copy inkling's) and `slot-save-path` in its `[*]`
- first deploy: `docker compose up -d <name>-llama-cpp openresty model-cache`

**Adding another kind of backend:** `HOST`; `TARGET` in `cortex.lua` (port → key; `log.lua` releases
the key in `ngx.ctx.target`); `BACKENDS` in `cortex.lua`; an unload function and the no-state sweep
in `switch_to`; a mock and a scenario in `tools/coord_mock.py` / `tools/test_coordinator.py`.

## Deploying changes

| Change | Apply with |
|---|---|
| Lua file or `nginx.conf` | `docker compose restart openresty`. These are single-file mounts: an editor that saves by rename (most do, including Claude Code's Edit) leaves the container on the old file, and `openresty -s reload` keeps it. Check with `docker exec cortex-openresty-1 grep … /etc/nginx/lua/<file>`. |
| `openresty/Dockerfile` | `docker compose build openresty && docker compose up -d openresty` |
| a router's `models.ini` | `docker compose restart <router>` (read only at start) |
| `openresty/scripts/`, `opencode/agents/`, `opencode/commands/` | nothing: directory mounts. A running OpenCode session may need a restart. |
| a new mount or volume in `compose.yml` | `docker compose up -d <service>` (recreate) |
| `model-cache` settings | `docker compose up -d model-cache` |
| `pi` / `opencode` images | `CACHEBUST=$(date +%s) docker compose build pi opencode`. Neither agent is pinned; a new `CACHEBUST` re-runs only the agent-install layer. |
| a llama.cpp build | `docker compose --profile build build <name>-llama-build`, then `docker compose up -d <router>` and re-bench |

**llama.cpp builds.** All builders share `llama-cpp/Dockerfile`. **`compose.yml` holds the pins**:
a release tag (`LLAMA_REF`), a commit (`LLAMA_COMMIT`, for a branch without tags), or a source archive
(`LLAMA_TARBALL` + `LLAMA_TARBALL_SHA256`, when a provider publishes the build only that way; the
build fails on a checksum mismatch). Bump a pin deliberately: each build is tagged with its pin, so the
previous image stays for rollback, and the router's records must be re-benched: a record keeps the
`build_info` of the build it was benched on until then (`docs/reference/llama-cpp-b12785-quick-ab.md`
has the last bump's A/B). A git tag named like an
archive release need not hold the same code (Unsloth's PR-list tags lack the `inkling2` arch their
tarballs carry): compare before choosing git. Build PrismML's fork from its `prism` branch release
tags; its `master` is a stale upstream mirror. An archive has no `.git`, so `--version` shows what its
`cmake/build-info.cmake` carries.

**Networks.** `cortex_network` is the compose-managed bridge. A shared network that clients use to
reach openresty is machine-specific: it goes in `compose.override.yml` (service `networks:` and a
top-level `external: true`) and must exist before `up`.

## Client agents (`pi`, `opencode`)

- **Model lists.** `openresty/scripts/models-common.sh` queries `CORTEX_URL/v1/models` and
  `OLLAMA_URL/api/tags` + `/api/show` (defaults `http://openresty:8080` and `:11434`) and writes Pi's
  `models.json` and OpenCode's `opencode.json`, with providers `cortex-llama-cpp` and `cortex-ollama`
  (not `llama`: that is OpenCode's built-in Meta Llama provider). It writes atomically, keeps a
  provider's existing block when that backend returns nothing (a backend still starting does not empty
  the list), and keeps other providers. The entrypoints retry the sync 10 times, 3 s apart.
  - **Context:** llama.cpp from `model-meta.json` / `meta.n_ctx` / `--ctx-size`. Ollama: the
    Modelfile's `num_ctx`, else `CORTEX_OLLAMA_CTX` (4096: Ollama's automatic default below 23 GiB of
    VRAM, from its log line `vram-based default context`), capped at the trained context. Do not set
    `OLLAMA_CONTEXT_LENGTH` on the ollama service: it disables Ollama's automatic context shrink when
    a load runs out of memory.
  - **Tools and images:** for Ollama from `/api/show` `capabilities`; for llama.cpp tools are assumed,
    because only a loaded model reports them. `model-meta.json` `tool_call` overrides both. Pi has no
    tool-support field and sends tools to every model.
  - **Output limit** (Pi `maxTokens`, OpenCode `limit.output`): `min(context/4, 16384)` unless
    `model-meta.json` sets `output`. Chosen 2026-11-04 from one day of logs, not measured as best.
- **Installers** (`install-pi.sh`, `install-opencode.sh`, served on every openresty port for
  `curl URL | sh`; apt or apk) install the agent and its model list; `--help` lists the flags. The
  official OpenCode v2 installer needs bash.
- **OpenCode agents and commands** are tracked in `opencode/agents/` and `opencode/commands/`,
  mounted read-write over the config volume. Design and open items: `docs/reference/opencode-agents.md`.
  They are OpenCode-specific (Pi has no agents or subagents). Machine-specific skills stay in the config
  volume.
- **OpenCode's background server** (`opencode serve --service`, port 49374) starts with the container
  (`OPENCODE_SERVICE=1`; `opencode/entrypoint.sh`). Its settings are the config volume's
  `service.json` (`opencode service get|set`). It listens on 127.0.0.1 unless `OPENCODE_HOSTNAME`
  (e.g. `0.0.0.0`, written to `service.json` at start) is set in `compose.override.yml` with a
  published port or a reverse proxy in front. `OPENCODE_PAIR_URL` makes a plain `opencode pair` add
  `--url` (`opencode/opencode-pair-url.sh`, installed as `/usr/local/sbin/opencode`); `--url` or
  `--remote` on the command line wins. Plain HTTP is guarded only by the server password: keep it on a
  LAN or VPN, or put HTTPS in front (Docker's published ports bypass host firewalls). `--remote` uses
  OpenCode's relay and stores a route in `service.json`.
- **OpenCode's data** (sessions, snapshots, logs) is kept in the config volume:
  `XDG_DATA_HOME=/root/.config/opencode/share`. `/root/.local/state/opencode` holds only the running
  server's record and is not kept.

## NVMe model cache (`model-cache`)

The models live on a slow disk; a 17–22 GB model took 1–3.5 min to load cold. `tools/model_cache.py`
copies the files loaded most to `/opt/cortex-models` on NVMe (measured: lfm-2.5-8b 46 s from the model
disk, 4.1 s from its NVMe copy).
- **Serving:** the HF cache stores each file as `snapshots/<rev>/<name>.gguf` → `../../blobs/<sha256>`.
  Promoting copies the blob to `/opt/cortex-models/<sha256>` (sha256-checked) and repoints the snapshot
  link; evicting repoints it back and deletes the copy. **The blob on the model disk is never touched.**
  `/opt/cortex-models` is mounted read-only at the same path in every router. Each load starts a new
  `llama-server`, which follows the link then; a loaded model keeps the file it opened.
- **Choosing:** it polls every router's `/v1/models` every 5 s; a preset turning `loaded` is one load of
  its `hf` file. On the 3rd load within 7 days the file is copied, with its `mtp-*.gguf` drafter and
  mmproj. Copies stay under 128 GB. **Eviction takes the lowest use score:** each load in the window
  counts `0.5 ** (age / 24 h)`. A model is copied only if it can make room from copies scoring below its
  own, so a one-off pass that loads every model once cannot push out models in daily use.
- **State:** `/opt/cortex-models/state.json`; on start and hourly it repairs dangling or unknown links,
  stale copies and `*.part` files. Settings are `CORTEX_NVME_CACHE*` in its `compose.yml` environment.
  `CORTEX_NVME_CACHE=off` points every link back, deletes the copies and exits.
- **A slow load usually means the file is not on the NVMe:** `docker logs cortex-model-cache-1` shows
  `evicted` and `SSD, load n/3`.

## Benchmarking

`tools/bench.sh` tunes and records llama.cpp router entries: batch, MTP settings, then a benchmark
JSON in `<backend>/models/`. Usage is in its header. **Method and evidence:
`docs/reference/benchmarking.md`.** What must not break:

- **Never run an untuned entry.** The `[*]` `batch-size`/`ubatch-size = 4096` is a deliberate fallback
  that OOMs on most entries. Tune first (`bench.sh all <model>`, or `bisect`); never set batch or MTP
  values by hand.
- **One `bench.sh` run at a time**, on any backend (it takes a `flock`; runs on different routers
  still fight over the GPU and the inis).
- **Families:** entries differing only in sampling, reasoning or chat-template keys share their
  head's record; only the head is benched. `-vision` entries and entries differing on memory keys are
  their own heads. Use `--no-inherit` when a pick sits within a factor of two of the spill ceiling.
- **Safety gates, never relaxed:** an OOM is read from the router log, never from the HTTP code; a CPU
  placement rejects a batch for a GPU-class model; a pick is validated only by saturation at ~99% ctx
  and a real-text long decode. A record with `discover.confirm: skipped` (batch-only) is not validated.
  Fast OOM grep: `docker logs --since 10s cortex-<router>-1 | grep -E "cudaMalloc failed|failed to
  allocate compute pp buffers|terminate called after throwing|failed to create MTP context|exiting due
  to model loading error|CUDA error: out of memory|cuMemCreate"`.
- **A load-only probe proves nothing:** OOM comes at the first decode, or at load for MTP models.
  Send a real inference request.
- **`-fit` never budgets the MTP draft:** on a tight model the draft lands on CPU silently (decode
  3–4× slower, CPU 270%+). Check placement again after any `spec-draft-n-max` change. Shrink the draft
  with `spec-draft-type-k/v = q4_0`; never use `spec-draft-ngl`, which pushes main-model layers to CPU.
- **MTP settings are speed-only** (output is unchanged by construction). MTP is kept only if it beats
  MTP off by more than 2%; `mtp.ab.decision: off` removes the spec-* keys. `-mtp` in a name marks an
  MTP-capable model, not MTP on.
- **The routers run offline** (`offline = true` in every `[*]`): an online load first asks Hugging Face
  for the file list, and a failed connection once stalled a load ~5 min while the coordinator waited.
  A model added by hand fails to load until fetched: `bench.sh fetch <entries…>` downloads with
  `tools/hf_fetch.sh`, pinned to the commit already cached; it falls back to a one-off online load
  only when the files cannot be resolved. **Going online can strand other quants of the same repo**
  (`refs/main` moves to the upstream head and offline loads look only in that snapshot);
  `strand_guard` lists what would stop loading and asks first (`BENCH_ALLOW_STRAND=1` without a
  terminal).

## Gotchas

- **`models-max` must not be set on a router.** The router would unload children itself, racing the
  coordinator's unloads and leaving residual VRAM. The coordinator is the only source of unloads.
- **`load-mode = mmap+mlock` in every `[*]`**, not `no-mmap`: `no-mmap` copies the GGUF into anonymous
  memory beside the page cache (~2× RAM) and `mlock` then locks nothing. Measured on a 35B MoE: RAM
  while loaded ~38.5 → ~23 GB, warm reload 20–27 → ~14 s; prefill −10%, decode +4–9% on the
  CPU-resident model. Never overwrite a loaded `.gguf` in place: truncating a mapped file kills the
  process with `SIGBUS` (download or copy-and-rename instead). b12785's warning `tensor overrides to
  CPU are used with mmap enabled - consider using --load-mode none` is not a reason to switch: on a
  35B MoE `load-mode none` loaded slower (15 s vs 8 s from NVMe) and held a ~15 GB private copy, for
  +25% prefill and the same decode.
- **Backends resolve at request time:** `proxy_pass` uses a variable, with `resolver 127.0.0.11
  valid=10s`. A router restart can hand its old IP to another router; with the default 600 s TTL,
  requests went to the wrong router (`model … not found`).
- **The drain blocks an nginx worker** (`ngx.sleep` in the access phase) for up to `DRAIN_TIMEOUT`. Do
  not raise it without weighing the concurrency cost.
- **A direct slot call loads the model it names.** `POST /slots/0?action=save|restore` for a model that
  is not loaded makes the router load it beside the resident one. Avoid such calls by hand.
- **`models_list.lua` must keep empty arrays as `[]`** (a private cjson instance with
  `decode_array_with_array_mt(true)`); the default round-trip turns `tags` / `aliases` into `{}`.
- **The coordinator's `http_request` must decode chunked replies:** the routers answer `/slots` that way.
- **`get_model()` reads the body in the access phase** (`ngx.req.read_body()`; nginx still forwards it).
  If it cannot parse a `model`, the coordinator unloads on a backend mismatch and skips on a
  same-backend model change.
- **Watch the coordinator:** `docker logs -f cortex-openresty-1 | grep '\[lua\]'` (prefixes
  `coordinate()`, `drain`, `switch:`, `state:`, `hold:`, `pass:`, `wait:`, `slot-cache:`). INFO-level
  logging is enabled by a `sed` in `openresty/Dockerfile`.

## File layout

```
cortex/
├── compose.yml, compose.override.yml (git-ignored), AGENTS.md, README.md, LICENSE
├── full-metrics.md        # every bench record in one table (tools/gen_metrics.sh)
├── openresty/
│   ├── nginx.conf           # shared dicts, 4 server blocks (80/11434/5002/8080)
│   ├── coordinator.lua      # routing, switching, unloads, slot cache
│   ├── cortex.lua           # routers, human/bot policy, constants
│   ├── availability.lua     # GET /availability
│   ├── models_list.lua      # GET /v1/models on :8080, every router merged
│   ├── log.lua              # log phase: releases counts, stamps idle times
│   ├── Dockerfile
│   └── scripts/             # client installers and model-list generators, served as text
├── llama-cpp/               # Dockerfile (every router's build), slot-cache-entrypoint.sh,
│                            # models.ini, models/ (bench JSONs)
├── prism-llama-cpp/, raon-llama-cpp/, inkling-llama-cpp/   # models.ini, models/
├── nllb/                    # Dockerfile, entrypoint.sh, server.py
├── pi/                      # Dockerfile, entrypoint.sh (model sync at start)
├── opencode/                # Dockerfile, entrypoint.sh, opencode-pair-url.sh, agents/, commands/
├── tools/                   # bench.sh, gen_metrics.sh, hf_fetch.sh, model_cache.py,
│                            # test_coordinator.py, coord_mock.py
├── docs/                    # reference/ (tracked), sessions/ (git-ignored)
└── tracker/                 # plans/, issues/, work-orders/
```

## Docs and tracker

Markdown about the project lives in two folders. **`docs/` holds documents you read; `tracker/` holds
items that move between states.** Outside them stay only files a tool expects in a fixed place
(`README.md`, `AGENTS.md`, `LICENSE`), markdown that code reads (`opencode/agents/`,
`opencode/commands/`) and generated output (`full-metrics.md`).

- `docs/reference/`: design, how-tos, runbooks and measured findings. Keep a reference doc current and
  edit it in place, without a change log; a dated finding is a record and is not rewritten later.
  Today: `benchmarking.md` (bench method and evidence), `CPU_POLLING.md` (placement measurement),
  `opencode-agents.md` (the OpenCode agents' design), `work-order-workflow.md` (how to use the
  triage agent), `nllb-translation-service.md` (the nllb API),
  `llama-cpp-b12785-quick-ab.md` (the last upstream bump's A/B) and
  `llama-cpp-tuning-and-version-gap.md` (untried llama.cpp knobs, 2026-11-22).
- `docs/sessions/`: session states and handoffs, named `YYYY-MM-DD-<topic>.md`. **Git-ignored**: they
  often hold private details and this repository is public. Delete one once it has been picked up;
  move anything lasting into `docs/reference/` or a tracker item first.
- `tracker/plans/`: blueprints and ideas, which may never be built.
- `tracker/issues/`: tangible items: bugs, features, improvements.
- `tracker/work-orders/`: one or more plans and/or issues organised into one actionable unit of work
  for an agent. An agent may also carry out a plan or an issue directly; a work order is where they
  are aggregated and ordered.

Each tracker has the same three states:

| | `open/` | `resolved/` | `closed/` |
|---|---|---|---|
| plan | still an idea | built, or turned into issues or a work order | dropped or rejected (a shelved plan stays open) |
| issue | to do | fixed or done | will not do, or no longer applies |
| work order | ready or in progress | carried out | abandoned |

- **Files:** `plan-NNNNNN-slug.md`, `issue-NNNNNN-slug.md`, `work-order-NNNNNN-slug.md`, the ID
  zero-padded to six digits and never reused. **Each tracker has its own sequence**: the next ID is one
  above the highest in all three of its folders, e.g.
  `ls tracker/issues/*/issue-*.md | sed 's/.*issue-0*\([0-9]*\)-.*/\1/' | sort -n | tail -1`.
  Start from the tracker's `TEMPLATE.md`.
- **Moving one:** `git mv` it to `resolved/` or `closed/`, set `**Status:**` to match, and add a
  **Resolution** section: what was done, what proved it, the commit; or why it was closed. Never
  delete a tracker file: the record of a rejected approach is the point.
- **Work orders** list their sources (`**Includes:** issue-NNNNNN, plan-NNNNNN`) and each source gets
  a back-link (`**Work order:** work-order-NNNNNN`). Tracker items name each other by ID, never by
  path: a folder changes with the item's state. An item is in at most one open work order.
  Resolving a work order moves the sources it fully covered to `resolved/` in the same commit; a
  source it only partly covered stays open with a note.
- **Work-order lifecycle:** the OpenCode `triage` writes work orders (`/triage`: it proposes the
  grouping and ranking, and writes on approval) and gives the final review (`/accept`). The builder
  (`/engineer <work order>`) adds only a `Report back, round N` section. The triage agent appends a
  `Review, round N` section: accepted (it moves the work order and the items it covered to
  `resolved/`) or returned (numbered blocker and nit findings, rulings, amendments). Reports and
  reviews are appended, never edited. A builder that finds the work order cannot be built as
  written stops with a `stopped: work-order defect` report; the triage agent answers with an amended
  round. After three returned rounds, or a second stop, the triage agent asks the user. The triage agent
  commits the tracker records it wrote, by explicit path; the builder commits only when the work
  order says so. Each step runs in a fresh OpenCode session; the work order is the hand-off.
- **Order of work:** `tracker/work-orders/triage.md` ranks the open work orders and lists the open
  issues left out of them, with the reason.
- **AGENTS.md, the README and code comments name no specific plan, issue or work order**: they
  state how things are, and the tracker holds the history behind them.
- **Public repository:** no personal names, hostnames, IPs or private paths in `docs/reference/` or
  `tracker/`.
- An item whose header predates the template keeps it; its folder is its state.
