local cjson = require "cjson"

local state_dict   = ngx.shared.backend_state
local counts_dict  = ngx.shared.request_counts

local HOST = { ollama = "ollama", llama_cpp = "llama-cpp" }


local function get_model()
    local ok, err = pcall(ngx.req.read_body)
    if not ok then
        return nil
    end

    local body = ngx.req.get_body_data()
    if not body or body == "" then
        return nil
    end

    local ok, data = pcall(cjson.decode, body)
    if not ok or type(data) ~= "table" then
        return nil
    end

    return data.model
end


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

    local method = ngx.var.request_method

    if method ~= "POST" then
        return
    end

    ngx.ctx.counted = true
    counts_dict:incr(target, 1, 0)

    local current_backend = state_dict:get("backend")
    local current_model   = state_dict:get("model")
    local target_model    = get_model()
    local same_backend    = (current_backend == target)

    ngx.log(ngx.INFO, "POST ", target,
            " backend=", (current_backend or "none"),
            " model: ", (current_model or "none"),
            " -> ", (target_model or "none"))

    if same_backend and current_model ~= nil and current_model == target_model then
        return
    end

    if current_backend ~= nil and not same_backend then
        ngx.log(ngx.INFO, "drain ", current_backend,
                " (", (counts_dict:get(current_backend) or 0), " active)")
        local waited = 0
        while waited < 30 do
            if (counts_dict:get(current_backend) or 0) == 0 then break end
            ngx.sleep(0.5)
            waited = waited + 0.5
        end
        if waited > 0 then
            ngx.log(ngx.INFO, "drain: ", current_backend, " waited ", waited, "s")
        end
    end

    ngx.log(ngx.INFO, "switch: ", (current_backend or "none"), " -> ", target,
            " (", (current_model or "none"), " -> ", (target_model or "none"), ")")

    if current_backend == "ollama" then
        unload_ollama()
    elseif current_backend == "llama_cpp" then
        unload_llamacpp()
    end

    state_dict:set("backend", target)
    if target_model then
        state_dict:set("model", target_model)
    end
    ngx.log(ngx.INFO, "state: backend=", target, " model=", (target_model or "none"))
end


coordinate()
