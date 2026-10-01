-- Log phase for every server block: release what coordinator.lua took for
-- this request, and stamp the activity times availability.lua reports.
--
-- This is the only place counts are released. A client that hangs up while
-- held or draining is finalised through ngx.on_abort -> ngx.exit(499), which
-- runs this phase straight away, so an aborted request cannot hold a count.

local cortex = require "cortex"
local ctx = ngx.ctx
local state = ngx.shared.backend_state
local counts = ngx.shared.request_counts

local function release(key)
    if key and (counts:get(key) or 0) > 0 then
        counts:incr(key, -1, 0)
    end
end

-- idle_for: only requests coordinator.lua let through as inference. A bot
-- turned away by the hold did no work, so it does not reset the clock.
if ctx.inference then
    state:set("last_done", ngx.now())
end
if ctx.counted then
    ctx.counted = false
    release(cortex.target_for_port(ngx.var.server_port))
end
if ctx.human_waiting then
    ctx.human_waiting = false
    release("human_waiting")
end
if ctx.human_running then
    ctx.human_running = false
    release("human_running")
end
-- human_idle_for, and the hold on bots, run from the end of a human request.
if ctx.human then
    state:set("human_last", ngx.now())
end
