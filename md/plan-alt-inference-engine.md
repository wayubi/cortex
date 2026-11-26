# Plan: evaluate a second inference engine for Inkling 2 Mini (Strata, Maya, UnbiasedStrata)

Status: research only (2026-11-25). Nothing is built, deployed, restarted or benched. Every
claim below about an engine comes from its own README/docs/release notes as read by a
research agent; none was reproduced here. Numbers are the projects' own, on their hardware.
"Unmeasured" means no measurement exists on this machine.

For the agent who implements this: **do not run bench.sh, restart a router, build a CUDA image
or send an inference request without asking the user first** (cortex is in live use).
Reading, drafting files and offline tests (`python3 tools/test_coordinator.py`) need no ask.

## 1. Why this exists

A third party claims Inkling 2 Mini runs much faster on their engine than on llama.cpp.
Candidates: Strata (original, Niko1221), Project Maya's Inkling engine (`maya-ik2`), and
robertkarl/UnbiasedStrata. The user wants to know (a) whether any is worth adding, (b) how it
would plug into cortex's openresty, (c) which supports more models. **Constraint from the
user: no extra bells and whistles; cortex already does routing, switching, queueing, model
listing and client config.** An engine is added only as a backend that holds a model.

## 2. What cortex needs from any backend (read from the code)

From `openresty/cortex.lua` and `openresty/coordinator.lua`:

- A router on :8080 is picked by **model name**: the first `cortex.ROUTERS` entry whose
  `ini` (bind-mounted at `/etc/nginx/<name>-models.ini`) has a section with that name; every
  other model goes to `llama_cpp`. Section names must be unique across all ini files. Only the
  section names are read, so a names-only ini is enough for routing.
- Port **8080 is hardcoded** in `cortex.upstream()` and in `unload_llamacpp`/`is_llamacpp_clear`.
  An engine behind a `ROUTERS` line must listen on 8080 inside its container.
- Unload (`unload_llamacpp`): `GET /v1/models`, then for each entry with
  `status.value == "loaded"`, `POST /models/unload` with `{"model": id}`. Clear check:
  `GET /v1/models` again. An unreachable backend counts as nothing loaded.
- Loading is implicit: the first proxied inference request for a model loads it
  (`/models/load`, `/tokenize`, `/detokenize` are also coordinated).
- `/availability` sums `/slots` from each router; no `/slots` gives `slots: null`, and the
  in-flight POST count still marks the backend busy. Not a blocker.
