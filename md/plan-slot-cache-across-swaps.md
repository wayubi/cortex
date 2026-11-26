# Plan: Keep each model's processed prompt across model swaps

**Date:** 2026-11-26
**Status:** Planned, not implemented. Nothing in this document is applied yet.
**Audience:** an implementing agent. Do the phases in order. Phase 0 needs a loaded model on the
GPU: **ask the user before running it** (cortex is in live use).

**Constraint (from the user, 2026-11-26): model weights are never kept in RAM on purpose.** Model
files are large and would exhaust host RAM quickly. Only the saved prompt state (the slot files)
may be kept, and it must be **bounded**: a size cap per router and an age limit, enforced
automatically. Weights stay in the page cache only as the kernel decides; nothing pins, copies or
preloads them (no `vmtouch -l`, no tmpfs copies of GGUFs, no warm-up loads).

---

## 0. Why this plan exists

The coordinator frees VRAM on every model change by calling the router's `POST /models/unload`. That
ends the model's `llama-server` child, and the child's KV cache (the conversation it has already
processed) is lost. When the model is loaded again, its next request re-processes the whole prompt.

With agent setups that alternate models (an orchestrator on one model, subagents on others), this
re-processing is now the main cost of a swap, not loading the weights.

Measured from the llama-cpp router log, 2026-11-25/26 (child log lines `load_model: loading model`,
`llama_server: model loaded`, and the first `prompt eval time` after each load):

| Model | Weight load (warm, from page cache) | First prompt after the load |
|---|---|---|
| groot-19b-a3b-iq3m-mtp-128k-think-coder | 3.5–3.8 s | 41,715–111,465 tokens, **22.9–84.2 s** |
| qwen-3.6-35b-a3b-q4-mtp-128k-think-coder | 11.6–12.5 s | 6,733–8,027 tokens, 8.2–10.0 s |

- 40 model loads in one 6-hour window (mostly groot ↔ qwen).
- Weights are not the problem: `load-mode = mmap+mlock` and the page cache already make warm loads
  fast, and the `model-cache` service covers cold loads.
- The waiting is re-processing a prompt the model had already processed before it was unloaded.

## 1. The mechanism: slot save / restore

llama.cpp's server can write a slot's state (its KV cache and the tokens it covers) to a file and
read it back:

- `--slot-save-path PATH` (preset key `slot-save-path`) enables it. Present in the pinned upstream
  build (`llama-server --help`).
- `POST /slots/{id}?action=save` with body `{"filename": "<name>"}` writes the slot to
  `PATH/<name>`.
- `POST /slots/{id}?action=restore` with the same body reads it back into the slot.
- After a restore, a request whose prompt starts with the saved tokens reuses them (the server picks
  the slot by longest common prefix and processes only the new tokens).

**The design:** before the coordinator unloads a llama.cpp model, it saves slot 0 to a RAM-backed
folder. When that model is loaded again, the coordinator restores the file before the first request
is proxied. A request that does not match the saved prefix (another client used the model in
between, or the client rewrote its history) costs what it costs today: a full prompt. Nothing gets
worse on a miss.

Every router runs `parallel = 1`, so slot 0 is the only slot.

## 2. Phase 0 — feasibility on one model (manual, needs the GPU; ask first)

Do this on `llama-cpp` with groot (or any model the user names). Record every result in this file
under "Phase 0 results" before going on. **Stop and report if any check fails.**

1. Add `slot-save-path = /slot-cache` to the `[*]` section of `llama-cpp/models.ini` and a tmpfs to
   the `llama-cpp` service (`tmpfs: - /slot-cache:size=8g` for the test). Recreate:
   `docker compose up -d llama-cpp`.
2. Load the model with a real conversation of ~30–60K tokens (one long request through openresty
   `:8080`).
3. **Routing check.** The router must pass the slot calls to the model's child. Try, in order:
   - `curl -s -X POST 'http://<router>:8080/slots/0?action=save&model=<entry>' -d '{"filename":"t.bin"}'`
   - the same with `"model":"<entry>"` in the JSON body instead of the query.
   Record which form works. If neither does, the router does not proxy slot calls: **stop** (the
   plan then needs a different design, e.g. calling the child port directly; report back).
4. **Size and time.** Record the response (`n_saved`, `n_written`, `timings.save_ms` or whatever
   this build returns), the file size (`ls -l /slot-cache` in the container) and the save time.
   Also record the file size per 1K tokens of context, so the caps in Phase 1 can be sized for the
   longest contexts in use (groot has re-processed up to ~111K tokens).
5. Unload the model (`POST /models/unload`), load it again (`POST /models/load`, poll `/v1/models`
   until `status.value == "loaded"`), then restore (`action=restore`, same routing form). Record the
   restore time.
6. **Reuse check.** Send the same conversation plus one new user message. In the child log, the
   `prompt eval time` line must show only the new tokens (hundreds, not tens of thousands). Record
   it.
7. Repeat 2–6 for qwen-3.6-35b 128k (a CPU-placed MoE) and one prism, raon or inkling model if the
   user agrees, because their builds differ.
