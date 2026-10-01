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

function M.target_for_port(port)
    return TARGET[port]
end

function M.is_bot()
    local v = ngx.var.http_x_cortex_client
    return v ~= nil and v:lower() == "bot"
end

return M
