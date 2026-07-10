# OpenResty + Lua + Redis URL 防护与动态封禁

基于 OpenResty、Lua 和 Redis 实现的轻量级访问频率防护服务，支持按 URL 规则限流、接口级限制、全站 IP 黑名单和可视化管理。

## 功能

- 按 HTTP 方法和 URL 精确匹配或关键字匹配
- 每条规则独立配置请求阈值、统计窗口和限制时长
- 超限后仅限制命中接口，或封禁该 IP 的全站访问
- 手动添加、查询和解除全站 IP 黑名单
- 查看并提前解除接口级限制记录
- 浏览器请求返回 HTML 安全拦截页
- API 请求返回结构化 JSON、事件 ID 和 `Retry-After`
- Redis 故障支持 fail-open 或 fail-closed
- 管理端与业务反向代理端口隔离

## 构建与启动

构建 Linux x86_64 部署镜像：

```bash
./build_release.sh linux
```

在 Apple Silicon Mac 的 Docker Desktop 中构建 ARM64 镜像：

```bash
./build_release.sh mac
```

构建脚本会生成带时间戳的版本镜像，并同时更新：

```text
openresty-redis-ban:latest
```

镜像构建完成后，启动阶段不再构建：

```bash
docker compose up -d
```

如需使用其他镜像仓库或版本，可通过环境变量覆盖：

```bash
IMAGE_REPO=registry.example.com/security/openresty-waf ./build_release.sh linux
OPENRESTY_WAF_IMAGE=registry.example.com/security/openresty-waf:latest docker compose up -d
```

### `OPENRESTY_WAF_IMAGE` 是什么

`docker-compose.yml` 中的配置：

```yaml
image: ${OPENRESTY_WAF_IMAGE:-openresty-redis-ban:latest}
```

是 Docker Compose 的环境变量替换语法，含义是：

- 如果设置了 `OPENRESTY_WAF_IMAGE`，使用变量指定的镜像；
- 如果没有设置，使用默认镜像 `openresty-redis-ban:latest`。

因此，使用默认构建流程时无需传递变量：

```bash
./build_release.sh linux
docker compose up -d
```

需要切换到其他仓库或指定版本时，可以在启动命令前临时传入：

```bash
OPENRESTY_WAF_IMAGE=registry.example.com/security/openresty-waf:v1.0.0 docker compose up -d
```

也可以在项目根目录的 `.env` 文件中配置，Docker Compose 会自动读取：

```env
OPENRESTY_WAF_IMAGE=registry.example.com/security/openresty-waf:v1.0.0
```

可以通过以下命令查看变量替换后的最终配置：

```bash
OPENRESTY_WAF_IMAGE=my-waf:v1 docker compose config
```

需要注意：`OPENRESTY_WAF_IMAGE` 是 Compose 启动前读取的变量，用于决定运行哪个镜像；`environment` 下的 `REDIS_HOST`、`ADMIN_TOKEN` 等变量才会传入容器内部供 OpenResty 和 Lua 使用。

默认端口：

- `80`：业务反向代理
- `8081`：管理后台和管理 API
- `6379`：Redis；生产环境不建议映射到公网

查看服务状态：

```bash
docker compose ps
```

检查 OpenResty 配置：

```bash
docker compose exec openresty openresty -t
```

## 管理后台

访问：

```text
http://localhost:8081/
```

默认管理 Token：

```text
change-me
```

生产部署前必须修改 `docker-compose.yml` 中的 `ADMIN_TOKEN`。

管理后台包含：

- URL 防护规则
- 接口限制记录
- 全站 IP 黑名单

`8081` 默认允许回环和 RFC1918 私网访问。生产环境还应通过安全组、防火墙、VPN 或端口绑定限制管理入口。

## 业务接入

参考 `conf/conf.d/example.com.conf`，在真实业务 `location` 中先执行 WAF，再反向代理：

```nginx
location / {
    access_by_lua_file /usr/local/openresty/lua/access.lua;

    proxy_pass http://172.16.110.11:8080/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

域名应解析到 OpenResty 所在服务器，外部请求必须先经过 OpenResty 才会触发防护规则。

## URL 防护规则

规则字段：

- 规则名称
- HTTP 方法：`GET`、`POST`、`PUT`、`DELETE` 或全部
- 匹配方式：精确匹配或关键字匹配
- URL 路径或关键字
- 限制次数
- 统计窗口
- 限制时长
- 处理范围：仅限制此接口或封禁该 IP 全站访问
- 风险等级和启用状态

精确规则优先于关键字规则，查询参数不参与匹配。

### 接口级限制

规则选择“仅限制此接口”时，Redis 写入：

```text
ban:rule:<规则ID>:<IP>
```

该 IP 仍可访问其他路径，并会出现在管理后台的“接口限制记录”中。

### 全站封禁

规则选择“封禁该 IP 全站访问”或管理员手动拉黑时，Redis 写入：

```text
ban:<IP>
```

该 IP 的所有业务请求都会被拦截，并出现在“全站 IP 黑名单”中。

## 管理 API

所有管理 API 都需要：

```http
X-Admin-Token: change-me
```

### URL 规则

```text
GET    /admin/rules
POST   /admin/rules
DELETE /admin/rules?id=<规则ID>
```

### 接口限制记录

```text
GET    /admin/rule-limits
DELETE /admin/rule-limits?rule_id=<规则ID>&ip=<IP>
```

解除接口限制时会同时删除该规则对应的限制键和计数键，避免立即再次触发。

### 全站 IP 黑名单

添加封禁：

```bash
curl -H 'X-Admin-Token: change-me' \
  'http://localhost:8081/admin/ban?ip=1.2.3.4&ttl=60&reason=test'
