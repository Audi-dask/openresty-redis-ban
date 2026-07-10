local admin = require "admin_common"
local cjson = require "cjson.safe"

if not admin.require_token() then
    return
end

local red = admin.redis()
if not red then
    return
end

local cursor = "0"
local bans = {}

repeat
    -- Redis SCAN 避免一次性 KEYS 扫全库，适合线上渐进式遍历。
    local res, err = red:scan(cursor, "MATCH", "ban:*", "COUNT", 100)
    if not res then
        ngx.log(ngx.ERR, "redis scan failed: ", err)
        admin.done(red)
        ngx.header["Content-Type"] = "application/json"
        ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
        ngx.say('{"ok":false,"reason":"读取 IP 黑名单失败"}')
        return
    end

    cursor = res[1]
    local keys = res[2]
    for _, key in ipairs(keys) do
        -- 接口级自动封禁使用 ban:rule:*，不应混入全站 IP 黑名单列表。
        if not key:match("^ban:rule:") then
            local reason, get_err = red:get(key)
            if get_err then
                admin.redis_error(red, "get", get_err)
                return
            end

            local ttl, ttl_err = red:ttl(key)
            if ttl_err then
                admin.redis_error(red, "ttl", ttl_err)
                return
            end

            table.insert(bans, {
                ip = string.sub(key, 5),
                ttl = ttl,
                reason = reason ~= ngx.null and reason or "",
            })
        end
    end
until cursor == "0"

table.sort(bans, function(a, b)
    return a.ip < b.ip
end)

ngx.header["Content-Type"] = "application/json"
ngx.say(cjson.encode({ ok = true, bans = #bans > 0 and bans or cjson.empty_array }))
admin.done(red)
