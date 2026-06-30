local redis_client = require "redis_client"

local function number_env(name, default)
    local value = tonumber(os.getenv(name))
    if value == nil then
        return default
    end
    return value
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

local ip = client_ip()
local red, err = redis_client.connect()
if not red then
    ngx.log(ngx.ERR, "redis connect failed: ", err)
    return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
end

local ban_key = "ban:" .. ip
local banned, get_err = red:get(ban_key)
if get_err then
    ngx.log(ngx.ERR, "redis get failed: ", get_err)
    redis_client.keepalive(red)
    return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
end

if banned and banned ~= ngx.null then
    -- 命中 Redis 里的 ban:<ip>，直接拒绝访问。
    ngx.header["Content-Type"] = "application/json"
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.say('{"ok":false,"reason":"ip banned"}')
    redis_client.keepalive(red)
    return ngx.exit(ngx.HTTP_FORBIDDEN)
end

local threshold = number_env("AUTO_BAN_THRESHOLD", 10)
local window = number_env("AUTO_BAN_WINDOW", 60)
local ttl = number_env("AUTO_BAN_TTL", 300)
local rate_key = "rate:" .. ip

-- rate:<ip> 是固定窗口计数器，第一次出现时设置窗口过期时间。
local count, incr_err = red:incr(rate_key)
if not count then
    ngx.log(ngx.ERR, "redis incr failed: ", incr_err)
    redis_client.keepalive(red)
    return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
end

if count == 1 then
    red:expire(rate_key, window)
end

ngx.header["X-RateLimit-Limit"] = threshold
ngx.header["X-RateLimit-Remaining"] = math.max(threshold - count, 0)

if count > threshold then
    -- 超过阈值后写入 ban:<ip>，让后续请求直接走 403 封禁逻辑。
    red:setex(ban_key, ttl, "auto-rate-limit")
    ngx.header["Content-Type"] = "application/json"
    ngx.status = ngx.HTTP_TOO_MANY_REQUESTS
    ngx.say('{"ok":false,"reason":"auto banned by rate limit"}')
    redis_client.keepalive(red)
    return ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end

redis_client.keepalive(red)
