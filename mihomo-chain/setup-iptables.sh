#!/usr/bin/env bash
# ============================================================
# setup-iptables.sh - 透明代理/iptables 转发
# 将局域网流量透明地转发到 mihomo 代理
# 在宿主机上以 root 执行
# ============================================================
set -euo pipefail

# mihomo 监听的端口
MIHOMO_TPROXY_PORT=7894
MIHOMO_REDIR_PORT=7893

# 需要绕过代理的内网网段
BYPASS_CIDRS=(
    "0.0.0.0/8"
    "10.0.0.0/8"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "224.0.0.0/4"
    "240.0.0.0/4"
)

echo "========================================"
echo "iptables 透明代理设置"
echo "========================================"
echo ""

# 检查 root
if [ "$EUID" -ne 0 ]; then
    echo "✗ 请以 root 身份运行: sudo $0"
    exit 1
fi

# 创建 mihomo 链
echo "[1/4] 创建 iptables 规则链..."
iptables -t mangle -N MIHOMO 2>/dev/null || true
iptables -t mangle -N MIHOMO_MARK 2>/dev/null || true
ip6tables -t mangle -N MIHOMO 2>/dev/null || true

# 绕过大网段
echo "[2/4] 设置直连网段..."
for CIDR in "${BYPASS_CIDRS[@]}"; do
    iptables -t mangle -A MIHOMO -d "${CIDR}" -j RETURN
done

# TCP - 重定向到 redir-port
echo "[3/4] 设置 TCP 重定向..."
iptables -t mangle -A MIHOMO -p tcp -j TPROXY \
    --on-port "${MIHOMO_TPROXY_PORT}" \
    --tproxy-mark 0x1/0x1
iptables -t mangle -A PREROUTING -j MIHOMO

# 标记已处理包
iptables -t mangle -A MIHOMO_MARK -p tcp -j MARK --set-mark 0x1
iptables -t mangle -A OUTPUT -p tcp -j MIHOMO_MARK

# UDP
echo "[4/4] 设置 UDP 重定向..."
iptables -t mangle -A MIHOMO -p udp -j TPROXY \
    --on-port "${MIHOMO_TPROXY_PORT}" \
    --tproxy-mark 0x1/0x1

# 路由规则
ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
ip rule add fwmark 0x1 lookup 100 2>/dev/null || true

echo ""
echo "✓ iptables 规则设置完成！"
echo "  透明代理端口: ${MIHOMO_TPROXY_PORT} (tproxy)"
echo ""
echo "撤销规则请执行: iptables -t mangle -F MIHOMO && iptables -t mangle -F MIHOMO_MARK && iptables -t mangle -D PREROUTING -j MIHOMO && iptables -t mangle -D OUTPUT -p tcp -j MIHOMO_MARK"
