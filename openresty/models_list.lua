-- GET /v1/models (and /models) on :8080: the llama.cpp routers behind this
-- port (cortex.ROUTERS: llama-cpp, prism-llama-cpp, flint-llama-cpp) listed as
-- one, so a client sees every model it can request here and coordinator.lua
-- routes each by name.
--
-- The routers share one HF cache and each also lists the GGUFs it finds in it,
-- so the lists overlap. Each id appears once, from the router that serves it
-- (cortex.router_for: a router's own presets go to it, everything else to
-- llama-cpp). If a router is down its models are simply missing; the reply
-- fails only when none answers.

local cortex = require "cortex"

-- A private cjson instance that marks decoded arrays, so an empty array a
-- router returns (`"tags": []`, `"aliases": []`) is re-encoded as [] — the
-- default round-trip turns it into {}, which strict clients reject. Private so
-- the shared module's behaviour in the other Lua files is untouched.
local cjson = require("cjson").new()
cjson.decode_array_with_array_mt(true)

if ngx.req.get_method() ~= "GET" and ngx.req.get_method() ~= "HEAD" then
    ngx.exit(ngx.HTTP_NOT_ALLOWED)
end

local uri, args = ngx.var.uri, ngx.var.args
local opts = { args = args }
local reqs = {}
for i, r in ipairs(cortex.ROUTERS) do
    reqs[i] = { "/__models/" .. r.host .. uri, opts }
end
local res = { ngx.location.capture_multi(reqs) }

local function decode(r)
    if not (r and r.status == 200) then return nil end
    local ok, d = pcall(cjson.decode, r.body)
    if ok and type(d) == "table" then return d end
    return nil
end

local lists = {}
local a = nil
for i in ipairs(cortex.ROUTERS) do
    lists[i] = decode(res[i])
    a = a or lists[i]
end
if not a then
    ngx.status = ngx.HTTP_BAD_GATEWAY
    ngx.say(cjson.encode({ error = "no llama.cpp router answered " .. uri }))
    return
end
-- The reply keeps the first answering router's other top-level fields.

local function key(e)
    return type(e) == "table" and (e.id or e.name or e.model) or nil
end

-- The list fields llama.cpp returns: OpenAI-style `data`, ollama-style `models`.
for _, field in ipairs({ "data", "models" }) do
    local out, seen, present = {}, {}, false
    for i, r in ipairs(cortex.ROUTERS) do
        local list = lists[i] and lists[i][field]
        if list ~= nil then present = true end
        if type(list) == "table" then
            for _, e in ipairs(list) do
                local k = key(e)
                if k and not seen[k] and cortex.router_for(k) == r.key then
                    seen[k] = true
                    out[#out + 1] = e
                end
            end
        end
    end
    if present then
        a[field] = setmetatable(out, cjson.array_mt)
    end
end

ngx.say(cjson.encode(a))
