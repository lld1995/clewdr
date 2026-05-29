#!/usr/bin/env bash
# ============================================================
# test.sh - 链式代理测试脚本
# ============================================================
set -euo pipefail

PROXY_HOST="${1:-127.0.0.1}"
HTTP_PORT="${2:-7890}"
SOCKS_PORT="${3:-7891}"
API_PORT="${4:-9090}"

echo "========================================"
echo "mihomo 链式代理 - 功能测试"
echo "========================================"
echo ""

# --------------------------------------------------
# 1. 检查容器是否运行
# --------------------------------------------------
echo "[1/5] 检查容器状态..."
if docker ps --format '{{.Names}}' | grep -q 'mihomo-chain'; then
    echo "  ✓ 容器 mihomo-chain 正在运行"
else
    echo "  ✗ 容器 mihomo-chain 未运行"
    echo "  请先执行: docker compose up -d"
    exit 1
fi
echo ""

# --------------------------------------------------
# 2. 检查 mihomo 版本
# --------------------------------------------------
echo "[2/5] 检查 mihomo 版本..."
MIHOMO_VER=$(curl -sf http://${PROXY_HOST}:${API_PORT}/version 2>/dev/null || echo "")
if [ -n "$MIHOMO_VER" ]; then
    echo "  ✓ mihomo API 响应正常"
    echo "  版本信息: ${MIHOMO_VER}"
else
    echo "  ✗ 无法连接 mihomo API，请检查服务"
    exit 1
fi
echo ""

# --------------------------------------------------
# 3. 检查链式代理组配置
# --------------------------------------------------
echo "[3/5] 检查链式代理组..."
PROXY_GROUPS=$(curl -sf http://${PROXY_HOST}:${API_PORT}/proxies 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for name, info in data.get('proxies', {}).items():
    t = info.get('type', '')
    if t == 'Relay':
        print(f'  ✓ relay 代理组: {name}')
        for p in info.get('proxies', []):
            chain = info.get('chain', [])
            print(f'      → 包含节点: {\" → \".join(p for p in info.get(\"proxies\", []))}')
            break
" 2>/dev/null || echo "  ! 无法解析代理组信息")

if [ -z "$PROXY_GROUPS" ]; then
    echo "  ! 未检测到 Relay 代理组，请检查 config.yaml 中的 proxy-groups 配置"
else
    echo "$PROXY_GROUPS"
fi
echo ""

# --------------------------------------------------
# 4. 测试 HTTP 代理连通性
# --------------------------------------------------
echo "[4/5] 测试 HTTP 代理连通性..."
HTTP_RESULT=$(curl -sf -x http://${PROXY_HOST}:${HTTP_PORT} \
    --connect-timeout 10 \
    --max-time 20 \
    -o /dev/null -w "HTTP %{http_code} | 耗时 %{time_total}s" \
    https://www.google.com 2>&1 || echo "✗ 失败")

if echo "$HTTP_RESULT" | grep -q "HTTP 200"; then
    echo "  ✓ HTTP 代理正常"
    echo "    结果: ${HTTP_RESULT}"
else
    echo "  ✗ HTTP 代理测试失败"
    echo "    结果: ${HTTP_RESULT}"
fi
echo ""

# --------------------------------------------------
# 5. 测试 SOCK5 代理
# --------------------------------------------------
echo "[5/5] 测试 SOCKS5 代理连通性..."
SOCKS_RESULT=$(curl -sf -x socks5h://${PROXY_HOST}:${SOCKS_PORT} \
    --connect-timeout 10 \
    --max-time 20 \
    -o /dev/null -w "HTTP %{http_code} | 耗时 %{time_total}s" \
    https://www.google.com 2>&1 || echo "✗ 失败")

if echo "$SOCKS_RESULT" | grep -q "HTTP 200"; then
    echo "  ✓ SOCKS5 代理正常"
    echo "    结果: ${SOCKS_RESULT}"
else
    echo "  ✗ SOCKS5 代理测试失败"
    echo "    结果: ${SOCKS_RESULT}"
fi
echo ""

echo "========================================"
echo "测试完成"
echo "========================================"