```

查询状态：

```bash
curl -H 'X-Admin-Token: change-me' \
  'http://localhost:8081/admin/check?ip=1.2.3.4'
```

查看列表：

```bash
curl -H 'X-Admin-Token: change-me' \
  'http://localhost:8081/admin/list'
```

解除封禁：

```bash
curl -H 'X-Admin-Token: change-me' \
  'http://localhost:8081/admin/unban?ip=1.2.3.4'
```

手动拉黑支持公网和 RFC1918 私网 IPv4，但拒绝回环、链路本地、组播和系统保留地址。

## WAF 拦截响应

### API 请求

接口级限频返回 `429 Too Many Requests`：

```json
{
  "status": "blocked",
  "code": "WAF_RATE_LIMITED",
  "message": "您的访问已被安全策略临时限制，请稍后再试。",
  "requestId": "817acbad31c15d4ddfd32896b1a5f1dc",
  "retryAfter": 90
}
```

全站黑名单返回 `403 Forbidden`，错误码为：

```text
WAF_IP_BLOCKED
```

响应头包含：

```text
Cache-Control: no-store
X-WAF-Request-ID: <事件ID>
Retry-After: <剩余秒数>
X-RateLimit-Remaining: 0
```

### 浏览器请求

非 `/api` 路径且 `Accept` 包含 `text/html` 时，返回响应式 HTML 安全拦截页，并展示事件 ID 和建议重试时间。

## 配置项

在 `docker-compose.yml` 中配置：

- `ADMIN_TOKEN`：管理接口 Token，必须显式配置
- `REDIS_HOST`：Redis 地址
- `REDIS_PORT`：Redis 端口
- `REDIS_PASSWORD`：Redis 密码；未启用时保持注释
- `CLIENT_IP_MODE`：客户端 IP 获取模式
- `FAIL_MODE`：Redis 故障策略，支持 `open` 和 `closed`

URL 阈值、统计窗口和限制时长由管理后台中的每条规则配置，不再使用全局 `AUTO_BAN_*` 环境变量。

## 客户端 IP 获取

### remote_addr

生产环境默认推荐：

```yaml
CLIENT_IP_MODE: "remote_addr"
```

如果 OpenResty 前面有可信负载均衡，应使用 Nginx Real IP 模块把可信上游提供的真实地址归一化到 `$remote_addr`：

```nginx
set_real_ip_from 100.125.0.0/16;
real_ip_header X-Forwarded-For;
real_ip_recursive on;
```

不要配置：

```nginx
set_real_ip_from 0.0.0.0/0;
```

否则任意客户端都可能伪造 `X-Forwarded-For`。

### x_real_ip

只适用于 OpenResty 无法被客户端直连，且可信上游会覆盖 `X-Real-IP` 的环境。否则客户端可以伪造 Header。

### proxy_protocol

前置四层负载均衡启用 Proxy Protocol 时，业务监听也必须启用：

```nginx
listen 80 proxy_protocol;
```

对应配置：

```yaml
CLIENT_IP_MODE: "proxy_protocol"
```

## Redis 故障策略

```yaml
FAIL_MODE: "open"
```

- `open`：Redis 故障时放行业务请求并记录错误日志，避免安全组件成为全站单点故障
- `closed`：Redis 故障时返回 `503` 和 `WAF_REDIS_UNAVAILABLE`

管理 API 在 Redis 不可用时始终返回 `503`。

## Redis Key

- `waf:rules`：URL 防护规则 Hash
- `waf:rule:id`：规则 ID 自增序列
- `rate:rule:<规则ID>:<IP>`：规则访问计数器
- `ban:rule:<规则ID>:<IP>`：接口级限制
- `ban:<IP>`：全站 IP 黑名单

访问计数和封禁使用 Redis `EVAL` 原子执行，避免计数成功但 TTL 设置失败。

## Redis 密码

启用本地 Redis 密码时，确保 OpenResty 与 Redis 配置一致：

```yaml
openresty:
  environment:
    REDIS_PASSWORD: "your-password"

redis:
  command: ["redis-server", "--appendonly", "yes", "--requirepass", "your-password"]
```

连接外部 Redis 时只需配置 OpenResty：

```yaml
openresty:
  environment:
    REDIS_HOST: "172.16.110.20"
    REDIS_PORT: "6379"
    REDIS_PASSWORD: "your-password"
```

## 生产注意事项

- 修改默认 `ADMIN_TOKEN`
- 仅向管理网开放 `8081`
- 不要将 Redis `6379` 暴露到公网
- 根据实际办公网、VPN 或堡垒机网段收窄 `waf-admin.conf` 的 `allow` 范围
- 使用 `remote_addr` 配合 Real IP 模块，而不是无条件信任客户端 Header
- 业务必须先经过 OpenResty，绕过 OpenResty 直连后端不会触发 WAF
- OpenResty 已配置 `server_tokens off`，不会在响应头和默认错误页中暴露具体版本号
