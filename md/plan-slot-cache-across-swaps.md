# Plan: Keep each model's processed prompt across model swaps

**Date:** 2026-11-26
**Status:** Phases 1-5 done 2026-11-26 (AGENTS.md: Architecture bullet, router checklist, layout, Gotchas). Phases 1-4 done 2026-11-26 (live: groot re-processes 30 tokens instead of 51K after a swap back). Phases 1-3 implemented 2026-11-26 (offline tests pass; see Implementation notes). Plan revised 2026-11-26 after review (prism excluded, bench opt-out, explicit `command:`,
no restore bookkeeping, caps from Phase 0). Phase 0 **passed** 2026-11-26 on upstream b12785 (the `llama-cpp` router's new pin) for
groot and mellum, and on raon's build. It failed on the old pin b10622 (no context checkpoints in
slot files). Phases 1-5 are ready to implement for `llama-cpp`, `raon-llama-cpp` and
`inkling-llama-cpp` (their builds carry PR #26004); `prism-llama-cpp` (b10777) does not, so its
models keep today's behaviour.
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

Run 2026-11-26 on `llama-cpp` (pinned upstream build), test settings reverted afterwards.
Prompt: ~51-53K tokens of repo documents through openresty `:8080`, `max_tokens 400`,
`temperature 0`; follow-up = the same messages plus the assistant's answer and one new user message.

| Check | groot-19b IQ3_M 128k (arch `qwen35moe`, hybrid) | mellum-12b 128k (arch `mellum`, SWA) |
|---|---|---|
| Routing form | model in the **JSON body** works; `?model=` in the query answers 400 "model name is missing" | same |
| Save | 51,387 tokens, 363 MB (~7.1 KB/token), **0.19 s** | 53,348 tokens, 228 MB (~4.3 KB/token), **0.13 s** |
| Reload (weights) | ~3.6 s | 3 s |
| Restore | 51,387 tokens, **0.16 s** | 53,348 tokens, **0.12 s** |
| Follow-up after restore | slot picked by LCP (sim 1.000, keep 0.992), but **all 51,010 tokens re-processed** (29.3 s) | slot picked by LCP (keep 0.993), **all 52,972 tokens re-processed** (18.7 s) |
| Follow-up without unload (control, groot) | 22 tokens processed, 51,006 cached (0.23 s) | — |

**Why it fails.** The saved state ends after the generated tokens (prompt + 400). A chat follow-up
re-renders the previous assistant turn differently from the raw generated tokens (thinking stripped,
end-of-turn tokens), so the new prompt diverges ~400 tokens before the end of the saved state and the
server must roll back. Hybrid/recurrent models (`qwen35moe`: groot, qwen-35B; `raon1`) cannot roll
back recurrent state, and SWA models (mellum, gemma4) cannot roll back their window, without a
**context checkpoint**. Inside a running server llama.cpp keeps checkpoints (`--ctx-checkpoints`,
default 32, min spacing 8192), which is why the control re-processed only 22 tokens. The slot file
does not carry them (`n_restored` = tokens only), so after a restore the server re-processes
everything. Architectures checked from the GGUF headers: groot and qwen-3.6-35B `qwen35moe` (ssm),
raon `raon1` (ssm), mellum `mellum` (SWA), gemma-4 `gemma4` (SWA): every model in the agent plan is
affected. qwen-35B and the other routers were therefore not tested.

**Options before Phases 1-5 make sense (each needs its own check):**

1. **A llama.cpp build whose slot save/restore includes context checkpoints.** Check upstream for
   such a change; if it exists, re-run Phase 0 on a test build. Bumping the pinned build re-benches
   the router (AGENTS.md), so test on a separate image first.
2. **Make the follow-up an exact extension of the saved tokens**, so no rollback is needed: the log
   suggests `--reasoning-preserve` ("chat template supports preserving reasoning"), which keeps the
   thinking in the re-rendered assistant turn. It only helps if the client sends the reasoning back
   and the re-render then matches the generated tokens exactly. Testable with one request pair.
3. **Do not end the child process on a swap.** Explore whether a child can free VRAM but keep its
   KV/checkpoints in host RAM (e.g. `--sleep-idle-seconds` behaviour), instead of the router's
   unload. Unknown; read the code before testing.

**Option 1 checked, 2026-11-26: the fix exists upstream.** llama.cpp PR #26004, "server : preserve
context checkpoints across slot save/restore" (merged 2026-10-08), appends the slot's context
checkpoints to the slot file and restores them. #30137 (merged 2026-11-05) adapted it to
reference-counted checkpoints without changing the file behaviour. First release tag containing it:
not determined. Builds in use, from strings in each binary:

| Router | Build | Checkpoints in slot files |
|---|---|---|
| llama-cpp | upstream b10622 (pinned 2026-08-25) | no |
| prism-llama-cpp | fork at b10777 | no |
| raon-llama-cpp | KRAFTON fork, upstream ~b11729 (`fb895662d`, 2026-10-20) | yes |
| inkling-llama-cpp | Unsloth b12588 (the running container; compose pins b12651, not yet recreated) | yes |

**Phase 0 on raon** (`raon-1-mini-q5-128k-think-coder`, arch `raon1`, hybrid; same procedure,
~17K-token prompt; test settings reverted afterwards):

| Check | Result |
|---|---|
| Routing form | model in the JSON body (as on llama-cpp) |
| Save | 17,344 tokens, 191 MB including 2 context checkpoints (96 MiB), **0.10 s**; log: `appended 2 context checkpoint(s)` |
| Reload (weights) | 18 s |
| Restore | 17,344 tokens, **0.11 s**; log: `restored 2 context checkpoint(s)` |
| Follow-up after restore | **72 tokens processed, 17,219 cached** (1.8 s), against 17,223 tokens / 18.5 s for the first request |

So the mechanism works for a hybrid model once the build carries the checkpoints. Groot and
qwen-35B (`qwen35moe`) are the same model class; mellum and gemma (SWA) rely on the same checkpoint
mechanism but were not re-tested on a new build.

**Next steps:**

1. Build a **test image** of upstream llama.cpp from a release tag after 2026-10-08 (preferably after
   #30137), tagged separately so `llama-cpp:latest` and the pinned b10622 stay untouched; run Phase 0
   with groot and mellum on it (a temporary service or a temporary image swap, reverted after).
2. Moving the `llama-cpp` router to that build is a separate decision: AGENTS.md requires a re-bench
   of its catalogue, which was benched on b10622. prism-llama-cpp lacks the fix too.
3. Phases 1-5 then apply to the routers whose builds carry the fix.

**Phase 0 on b12785** (after the `llama-cpp` router moved to it; same procedure as above, test
settings reverted afterwards):

| | groot-19b IQ3_M 128k-think-coder | mellum-12b 128k-think |
|---|---|---|
| First request (no cache) | 50,988 tokens, 22.9 s | 52,949 tokens, 17.5 s |
| Save (incl. 2 context checkpoints) | 495 MB (checkpoints 126 MiB), 0.24 s | 253 MB (checkpoints 24 MiB), 0.12 s |
| Reload (weights) | 4 s | 2 s |
| Restore | 0.20 s, `restored 2 context checkpoint(s)` | 0.13 s, `restored 2 context checkpoint(s)` |
| **Follow-up after restore** | **30 tokens processed, 50,984 cached, 0.28 s** | **77 tokens processed, 52,944 cached, 0.26 s** |

Sizes for sizing the tmpfs caps (Phase 1): ~9.7 KB/token for groot and ~4.7 KB/token for mellum
including checkpoints; raon ~11 KB/token. At groot's longest observed context (~111K tokens) a file
is ~1.1 GB.

Test artefacts (request script, outputs) were in the session scratchpad, not in the repo.

## 3. Phase 1 — routers: a bounded RAM folder for slot files

For the routers whose builds carry context checkpoints in slot files (upstream PR #26004):
`llama-cpp` (b12785), `raon-llama-cpp` (`fb895662d`), `inkling-llama-cpp` (b12651) and
`prism-llama-cpp`, which was moved from `prism-b10777-e3de715` (predates the fix) to the fork's
latest release `prism-b12232-f702476` for this, with `-DLLAMA_USE_PREBUILT_UI=OFF` (the prebuilt UI
download fails for fork tags). Mark the routers in `cortex.ROUTERS` with `slot_cache = true`
(Phase 2). A router whose build lacks the fix must not get the flag: its restores are not reused.

1. **A size-capped tmpfs.** `compose.yml`: add a tmpfs mount at `/slot-cache` to the service, with a
   `size=` cap. A tmpfs uses RAM only for the files actually written, and can never exceed its cap
   (a save that would exceed it fails, and the coordinator treats that as a miss). Caps from the
   Phase 0 sizes (including checkpoints): groot ~9.7 KB/token (~1.1 GB at its longest observed
   context, ~111K tokens), mellum ~4.7 KB/token, raon ~11 KB/token (~1.4 GB at 128K). A file is
   KV (grows per token) plus context checkpoints (one at least every 8,192 tokens, up to 32; ~63 MiB
   each for groot, ~48 MiB raon, ~12 MiB mellum), so at full context: groot ~1.6 GB (111K),
   raon ~1.4 GB (128K), mellum ~0.75 GB (128K). Caps, chosen conservative (2026-11-26):
   `llama-cpp` **8g** (groot + qwen-35B + mellum at full context with margin), `raon-llama-cpp`
   **2g** (one quant in use at a time), `prism-llama-cpp` **2g** and `inkling-llama-cpp` **2g**
   (their sizes are **unmeasured**; re-size them from the first `slot-cache: saved` log lines).
   Pruner targets (`SLOT_CACHE_KEEP_GB`): 6 / 2 / 2 / 2. On the 2g routers the target equals the
   cap (size pruning effectively off; the 2-hour expiry still applies): a lower target would delete
   a full-context slot (raon ~1.4 GB) minutes after saving it. The target must always be at least
   the largest single slot the router can hold. A slot that does not fit fails to save:
   one cache miss, nothing worse. The caps are in `compose.yml`: they are sized from model cache
   sizes, not from anything host-specific. Worst case, the slot cache holds the sum of the caps
   (14 GB); no RAM is reserved up front. Nothing else is kept.
2. **One file per model.** Each save overwrites `/slot-cache/<entry>.bin`, so a router never holds
   more than one file per model it serves.
3. **A pruner in each router container.** llama.cpp has no API to delete slot files, and a compose
   tmpfs is private to its container, so the pruner runs inside the router container. Override the
   service's `entrypoint` (the image's is `["llama-server"]`) with a small `sh` wrapper that starts
   a background loop and then `exec`s `llama-server "$@"`. The services already set `command:`
   (`--models-preset /models.ini --port 8080 --host 0.0.0.0`) in `compose.yml`, so the arguments
   survive the override (Docker drops only the *image's* arguments when `entrypoint` changes). Every
   `SLOT_CACHE_PRUNE_EVERY` (300 s) the loop:
   - deletes `*.bin` files not modified for `SLOT_CACHE_TTL_MIN` (120 min): a model not swapped
     back within two hours is not worth its RAM;
   - if the folder still holds more than `SLOT_CACHE_KEEP_GB` (default: 75% of the tmpfs cap),
     deletes the oldest files until it is under. Keeping usage under the cap this way is what keeps
     saves from failing for lack of space.
   - A save that fails part-way (for example on a full tmpfs) can leave a truncated file. That is
     harmless (llama.cpp rejects or ignores it on restore, and the request processes its full
     prompt), and the next successful save of that model overwrites it; the age and size rules
     remove it otherwise.
   Pass the three values as environment variables of the service, so they are tunable in
   `compose.override.yml` without editing the wrapper. Keep the wrapper in a tracked file
   (`llama-cpp/slot-cache-entrypoint.sh`, mounted read-only into each router) rather than inline
   YAML, so all routers share one copy.
4. **`models.ini`:** each `[*]` gets `slot-save-path = /slot-cache`.
5. **Which conversation is restored:** the model's last conversation at unload time (slot 0). For
   the orchestrator's model that is the orchestrator's last turn, the case that matters. For a model
   shared by several callers (e.g. coders on mellum) it is whichever ran last: of little value, but
   harmless. Restoring per conversation would need `parallel > 1`; out of scope.
6. **Stale files are impossible by construction:** a compose `tmpfs` is empty on every container
   start, and every `models.ini` change already needs a router restart (AGENTS.md). So a saved state
   can never be restored into a model whose settings or weights changed. Do not use a named volume
   or a host path for this, because those survive restarts.
7. **A pruned or missing file is harmless:** the restore answers "not found" and the request
   processes its full prompt as it does today.
8. Deploy: `docker compose up -d <router>` for each.

Acceptance: `docker exec <router> df -h /slot-cache` shows the tmpfs with its cap; a router restart
empties it; a file older than the TTL disappears within one prune interval; with the folder filled
past `SLOT_CACHE_KEEP_GB` (test with small values), the oldest files are removed first; the router
still lists all its presets (`GET /v1/models`), proving `command:` is right; `llama-server` receives
signals (`docker compose stop` stops it cleanly); prism is unchanged.

## 4. Phase 2 — coordinator: save before unload, restore after load

All in `openresty/coordinator.lua` and `openresty/cortex.lua`. Anchors are function names.

### Constants (`cortex.lua`)

- `M.SLOT_CACHE = true`: master switch. `false` restores today's behaviour exactly.
- Per router: `slot_cache = true` in the `M.ROUTERS` entries for `llama_cpp`, `raon_llama_cpp` and
  `inkling_llama_cpp` (not `prism_llama_cpp`). Save and restore only for routers with the flag.
- `M.SLOT_CACHE_SKIP_HEADER = "X-Cortex-No-Slot-Cache"`: a request carrying this header (any value)
  neither triggers a save of the model it evicts nor a restore of the model it loads. `bench.sh`
  sends it (Phase 2b).
- `M.SLOT_SAVE_TIMEOUT = 60` (s), `M.SLOT_RESTORE_TIMEOUT = 60` (s), `M.MODEL_LOAD_TIMEOUT = 300`
  (s; a cold load from the slow SSD has taken up to ~3.5 min). Revise the two slot timeouts from the
  Phase 0 measurements (about 5× the slowest measured).

### `http_request` (coordinator.lua)

It sets `sock:settimeout(5000)`, which is too short for a save or a load. Add an optional last
parameter `timeout_ms`, default 5000, so existing callers are unchanged.

### Save: in `unload_llamacpp(key)`

For each model it is about to unload (`status.value == "loaded"`), when `cortex.SLOT_CACHE`, the
router has `slot_cache = true`, and the current request does not carry the skip header:

1. `POST /slots/0?action=save` routed to that model (the form from Phase 0), body
   `{"filename": "<m.id>.bin"}`, timeout `SLOT_SAVE_TIMEOUT`.
2. Log `slot-cache: saved <m.id> (<bytes>, <ms>)` or a WARN with the error.
3. **A failed or timed-out save never blocks the unload.** Go on to `/models/unload` as now.

File names: one file per models.ini entry, overwritten on each save. Entry names are unique across
all models.ini files (AGENTS.md), so files cannot collide.

### Restore: at the end of `switch_to`, for a llama.cpp router target

After the state is set and before returning `"ok"`, when `cortex.SLOT_CACHE`, `cortex.ROUTER[target]`
has `slot_cache = true`, `target_model` is set, and the request does not carry the skip header.
**Always attempt the restore** in that case: no bookkeeping of which files exist. A shared-dict
record would be lost whenever openresty restarts (skipping valid restores), and a missing file only
costs a "not found" answer in milliseconds; the load has to happen before the first request anyway.

1. `POST /models/load` `{"model": target_model}` on `HOST[target]`.
2. Poll `GET /v1/models` every 0.5 s until that model's `status.value == "loaded"`, up to
   `MODEL_LOAD_TIMEOUT`. Write this as a new helper `wait_until_loaded(key, model, timeout)` next to
   `wait_until_clear`.
3. `POST /slots/0?action=restore` routed to the model, body `{"filename": "<target_model>.bin"}`,
   timeout `SLOT_RESTORE_TIMEOUT`.
4. Log `slot-cache: restored <model> (<n_restored>, <ms>)`; a "not found" answer at INFO (expected:
   first load, pruned file, or router restarted); any other error at WARN.
5. **Any failure (load timeout, restore error) only logs.** The request proceeds as today; it will
   load the model and process its full prompt.

Why inside `switch_to`: it runs while the request holds the switch key, so no other request reaches
the model between the load and the restore, and the waiters behave as for any switch.

### Phase 2b — `bench.sh` opts out

A restore puts a model's previous conversation back in its cache. `bench.sh` sends
`cache_prompt: false` only in its sized prefill probe; any other measurement that repeats an earlier
prompt after the coordinator swapped models could then read part of its prefill from the restored
cache and report it too fast. Add the header `X-Cortex-No-Slot-Cache: 1` to **every** request
`bench.sh` sends through openresty (find each `curl` / Python request it builds), so benches never
save or restore. Check with `grep -n` that no request path is missed. (Implemented: bench.sh has
three POSTs to `:8080/v1/chat/completions`, in `fire_request` and the two fetch/cache probes; all
three send it. Its only other `:8080` call is an uncoordinated `GET /v1/models`.)

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

1. Mock: implement `POST /slots/0?action=save|restore` with the model in the JSON body, as Phase 0
   found (record calls; `restore` of an unknown file answers with an error like llama.cpp's),
   `POST /models/load` (sets the model loaded after a short delay; the mock has neither today), and
   a switch to make a save slow or fail.
2. Scenarios:
   - switch A → B saves A; switch B → A restores A, after the load and before the request is
     proxied;
   - a failing save still unloads and switches;
   - a slow save beyond `SLOT_SAVE_TIMEOUT` still unloads and switches;
   - restore of a missing file: the request proceeds;
   - a request with `X-Cortex-No-Slot-Cache` makes no slot calls on save or restore;
   - a router without `slot_cache` (prism's mock) gets no slot calls;
   - `SLOT_CACHE = false`: no slot calls at all (today's call sequence exactly);
   - a request that arrives during the restore waits for the switch, like any waiter;
   - ollama/nllb switches make no slot calls.
3. `python3 tools/test_coordinator.py` passes, and `--ref HEAD` still passes against the old commit
   for the unchanged scenarios.

### Implementation notes (2026-11-26)

- `openresty/cortex.lua`: `slot_cache = true` on all four routers; `SLOT_CACHE`, the three timeouts
  (save 30 s, restore 30 s, load 300 s), `SLOT_CACHE_SKIP_HEADER` and `slot_cache_for(key)`.
- `openresty/coordinator.lua`: `http_request(..., timeout_ms)`; `slot_call`, `wait_until_loaded`
  (also stops on a failed load: `failed` / `exit_code` in the status, or `unloaded` after 5 s),
  `restore_slot`; the save in `unload_llamacpp`; the restore at the end of `switch_to`; `SWITCH_TTL`
  extended by the three timeouts.
- `llama-cpp/slot-cache-entrypoint.sh`: the pruner wrapper, mounted into all four routers.
- `compose.yml`: tmpfs, entrypoint, mount and pruner settings on the four routers; prism pinned to
  `prism-b12232-f702476`.
- Every `models.ini` `[*]`: `slot-save-path = /slot-cache` (comment on its own line: string values
  take no inline comment).
- `tools/bench.sh`: the skip header on its three POSTs.
- `tools/coord_mock.py` / `tools/test_coordinator.py`: slot, load, log and control endpoints; five
  scenarios (save then restore in order, across routers; failed / slow save and missing file;
  skip header and ollama/nllb; a waiter during the load and restore; `SLOT_CACHE = false`). All 16
  scenarios pass; against the previous commit the 11 old ones pass and only the slot-cache checks
  fail.

## 6. Phase 4 — measure on the live stack (ask first)

Run a real orchestrated session (or replay the groot ↔ qwen pattern) and compare with section 0:

- First `prompt eval time` after each groot reload: target a few hundred to a few thousand tokens,
  against 41–111K today.
- Total switch time (openresty `switch:` line → first token), including save and restore.
- RAM: tmpfs usage per router (`df -h /slot-cache` in each container) over a day of normal use;
  confirm it stays under the caps and that the pruner removes idle files.
- A vision entry (gemma-4-12B `-vision`) with an image in its conversation: save and restore may not
  support image tokens. Confirm it fails harmlessly (logged, full prompt processed) or works.
- A bench run (any short `bench.sh` step) logs no `slot-cache:` lines for its requests.

Record the numbers here and in AGENTS.md.

### Phase 4 results (2026-11-26, live stack)

Replay of the orchestrator ↔ advisor pattern through openresty `:8080`: groot (~51K-token
conversation) → qwen-3.6-35B 128k-think-coder (~7K) → groot follow-up → qwen follow-up.

| Step | Coordinator / router | Effect |
|---|---|---|
| groot → qwen | groot saved in 247 ms (2 checkpoints) | — |
| qwen → groot | qwen saved (111 ms); groot loaded; **restored in 276 ms** | groot follow-up: **30 tokens processed, 51,052 cached** (0.3 s instead of ~23 s) |
| groot → qwen | groot saved (406 ms, 4 checkpoints, 627 MB) | qwen **restored in 123 ms**; follow-up **30 tokens processed, 6,985 cached** |

- **Switch back to groot: ~9 s** from the `switch:` line to the restore (save 0.1 s, unload ~1 s,
  load ~7 s, restore 0.3 s), against ~4 s load + ~23 s re-processing before.
- **Vision:** gemma-4-12B 64k-vision with an image in the conversation: saved (106 tokens, 20 MB,
  25 ms) and restored (15 ms, checkpoints and the MTP draft state restored); the follow-up processed
  28 tokens with 100 cached and answered correctly. Images do not break save/restore.
- **Skip header:** a request with `X-Cortex-No-Slot-Cache` switching models logged no save and no
  restore.
- **RAM:** llama-cpp tmpfs 974 MB for four saved models (groot 627 MB, qwen ~370 MB, gemma 20 MB,
  mellum 1 MB); the other routers 0. Over a day of use: not yet observed.
- **Fix found and made:** llama.cpp answers `/slots` with `Transfer-Encoding: chunked`, which
  `http_request` did not decode, so the logged token and byte counts were `?` and error bodies
  empty (save and restore themselves worked). `http_request` now decodes chunked bodies; the mock
  answers slot calls chunked.
- **Not slot-cache, found along the way:** on b12785 qwen-3.6-35B 128k loads in ~38 s even warm
  (b10622: ~12 s), right after a new warning `tensor overrides to CPU are used with mmap enabled -
  consider using --load-mode none for better performance`. It applies to CPU-placed models with
  `load-mode = mmap+mlock`; check in the benches whether `load-mode none` (or the warning's cause)
  restores load speed without the RAM cost `mmap+mlock` was chosen to avoid (AGENTS.md Gotchas).
- **Caution for manual testing:** a direct `POST /slots/...` to a router that names a model not
  loaded makes the router load it (beside the resident one); the coordinator only saves loaded
  models and restores after its own load, so this only arises from hand-made calls.

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
