#!/bin/bash

echo -e "\033[33m========================================================\033[0m"
echo -e "\033[33m     🗑️  VPN Gate 家宽落地项目 完全卸载程序             \033[0m"
echo -e "\033[33m========================================================\033[0m"

# 交互确认（支持从终端直接管道输入）
if [ -t 0 ] || [ -e /dev/tty ]; then
    read -r -p "⚠️  确定要彻底卸载并清理 VPN Gate 项目的所有组件与规则吗？[y/N]: " confirm < /dev/tty
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "\033[32m已取消卸载操作。\033[0m"
        exit 0
    fi
fi

echo -e "\n\033[32m[1/6] 停止并注销 systemd 后台守护服务...\033[0m"
systemctl stop vpngate 2>/dev/null || true
systemctl disable vpngate 2>/dev/null || true
rm -f /etc/systemd/system/vpngate.service
systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true

echo -e "\033[32m[2/6] 终止所有残留网络进程 (OpenVPN & Python)...\033[0m"
pkill -9 -f openvpn 2>/dev/null || true
pkill -9 -f vpngate_panel.py 2>/dev/null || true

echo -e "\033[32m[3/6] 清理 Docker 代理网关容器...\033[0m"
if command -v docker &> /dev/null; then
    docker rm -f vpngate-proxy vpngate-socks5 vpngate-ss 2>/dev/null || true
fi

echo -e "\033[32m[4/6] 撤销 tun0 虚拟网卡与专属策略路由...\033[0m"
ip link delete tun0 2>/dev/null || true
ip route flush table 100 2>/dev/null || true
while ip rule del table 100 2>/dev/null; do :; done

echo -e "\033[32m[5/6] 清除防火墙临时放行规则...\033[0m"
iptables -D INPUT -p tcp --dport 5000 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp --dport 10808 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp --dport 10809 -j ACCEPT 2>/dev/null || true

echo -e "\033[32m[6/6] 彻底删除项目文件与配置缓存...\033[0m"
rm -f /opt/vpngate_panel.py
rm -f /opt/up.sh
rm -f /opt/vpngate_cache.csv
rm -f /opt/vpngate_auto.json
rm -f /opt/vpngate_info.txt
rm -f /tmp/vpngate_current.ovpn
rm -f /tmp/vpngate_panel.log
rm -f /root/install.sh

echo -e "\n\033[32m========================================================\033[0m"
echo -e "\033[32m🎉 卸载完成！系统网络规则与文件已恢复干净！\033[0m"
echo -e "\033[32m========================================================\033[0m\n"
