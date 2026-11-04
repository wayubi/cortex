# Plan: Record llama.cpp tool support from normal use

**Date:** 2026-11-04
**Status:** Shelved. Not started. Written so it can be picked up later without re-research.
**Audience:** an implementing agent. Follow the steps in order; each has an acceptance check.
Stop and ask where a step says so.

---

## 0. Why this plan exists

The client model generator (`openresty/scripts/models-common.sh`, function `models_fetch_cortex`)
tells OpenCode whether each model supports tool calling. For Ollama it uses Ollama's own answer
(`/api/show` `capabilities`). For llama.cpp it **assumes `true`** for every model, because:

- the routers' `GET /v1/models` never reports tool support (llama.cpp `b10622`,
  `tools/server/server-models.cpp`, `get_router_models`: the entry has `status`, `architecture`,
  and for a running model the child's `get_res_model_info` fields; none is about tools);
- tool support is only reported by a **loaded** model, in `GET /props` as `chat_template_caps`
  (`tools/server/server-context.cpp`, from `common_chat_templates_get_caps`);
- asking `/props` in a way that loads a model would switch the GPU outside the coordinator.

A model whose chat template cannot do tool calls is therefore offered tools by OpenCode, and
its requests fail or misbehave.

The fix: record the answer **while models are used normally**, from a model that is already
loaded, and pass it on in the merged `/v1/models`.

## 1. Facts this plan relies on (verified 2026-11-04 against llama.cpp `b10622` source)

1. A router GET accepts `autoload`: `GET /props?model=<name>&autoload=false`.
   `is_autoload()` reads the query parameter; `router_validate_model()` then returns an error
   if the model is not running, and `proxy_get` does not call `ensure_model_ready`. So this
   request **never loads a model**. It is answered only by a running model.
2. `chat_template_caps` is a JSON object of booleans from `common/jinja/caps.h`
   (`caps::to_map()`): `supports_tools`, `supports_tool_calls`, `supports_system_role`,
   `supports_parallel_tool_calls`, `supports_preserve_reasoning`, `supports_reasoning_effort`,
   `supports_string_content`, `supports_typed_content`, `supports_object_arguments`.
   **Note:** in `caps.h` `supports_tools` and `supports_tool_calls` default to `true`; they are
   set by analysing the template. Treat a model as tool-capable only when **both** are `true`.
3. In a router's `GET /v1/models`, a loaded preset has `status.value == "loaded"`.
4. Only `llama-cpp` was checked. `prism-llama-cpp` (fork `prism-b10777-e3de715`),
   `flint-llama-cpp` (`b11820`) and `raon-llama-cpp` (KRAFTON fork `fb895662d`) are newer or
   forks; step 1 verifies them.

## 2. Design

- **Where:** openresty. It already reaches every router (`cortex.ROUTERS`) and serves the merged
  `/v1/models` (`openresty/models_list.lua`). No new container, and it does not depend on the
  NVMe cache (`model-cache` exits when `CORTEX_NVME_CACHE=off`, which would stop recording).
- **How:** one nginx worker runs a timer every **5 s** (same cadence as `model-cache`). For each
  router in `cortex.ROUTERS` it reads `GET /v1/models`; for each preset with
  `status.value == "loaded"` that has no record yet **for this load**, it calls
  `GET /props?model=<preset>&autoload=false` on that router and records the caps.
  "This load" = re-record whenever a preset goes from not-loaded to loaded (a preset's chat
  template keys can change between loads).
- **Kept in:** a new shared dict `model_caps`, and persisted to a JSON file so a restart does not
  forget: `/var/lib/cortex/model-caps.json`, on a new named volume `openresty_state`.
- **Passed on:** `models_list.lua` adds, to each merged entry it has a record for:
  `"cortex_caps": {"tools": <bool>, "recorded_at": <unix seconds>}`.
  A preset never loaded since this was deployed has no `cortex_caps`.
