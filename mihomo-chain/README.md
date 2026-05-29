# mihomo v1.19.25 链式代理 Docker 容器

在 Docker 中运行 mihomo v1.19.25，通过 **Relay** 类型代理组实现 A1 → A2 链式代理，
为局域网提供 HTTP/SOCKS5/透明代理服务。

## 流量路径

```
客户端设备（局域网）
     │
     ▼ HTTP :7890 / SOCKS5 :7891 / 透明代理 :7894
┌──────────────────────────────────────────┐
│          mihomo 容器 (Docker)            │
│                                          │
│   Chain-Proxy (type: relay)              │
│       ├── A1 (跳板/第一跳)               │
│       └── A2 (出口/第二跳)               │
│                                          │
│   → Relay 流量: 客户端 → A1 → A2 → 目标  │
└──────────────────────────────────────────┘
```

## 快速开始

### 1. 编辑配置

修改 `config.yaml` 中的代理节点信息：

- `A1.server` / `A1.port` / `A1.password` — 第一跳代理参数
- `A2.server` / `A2.port` / `A2.password` — 第二跳代理参数

### 2. 构建并启动

```bash
# 在 mihomo-chain/ 目录下
docker compose build
docker compose up -d
```

### 3. 验证运行

```bash
# 查看日志
docker compose logs -f

# 运行测试脚本
bash test.sh

# 直接测试 HTTP 代理
curl -x http://127.0.0.1:7890 https://www.google.com
```

### 4. 客户端配置

在局域网设备上，将 HTTP 或 SOCKS5 代理指向 Docker 宿主机的 IP：

| 协议      | 地址              | 端口  |
|-----------|-------------------|-------|
| HTTP      | <宿主机IP>        | 7890  |
| SOCKS5    | <宿主机IP>        | 7891  |
| Mixed     | <宿主机IP>        | 7892  |

### 5. 透明代理（可选）

如果想**无配置**地让局域网所有设备自动走代理：

```bash
# 在 Docker 宿主机上运行（root 权限）
sudo bash setup-iptables.sh

# 将路由器的 DHCP 的网关和 DNS 指向这台宿主机
```

## 目录结构

```
mihomo-chain/
├── config.yaml            # mihomo 主配置文件
├── Dockerfile             # 容器镜像构建
├── docker-compose.yml     # 服务编排
├── test.sh                # 代理测试脚本
├── setup-iptables.sh      # 透明代理 iptables 规则
└── README.md              # 本文件
```

## 常用命令

```bash
# 启动
docker compose up -d

# 查看日志
docker compose logs -f

# 重启
docker compose restart

# 停止
docker compose down

# 进入容器
docker exec -it mihomo-chain sh

# 查看代理状态
curl http://127.0.0.1:9090/proxies | python3 -m json.tool
```

## 配置说明

- **Relay 代理组**：`Chain-Proxy` 使用 `type: relay`，顺序指定 A1 → A2，流量依次经过
- **Selector**：`Proxy` 组可在 Web UI 中切换 Chain-Proxy / DIRECT
- **allow-lan: true** + **bind-address: "0.0.0.0"** 确保局域网设备可以连接

## 架构兼容性

默认下载 `amd64` 架构。如果是树莓派 (arm64) 或 32 位设备，
`docker compose build` 时会自动检测架构。支持：

- linux/amd64
- linux/arm64
- linux/arm/v7
- linux/386
