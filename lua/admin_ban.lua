local admin = require "admin_common"
local cjson = require "cjson.safe"

if not admin.require_token() then
    return
end

local ip = admin.ip_arg()
if not ip then
    return
end

if not admin.validate_ban_ip(ip) then
    return
end

local ttl = tonumber(ngx.var.arg_ttl or "3600") or 3600
local reason = ngx.var.arg_reason or "manual"
local red = admin.redis()
if not red then
    return
end

local ok, err = red:setex("ban:" .. ip, ttl, reason)
if not ok then
    admin.redis_error(red, "setex", err)
    return
end

ngx.header["Content-Type"] = "application/json"
ngx.say(cjson.encode({ ok = true, ip = ip, ttl = ttl, reason = reason }))
admin.done(red)
