-- GET /availability -- cortex's own status, served on every port openresty
-- listens on (11434, 5002, 8080), so a client asks the port it already uses.
--
-- For schedulers that would rather wait than evict. It only reads the two
-- shared dicts coordinator.lua maintains, which are shared across all three
-- servers: `busy` is in-flight POSTs (inference) on ANY backend -- GET probes are
-- not counted -- or a llama.cpp slot reporting `processing`; `model` and
-- `backend` are what is resident right now, so a caller can also choose work
-- that avoids a reload; `idle_for` is how long it has been quiet.
--
-- Each server block defines the internal /__slots/<host> location this
-- subrequests, because a subrequest stays within its own server.

local cjson = require "cjson"
local cortex = require "cortex"
local state = ngx.shared.backend_state
local counts = ngx.shared.request_counts
local in_flight, total = {}, 0
for _, b in ipairs(cortex.BACKENDS) do
    local n = counts:get(b) or 0
    in_flight[b] = n
    total = total + n
end

-- The llama.cpp routers' own view (every router in cortex.ROUTERS), when they
-- have one. The in-flight counter only sees traffic that came through here;
-- /slots also catches work submitted to a router directly. A router whose
-- endpoint is absent, disabled (--no-slots) or slow adds nothing; if neither
-- answers, this stays null and the counter decides alone.
local function read_slots(loc)
    local ok_cap, res = pcall(ngx.location.capture, loc)
    if not (ok_cap and res and res.status == 200) then return nil end
    local ok_json, parsed = pcall(cjson.decode, res.body)
    -- Older builds return a bare array, newer ones {"slots": [...]}
    if not (ok_json and type(parsed) == "table") then return nil end
    local list = parsed
    if type(parsed.slots) == "table" then list = parsed.slots end
    if type(list) ~= "table" or #list == 0 then return nil end
    local processing = 0
    for _, sl in ipairs(list) do
        if type(sl) == "table" and
           (sl.is_processing == true or sl.state == 1 or
            sl.state == "processing") then
            processing = processing + 1
        end
    end
    return { processing = processing, total = #list }
end

local slots = nil
for _, r in ipairs(cortex.ROUTERS) do
    local s = read_slots("/__slots/" .. r.host)
    if s then
        slots = slots or { processing = 0, total = 0 }
        slots.processing = slots.processing + s.processing
        slots.total = slots.total + s.total
    end
end

-- idle_for: seconds since the last inference finished on any backend; 0
-- while one is running; null when none has finished since openresty started.
-- busy says "right now"; idle_for lets a caller see a client that is between
-- the requests of a longer run (a pipeline sending one NLLB call per sentence
-- goes idle for a moment between each) and decide whether to wait for quiet.
local busy = total > 0 or (slots ~= nil and slots.processing > 0)
local idle_for = cjson.null
local last_done = state:get("last_done")
if busy then
    idle_for = 0
elseif last_done then
    idle_for = math.floor((ngx.now() - last_done) * 10 + 0.5) / 10
end

-- The human side of the same picture (cortex.lua has the policy). A request
-- without `X-Cortex-Client: bot` is a human's. human_pending: one is waiting
-- for the GPU or running; human_idle_for: seconds since the last one ended, 0
-- while pending, null when none since openresty started. A bot that stands
-- aside while these are recent is never held here.
local human_pending = ((counts:get("human_waiting") or 0) +
                       (counts:get("human_running") or 0)) > 0
local human_idle_for = cjson.null
local human_last = state:get("human_last")
if human_pending then
    human_idle_for = 0
elseif human_last then
    human_idle_for = math.floor((ngx.now() - human_last) * 10 + 0.5) / 10
end

ngx.say(cjson.encode({
    busy      = busy,
    idle_for  = idle_for,
    human_pending  = human_pending,
    human_idle_for = human_idle_for,
    in_flight = in_flight,
    slots     = slots or cjson.null,
    backend   = state:get("backend") or cjson.null,
    model     = state:get("model") or cjson.null,
}))
