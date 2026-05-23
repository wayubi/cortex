local cjson = require "cjson"

local state_dict = ngx.shared.backend_state

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
        ngx.log(ngx.WARN, "ollama PS failed: ", err)
        return
    end

    local ok, data = pcall(cjson.decode, res.body)
    if not ok or type(data) ~= "table" or not data.models or #data.models == 0 then
        return
    end

    for _, m in ipairs(data.models) do
        local name = m.name
        if name then
            ngx.log(ngx.INFO, "ollama: unloading ", name)
            local body = cjson.encode({ model = name, keep_alive = 0 })
            local _, _ = http_request("POST", HOST.ollama, 11434, "/api/generate", body)
        end
    end
end


local function unload_llamacpp()
    local res, err = http_request("GET", HOST.llama_cpp, 8080, "/v1/models")
    if not res then
        ngx.log(ngx.WARN, "llama-cpp /v1/models failed: ", err)
        return
    end

    local ok, data = pcall(cjson.decode, res.body)
    if not ok or type(data) ~= "table" or not data.data then
        return
    end

    for _, m in ipairs(data.data) do
        if m.status and m.status.value == "loaded" and m.id then
            ngx.log(ngx.INFO, "llama-cpp: unloading ", m.id)
            local body = cjson.encode({ model = m.id })
            local _, _ = http_request("POST", HOST.llama_cpp, 8080, "/models/unload", body)
        end
    end
end


local function coordinate()
    local target = get_target()
    if not target then
        ngx.exit(503)
        return
    end

    local current = state_dict:get("backend")

    if current == target then
        return
    end

    if current == "ollama" and target == "llama_cpp" then
        unload_ollama()
    elseif current == "llama_cpp" and target == "ollama" then
        unload_llamacpp()
    end

    state_dict:set("backend", target)
end


coordinate()
