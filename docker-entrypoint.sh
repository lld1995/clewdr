#!/bin/sh
# s6-overlay cont-init: 容器启动时执行一次
# 1. 若 /etc/mihomo/config.yaml 不存在，写入默认空配置（防止 mihomo 启动报错）
# 2. 确保 /etc/clewdr 目录权限正常

set -e

# ---------- mihomo config ----------
if [ ! -f /etc/mihomo/config.yaml ]; then
    echo "[init] /etc/mihomo/config.yaml not found, writing default passthrough config..."
    cat > /etc/mihomo/config.yaml << 'EOF'
# ============================================================
# 默认 mihomo 直连配置（无上游代理）
# 如需链式代理，请将 config.yaml 通过 volume 挂载到 /etc/mihomo/config.yaml
# ============================================================
port: 17890
socks-port: 17891
mixed-port: 17892
allow-lan: true
bind-address: "127.0.0.1"
mode: rule
log-level: warning
ipv6: false

dns:
  enable: false

proxies: []

proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
      - DIRECT

rules:
  - MATCH,DIRECT
EOF
    echo "[init] default config written."
else
    echo "[init] /etc/mihomo/config.yaml found, using existing config."
fi

# ---------- clewdr dirs ----------
mkdir -p /etc/clewdr/log

echo "[init] done."
