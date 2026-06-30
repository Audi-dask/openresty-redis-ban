local redis_client = require "redis_client"

local function number_env(name, default)
    local value = tonumber(os.getenv(name))
    if value == nil then
        return default
    end
    return value
end

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
        -- X-Real-IP 模式：只在 X-Real-IP 由可信七层 LB / 反向代理写入时使用。
        return ngx.req.get_headers()["X-Real-IP"] or ngx.var.remote_addr or "unknown"
    elseif mode == "proxy_protocol" then
        -- 四层 LB 模式：LB 需要启用 Proxy Protocol，Nginx listen 也要加 proxy_protocol。
        return ngx.var.proxy_protocol_addr or ngx.var.remote_addr or "unknown"
    elseif mode == "remote_addr" then
        -- 裸连或不信任任何 Header：只使用 TCP 连接来源地址。
        return ngx.var.remote_addr or "unknown"
    end

    ngx.log(ngx.WARN, "unknown CLIENT_IP_MODE: ", mode, ", fallback to remote_addr")
    return ngx.var.remote_addr or "unknown"
end

local rate_script = [[
local ban_key = KEYS[1]
local rate_key = KEYS[2]
local threshold = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local ban_ttl = tonumber(ARGV[3])

local banned = redis.call("GET", ban_key)
if banned then
    return {"banned", banned, -1}
end

local count = redis.call("INCR", rate_key)
if count == 1 then
    redis.call("EXPIRE", rate_key, window)
end

if count > threshold then
    redis.call("SETEX", ban_key, ban_ttl, "auto-rate-limit")
    return {"limited", "auto-rate-limit", count}
end

return {"allowed", "", count}
]]

local function run_rate_script(red, ban_key, rate_key, threshold, window, ttl)
    return red:eval(rate_script, 2, ban_key, rate_key, threshold, window, ttl)
end

local ip = client_ip()
local red, err = redis_client.connect()
if not red then
    return redis_unavailable("connect failed: " .. (err or "unknown"))
end

local function reconnect_once(old_red, reason)
    redis_client.close(old_red)
    ngx.log(ngx.WARN, "redis command failed, reconnecting once: ", reason)
    return redis_client.connect()
end

local threshold = number_env("AUTO_BAN_THRESHOLD", 10)
local window = number_env("AUTO_BAN_WINDOW", 60)
local ttl = number_env("AUTO_BAN_TTL", 300)
local ban_key = "ban:" .. ip
local rate_key = "rate:" .. ip

-- 原子完成：查封禁、计数、首次设置窗口 TTL、超阈值写入封禁。
local result, eval_err = run_rate_script(red, ban_key, rate_key, threshold, window, ttl)
if eval_err == "closed" then
    red, err = reconnect_once(red, eval_err)
    if not red then
        return redis_unavailable("reconnect failed after eval: " .. (err or "unknown"))
    end
    result, eval_err = run_rate_script(red, ban_key, rate_key, threshold, window, ttl)
end

if not result then
    return redis_unavailable("eval failed: " .. (eval_err or "unknown"), red)
end

local status = result[1]
local reason = result[2]
local count = tonumber(result[3]) or 0

if status == "banned" then
    ngx.header["Content-Type"] = "application/json"
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.say('{"ok":false,"reason":"ip banned"}')
    redis_client.keepalive(red)
    return ngx.exit(ngx.HTTP_FORBIDDEN)
end

ngx.header["X-RateLimit-Limit"] = threshold
ngx.header["X-RateLimit-Remaining"] = math.max(threshold - count, 0)

if status == "limited" then
    ngx.header["Content-Type"] = "application/json"
    ngx.status = ngx.HTTP_TOO_MANY_REQUESTS
    ngx.say('{"ok":false,"reason":"auto banned by rate limit"}')
    redis_client.keepalive(red)
    return ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end

if status ~= "allowed" then
    return redis_unavailable("unexpected eval status: " .. tostring(status), red)
end

redis_client.keepalive(red)