- Rules in AGENTS.md that apply: the coordinator is the **only** thing that unloads
  (llama.cpp's self-unload leaks VRAM); one model owns the GPU at a time.

## 3. Findings per engine

### 3.1 Strata (original) — github.com/Niko1221/Strata
- MIT. v0.2.22 released 2026-11-25 (nine releases in ~10 days; pre-1.0). 961 open issues.
- Python HTTP server (OpenAI, Responses and Anthropic APIs) in front of a C++/CUDA engine.
- **Inkling 2 Mini on NVIDIA CUDA/Linux: yes** (`strata-inkling`). Files: its own SQ-10 /
  SQ-15 / SQ-20 `.strata` packs (10.5 / 14.4 / 19.4 GB), **or the Unsloth UD-Q4_K_XL GGUF
  directly** (release 0.2.20: lossless `GGUF_RAW` execution).
- Host-RAM expert offload by design (hot experts in leftover VRAM, cold experts in RAM with CPU
  workers). Flags seen in release notes: `--vram-experts-gb`, `--ram-experts-gb`,
  `--ssd-experts`, `--kv-offload auto`, `--layer-split auto`. How they are passed (`--set
  KEY=VALUE`?) is not documented in the pages read.
- Launch: `strata launch --family inkling-2-mini --model SQ-10 --yes --no-tui`, or Docker
  (`ghcr.io/niko1221/strata:<ver>-cuda13`, env vars `FAMILY`, `MODEL`, `MODEL_PATH`,
  `CONTEXT`, `KV`, `PARALLEL`, `PORT`, ...). Default port 8080. cuda13 flavor needs driver 580+,
  cuda12 flavor 575+. Docker advice: `--ulimit memlock=-1:-1 --shm-size 2g --stop-timeout 120`,
  no container memory limit.
- Endpoints documented: `/v1/chat/completions`, `/v1/responses`, `/v1/messages`, `/v1/models`,
  `/health` (no key), `/metrics`. **Not found:** `/props`, `/slots`, `/tokenize`, any unload
  or switch endpoint. `model` field checking: not documented. `reasoning_effort` supported
  (default low if unset); `chat_template_kwargs` not documented. `--parallel N` slots.
- Lifecycle: model loads at launch. `--stop` / `docker stop` frees VRAM (Inkling stop <1 s;
  Inkling SQ-10 ready in ~21 s on an AMD card). `lazy_load` / `idle_unload_s` settings exist,
  defaults unknown.
- Published speed: HF card, SQ-10, thinking off, DSpark draft on: RTX 5070 12 GB 93.9–101.4
  decode tok/s; 2080 Ti 11 GB hybrid 42.8. No RTX 3060 row, **no llama.cpp baseline**. Release
  notes compare only to Strata's own earlier versions. SQ-10 is a lossier quantization than
  UD-Q4_K_XL (card: 92.35% same-word vs the original), so those figures are not comparable.
- Stability notes from release notes: Inkling reasoning loops still open (#7092); idle
  connection drops through a proxy at 125 s on `/v1/responses` (fixed 0.2.22; relevant to
  nginx timeouts).
- Models: Inkling 2 Mini, Qwen3.8-Flash-Next, Qwen3.6-35B-A3B, Hy4-Flash. Backends CUDA, HIP,
  SYCL, Metal.

### 3.2 Project Maya Inkling engine — github.com/alesha-pro/maya-inkling-mini
- MIT code, branch of Project Maya v1.1.70 (parent mw00/project-maya, 3.4k stars). Branch is
  Inkling only; other Maya models "aren't maintained here".
- Engine binary `build/maya-ik2`, launched through `python serve/server.py --engine maya
  --config <cfg>.json --host ... --port ...`. Config JSON keys: `exe`, `args`, `env`,
  `tokenizer`, `model_name`. Needs a tokenizer step from the GGUF (`tools/strata_tokenizer.py`).
- Reads **UD-Q4_K_XL GGUF only** from a plain `--model` path. HF-cache snapshot path: not
  documented.
- **12 GB-class config exists**: `docs/inkling2-mini/ik2-mini-8gb.json` (`--max-context 16384
  --chunk 512 --cache-gb 7 --threads 8`; env IK2_CPU=1, IK2_UP_MS=5, IK2_CPU_Q8=1,
  IK2_LAZY_CPU=1, IK2_LAZY_MAX=2, IK2_LAZY_PER=1, IK2_DENSE=q8, IK2_ROOM_MIB=256,
  IK2_GATE_TILE=64, IK2_GATE_BF16=1, IK2_Q8_UNROLL=1, IK2_BATCH_PREFILL=1). Experts sit in
  pinned host RAM (14.7 GiB). KV is **FP8 only** (`IK2_KV=fp8`, ~16 KB/token); no q4_0.
- Its own numbers (vendor, unreproduced), RTX 3090, all in VRAM, greedy: decode 128.7 vs
  llama.cpp b12590 57.0; prefill 2,742 vs 1,052 at 4K; at 64K depth 42.7 decode / 630 prefill
  for llama.cpp. 8 GB laptop with experts in RAM: 40–43 tok/s vs llama.cpp 12.5 at 16K; 36 at
  32K, 32 at 64K. The one engine with a llama.cpp comparison. Maya's two pages disagree on
  launch counts (757 vs 781 per token).
- API: `/v1/chat/completions`, `/v1/responses`, `/v1/messages`, `/tokenize`, `/detokenize`,
  `/v1/models`, `/models`, `/props`, `/slots`, `/health`, default port not stated (examples
  18000, configurable). Unload: `/models/load` and `/models/unload` are documented for parent
  Maya (`MAYA_MODEL_MANAGEMENT=0` turns them off); **not confirmed for this branch.**
  Context overflow returns 400, never truncates. `model_name` in the config is
  `inkling-2-mini`; whether a mismatched `model` is rejected is not documented.
- No Docker build for `maya-ik2`: the repo's `docker/Dockerfile` builds `maya`, `maya-ds4`,
  `maya-mm3` only. Build recipe: CMake, CUDA 12.8+/13, Ninja, `-DCMAKE_CUDA_ARCHITECTURES=86`
  (the RTX 3060's arch), target `maya-ik2`. Build time and minimum driver not documented.
- Open issues of note: #13 (possible attention-kernel correctness bug at a window edge,
  unconfirmed), #15 (Unsloth moved files; affects download paths).

### 3.3 UnbiasedStrata — github.com/robertkarl/UnbiasedStrata
- MIT, fork of PolyStrata v0.1.45-poly.1 (PolyStrata built on Strata). README: "Works on my
  machine." 280 stars, 247 commits.
- `unbiased-strata` is a **single C++ front end** (llama.cpp server/common/mtmd code) that
  starts one engine as a child (`--engine strata-ik2 -m <gguf> --alias <name> --port 8080 --
  <engine flags>`). Endpoints like llama.cpp: `/v1/chat/completions`, `/v1/models`,
  `/health` (reports `busy`, `loaded`), `/props`, `/tokenize`, `/detokenize`. One request at a
  time. **No unload endpoint, no model switching, no router mode** (those belong to upstream
  PolyStrata's removed Python server).
- Inkling CUDA engine `strata-ik2` is Maya's engine, pinned to alesha-pro/maya-inkling-mini
  commit `e819852f…`. Documented runs: full-GPU on 3090 24 GB and A6000 48 GB, FP8 KV. **No CPU
  offload for Inkling is documented**, nothing on 12 GB.
- Its Inkling table is fork vs stock Maya on an A6000, one run per depth: within about 1–3%
  everywhere (slightly slower at 340K). **No llama.cpp comparison.** It adds no Inkling speed
  over Maya.
- No Dockerfile (removed on purpose); source build via `make inkling CUDA_ARCHS=86`.
  Provenance of `src/ik2` (vendored vs fetched) not confirmed.
- Models: Qwen3.8-Flash-Next (packs), Qwen3.6-35B-A3B (GGUF in place), GLM 5.3 Flash,
  DeepSeek V4.1 Flash (needs 46+ GB RAM; upstream quotes 7.2 tok/s on a 3060 12 GB, not
  measured in this fork), Hy4-Flash (.strata packs), Inkling 2 Mini.
- Open: #36 "100% of a single core for no reason on inkling 2"; PR #24 says the thinking
  budget is not enforced in the front end.

## 4. Comparison

| | Strata | Maya | UnbiasedStrata |
|---|---|---|---|
| Prebuilt image | yes (GHCR) | no (and repo Dockerfile skips ik2) | no |
| Reads your UD-Q4_K_XL GGUF | yes (`GGUF_RAW`) | yes | yes |
| Inkling host-RAM offload on 12 GB | documented by design | documented config (16K ctx) | not documented |
| llama.cpp comparison | none found | yes (vendor, 3090 + laptop) | none |
| HTTP unload | none found | parent only, unconfirmed here | none |
| llama.cpp-style `/props` `/tokenize` | not found | yes | yes |
| `/slots` | not found | yes (shape unknown) | not found |
| Models beyond Inkling | Qwen3.8-Flash-Next, Qwen3.6-35B-A3B, Hy4 | none on this branch | + GLM 5.3 Flash, DeepSeek V4.1 |
| Churn / maturity | very high | medium | low, self-described fragile |

## 5. How to plug an engine into cortex (shared design)

Goal: no change to coordinator policy; the engine looks like another llama.cpp router.

1. **Name the backend for the engine** (AGENTS.md rule: a router is named for what it needs),
   one word before `-llama-cpp` is required by nginx's location regex. A non-llama.cpp
   engine would not match `…-llama-cpp`; **decide the compose service name first and check
   `openresty/nginx.conf` for the `(?:[a-z0-9]+-)?llama-cpp` match.** Either keep the
   `*-llama-cpp` hostname (simple; slightly misleading) or widen that regex (small nginx.conf
   edit + `docker compose build openresty`). Do not guess: read the nginx.conf locations.
2. **One line in `cortex.ROUTERS`** (`key`, `host`, `ini = "/etc/nginx/<name>-models.ini"`),
   plus a names-only `<name>-models.ini` (section = model name, as sent in the request) and the
   ini mount into openresty. The engine **must listen on 8080**.
3. **A small lifecycle shim** (in `tools/`, run as the container's main process): none of the
   engines documents an HTTP unload. The shim should only
   - answer `GET /v1/models` with `{data:[{id, status:{value:"loaded"|"unloaded"}}]}`,
   - start the engine child on the first proxied request for its model,
   - on `POST /models/unload` terminate the child and confirm the GPU memory is released,
   - pass every other request to the child on an internal port (streaming without buffering).
   No scheduling, queues, auth, UI or model download beyond that. If a candidate's
   `/models/unload` is confirmed to work (Maya branch), skip the shim.
4. Compose: a service for the engine (image or build), the ini mount, the model-file volume,
   and `ulimit memlock` / `shm_size` as the engine docs require. Machine-specific bits go in
   `compose.override.yml`, not tracked files.
5. Not needed: `HOST`/`TARGET`/`BACKENDS` edits (follow from `ROUTERS`), a new unload function,
   `/availability` changes. The model-cache polls router `/v1/models` for `loaded` presets and
   uses the HF cache; a non-llama engine will not take part in it. Not a blocker.
6. Offline test: add a mock for the engine to `tools/coord_mock.py` (`EXTRA` in
   `tools/test_coordinator.py`) and a scenario for a switch to and from it.
7. nginx: keep `proxy_buffering off` for streaming and set read timeouts above the longest
   thinking turn (Strata release notes mention drops through a proxy at 125 s).
8. Bench: `bench.sh` only knows llama.cpp routers. Do not extend it for this; compare with a
   short manual script (see §7), written in `tools/`.

## 6. Broader model support (user's question)

Strata (original) is the broadest: Inkling, Qwen3.8-Flash-Next, Qwen3.6-35B-A3B and Hy4-Flash,
with Inkling and Qwen3.6 usable from GGUF. UnbiasedStrata adds GLM 5.3 Flash and DeepSeek V4.1
Flash, but the DeepSeek and Hy4 files are 120+ GB and none is documented on a 12 GB card by
that fork. Maya's Inkling branch supports Inkling only. Of all of these, the models you
already serve through llama.cpp are Inkling and Qwen3.6-35B-A3B, so a second engine adds
capability only if it is measurably better on those.

## 7. Proposed steps (each needs user approval before touching the GPU)

1. **Read-only gaps first** (no approval needed): Strata `docs/DETAILS.md` (does the API check
   `model`? any unload route? how to pass `--vram-experts-gb`/`--ram-experts-gb`?), Strata
   Issues for Inkling on 30-series cards, Maya `serve/server.py` for `/models/unload` and `/slots`
   on the `maya-ik2` branch, UnbiasedStrata `src/ik2` provenance, and the Strata image tags
   (docs show 0.2.20, latest release 0.2.22).
2. Pull your own baseline: read `inkling-llama-cpp/models/*.json` (bench records, if any) and
   `inkling-llama-cpp/models.ini` for the entries to compare. Unmeasured if none exist.
3. With the user's go-ahead and a free GPU: run **one engine at a time, outside cortex's
   router**, with the **same UD-Q4_K_XL file**, same context (start 16K and 64K, the contexts
   the offload configs document), median of at least 3 runs, decode and prefill reported
   separately, thinking effort matched (`reasoning_effort` 0.1 on the llama.cpp side is in
   `inkling-llama-cpp/models.ini` now). Record GPU placement and host RAM use. Order:
   Strata (`GGUF_RAW`), then Maya. Skip UnbiasedStrata unless its llama.cpp-style API is wanted.
4. Only if one clearly beats the current build at the contexts actually used: write the shim,
   the compose service and the `ROUTERS` line (§5), run `tools/test_coordinator.py`, then ask
   before the first real deploy (`docker compose up -d <service> openresty`).
5. If nothing wins: leave cortex unchanged; this file stays as the record.

## 8. Open risks to confirm before building anything

- Whether any engine rejects, ignores or mis-handles the request `model` name (cortex sends
  the models.ini section name).
- Whether `reasoning_effort` and client-sent tool calls behave the same as on llama.cpp
  (Maya notes malformed tool-call JSON, issue #2; Strata notes Inkling reasoning loops, #7092).
- Whether the container releases all VRAM on stop, as the coordinator's next switch assumes.
- FP8-only KV (Maya) versus the `q4_0` KV the llama.cpp entries use: context capacity differs.
- Engine churn: Strata ships near-daily; pin an image tag if adopted, as cortex pins builds.
- Licenses are MIT for code; Inkling weights are Apache-2.0 (Thinking Machines).

## 9. Sources (as read by the research agents, 2026-11-25)

- github.com/Niko1221/Strata (README, AGENTS.md, docs/AI_REFERENCE.md, DOCKER.md,
  SOURCE_INSTALL.md, TERMINAL_LAUNCH.md, releases) and huggingface.co/strata-engine/Inkling-2-Mini-Strata
- github.com/alesha-pro/maya-inkling-mini (README, docs/INKLING2-MINI.md,
  docs/inkling2-mini/ik2-mini-8gb.json, docker/Dockerfile, serve/server.py head, issues) and
  github.com/mw00/project-maya
- github.com/robertkarl/UnbiasedStrata (README, bench/inkling/README.md, UPSTREAM.md,
  Makefile, docs/MEMORY_LAYOUT.md, MODEL-FILES.md, HY4.md, DEEPSEEK41.md, BACKENDS.md
  partially, issues/PRs)
- Local: `openresty/cortex.lua`, `openresty/coordinator.lua` (unload and routing code).
- Not read: Strata `docs/DETAILS.md`, `INSTALL.md`, `MODELS.md`; Strata Issues tab; most of
  Maya `serve/server.py` and `docs/SETTINGS.md`; UnbiasedStrata `CMakeLists.txt` ik2 section
  and the last 22K characters of `BACKENDS.md`.
