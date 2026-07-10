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

local function wants_html()
    local accept = ngx.var.http_accept or ""
    local uri = ngx.var.uri or "/"
    local api_path = uri == "/api" or string.sub(uri, 1, 5) == "/api/"
    return not api_path and accept:find("text/html", 1, true) ~= nil
end

local function request_id()
    if ngx.var.request_id and ngx.var.request_id ~= "" then
        return ngx.var.request_id
    end
    return string.sub(ngx.md5(tostring(ngx.now()) .. (ngx.var.remote_addr or "") .. (ngx.var.request_uri or "")), 1, 16)
end

local function block_response(status, code, title, message, retry_after)
    local event_id = request_id()
    local retry = math.max(tonumber(retry_after) or 0, 0)
    ngx.status = status
    ngx.header["Cache-Control"] = "no-store"
    ngx.header["X-WAF-Request-ID"] = event_id
    if retry > 0 then
        ngx.header["Retry-After"] = retry
    end

    if not wants_html() then
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.say(cjson.encode({
            status = "blocked",
            code = code,
            message = message,
            requestId = event_id,
            retryAfter = retry > 0 and retry or nil,
        }))
        return ngx.exit(status)
    end

    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.say('<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>' .. title .. '</title><style>')
    ngx.say('*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;background:radial-gradient(circle at top,#18233f 0,#0b1020 48%,#070a12 100%);color:#e8edf7;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.card{width:min(560px,100%);padding:42px;border:1px solid rgba(255,255,255,.12);border-radius:20px;background:rgba(17,24,39,.86);box-shadow:0 24px 80px rgba(0,0,0,.45);backdrop-filter:blur(16px)}.shield{display:grid;place-items:center;width:58px;height:58px;margin-bottom:28px;border-radius:16px;background:linear-gradient(135deg,#f97316,#ef4444);font-size:28px;font-weight:800}.eyebrow{margin-bottom:10px;color:#fb923c;font-size:13px;font-weight:700;letter-spacing:.14em;text-transform:uppercase}h1{margin:0 0 14px;font-size:30px;line-height:1.25}p{margin:0;color:#aeb9cc;font-size:16px;line-height:1.75}.meta{margin-top:30px;padding-top:22px;border-top:1px solid rgba(255,255,255,.1);display:grid;gap:8px;color:#7f8ba3;font-size:13px}.meta code{color:#cbd5e1;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}.hint{margin-top:24px;color:#718096;font-size:13px}</style></head><body>')
    ngx.say('<main class="card"><div class="shield">!</div><div class="eyebrow">Security protection</div><h1>' .. title .. '</h1><p>' .. message .. '</p><div class="meta"><div>事件 ID：<code>' .. event_id .. '</code></div>' .. (retry > 0 and '<div>建议重试：<code>' .. retry .. ' 秒后</code></div>' or '') .. '</div><div class="hint">如确认这是正常访问，请将事件 ID 提供给网站管理员。</div></main></body></html>')
    return ngx.exit(status)
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
    local ttl = red:ttl("ban:" .. ip)
    redis_client.keepalive(red)
    return block_response(
        ngx.HTTP_FORBIDDEN,
        "WAF_IP_BLOCKED",
        "访问已被安全策略拦截",
        "当前网络地址已被临时限制访问，请稍后重试。",
        ttl
    )
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
ngx.header["X-RateLimit-Remaining"] = status == "allowed" and math.max(rule.threshold - count, 0) or 0

if status == "global_banned" or status == "global_limited" then
    local response_status = status == "global_banned" and ngx.HTTP_FORBIDDEN or ngx.HTTP_TOO_MANY_REQUESTS
    local ttl = red:ttl("ban:" .. ip)
    redis_client.keepalive(red)
    return block_response(
        response_status,
        "WAF_IP_BLOCKED",
        "访问已被安全策略拦截",
        "当前网络地址触发了安全防护策略，请稍后重试。",
        ttl
    )
end

if status == "rule_banned" or status == "rule_limited" then
    local ttl = red:ttl("ban:rule:" .. rule_id .. ":" .. ip)
    redis_client.keepalive(red)
    return block_response(
        ngx.HTTP_TOO_MANY_REQUESTS,
        "WAF_RATE_LIMITED",
        "请求过于频繁",
        "您的访问已被安全策略临时限制，请稍后再试。",
        ttl
    )
end

if status ~= "allowed" then
    return redis_unavailable("unexpected eval status: " .. tostring(status), red)
end

redis_client.keepalive(red)
