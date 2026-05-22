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

local SERVICE = { ollama = "ollama", llama_cpp = "llama-cpp" }
local HOST    = { ollama = "ollama", llama_cpp = "llama-cpp" }

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


local function resolve_container(service)
    local c = http.new()
    local ok, err = c:connect{ path = DOCKER_SOCKET }
    if not ok then return nil, err end
    c:set_timeout(5000)

    local filters = '{"label":["com.docker.compose.service=' .. service .. '"]}'
    local path = "/containers/json?all=true&filters=" .. ngx.escape_uri(filters)

    local res, err = c:request{
        method = "GET",
        path   = path,
        headers = { ["Host"] = "localhost" },
    }
    c:close()
    if not res then return nil, err end

    local body, err = res:read_body()
    if not body then return nil, "empty response" end

    local ok, data = pcall(cjson.decode, body)
    if not ok or type(data) ~= "table" or #data == 0 then
        return nil, "no container found for service: " .. service
    end

    local names = data[1].Names
    if type(names) ~= "table" or #names == 0 then
        return nil, "container has no name"
    end
    return names[1]:gsub("^/", ""), nil
end


local function stop_container(service)
    local name, err = resolve_container(service)
    if not name then return false, err end
    local res, err = docker_req("POST", "/containers/" .. name .. "/stop")
    if err then return false, err end
    return true
end


local function start_container(service)
    local name, err = resolve_container(service)
    if not name then return false, err end
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

    if current ~= nil then
        release_lock()
        local waited = 0
        while waited < LOCK_TIMEOUT do
            if (counts_dict:get(current) or 0) == 0 then break end
            ngx.sleep(0.5)
            waited = waited + 0.5
        end

        if not acquire_lock(LOCK_TIMEOUT) then
            ngx.log(ngx.ERR, "coordinator re-lock timeout during switch")
            ngx.exit(503)
            return
        end

        cleanup_stale()

        local rechecked = state_dict:get("backend")
        if rechecked == target then
            counts_dict:incr(target, 1, 0)
            ts_dict:set(target, ngx.time())
            ngx.ctx.counted = true
            release_lock()
            return
        end
        if rechecked ~= nil then
            current = rechecked
        end
    end

    local other_backend = (target == "ollama") and SERVICE.llama_cpp or SERVICE.ollama

    if current ~= nil then
        ngx.log(ngx.INFO, "switching: stopping ", other_backend)
        stop_container(other_backend)
    end

    ngx.log(ngx.INFO, "starting ", SERVICE[target])
    start_container(SERVICE[target])

    local health_port = (target == "ollama") and 11434 or 8080
    local ok, err = wait_for_port(HOST[target], health_port, HEALTHCHECK_TIMEOUT)
    if not ok then
        ngx.log(ngx.ERR, target, " healthcheck failed: ", err)
        state_dict:set("backend", "idle")
        release_lock()
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
