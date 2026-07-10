local admin = require "admin_common"
local cjson = require "cjson.safe"

if not admin.require_token() then
    return
end

if ngx.req.get_method() ~= "GET" then
    ngx.status = ngx.HTTP_NOT_ALLOWED
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ ok = false, reason = "该接口仅支持读取配置" }))
    return
end

local function trim(value)
    return value and value:match("^%s*(.-)%s*$") or ""
end

local function read_file(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function parse_site(file_name, content)
    local upstream = content:match("proxy_pass%s+([^;%s]+)%s*;")
    if not upstream then
        return nil
    end

    local scheme, host, port, path = upstream:match("^(https?)://([^:/]+):?(%d*)(/?.*)$")
    if not scheme or not host then
        return nil
    end

    local listen = tonumber(content:match("listen%s+(%d+)") or "80")
    local domains = trim(content:match("server_name%s+([^;]+)%s*;"))
    local websocket = content:find("proxy_set_header%s+Upgrade%s+%$http_upgrade%s*;") ~= nil
    local waf = content:find("access_by_lua_file%s+/usr/local/openresty/lua/access%.lua%s*;") ~= nil

    return {
        id = file_name,
        file = file_name,
        name = domains ~= "" and domains or file_name,
        domain = domains,
        listenPort = listen,
        upstreamScheme = scheme,
        upstreamHost = host,
        upstreamPort = tonumber(port) or (scheme == "https" and 443 or 80),
        upstreamPath = path ~= "" and path or "/",
        wafEnabled = waf,
        websocketEnabled = websocket,
        enabled = true,
        readOnly = true,
    }
end

local directory = "/usr/local/openresty/nginx/conf/conf.d"
local pipe = io.popen("find " .. directory .. " -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null")
if not pipe then
    ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ ok = false, reason = "无法读取 Nginx 站点配置目录" }))
    return
end

local sites = {}
for path in pipe:lines() do
    local file_name = path:match("([^/]+)$")
    local content = read_file(path)
    local site = content and parse_site(file_name, content) or nil
    if site then
        table.insert(sites, site)
    end
end
pipe:close()

table.sort(sites, function(a, b)
    return a.file < b.file
end)

ngx.header["Content-Type"] = "application/json"
ngx.say(cjson.encode({ ok = true, sites = #sites > 0 and sites or cjson.empty_array }))