8. Revert the test edits (`models.ini`, compose) unless the user says to keep them.

Acceptance: routing form known; save and restore each take seconds, not tens of seconds; the
follow-up request processes only the new tokens; file sizes known per model (they size the tmpfs).

### Phase 0 results

(to be filled in)

## 3. Phase 1 — routers: a bounded RAM folder for slot files

For **every** router in `cortex.ROUTERS` (`llama-cpp`, `prism-llama-cpp`, `raon-llama-cpp`,
`inkling-llama-cpp`):

1. **A size-capped tmpfs.** `compose.yml`: add a tmpfs mount at `/slot-cache` to the service, with a
   `size=` cap. A tmpfs uses RAM only for the files actually written, and can never exceed its cap
   (a save that would exceed it fails, and the coordinator treats that as a miss). Suggested caps,
   to be revised from the Phase 0 sizes: `llama-cpp` 16g (it serves most models in rotation),
   `raon-llama-cpp` 8g, `prism-llama-cpp` and `inkling-llama-cpp` 4g. The caps are host-specific:
   put the real values in `compose.override.yml` and leave neutral defaults in `compose.yml`.
   Worst case, the slot cache holds the sum of the caps; nothing else is kept.
2. **One file per model.** Each save overwrites `/slot-cache/<entry>.bin`, so a router never holds
   more than one file per model it serves.
3. **A pruner in each router container.** llama.cpp has no API to delete slot files, and a compose
   tmpfs is private to its container, so the pruner runs inside the router container. Override the
   service's `entrypoint` (the image's is `["llama-server"]`; keep the existing `command:`) with a
   small `sh -c` wrapper that starts a background loop and then `exec`s `llama-server "$@"`. Every
   `SLOT_CACHE_PRUNE_EVERY` (300 s) the loop:
   - deletes `*.bin` files not modified for `SLOT_CACHE_TTL_MIN` (120 min): a model not swapped
     back within two hours is not worth its RAM;
   - if the folder still holds more than `SLOT_CACHE_KEEP_GB` (default: 75% of the tmpfs cap),
     deletes the oldest files until it is under.
   Pass the three values as environment variables of the service, so they are tunable in
   `compose.override.yml` without editing the wrapper. Keep the wrapper in a tracked file
   (`llama-cpp/slot-cache-entrypoint.sh`, mounted read-only into each router) rather than inline
   YAML, so all routers share one copy.
4. **`models.ini`:** each `[*]` gets `slot-save-path = /slot-cache`.
5. **Stale files are impossible by construction:** a compose `tmpfs` is empty on every container
   start, and every `models.ini` change already needs a router restart (AGENTS.md). So a saved state
   can never be restored into a model whose settings or weights changed. Do not use a named volume
   or a host path for this, because those survive restarts.
6. **A pruned or missing file is harmless:** the restore answers "not found", the coordinator clears
   its dict entry, and the request processes its full prompt as it does today.
7. Deploy: `docker compose up -d <router>` for each.

Acceptance: `docker exec <router> df -h /slot-cache` shows the tmpfs with its cap; a router restart
empties it; a file older than the TTL disappears within one prune interval; with the folder filled
past `SLOT_CACHE_KEEP_GB` (test with small values), the oldest files are removed first; `llama-server`
is still PID 1's child that receives signals (`docker compose stop` stops it cleanly).

## 4. Phase 2 — coordinator: save before unload, restore after load

All in `openresty/coordinator.lua` and `openresty/cortex.lua`. Anchors are function names.

### Constants (`cortex.lua`)

- `M.SLOT_CACHE = true`: master switch. `false` restores today's behaviour exactly.
- `M.SLOT_SAVE_TIMEOUT = 60` (s), `M.SLOT_RESTORE_TIMEOUT = 60` (s), `M.MODEL_LOAD_TIMEOUT = 300`
  (s; a cold load from the slow SSD has taken up to ~3.5 min). Revise the two slot timeouts from the
  Phase 0 measurements (about 5× the slowest measured).

### `http_request` (coordinator.lua)

It sets `sock:settimeout(5000)`, which is too short for a save or a load. Add an optional last
parameter `timeout_ms`, default 5000, so existing callers are unchanged.

### Save: in `unload_llamacpp(key)`

For each model it is about to unload (`status.value == "loaded"`), when `cortex.SLOT_CACHE`:

1. `POST /slots/0?action=save` routed to that model (the form from Phase 0), body
   `{"filename": "<m.id>.bin"}`, timeout `SLOT_SAVE_TIMEOUT`.
2. Log `slot-cache: saved <m.id> (<bytes>, <ms>)` or a WARN with the error.
3. Record success in `backend_state` as key `slot:<m.id>` (value: the time saved).
4. **A failed or timed-out save never blocks the unload.** Go on to `/models/unload` as now.

File names: one file per models.ini entry, overwritten on each save. Entry names are unique across
all models.ini files (AGENTS.md), so files cannot collide.

### Restore: at the end of `switch_to`, for a llama.cpp router target

