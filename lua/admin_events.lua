local admin = require "admin_common"
local cjson = require "cjson.safe"

if not admin.require_token() then
    return
end

local function respond(status, payload)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode(payload))
end

local red = admin.redis()
if not red then
    return
end

local method = ngx.req.get_method()
if method == "DELETE" then
    local deleted, err = red:del("waf:security:events")
    if deleted == nil then
        admin.redis_error(red, "clear security events", err)
        return
    end
    admin.done(red)
    respond(ngx.HTTP_OK, { ok = true })
    return
end

if method ~= "GET" then
    admin.done(red)
    respond(ngx.HTTP_NOT_ALLOWED, { ok = false, reason = "不支持该请求方法" })
    return
end

local limit = tonumber(ngx.var.arg_limit) or 100
limit = math.max(1, math.min(math.floor(limit), 500))
local request_id = ngx.var.arg_request_id or ""
local ip = ngx.var.arg_ip or ""
local rule_id = ngx.var.arg_rule_id or ""
local action = ngx.var.arg_action or ""
local scan_count = (request_id ~= "" or ip ~= "" or rule_id ~= "" or action ~= "") and 1000 or limit

local rows, err = red:xrevrange("waf:security:events", "+", "-", "COUNT", scan_count)
if not rows then
    admin.redis_error(red, "read security events", err)
    return
end

local events = {}
for _, row in ipairs(rows) do
    local values = row[2]
    local event = { id = row[1] }
    for index = 1, #values, 2 do
        event[values[index]] = values[index + 1]
    end
    event.timestamp = tonumber(event.timestamp) or 0
    event.status = tonumber(event.status) or 0

    local matched = (request_id == "" or event.requestId == request_id)
        and (ip == "" or event.ip == ip)
        and (rule_id == "" or event.ruleId == rule_id)
        and (action == "" or event.action == action)

    if matched then
        table.insert(events, event)
        if #events >= limit then
            break
        end
    end
end

admin.done(red)
respond(ngx.HTTP_OK, { ok = true, events = #events > 0 and events or cjson.empty_array })
