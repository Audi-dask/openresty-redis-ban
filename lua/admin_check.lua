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

local reason = red:get("ban:" .. ip)
local ttl = red:ttl("ban:" .. ip)
local banned = reason and reason ~= ngx.null

ngx.header["Content-Type"] = "application/json"
if banned then
    ngx.say(cjson.encode({ ok = true, ip = ip, banned = true, ttl = ttl, reason = reason }))
else
    ngx.say(cjson.encode({ ok = true, ip = ip, banned = false }))
end
admin.done(red)
