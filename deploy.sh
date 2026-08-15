#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# 出站流量监控（mitmproxy 透明代理）一键部署脚本
# 适用：全新安装的 Ubuntu 24.04 x86_64
# 用法：sudo bash deploy.sh
# =============================================================

if [ "$EUID" -ne 0 ]; then
    echo "请用 root 运行: sudo bash deploy.sh"; exit 1
fi

PROXY_PORT=8082
WEB_PORT=8083
SERVICE_USER=mitmproxyuser
ADDON_SRC="$(dirname "$(readlink -f "$0")")/autopatch.py"
UNIT_SRC="$(dirname "$(readlink -f "$0")")/mitmweb.service"
SYSCTL_SRC="$(dirname "$(readlink -f "$0")")/90-mitmproxy.conf"

# 自动探测局域网网段（用于网页界面防火墙白名单）
IFACE=$(ip route | awk '/^default/ {print $5; exit}')
LAN_CIDR=$(ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4; exit}')
LAN_CIDR="${LAN_CIDR:-192.168.1.0/24}"
echo "==> 检测到主网卡: $IFACE，局域网网段: $LAN_CIDR"

echo "==> 1/9 安装 mitmproxy 和 iptables-persistent"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y mitmproxy iptables-persistent

echo "==> 2/9 创建专用运行用户"
id -u "$SERVICE_USER" &>/dev/null || useradd --create-home --shell /bin/bash "$SERVICE_USER"

echo "==> 3/9 写入 sysctl 内核转发配置"
cp "$SYSCTL_SRC" /etc/sysctl.d/mitmproxy.conf
sysctl --system >/dev/null

echo "==> 4/9 部署 systemd 服务"
cp "$UNIT_SRC" /etc/systemd/system/mitmweb.service
mkdir -p /var/lib/mitmweb
chown "$SERVICE_USER:$SERVICE_USER" /var/lib/mitmweb
mkdir -p /etc/mitmweb
cp "$ADDON_SRC" /etc/mitmweb/autopatch.py
systemctl daemon-reload
systemctl enable mitmweb >/dev/null

echo "==> 5/9 启动服务并生成 CA 证书"
systemctl restart mitmweb
sleep 4
systemctl is-active mitmweb >/dev/null || { echo "mitmweb 启动失败"; exit 1; }

echo "==> 6/9 安装 mitmproxy CA 到系统信任库"
cp "/home/$SERVICE_USER/.mitmproxy/mitmproxy-ca-cert.pem" /usr/local/share/ca-certificates/mitmproxy-ca.crt
update-ca-certificates >/dev/null

echo "==> 7/9 添加透明劫持规则（OUTPUT 链，排除代理自身用户防循环）"
iptables -t nat -C OUTPUT -p tcp -m owner ! --uid-owner "$SERVICE_USER" --dport 80 -j REDIRECT --to-port "$PROXY_PORT" 2>/dev/null \
    || iptables -t nat -A OUTPUT -p tcp -m owner ! --uid-owner "$SERVICE_USER" --dport 80 -j REDIRECT --to-port "$PROXY_PORT"
iptables -t nat -C OUTPUT -p tcp -m owner ! --uid-owner "$SERVICE_USER" --dport 443 -j REDIRECT --to-port "$PROXY_PORT" 2>/dev/null \
    || iptables -t nat -A OUTPUT -p tcp -m owner ! --uid-owner "$SERVICE_USER" --dport 443 -j REDIRECT --to-port "$PROXY_PORT"
ip6tables -t nat -C OUTPUT -p tcp -m owner ! --uid-owner "$SERVICE_USER" --dport 80 -j REDIRECT --to-port "$PROXY_PORT" 2>/dev/null \
    || ip6tables -t nat -A OUTPUT -p tcp -m owner ! --uid-owner "$SERVICE_USER" --dport 80 -j REDIRECT --to-port "$PROXY_PORT"
ip6tables -t nat -C OUTPUT -p tcp -m owner ! --uid-owner "$SERVICE_USER" --dport 443 -j REDIRECT --to-port "$PROXY_PORT" 2>/dev/null \
    || ip6tables -t nat -A OUTPUT -p tcp -m owner ! --uid-owner "$SERVICE_USER" --dport 443 -j REDIRECT --to-port "$PROXY_PORT"

echo "==> 8/9 网页界面防火墙：仅允许本机 + 局域网访问 :$WEB_PORT"
iptables -C INPUT -p tcp --dport "$WEB_PORT" -s 127.0.0.1 -j ACCEPT 2>/dev/null \
    || iptables -I INPUT 1 -p tcp --dport "$WEB_PORT" -s 127.0.0.1 -j ACCEPT
iptables -C INPUT -p tcp --dport "$WEB_PORT" -s "$LAN_CIDR" -j ACCEPT 2>/dev/null \
    || iptables -A INPUT -p tcp --dport "$WEB_PORT" -s "$LAN_CIDR" -j ACCEPT
iptables -C INPUT -p tcp --dport "$WEB_PORT" -j DROP 2>/dev/null \
    || iptables -A INPUT -p tcp --dport "$WEB_PORT" -j DROP

echo "==> 9/9 持久化 iptables 规则"
netfilter-persistent save >/dev/null 2>&1

echo ""
echo "=============================================="
echo "部署完成！"
echo "  代理端口(内部): $PROXY_PORT (127.0.0.1)"
echo "  网页界面     : http://$LAN_CIDR 所在网段的本机IP:$WEB_PORT"
echo "  流量落盘     : /var/lib/mitmweb/flows.json"
echo "  修改规则     : /etc/mitmweb/autopatch.py 改后 systemctl restart mitmweb"
echo "  服务状态     : systemctl status mitmweb"
echo "=============================================="
