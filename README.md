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

默认配置下，同一个 IP 在 60 秒内请求超过 `AUTO_BAN_THRESHOLD` 次会被自动封禁 300 秒。

```bash
for i in $(seq 1 25); do curl -s -o /dev/null -w "%{http_code}\n" -H 'X-Real-IP: 5.6.7.8' http://localhost:80/; done
```

预期结果：前 `AUTO_BAN_THRESHOLD` 次返回 `200`，下一次返回 `429`，之后命中黑名单返回 `403`。

## 配置项

修改 `docker-compose.yml` 里的环境变量：

- `ADMIN_TOKEN`：管理接口 Token，必须显式配置；未配置时管理接口会拒绝服务
- `REDIS_HOST`：Redis 地址
- `REDIS_PORT`：Redis 端口
- `REDIS_PASSWORD`：Redis 密码，未开启密码时在 `docker-compose.yml` 中保持注释
- `CLIENT_IP_MODE`：客户端 IP 获取模式，可选 `x_real_ip`、`proxy_protocol`、`remote_addr`
- `FAIL_MODE`：业务防护链路的 Redis 故障策略，可选 `open`、`closed`
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
conf/conf.d/example.com.conf.example
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

### 生产推荐

生产环境优先推荐使用：

```yaml
CLIENT_IP_MODE: "remote_addr"
```

然后在 Nginx/OpenResty 配置里用 `realip` 模块把可信上游传来的真实 IP 归一化到 `$remote_addr`。这样 Lua 不需要直接读取容易被伪造的 HTTP Header。

### 华为云七层 ELB

华为云七层 HTTP/HTTPS ELB 会通过 `X-Forwarded-For` 传递真实客户端 IP，格式类似：

```text
X-Forwarded-For: 来访者真实IP, 代理服务器1-IP, 代理服务器2-IP
```

`X-Forwarded-For` 本身可以被客户端伪造，所以不要在 Lua 里无条件直接读取它。推荐做法是在 Nginx/OpenResty 中只信任华为云 ELB 或你自己的上游代理来源，再让 `realip` 改写 `$remote_addr`：

```nginx
set_real_ip_from 100.125.0.0/16;
real_ip_header X-Forwarded-For;
real_ip_recursive on;
```

说明：

- 共享型 ELB：华为云文档建议添加 `100.125.0.0/16`。
- 独享型 ELB：添加 ELB 实例关联的 VPC 子网网段。
- 如果 OpenResty 前面还有你自己的 NAT、网关或反向代理，需要把 OpenResty 看到的直接上游 IP 或网段加入 `set_real_ip_from`。
- 不要配置 `set_real_ip_from 0.0.0.0/0`，否则等于信任任意客户端伪造的 `X-Forwarded-For`。

配置完成后，Lua 继续使用 `CLIENT_IP_MODE=remote_addr`。此时 `$remote_addr` 已经是 realip 模块处理后的可信客户端 IP。

### X-Real-IP 模式

`x_real_ip` 只适用于满足以下条件的环境：

- OpenResty 不能被公网客户端直连，只能被可信七层代理访问。
- 上游代理会覆盖 `X-Real-IP`，而不是透传客户端自带的 `X-Real-IP`。
- 你明确确认 `X-Real-IP` 就是真实客户端 IP。

如果这些条件不满足，客户端可以伪造 `X-Real-IP` 绕过或误导封禁逻辑。

### 四层 LB 模式

四层 LB 模式还需要业务 `server` 的监听配置启用 Proxy Protocol：

```nginx
listen 80 proxy_protocol;
```

对应配置：

```yaml
CLIENT_IP_MODE: "proxy_protocol"
```

只有当前面的四层 LB 已启用 Proxy Protocol 时才能使用该模式。

### 为什么没有 x_forwarded_for 模式

项目不提供直接读取 `X-Forwarded-For` 的模式。原因是 `X-Forwarded-For` 可以被客户端 100% 伪造。如果需要使用它，应该通过 Nginx/OpenResty 的 `realip` 模块限定可信上游，然后让 Lua 读取处理后的 `$remote_addr`。

## Redis 故障策略

通过 `FAIL_MODE` 控制业务请求在 Redis 不可用时的行为：

- `open`：Redis 故障时放行业务请求，只记录错误日志；默认推荐，避免安全组件变成全站单点故障
- `closed`：Redis 故障时返回 `503`；适合宁可拒绝请求也不能绕过封禁的场景

该策略只影响业务防护链路。管理 API 在 Redis 不可用时始终返回 `503`，避免拉黑、解封、查询出现假成功。

```yaml
FAIL_MODE: "open"
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

业务防护链路使用 Redis `EVAL` 原子完成封禁检查和计数，避免 `INCR` 成功但 `EXPIRE` 失败导致计数器永久存在。

## 生产注意事项

- 对外暴露服务前必须修改 `ADMIN_TOKEN`，Lua 不会使用默认 Token 兜底。
- 真实部署时建议通过内网、VPN、mTLS 或网关规则限制 `/admin/*` 访问。
- 只有当 `X-Real-IP` 是由你自己的反向代理写入时才能信任它，否则应该使用 `ngx.var.remote_addr`。
- 管理配置默认用 `allow/deny` 限制了 `/admin/*` 来源，部署时应改成你的实际办公网、堡垒机或 VPN 出口 IP。
- 手动拉黑接口会拒绝 `0.0.0.0/8`、本机地址、内网地址、链路本地地址、组播和保留地址，避免误操作影响内部服务。
