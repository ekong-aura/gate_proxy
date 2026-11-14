#!/usr/bin/env bash
# ==============================================================================
#  VPN Gate 多隧道版 完全卸载程序 (v3)
# ==============================================================================
set -uo pipefail

G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
echo -e "${Y}========================================================${N}"
echo -e "${Y}     🗑️  VPN Gate 多隧道版 完全卸载程序                   ${N}"
echo -e "${Y}========================================================${N}"

if [ "$(id -u)" != "0" ]; then
  echo "请用 root 运行： sudo bash uninstall.sh"; exit 1
fi

if [ -c /dev/tty ] && [ -t 0 ] 2>/dev/null; then
  read -r -p "⚠️  确定彻底卸载并清理所有组件与路由规则？[y/N]: " confirm < /dev/tty 2>/dev/null || confirm="n"
  if [[ ! "${confirm:-n}" =~ ^[yY]$ ]]; then
    echo -e "${G}已取消。${N}"; exit 0
  fi
else
  echo -e "${Y}非交互环境，直接执行卸载。${N}"
fi

echo -e "\n${G}[1/7]${N} 停止并注销 systemd 服务..."
for S in vpngate vpngate-gost; do
  systemctl stop "$S" 2>/dev/null || true
  systemctl disable "$S" 2>/dev/null || true
  rm -f "/etc/systemd/system/$S.service"
done
systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true
echo -e "     ${G}✔${N} 已清理"

echo -e "\n${G}[2/7]${N} 终止残留进程..."
pkill -9 -f "vpngate_panel.py" 2>/dev/null || true
pkill -9 -f "/usr/local/bin/gost" 2>/dev/null || true
for i in 0 1 2 3 4 5; do pkill -9 -f "/tmp/vpngate_${i}.ovpn" 2>/dev/null || true; done
pkill -9 -f "vpngate_current.ovpn" 2>/dev/null || true
pkill -9 -f "openvpn" 2>/dev/null || true
sleep 1
echo -e "     ${G}✔${N} 已终止"

echo -e "\n${G}[3/7]${N} 清理 Docker 容器..."
if command -v docker >/dev/null 2>&1; then
  docker rm -f vpngate-proxy vpngate-socks5 vpngate-ss 2>/dev/null || true
  if [ "${PURGE:-0}" = "1" ]; then
    docker image inspect gogost/gost >/dev/null 2>&1 && \
      docker rmi -f gogost/gost >/dev/null 2>&1 && echo -e "     ${G}✔${N} 已删除镜像 gogost/gost"
  else
    echo -e "     ${G}✔${N} 容器已删除（镜像 gogost/gost 保留，加 PURGE=1 可一并删除）"
  fi
else
  echo -e "     ${Y}▲${N} 无 docker，跳过"
fi

echo -e "\n${G}[4/7]${N} 撤销所有 tun 设备与策略路由..."
for i in 0 1 2 3 4 5; do
  ip link set "tun$i" down 2>/dev/null || true
  ip link delete "tun$i" 2>/dev/null || true
done
for T in $(seq 100 120); do
  ip route flush table "$T" 2>/dev/null || true
  while ip rule del table "$T" 2>/dev/null; do :; done
done
echo -e "     ${G}✔${N} 已撤销"

echo -e "\n${G}[5/7]${N} 清理防火墙规则..."
for P in 5000 10808 10809; do
  while iptables -D INPUT -p tcp --dport "$P" -j ACCEPT 2>/dev/null; do :; done
done
command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
echo -e "     ${G}✔${N} 已清理"

echo -e "\n${G}[6/7]${N} 删除项目文件..."

# 安装目录（新版全部集中在这里）
INSTALL_DIR=$(systemctl show vpngate -p Environment --value 2>/dev/null | tr ' ' '\n' | sed -n 's/^INSTALL_DIR=//p' | head -1)
INSTALL_DIR=${INSTALL_DIR:-/opt/gate_proxy}
if [ -d "$INSTALL_DIR" ]; then
  if [ "${KEEP_DATA:-0}" = "1" ]; then
    echo -e "     ${Y}▲${N} 保留数据目录 $INSTALL_DIR（KEEP_DATA=1）"
  else
    rm -rf "$INSTALL_DIR" && echo -e "     ${G}✔${N} 已删除 $INSTALL_DIR"
  fi
fi

# 旧版散落在 /opt 下的文件（v1~v3.10）
rm -f /opt/vpngate_panel.py /opt/up.sh /opt/vpngate_cache.csv /opt/vpngate_auto.json \
      /opt/vpngate_auto.json.tmp /opt/vpngate_runtime.json /opt/vpngate_credentials.json \
      /opt/vpngate_status.json /opt/vpngate_pool.json /opt/vpngate_gost_run.sh \
      /opt/vpngate_info.txt /opt/vpngate_auth.txt /opt/vpngate_gost_mode \
      /usr/local/bin/gost /usr/local/bin/vg \
      /tmp/vpngate_*.ovpn /tmp/vpngate_panel.log /run/vpngate_*.pid \
      /tmp/vpngate_current.ovpn /tmp/gost.tgz /tmp/gost_rel.json /root/install.sh \
      /tmp/_vpngate_step.log /tmp/gost_selftest.log /tmp/vb.raw /tmp/vb.csv
rm -rf /tmp/gost_x

# v1 时代用 apt 装的 Flask / requests，新版面板是纯标准库，这两个已经不需要了
if [ "${PURGE:-0}" = "1" ]; then
  echo -e "     ${Y}▲${N} 检查 v1 遗留的 python3-flask / python3-requests ..."
  REMOVED=""
  for p in python3-flask python3-requests; do
    if dpkg -s "$p" >/dev/null 2>&1; then
      apt-get remove -y --purge "$p" >/dev/null 2>&1 && REMOVED="$REMOVED $p"
    fi
  done
  if [ -n "$REMOVED" ]; then
    echo -e "     ${G}✔${N} 已卸载:${REMOVED}"
  else
    echo -e "     ${G}✔${N} 没有需要卸载的 python 包"
  fi
fi

if [ "${KEEP_LOG:-0}" != "1" ]; then rm -f /var/log/openvpn_vpngate.log
else echo -e "     ${Y}▲${N} 保留日志 /var/log/openvpn_vpngate.log"; fi
if [ "${KEEP_SYSCTL:-0}" != "1" ]; then
  rm -f /etc/sysctl.d/99-vpngate.conf
  echo -e "     ${G}✔${N} 已删除 /etc/sysctl.d/99-vpngate.conf（BBR 等参数下次重启还原）"
else
  echo -e "     ${Y}▲${N} 保留 /etc/sysctl.d/99-vpngate.conf"
fi
echo -e "     ${G}✔${N} 文件已删除"

echo -e "\n${G}[7/7]${N} 恢复内核网络参数..."
sysctl -qw net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
sysctl -qw net.ipv4.conf.default.rp_filter=0 2>/dev/null || true
echo -e "     ${G}✔${N} 已恢复"

echo -e "\n${G}========================================================${N}"
echo -e "${G}🎉 卸载完成。${N}"
echo -e "   彻底清依赖： apt-get remove --purge openvpn docker.io"
echo -e "${G}========================================================${N}\n"