After the state is set and before returning `"ok"`, when `cortex.SLOT_CACHE`, `cortex.ROUTER[target]`
and `target_model`, and `backend_state` has `slot:<target_model>`:

1. `POST /models/load` `{"model": target_model}` on `HOST[target]`.
2. Poll `GET /v1/models` every 0.5 s until that model's `status.value == "loaded"`, up to
   `MODEL_LOAD_TIMEOUT`. Write this as a new helper `wait_until_loaded(key, model, timeout)` next to
   `wait_until_clear`.
3. `POST /slots/0?action=restore` routed to the model, body `{"filename": "<target_model>.bin"}`,
   timeout `SLOT_RESTORE_TIMEOUT`.
4. Log `slot-cache: restored <model> (<ms>)`, or a WARN, and delete `slot:<model>` from the dict on
   a "file not found" answer (the router restarted and its tmpfs is empty).
5. **Any failure (load timeout, restore error) only logs.** The request proceeds as today; it will
   load the model and process its full prompt.

Why inside `switch_to`: it runs while the request holds the switch key, so no other request reaches
the model between the load and the restore, and the waiters behave as for any switch.

### Switch key lifetime

`SWITCH_TTL` is `DRAIN_TIMEOUT + UNLOAD_CONFIRM_TIMEOUT + NLLB_READY_TIMEOUT + 30`. Add
`SLOT_SAVE_TIMEOUT + MODEL_LOAD_TIMEOUT + SLOT_RESTORE_TIMEOUT`, or the key can expire mid-switch and
let a second switcher in.

### The no-state sweep

`switch_to` with `current_backend == nil` unloads whatever each router reports. It calls
`unload_llamacpp`, so it will also save. That is correct: the state is valid until the router
restarts.

### What does not change

- ollama and nllb: no slot API; untouched.
- GET requests, `/availability`, the human/bot policy, drain and counts.
- Same-model requests: no unload, so no save or restore.

## 5. Phase 3 — tests

`tools/coord_mock.py` and `tools/test_coordinator.py` (offline, no GPU):

1. Mock: implement `POST /slots/0?action=save|restore` (record calls; `restore` of an unknown file
   answers with an error like llama.cpp's), `POST /models/load` (sets the model loaded after a short
   delay), and a switch to make a save slow or fail.
2. Scenarios:
   - switch A → B saves A; switch B → A restores A, after the load and before the request is
     proxied;
   - a failing save still unloads and switches;
   - a slow save beyond `SLOT_SAVE_TIMEOUT` still unloads and switches;
   - restore of a missing file: the request proceeds; `slot:<model>` is cleared;
   - `SLOT_CACHE = false`: no slot calls at all (today's call sequence exactly);
   - a request that arrives during the restore waits for the switch, like any waiter;
   - ollama/nllb switches make no slot calls.
3. `python3 tools/test_coordinator.py` passes, and `--ref HEAD` still passes against the old commit
   for the unchanged scenarios.

## 6. Phase 4 — measure on the live stack (ask first)

Run a real orchestrated session (or replay the groot ↔ qwen pattern) and compare with section 0:

- First `prompt eval time` after each groot reload: target a few hundred to a few thousand tokens,
  against 41–111K today.
- Total switch time (openresty `switch:` line → first token), including save and restore.
- RAM: tmpfs usage per router (`df -h /slot-cache` in each container) over a day of normal use;
  confirm it stays under the caps and that the pruner removes idle files.

Record the numbers here and in AGENTS.md.

## 7. Phase 5 — docs

AGENTS.md "Architecture": one bullet on the slot cache (save before unload, restore after load, the
tmpfs, the constants, the master switch, that misses fall back to today's behaviour). Update the
"Gotchas" list if Phase 0 or 4 found something surprising.

## 8. Related ideas, not in this plan

Each needs its own decision; listed so they are not lost.

- **Same-model subagents re-processing each other's prompts.** With one slot, subagents that share a
  model are served one after another, and each switch between their conversations re-processes the
  prompt. `--cache-ram` (default 8192 MiB in this build) should keep idle slot states in RAM, but no
  prompt-cache activity shows in the logs. Check whether it engages with `parallel = 1`, and try a
  larger value. Separately, `parallel = N` on a dedicated entry gives real concurrency (llama.cpp
  splits `ctx-size` across the slots; needs re-tuning and a bench).
- **Pinning model files in RAM: rejected** (the user, 2026-11-26; also `md/plan-model-load-speed.md`).
  Model files would exhaust host RAM. Warm loads are already 3.5–12.5 s from the page cache.
- **A CPU-only resident router** for one role (no swaps at all). CPU prefill would be far slower,
  and it would compete with CPU-placed models for cores. Unmeasured; a separate plan.
- **Several slots per model** (`parallel > 1`): this plan saves and restores slot 0 only.

## 9. Out of scope

- ollama and nllb.
- Changing which model a role uses, or the agents' batching rules.
- Any change to `bench.sh` beyond what a new `[*]` key needs (none expected: benches restart the
  router, which empties the tmpfs).