- **Used by:** `models_fetch_cortex` in `models-common.sh`: `tools` = `model-meta.json`
  `tool_call` if set, else `.cortex_caps.tools` if present, else `true` (today's assumption).

## 3. Steps

### Step 1. Verify the router API on all four routers (read-only)

Ask before running anything on the live stack (cortex is in live use). With the user's OK, for
each router and **one preset that is already loaded** (check `GET /v1/models` on that router
first; never pick an unloaded one):

```
curl -s 'http://<router-host>:8080/props?model=<loaded-preset>&autoload=false' | jq '.chat_template_caps'
curl -s -o /dev/null -w '%{http_code}\n' 'http://<router-host>:8080/props?model=<unloaded-preset>&autoload=false'
```

Run them from a container on `cortex_network` (e.g. `docker exec cortex-openresty-1 ...`),
straight to the router, not through openresty `:8080`.

**Acceptance:** the first prints an object with `supports_tools` / `supports_tool_calls`; the
second returns a non-200 **and the router log shows no load** (`docker logs <router> --since 1m`
has no `spawning server instance`). If a router lacks either behaviour, **stop and report**; that
router is left out of the timer (record nothing for it).

### Step 2. Shared dict and state volume

- `openresty/nginx.conf`: add `lua_shared_dict model_caps 1m;` next to `backend_state`.
- `compose.yml`, service `openresty`: add volume `openresty_state:/var/lib/cortex`; add
  `openresty_state:` under top-level `volumes:`.

**Acceptance:** `docker compose config` is valid. (Deploy happens in step 7.)

### Step 3. `openresty/model_caps.lua` (new module)

Functions:
- `M.http_get(host, port, path)`: minimal HTTP/1.0 GET over `ngx.socket.tcp`, timeouts 1 s
  connect / 3 s read, returns `status, body`. Write it here; **do not** import or modify
  `http_request` in `coordinator.lua` (a coordinator change needs its own test run).
- `M.poll()`: for each router in `cortex.ROUTERS`:
  1. `GET /v1/models`; on failure skip the router.
  2. For each `data[]` entry: let `loaded = (status.value == "loaded")`.
     Keep the previous loaded state per preset in the dict (key `loaded:<id>`).
  3. If `loaded` and the previous state was not loaded: `GET /props?model=<id>&autoload=false`.
     URL-encode `<id>` (`ngx.escape_uri`). On 200, decode, read `chat_template_caps`;
     `tools = (supports_tools == true and supports_tool_calls == true)`.
     Store `caps:<id>` = cjson `{"tools":…,"recorded_at":ngx.time()}`.
  4. Store `loaded:<id>` = loaded.
  5. If any `caps:` changed: write all `caps:` entries to `/var/lib/cortex/model-caps.json`
     (write `…json.tmp`, then `os.rename`).
- `M.load_file()`: at worker start, read the JSON file (if present and valid) into `caps:` keys.
- `M.get(id)`: return the decoded record or nil.

Use a private cjson instance with `decode_array_with_array_mt(true)`, as `models_list.lua` does.

**Acceptance:** `luajit -bl openresty/model_caps.lua >/dev/null` compiles (or `docker run --rm
-v $PWD/openresty:/x openresty/openresty:bookworm-fat luajit -bl /x/model_caps.lua`).

### Step 4. Start the timer

`openresty/nginx.conf`, http level (the conf.d file is inside `http {}`):

```
init_worker_by_lua_block {
    local caps = require "model_caps"
    caps.load_file()
    if ngx.worker.id() == 0 then
        ngx.timer.every(5, function(premature) if not premature then pcall(caps.poll) end end)
    end
}
```

Every worker calls `load_file()` (the dict is shared, so this is idempotent); only worker 0 polls.

**Acceptance:** after deploy (step 7), `docker logs cortex-openresty-1` shows no Lua error from
`model_caps`.

### Step 5. Add `cortex_caps` in `models_list.lua`

In the merge loop, after an entry `e` is accepted (`out[#out + 1] = e`), add:
`local c = caps.get(k); if c then e.cortex_caps = c end` (with `local caps = require "model_caps"`
at the top). Do not change anything else; empty arrays must stay `[]` (see AGENTS.md).

**Acceptance:** a preset with a record shows `cortex_caps` in `GET :8080/v1/models`; others don't;
`tags`/`aliases` are still `[]`.

### Step 6. Use it in the generator

`openresty/scripts/models-common.sh`, `models_fetch_cortex`, the `tools:` line: replace the
`else true end` fallback with `else (.cortex_caps.tools // true) end`. Update the comment above
it (it currently says the value is assumed). `model-meta.json` `tool_call` still wins.

**Acceptance:** with a hand-made `/v1/models` body (one entry with `cortex_caps.tools: false`, one
without), the generated OpenCode config has `capabilities.tools` false and true respectively.
Test against a local fake server, not cortex.

### Step 7. Test and deploy

- `tools/coord_mock.py`: make the llama.cpp mock answer `GET /props?model=…&autoload=false` with
  a `chat_template_caps` for loaded models and 4xx otherwise. `tools/test_coordinator.py`: add a
  scenario: load a mock model via a request, wait 6 s, assert `/v1/models` has `cortex_caps`,
  and assert the mock received **no** load for a `/props` call.
- Run `python3 tools/test_coordinator.py`. **Acceptance:** all scenarios pass.
- Ask before deploying. Deploy: `docker compose up -d openresty` (recreate: new volume).

### Step 8. Docs

- `AGENTS.md`: the "Model discovery" bullet (llama.cpp tool support now recorded, fallback
  `true` until a preset has been loaded once); the File layout (`model_caps.lua`); "Adding
  another llama.cpp router" (no extra step needed, it follows `cortex.ROUTERS`).
- `README.md` file tree: `model_caps.lua`.

## 4. Out of scope

- **Pi.** Its `models.json` schema has no tool-support field, so Pi keeps sending tools to every
  model. Models stay listed in Pi (user decision, 2026-11-04).
- **Ollama.** Already uses `/api/show` `capabilities`.
- `bench.sh`, `model-cache`, `coordinator.lua`: unchanged.
- Recording anything for a preset that is not loaded. No load is ever triggered to find out.
- Other caps (`supports_parallel_tool_calls`, reasoning fields): recorded only if trivially
  available; not passed to clients by this plan.
