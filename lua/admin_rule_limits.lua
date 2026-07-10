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
    local rule_id = ngx.var.arg_rule_id
    local ip = ngx.var.arg_ip
    if not rule_id or rule_id == "" or not ip or ip == "" then
        admin.done(red)
        respond(ngx.HTTP_BAD_REQUEST, { ok = false, reason = "missing rule id or ip" })
        return
    end

    local deleted, err = red:del("ban:rule:" .. rule_id .. ":" .. ip, "rate:rule:" .. rule_id .. ":" .. ip)
    if deleted == nil then
        admin.redis_error(red, "delete rule ban", err)
        return
    end

    admin.done(red)
    respond(ngx.HTTP_OK, { ok = true, ruleId = rule_id, ip = ip })
    return
end

if method ~= "GET" then
    admin.done(red)
    respond(ngx.HTTP_NOT_ALLOWED, { ok = false, reason = "method not allowed" })
    return
end

local cursor = "0"
local limits = {}

repeat
    local res, err = red:scan(cursor, "MATCH", "ban:rule:*", "COUNT", 100)
    if not res then
        admin.redis_error(red, "scan rule bans", err)
        return
    end

    cursor = res[1]
    for _, key in ipairs(res[2]) do
        local rule_id, ip = key:match("^ban:rule:([^:]+):(.+)$")
        if rule_id and ip then
            local ttl, ttl_err = red:ttl(key)
            if ttl_err then
                admin.redis_error(red, "ttl rule ban", ttl_err)
                return
            end

            local encoded_rule, rule_err = red:hget("waf:rules", rule_id)
            if rule_err then
                admin.redis_error(red, "get waf rule", rule_err)
                return
            end
            local rule = encoded_rule ~= ngx.null and cjson.decode(encoded_rule) or nil

            table.insert(limits, {
                ruleId = rule_id,
                ip = ip,
                ttl = ttl,
                ruleName = rule and rule.name or "已删除规则",
                method = rule and rule.method or "-",
                path = rule and rule.path or "-",
                matchType = rule and rule.matchType or "exact",
            })
        end
    end
until cursor == "0"

table.sort(limits, function(a, b)
    if a.ruleId == b.ruleId then
        return a.ip < b.ip
    end
    return tonumber(a.ruleId) < tonumber(b.ruleId)
end)

admin.done(red)
respond(ngx.HTTP_OK, { ok = true, limits = #limits > 0 and limits or cjson.empty_array })
