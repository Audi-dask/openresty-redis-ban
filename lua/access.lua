local redis_client = require "redis_client"
local cjson = require "cjson.safe"

local function fail_mode()
    local mode = os.getenv("FAIL_MODE") or "open"
    if mode == "open" or mode == "closed" then
        return mode
    end
    ngx.log(ngx.WARN, "unknown FAIL_MODE: ", mode, ", fallback to open")
    return "open"
end

local function redis_unavailable(reason, red)
    if red then
        redis_client.close(red)
    end
    if fail_mode() == "open" then
        ngx.log(ngx.ERR, "redis unavailable, fail-open allow request: ", reason)
        return ngx.OK
    end
    ngx.log(ngx.ERR, "redis unavailable, fail-closed reject request: ", reason)
    ngx.header["Content-Type"] = "application/json"
    ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
    ngx.say('{"ok":false,"reason":"redis unavailable"}')
    return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
end

local function client_ip()
    local mode = os.getenv("CLIENT_IP_MODE") or "x_real_ip"
    if mode == "x_real_ip" then
        return ngx.req.get_headers()["X-Real-IP"] or ngx.var.remote_addr or "unknown"
    elseif mode == "proxy_protocol" then
        return ngx.var.proxy_protocol_addr or ngx.var.remote_addr or "unknown"
    elseif mode == "remote_addr" then
        return ngx.var.remote_addr or "unknown"
    end
    ngx.log(ngx.WARN, "unknown CLIENT_IP_MODE: ", mode, ", fallback to remote_addr")
    return ngx.var.remote_addr or "unknown"
end

local function load_rules(red)
    local cache = ngx.shared.waf_rules
    local cached = cache and cache:get("rules")
    if cached then
        return cjson.decode(cached) or {}
    end

    local values, err = red:hvals("waf:rules")
    if not values then
        return nil, err
    end

    local rules = {}
    for _, value in ipairs(values) do
        local rule = cjson.decode(value)
        if rule and rule.enabled == true then
            table.insert(rules, rule)
        end
    end
    table.sort(rules, function(a, b)
        if a.matchType ~= b.matchType then
            return a.matchType == "exact"
        end
        return tonumber(a.id) < tonumber(b.id)
    end)

    if cache then
        cache:set("rules", cjson.encode(rules), 10)
    end
    return rules
end

local function match_rule(rules)
    local uri = ngx.var.uri or "/"
    local method = ngx.req.get_method()
    for _, rule in ipairs(rules) do
        local method_matches = rule.method == "全部" or rule.method == method
        local path_matches = false
        if rule.matchType == "exact" then
            path_matches = uri == rule.path
        elseif rule.matchType == "keyword" then
            path_matches = string.find(uri, rule.path, 1, true) ~= nil
        end
        if method_matches and path_matches then
            return rule
        end
    end
    return nil
end

local rate_script = [[
local global_ban_key = KEYS[1]
local rule_ban_key = KEYS[2]
local rate_key = KEYS[3]
local threshold = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local ban_ttl = tonumber(ARGV[3])
local action = ARGV[4]
local rule_name = ARGV[5]

local global_ban = redis.call("GET", global_ban_key)
if global_ban then
    return {"global_banned", global_ban, -1}
end

local rule_ban = redis.call("GET", rule_ban_key)
if rule_ban then
    return {"rule_banned", rule_ban, -1}
end

local count = redis.call("INCR", rate_key)
if count == 1 then
    redis.call("EXPIRE", rate_key, window)
end

if count > threshold then
    if action == "global" then
        redis.call("SETEX", global_ban_key, ban_ttl, "auto-rule:" .. rule_name)
        return {"global_limited", rule_name, count}
    end
    redis.call("SETEX", rule_ban_key, ban_ttl, rule_name)
    return {"rule_limited", rule_name, count}
end

return {"allowed", "", count}
]]

local ip = client_ip()
local red, err = redis_client.connect()
if not red then
    return redis_unavailable("connect failed: " .. (err or "unknown"))
end

local global_banned, global_err = red:get("ban:" .. ip)
if global_err then
    return redis_unavailable("global ban check failed: " .. global_err, red)
end
if global_banned ~= ngx.null then
    ngx.header["Content-Type"] = "application/json"
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.say('{"ok":false,"reason":"ip banned"}')
    redis_client.keepalive(red)
    return ngx.exit(ngx.HTTP_FORBIDDEN)
end

local rules, rules_err = load_rules(red)
if not rules then
    return redis_unavailable("load rules failed: " .. (rules_err or "unknown"), red)
end

local rule = match_rule(rules)
if not rule then
    redis_client.keepalive(red)
    return
end

local rule_id = tostring(rule.id)
local result, eval_err = red:eval(
    rate_script,
    3,
    "ban:" .. ip,
    "ban:rule:" .. rule_id .. ":" .. ip,
    "rate:rule:" .. rule_id .. ":" .. ip,
    rule.threshold,
    rule.window,
    rule.banTtl,
    rule.action,
    rule.name
)
if not result then
    return redis_unavailable("eval failed: " .. (eval_err or "unknown"), red)
end

local status = result[1]
local count = tonumber(result[3]) or 0
ngx.header["X-WAF-Rule"] = rule.name
ngx.header["X-RateLimit-Limit"] = rule.threshold
ngx.header["X-RateLimit-Remaining"] = math.max(rule.threshold - count, 0)

if status == "global_banned" or status == "global_limited" then
    ngx.header["Content-Type"] = "application/json"
    ngx.status = status == "global_banned" and ngx.HTTP_FORBIDDEN or ngx.HTTP_TOO_MANY_REQUESTS
    ngx.say('{"ok":false,"reason":"ip banned by waf rule"}')
    redis_client.keepalive(red)
    return ngx.exit(ngx.status)
end

if status == "rule_banned" or status == "rule_limited" then
    ngx.header["Content-Type"] = "application/json"
    ngx.status = ngx.HTTP_TOO_MANY_REQUESTS
    ngx.say('{"ok":false,"reason":"request limited by waf rule"}')
    redis_client.keepalive(red)
    return ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end

if status ~= "allowed" then
    return redis_unavailable("unexpected eval status: " .. tostring(status), red)
end

redis_client.keepalive(red)
