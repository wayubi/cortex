local cjson = require "cjson"

local state_dict   = ngx.shared.backend_state
local counts_dict  = ngx.shared.request_counts

local HOST = { ollama = "ollama", llama_cpp = "llama-cpp" }


local function get_target()
    local port = ngx.var.server_port
    if port == "11434" then return "ollama"
    elseif port == "8080" then return "llama_cpp" end
    return nil
end


local function http_request(method, host, port, path, body)
    local sock = ngx.socket.tcp()
    sock:settimeout(5000)
    local ok, err = sock:connect(host, port)
    if not ok then
        return nil, "connect: " .. (err or "?")
    end

    local req = method .. " " .. path .. " HTTP/1.1\r\nHost: " .. host .. "\r\n"
    if body then
        req = req .. "Content-Type: application/json\r\nContent-Length: " .. #body .. "\r\n"
    end
    req = req .. "\r\n"
    if body then
        req = req .. body
    end

    local bytes, err = sock:send(req)
    if not bytes then
        sock:close()
        return nil, "send: " .. (err or "?")
    end

    local status_line, err = sock:receive("*l")
    if not status_line then
        sock:close()
        return nil, "receive status: " .. (err or "?")
    end

    local status = tonumber(status_line:match("HTTP/%d%.%d (%d+)"))
    if not status then
        sock:close()
        return nil, "bad status line: " .. status_line
    end

    local content_length = 0
    while true do
        local line, err = sock:receive("*l")
        if not line or line == "" then break end
        local len = line:match("^[Cc]ontent%-[Ll]ength:%s*(%d+)")
        if len then content_length = tonumber(len) end
    end

    local resp_body = ""
    if content_length > 0 then
        resp_body, err = sock:receive(content_length)
        if not resp_body then
            sock:close()
            return nil, "receive body: " .. (err or "?")
        end
    end

    sock:close()
    return { status = status, body = resp_body }, nil
end


local function unload_ollama()
    local res, err = http_request("GET", HOST.ollama, 11434, "/api/ps")
    if not res then
        ngx.log(ngx.WARN, "ollama ps failed: ", err)
        return
    end

    local ok, data = pcall(cjson.decode, res.body)
    if not ok or type(data) ~= "table" or not data.models or #data.models == 0 then
        ngx.log(ngx.INFO, "ollama: no loaded model to unload")
        return
    end

    for _, m in ipairs(data.models) do
        local name = m.name
        if name then
            ngx.log(ngx.INFO, "ollama: unloading ", name)
            local body = cjson.encode({ model = name, keep_alive = 0 })
            local r, e = http_request("POST", HOST.ollama, 11434, "/api/generate", body)
            if r then
                ngx.log(ngx.INFO, "ollama: unloaded ", name)
            else
                ngx.log(ngx.WARN, "ollama: unload failed for ", name, ": ", e)
            end
        end
    end
end


local function unload_llamacpp()
    local res, err = http_request("GET", HOST.llama_cpp, 8080, "/v1/models")
    if not res then
        ngx.log(ngx.WARN, "llama-cpp models failed: ", err)
        return
    end

    local ok, data = pcall(cjson.decode, res.body)
    if not ok or type(data) ~= "table" or not data.data then
        return
    end

    local count = 0
    for _, m in ipairs(data.data) do
        if m.status and m.status.value == "loaded" and m.id then
            ngx.log(ngx.INFO, "llama-cpp: unloading ", m.id)
            local body = cjson.encode({ model = m.id })
            local r, e = http_request("POST", HOST.llama_cpp, 8080, "/models/unload", body)
            if r then
                ngx.log(ngx.INFO, "llama-cpp: unloaded ", m.id)
                count = count + 1
            else
                ngx.log(ngx.WARN, "llama-cpp: unload failed for ", m.id, ": ", e)
            end
        end
    end
    if count == 0 then
        ngx.log(ngx.INFO, "llama-cpp: no loaded model to unload")
    end
end


local function coordinate()
    local target = get_target()
    if not target then
        ngx.exit(503)
        return
    end

    local current = state_dict:get("backend")
    local method = ngx.var.request_method

    ngx.log(ngx.INFO, "request: ", method, " ", target, " current=", (current or "none"))

    if current == target then
        if method == "POST" then
            ngx.ctx.counted = true
            counts_dict:incr(target, 1, 0)
        end
        return
    end

    if method ~= "POST" then
        ngx.log(ngx.INFO, "skip: ", method, " ", target, " — only POST triggers switch")
        return
    end

    ngx.ctx.counted = true
    counts_dict:incr(target, 1, 0)

    if current ~= nil then
        ngx.log(ngx.INFO, "drain ", current, " (", (counts_dict:get(current) or 0), " active)")
        local waited = 0
        while waited < 30 do
            if (counts_dict:get(current) or 0) == 0 then break end
            ngx.sleep(0.5)
            waited = waited + 0.5
        end
        if waited > 0 then
            ngx.log(ngx.INFO, "drain: ", current, " waited ", waited, "s")
        end
    end

    ngx.log(ngx.INFO, "switch: ", (current or "none"), " -> ", target)

    if current == "ollama" and target == "llama_cpp" then
        unload_ollama()
    elseif current == "llama_cpp" and target == "ollama" then
        unload_llamacpp()
    end

    state_dict:set("backend", target)
    ngx.log(ngx.INFO, "state: backend=", target)
end


coordinate()
