local http = require "resty.http"
local cjson = require "cjson"

local LOCK_TIMEOUT       = 600
local HEALTHCHECK_TIMEOUT = 30
local PROXY_TIMEOUT       = 600
local DOCKER_SOCKET       = "/var/run/docker.sock"

local state_dict   = ngx.shared.backend_state
local counts_dict  = ngx.shared.request_counts
local ts_dict      = ngx.shared.request_timestamps
local lock_dict    = ngx.shared.coord_lock


local function get_target()
    local port = ngx.var.server_port
    if port == "11434" then return "ollama"
    elseif port == "8080" then return "llama_cpp" end
    return nil
end


local function acquire_lock(timeout)
    local elapsed = 0
    while elapsed < timeout do
        local ok = lock_dict:add("lock", true, 0)
        if ok then return true end
        ngx.sleep(0.05)
        elapsed = elapsed + 0.05
    end
    return false
end


local function release_lock()
    lock_dict:delete("lock")
end


local function docker_req(method, path, timeout_ms)
    local c = http.new()
    local ok, err = c:connect{ path = DOCKER_SOCKET }
    if not ok then
        return nil, "connect: " .. (err or "?")
    end
    c:set_timeout(timeout_ms or 10000)
    local res, err = c:request{
        method = method,
        path   = path,
        headers = { ["Content-Length"] = 0, ["Host"] = "localhost" },
    }
    c:close()
    if not res then
        return nil, "request: " .. (err or "?")
    end
    return res, nil
end


local function stop_container(name)
    local res, err = docker_req("POST", "/containers/" .. name .. "/stop")
    if err then return false, err end
    return true
end


local function start_container(name)
    local res, err = docker_req("POST", "/containers/" .. name .. "/start")
    if err then return false, err end
    return true
end


local function wait_for_port(host, port, timeout)
    local elapsed = 0
    while elapsed < timeout do
        local sock = ngx.socket.tcp()
        sock:settimeout(2000)
        local ok, err = sock:connect(host, port)
        sock:close()
        if ok then return true end
        ngx.sleep(1)
        elapsed = elapsed + 1
    end
    return false, "port " .. host .. ":" .. port .. " not ready after " .. timeout .. "s"
end


local function cleanup_stale()
    local now = ngx.time()
    for _, b in ipairs{ "ollama", "llama_cpp" } do
        local ts = ts_dict:get(b)
        if ts and (now - ts) > PROXY_TIMEOUT then
            local n = counts_dict:get(b) or 0
            if n > 0 then
                ngx.log(ngx.WARN, "clearing ", n, " stale count(s) for ", b)
                counts_dict:set(b, 0)
                ts_dict:delete(b)
            end
        end
    end
end


local function coordinate()
    local target = get_target()
    if not target then
        ngx.log(ngx.ERR, "unknown server_port ", ngx.var.server_port)
        ngx.exit(503)
        return
    end

    -- 1. Acquire lock
    if not acquire_lock(LOCK_TIMEOUT) then
        ngx.log(ngx.ERR, "coordinator lock timeout")
        ngx.status = 503
        ngx.say('{"error":"coordinator busy"}')
        ngx.exit(503)
        return
    end

    cleanup_stale()

    local current = state_dict:get("backend")

    if current == target then
        -- Already active — just register this request
        counts_dict:incr(target, 1, 0)
        ts_dict:set(target, ngx.time())
        ngx.ctx.counted = true
        release_lock()
        return
    end

    -- Need to switch. Release lock first if another backend is active so
    -- other requests can still increment while we drain.
    if current ~= nil then
        release_lock()
        local waited = 0
        while waited < LOCK_TIMEOUT do
            if (counts_dict:get(current) or 0) == 0 then break end
            ngx.sleep(0.5)
            waited = waited + 0.5
        end
    end

    -- Re-acquire lock for state transition
    if not acquire_lock(LOCK_TIMEOUT) then
        ngx.log(ngx.ERR, "coordinator re-lock timeout during switch")
        ngx.status = 503
        ngx.say('{"error":"coordinator busy"}')
        ngx.exit(503)
        return
    end

    cleanup_stale()

    local other_name = (target == "ollama") and "llama-cpp" or "ollama"

    if current ~= nil then
        ngx.log(ngx.INFO, "switching: stopping ", other_name)
        stop_container(other_name)
    end

    ngx.log(ngx.INFO, "starting ", target)
    start_container(target)

    local health_host = target
    local health_port = (target == "ollama") and 11434 or 8080
    local ok, err = wait_for_port(health_host, health_port, HEALTHCHECK_TIMEOUT)
    if not ok then
        ngx.log(ngx.ERR, target, " healthcheck failed: ", err)
        state_dict:set("backend", "idle")
        release_lock()
        ngx.status = 503
        ngx.say('{"error":"backend ' .. target .. ' failed to start"}')
        ngx.exit(503)
        return
    end

    state_dict:set("backend", target)
    counts_dict:incr(target, 1, 0)
    ts_dict:set(target, ngx.time())
    ngx.ctx.counted = true
    release_lock()
end


coordinate()
