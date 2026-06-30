local redis = require "resty.redis"

local _M = {}

local function connect_once()
    local red = redis:new()
    red:set_timeout(1000)

    local host = os.getenv("REDIS_HOST") or "redis"
    local port = tonumber(os.getenv("REDIS_PORT") or "6379")
    local ok, err = red:connect(host, port)
    if not ok then
        return nil, err
    end

    local password = os.getenv("REDIS_PASSWORD") or ""
    if password ~= "" then
        local auth_ok, auth_err = red:auth(password)
        if not auth_ok then
            red:close()
            return nil, auth_err
        end
    end

    return red
end

function _M.connect()
    local red, err = connect_once()
    if not red then
        return nil, err
    end

    -- 连接池里可能有 Redis 重启前留下的旧连接；用 PING 发现后重连一次。
    local ok, ping_err = red:ping()
    if ok then
        return red
    end

    red:close()
    ngx.log(ngx.WARN, "redis ping failed, reconnecting: ", ping_err)
    return connect_once()
end

function _M.keepalive(red)
    if red then
        red:set_keepalive(10000, 100)
    end
end

function _M.close(red)
    if red then
        red:close()
    end
end

return _M
