# OpenResty + Lua + Redis 动态封禁

这是一个本地 Docker 示例，用 OpenResty、Lua 和 Redis 实现动态 IP 封禁。

## 启动

```bash
docker compose up --build
```

另开一个终端测试访问：

```bash
curl -i http://localhost:80/
```

## 页面管理

打开 Bootstrap 管理页面：

```text
http://localhost:80/admin/
```

默认管理 Token：

```text
change-me
```

页面支持查看、添加和解除拉黑 IP。

## API

拉黑一个 IP 60 秒：

```bash
curl -i -H 'X-Admin-Token: change-me' 'http://localhost:80/admin/ban?ip=1.2.3.4&ttl=60&reason=test'
```

模拟这个 IP 访问：

```bash
curl -i -H 'X-Real-IP: 1.2.3.4' http://localhost:80/
```

查询封禁状态：

```bash
curl -i -H 'X-Admin-Token: change-me' 'http://localhost:80/admin/check?ip=1.2.3.4'
```

查看当前黑名单：

```bash
curl -i -H 'X-Admin-Token: change-me' 'http://localhost:80/admin/list'
```

解除封禁：

```bash
curl -i -H 'X-Admin-Token: change-me' 'http://localhost:80/admin/unban?ip=1.2.3.4'
```

## 自动封禁

默认配置下，同一个 IP 在 60 秒内请求超过 20 次会被自动封禁 300 秒。

```bash
for i in $(seq 1 25); do curl -s -o /dev/null -w "%{http_code}\n" -H 'X-Real-IP: 5.6.7.8' http://localhost:80/; done
```

预期结果：前 `AUTO_BAN_THRESHOLD` 次返回 `200`，下一次返回 `429`，之后命中黑名单返回 `403`。

## 配置项

修改 `docker-compose.yml` 里的环境变量：

- `ADMIN_TOKEN`：管理接口 Token
- `REDIS_HOST`：Redis 地址
- `REDIS_PORT`：Redis 端口
- `REDIS_PASSWORD`：Redis 密码，未开启密码时在 `docker-compose.yml` 中保持注释
- `CLIENT_IP_MODE`：客户端 IP 获取模式，可选 `x_real_ip`、`proxy_protocol`、`remote_addr`
- `AUTO_BAN_THRESHOLD`：触发自动封禁的请求次数阈值
- `AUTO_BAN_WINDOW`：统计窗口，单位秒
- `AUTO_BAN_TTL`：自动封禁时长，单位秒

## Nginx 配置结构

主配置只保留全局 Lua 路径、环境变量和站点 include：

```nginx
http {
    lua_package_path "/usr/local/openresty/lua/?.lua;;";
    resolver 127.0.0.11 valid=30s ipv6=off;

    include /usr/local/openresty/nginx/conf/conf.d/*.conf;
}
```

管理页面和管理 API 在：

```text
conf/conf.d/blacklist-admin.conf
```

业务站点可以参考：

```text
conf/conf.d/aps.jinglewill.com.conf.example
```

真实业务接入时，在对应 `location` 里加入：

```nginx
access_by_lua_file /usr/local/openresty/lua/access.lua;
```

## 客户端 IP 获取模式

通过 `CLIENT_IP_MODE` 控制 Lua 使用哪个地址作为封禁 IP：

- `x_real_ip`：七层 LB / 反向代理模式，读取 `X-Real-IP`，本地测试默认使用这个模式
- `proxy_protocol`：四层 LB 模式，读取 `ngx.var.proxy_protocol_addr`
- `remote_addr`：不信任 Header，只使用 TCP 连接来源地址

四层 LB 模式还需要业务 `server` 的监听配置启用 Proxy Protocol：

```nginx
listen 80 proxy_protocol;
```

## Redis Key

## Redis 密码

默认本地开发不启用 Redis 密码。如需开启，取消 `docker-compose.yml` 中两处注释，并保证密码一致：

```yaml
openresty:
  environment:
    REDIS_PASSWORD: "your-password"

redis:
  command: ["redis-server", "--appendonly", "yes", "--requirepass", "your-password"]
```

如果连接外部 Redis，只需要设置 OpenResty 侧：

```yaml
openresty:
  environment:
    REDIS_HOST: "172.16.110.20"
    REDIS_PORT: "6379"
    REDIS_PASSWORD: "your-password"
```

- `ban:<ip>`：封禁记录，值是封禁原因，TTL 是剩余封禁时间
- `rate:<ip>`：请求计数器，TTL 是当前统计窗口剩余时间

## 生产注意事项

- 对外暴露服务前必须修改 `ADMIN_TOKEN`。
- 真实部署时建议通过内网、VPN、mTLS 或网关规则限制 `/admin/*` 访问。
- 只有当 `X-Real-IP` 是由你自己的反向代理写入时才能信任它，否则应该使用 `ngx.var.remote_addr`。
- 管理配置默认用 `allow/deny` 限制了 `/admin/*` 来源，部署时应改成你的实际办公网、堡垒机或 VPN 出口 IP。
- 手动拉黑接口会拒绝 `0.0.0.0/8`、本机地址、内网地址、链路本地地址、组播和保留地址，避免误操作影响内部服务。
