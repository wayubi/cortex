-- GET /v1/models (and /models) on :8080: the two llama.cpp routers behind this
-- port -- llama-cpp and prism-llama-cpp -- listed as one, so a client sees every
-- model it can request here and coordinator.lua routes each by name.
--
-- Both routers share one HF cache and both also list the GGUFs they find in it,
-- so the lists overlap. Each id appears once, from the router that serves it:
-- prism-llama-cpp for its own presets (cortex.is_prism_model), llama-cpp for
-- everything else. If one router is down its models are simply missing; the
-- reply fails only when neither answers.

local cjson = require "cjson"
local cortex = require "cortex"

if ngx.req.get_method() ~= "GET" and ngx.req.get_method() ~= "HEAD" then
    ngx.exit(ngx.HTTP_NOT_ALLOWED)
end

local uri, args = ngx.var.uri, ngx.var.args
local opts = { args = args }
local llama, prism = ngx.location.capture_multi({
    { "/__models_llama" .. uri, opts },
    { "/__models_prism" .. uri, opts },
})

local function decode(res)
    if not (res and res.status == 200) then return nil end
    local ok, d = pcall(cjson.decode, res.body)
    if ok and type(d) == "table" then return d end
    return nil
end

local a, b = decode(llama), decode(prism)
if not a and not b then
    ngx.status = ngx.HTTP_BAD_GATEWAY
    ngx.say(cjson.encode({ error = "no llama.cpp router answered " .. uri }))
    return
end
a = a or {}

local function key(e)
    return type(e) == "table" and (e.id or e.name or e.model) or nil
end

-- The list fields llama.cpp returns: OpenAI-style `data`, ollama-style `models`.
for _, field in ipairs({ "data", "models" }) do
    local out, seen = {}, {}
    local function add(list, from_prism)
        if type(list) ~= "table" then return end
        for _, e in ipairs(list) do
            local k = key(e)
            if k and not seen[k] and cortex.is_prism_model(k) == from_prism then
                seen[k] = true
                out[#out + 1] = e
            end
        end
    end
    add(a[field], false)
    add(b and b[field], true)
    if a[field] ~= nil or (b and b[field] ~= nil) then
        a[field] = setmetatable(out, cjson.array_mt)
    end
end
if a.object == nil and b and b.object ~= nil then a.object = b.object end

ngx.say(cjson.encode(a))
