local redis = require "resty.redis"

local _M = {}

function _M.connect()
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
            return nil, auth_err
        end
    end

    return red
end

function _M.keepalive(red)
    if red then
        red:set_keepalive(10000, 100)
    end
end

return _M
