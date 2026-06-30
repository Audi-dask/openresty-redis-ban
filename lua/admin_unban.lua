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

red:del("ban:" .. ip)
red:del("rate:" .. ip)

ngx.header["Content-Type"] = "application/json"
ngx.say(cjson.encode({ ok = true, ip = ip, unbanned = true }))
admin.done(red)
