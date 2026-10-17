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

-- Every backend key, for the in-flight counts availability.lua reports.
M.BACKENDS = { "llama_cpp", "prism_llama_cpp", "ollama", "nllb" }

function M.target_for_port(port)
    return TARGET[port]
end

-- :8080 serves two llama.cpp routers. A model named by a section of
-- prism-llama-cpp/models.ini (bind-mounted read-only) goes to the PrismML fork;
-- every other model to llama-cpp, so names must be unique across both files.
-- The set is re-read at most every PRISM_REREAD seconds per worker, so an edit
-- to that models.ini routes without an openresty reload.
local PRISM_INI = "/etc/nginx/prism-models.ini"
local PRISM_REREAD = 5
local prism = { names = {}, at = nil }

local function prism_names()
    local now = ngx.now()
    if prism.at and now - prism.at < PRISM_REREAD then
        return prism.names
    end
    prism.at = now
    local f = io.open(PRISM_INI, "r")
    if not f then
        prism.names = {}
        return prism.names
    end
    local names = {}
    for line in f:lines() do
        local name = line:match("^%s*%[([^%]]+)%]")
        if name and name ~= "*" then
            names[name] = true
        end
    end
    f:close()
    prism.names = names
    return names
end

function M.is_prism_model(model)
    return type(model) == "string" and prism_names()[model] == true
end

-- The backend key for a request on `port` naming `model` (nil model: by port).
function M.target_for(port, model)
    if port == "8080" and M.is_prism_model(model) then
        return "prism_llama_cpp"
    end
    return TARGET[port]
end

M.PRISM_UPSTREAM = "http://prism-llama-cpp:8080"

function M.is_bot()
    local v = ngx.var.http_x_cortex_client
    return v ~= nil and v:lower() == "bot"
end

return M
