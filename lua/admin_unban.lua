local admin = require "admin_common"
local cjson = require "cjson.safe"

if not admin.require_token() then
    return
end

local ip = admin.ip_arg()
if not ip then
    return
end

local red = admin.redis()
if not red then
    return
end

local ok, err = red:del("ban:" .. ip)
if not ok then
    admin.redis_error(red, "del ban", err)
    return
end

ok, err = red:del("rate:" .. ip)
if not ok then
    admin.redis_error(red, "del rate", err)
    return
end

ngx.header["Content-Type"] = "application/json"
ngx.say(cjson.encode({ ok = true, ip = ip, unbanned = true }))
admin.done(red)
