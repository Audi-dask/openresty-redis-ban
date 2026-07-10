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

local function invalidate_cache()
    local cache = ngx.shared.waf_rules
    if cache then
        cache:delete("rules")
    end
end

local function validate_rule(rule)
    if type(rule) ~= "table" then
        return nil, "invalid json body"
    end

    local name = type(rule.name) == "string" and rule.name:match("^%s*(.-)%s*$") or ""
    local path = type(rule.path) == "string" and rule.path:match("^%s*(.-)%s*$") or ""
    local method = rule.method or "全部"
    local match_type = rule.matchType
    local action = rule.action
    local risk = rule.risk
    local threshold = tonumber(rule.threshold)
    local window = tonumber(rule.window)
    local ban_ttl = tonumber(rule.banTtl)

    if name == "" or #name > 100 then
        return nil, "规则名称不能为空且不能超过 100 个字符"
    end
    if path == "" or #path > 500 then
        return nil, "URL 路径或关键字不能为空且不能超过 500 个字符"
    end
    if match_type == "exact" and string.sub(path, 1, 1) ~= "/" then
        return nil, "精确匹配路径必须以 / 开头"
    end
    if match_type ~= "exact" and match_type ~= "keyword" then
        return nil, "匹配方式无效"
    end
    if method ~= "全部" and method ~= "GET" and method ~= "POST" and method ~= "PUT" and method ~= "DELETE" then
        return nil, "HTTP 方法无效"
    end
    if action ~= "endpoint" and action ~= "global" then
        return nil, "处理范围无效"
    end
    if risk ~= "high" and risk ~= "medium" and risk ~= "normal" then
        return nil, "风险等级无效"
    end
    if not threshold or threshold < 1 or threshold > 1000000 then
        return nil, "限制次数必须在 1 到 1000000 之间"
    end
    if not window or window < 1 or window > 31536000 then
        return nil, "统计窗口必须在 1 到 31536000 秒之间"
    end
    if not ban_ttl or ban_ttl < 1 or ban_ttl > 31536000 then
        return nil, "封禁时间必须在 1 到 31536000 秒之间"
    end

    return {
        id = rule.id and tostring(rule.id) or nil,
        name = name,
        method = method,
        matchType = match_type,
        path = path,
        threshold = math.floor(threshold),
        window = math.floor(window),
        banTtl = math.floor(ban_ttl),
        action = action,
        risk = risk,
        enabled = rule.enabled == true,
    }
end

local red = admin.redis()
if not red then
    return
end

local method = ngx.req.get_method()

if method == "GET" then
    local values, err = red:hvals("waf:rules")
    if not values then
        admin.redis_error(red, "hvals waf rules", err)
        return
    end

    local rules = {}
    for _, value in ipairs(values) do
        local rule = cjson.decode(value)
        if rule then
            table.insert(rules, rule)
        end
    end
    table.sort(rules, function(a, b)
        return tonumber(a.id) < tonumber(b.id)
    end)

    respond(ngx.HTTP_OK, { ok = true, rules = #rules > 0 and rules or cjson.empty_array })
    admin.done(red)
    return
end

if method == "POST" then
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    local input = body and cjson.decode(body) or nil
    local rule, validation_err = validate_rule(input)
    if not rule then
        admin.done(red)
        respond(ngx.HTTP_BAD_REQUEST, { ok = false, reason = validation_err })
        return
    end

    if not rule.id then
        local id, id_err = red:incr("waf:rule:id")
        if not id then
            admin.redis_error(red, "incr waf rule id", id_err)
            return
        end
        rule.id = tostring(id)
    else
        local exists, exists_err = red:hexists("waf:rules", rule.id)
        if exists_err then
            admin.redis_error(red, "hexists waf rule", exists_err)
            return
        end
        if exists == 0 then
            admin.done(red)
            respond(ngx.HTTP_NOT_FOUND, { ok = false, reason = "规则不存在" })
            return
        end
    end

    local ok, err = red:hset("waf:rules", rule.id, cjson.encode(rule))
    if not ok then
        admin.redis_error(red, "hset waf rule", err)
        return
    end

    invalidate_cache()
    respond(ngx.HTTP_OK, { ok = true, rule = rule })
    admin.done(red)
    return
end

if method == "DELETE" then
    local id = ngx.var.arg_id
    if not id or id == "" then
        admin.done(red)
        respond(ngx.HTTP_BAD_REQUEST, { ok = false, reason = "缺少规则 ID" })
        return
    end

    local deleted, err = red:hdel("waf:rules", id)
    if deleted == nil then
        admin.redis_error(red, "hdel waf rule", err)
        return
    end
    if deleted == 0 then
        admin.done(red)
        respond(ngx.HTTP_NOT_FOUND, { ok = false, reason = "规则不存在" })
        return
    end

    invalidate_cache()
    respond(ngx.HTTP_OK, { ok = true, id = id })
    admin.done(red)
    return
end

admin.done(red)
respond(ngx.HTTP_NOT_ALLOWED, { ok = false, reason = "不支持该请求方法" })
