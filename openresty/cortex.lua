-- Policy and helpers shared by coordinator.lua, log.lua and availability.lua.
--
-- Clients are humans or bots. A bot marks itself with `X-Cortex-Client: bot`
-- (afghanica, the mastodon x_bridge); anything without the header is a human
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
-- plus their generation budget (afghanica llm_timeout 900, x_bridge 900).
M.BOT_HOLD_CAP = 600
M.HOLD_POLL = 0.5

local TARGET = { ["11434"] = "ollama", ["8080"] = "llama_cpp", ["5002"] = "nllb" }

-- :8080 serves several llama.cpp routers, each its own compose service with
-- its own build. The first is the default; every other one serves the models
-- named by the sections of its models.ini (bind-mounted read-only at `ini`),
-- so a name must be unique across all of them. Adding a router is one line
-- here plus its compose service and ini mount (see AGENTS.md).
M.ROUTERS = {
    { key = "llama_cpp",       host = "llama-cpp" },
    -- PrismML's fork: ternary Bonsai types upstream cannot load
    { key = "prism_llama_cpp", host = "prism-llama-cpp", ini = "/etc/nginx/prism-models.ini" },
    -- the upstream build for Flint (arch `flint`, b11803+; llama-cpp's pin predates it)
    { key = "flint_llama_cpp",  host = "flint-llama-cpp",  ini = "/etc/nginx/flint-models.ini" },
    -- KRAFTON's fork for Raon-1 mini (arch `raon1`; upstream support pending)
    { key = "raon_llama_cpp",   host = "raon-llama-cpp",   ini = "/etc/nginx/raon-models.ini" },
}
M.ROUTER = {}
for _, r in ipairs(M.ROUTERS) do
    M.ROUTER[r.key] = r
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
