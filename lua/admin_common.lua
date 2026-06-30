local redis_client = require "redis_client"

local _M = {}

function _M.require_token()
    local expected = os.getenv("ADMIN_TOKEN")
    if not expected or expected == "" then
        ngx.log(ngx.ERR, "ADMIN_TOKEN is not configured")
        ngx.header["Content-Type"] = "application/json"
        ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
        ngx.say('{"ok":false,"reason":"admin token not configured"}')
        return false
    end

    -- 管理接口支持 Header 或 query token，页面请求使用 Header。
    local actual = ngx.req.get_headers()["X-Admin-Token"] or ngx.var.arg_token

    if actual ~= expected then
        ngx.header["Content-Type"] = "application/json"
        ngx.status = ngx.HTTP_UNAUTHORIZED
        ngx.say('{"ok":false,"reason":"unauthorized"}')
        return false
    end

    return true
end

function _M.ip_arg()
    local ip = ngx.var.arg_ip
    if not ip or ip == "" then
        ngx.header["Content-Type"] = "application/json"
        ngx.status = ngx.HTTP_BAD_REQUEST
        ngx.say('{"ok":false,"reason":"missing ip"}')
        return nil
    end
    return ip
end

local function ipv4_to_number(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not a or not b or not c or not d then
        return nil
    end
    if a > 255 or b > 255 or c > 255 or d > 255 then
        return nil
    end
    return a * 16777216 + b * 65536 + c * 256 + d
end

local function cidr_contains(ip_num, cidr)
    local base, bits = cidr:match("^([^/]+)/(%d+)$")
    local base_num = ipv4_to_number(base)
    bits = tonumber(bits)
    if not base_num or not bits or bits < 0 or bits > 32 then
        return false
    end

    local size = 2 ^ (32 - bits)
    return ip_num >= base_num and ip_num < base_num + size
end

function _M.validate_ban_ip(ip)
    local ip_num = ipv4_to_number(ip)
    if not ip_num then
        ngx.header["Content-Type"] = "application/json"
        ngx.status = ngx.HTTP_BAD_REQUEST
        ngx.say('{"ok":false,"reason":"invalid ipv4"}')
        return false
    end

    local protected_cidrs = {
        "0.0.0.0/8",
        "10.0.0.0/8",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "224.0.0.0/4",
        "240.0.0.0/4",
        "255.255.255.255/32",
    }

    for _, cidr in ipairs(protected_cidrs) do
        if cidr_contains(ip_num, cidr) then
            ngx.header["Content-Type"] = "application/json"
            ngx.status = ngx.HTTP_BAD_REQUEST
            ngx.say('{"ok":false,"reason":"protected ip range"}')
            return false
        end
    end

    return true
end

function _M.redis()
    local red, err = redis_client.connect()
    if not red then
        ngx.log(ngx.ERR, "redis connect failed: ", err)
        ngx.header["Content-Type"] = "application/json"
        ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
        ngx.say('{"ok":false,"reason":"redis unavailable"}')
        return nil
    end
    return red
end

function _M.redis_error(red, operation, err)
    ngx.log(ngx.ERR, "redis ", operation, " failed: ", err)
    redis_client.close(red)
    ngx.header["Content-Type"] = "application/json"
    ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
    ngx.say('{"ok":false,"reason":"redis unavailable"}')
end

function _M.done(red)
    redis_client.keepalive(red)
end

return _M
