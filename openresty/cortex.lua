-- Policy and helpers shared by coordinator.lua, log.lua and availability.lua.
--
-- Clients are humans or bots. A bot marks itself with `X-Cortex-Client: bot`
-- (automated clients: batch pipelines, social-media bridges); anything without the header is a human
-- (Open WebUI, opencode), so a client that knows nothing about cortex gets the
-- priority by default.
--
-- A human never waits for more than the bot call already in flight: while one
-- is waiting, new bot requests are held, so that call is the last. A bot is
-- not interrupted; once a human has been active, a bot request that would
-- evict the human's model is held until the human has gone HUMAN_HOLD seconds
-- without a request, and gets a 503 marked `X-Cortex-Held: human` after
-- BOT_HOLD_CAP -- before a bot's own client timeout, so it learns "stand aside"
-- rather than "broken".

local M = {}

-- Reading a reply and typing the next prompt.
M.HUMAN_HOLD = 120
-- The same as DRAIN_TIMEOUT. Bots set their per-call client timeouts to this
-- plus their generation budget (e.g. a 900 s per-call timeout).
M.BOT_HOLD_CAP = 600
M.HOLD_POLL = 0.5

local TARGET = { ["11434"] = "ollama", ["8080"] = "llama_cpp", ["5002"] = "nllb" }

-- :8080 serves several llama.cpp routers, each its own compose service with
-- its own build. The first is the default; every other one serves the models
-- named by the sections of its models.ini (bind-mounted read-only at `ini`),
-- so a name must be unique across all of them. Adding a router is one line
-- here plus its compose service and ini mount (see AGENTS.md).
--
-- slot_cache: the router's build writes context checkpoints into slot files
-- (upstream PR #26004) and the router has the /slot-cache tmpfs and
-- `slot-save-path`, so the coordinator saves a model's slot before unloading
-- it and restores it after the next load (see AGENTS.md, slot cache).
-- Without checkpoints a restored slot is not reused, so leave it false.
M.ROUTERS = {
    { key = "llama_cpp",       host = "llama-cpp", slot_cache = true },
    -- PrismML's fork: ternary Bonsai types upstream cannot load
    { key = "prism_llama_cpp", host = "prism-llama-cpp", ini = "/etc/nginx/prism-models.ini",
      slot_cache = true },
    -- KRAFTON's fork for Raon-1 mini (arch `raon1`; upstream support pending)
    { key = "raon_llama_cpp",   host = "raon-llama-cpp",   ini = "/etc/nginx/raon-models.ini",
      slot_cache = true },
    -- Unsloth's prebuilt for Inkling 2 Mini (looped `inkling2` arch)
    { key = "inkling_llama_cpp", host = "inkling-llama-cpp", ini = "/etc/nginx/inkling-models.ini",
      slot_cache = true },
}
M.ROUTER = {}
for _, r in ipairs(M.ROUTERS) do
    M.ROUTER[r.key] = r
end

-- Slot cache: keep a model's processed prompt across model swaps. Before the
-- coordinator unloads a llama.cpp model it saves slot 0 (KV cache + context
-- checkpoints) to the router's /slot-cache tmpfs; after the model is loaded
-- again it restores it, so the next request processes only its new tokens.
-- Every failure only logs and falls back to a full prompt. false = off.
M.SLOT_CACHE = true
-- Seconds. Measured 2026-11-26: save 0.1-0.25 s, restore 0.1-0.2 s for
-- 50K-token slots (250-500 MB); a load from the page cache 2-18 s, from the
-- slow SSD up to ~3.5 min.
M.SLOT_SAVE_TIMEOUT = 30
M.SLOT_RESTORE_TIMEOUT = 30
M.MODEL_LOAD_TIMEOUT = 300
-- A request carrying this header (any value) neither saves the model it evicts
-- nor restores the one it loads. bench.sh sends it, so a measurement never
-- reads a restored cache.
M.SLOT_CACHE_SKIP_HEADER = "X-Cortex-No-Slot-Cache"

function M.slot_cache_for(key)
    local r = M.ROUTER[key]
    return M.SLOT_CACHE and r ~= nil and r.slot_cache == true
        and ngx.var.http_x_cortex_no_slot_cache == nil
end

-- Every backend key, for the in-flight counts availability.lua reports.
M.BACKENDS = { "ollama", "nllb" }
for i, r in ipairs(M.ROUTERS) do
    table.insert(M.BACKENDS, i, r.key)
end

function M.target_for_port(port)
    return TARGET[port]
end

-- Each ini's section names are re-read at most every INI_REREAD seconds per
-- worker, so an edit to a models.ini routes without an openresty reload.
local INI_REREAD = 5
local ini_cache = {}

local function section_names(path)
    local c = ini_cache[path]
    local now = ngx.now()
    if c and now - c.at < INI_REREAD then
        return c.names
    end
    local names = {}
    local f = io.open(path, "r")
    if f then
        for line in f:lines() do
            local name = line:match("^%s*%[([^%]]+)%]")
            if name and name ~= "*" then
                names[name] = true
            end
        end
        f:close()
    end
    ini_cache[path] = { names = names, at = now }
    return names
end

-- The router key serving `model` on :8080: the first router whose models.ini
-- names it, else the default (also for a nil model).
function M.router_for(model)
    if type(model) == "string" then
        for _, r in ipairs(M.ROUTERS) do
            if r.ini and section_names(r.ini)[model] then
                return r.key
            end
        end
    end
    return M.ROUTERS[1].key
end

-- The backend key for a request on `port` naming `model` (nil model: by port).
function M.target_for(port, model)
    if port == "8080" then
        return M.router_for(model)
    end
    return TARGET[port]
end

function M.upstream(key)
    return "http://" .. M.ROUTER[key].host .. ":8080"
end

function M.is_bot()
    local v = ngx.var.http_x_cortex_client
    return v ~= nil and v:lower() == "bot"
end

return M
