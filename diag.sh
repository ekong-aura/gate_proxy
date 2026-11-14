#!/usr/bin/env bash
# ==============================================================================
#  gate_proxy 一键体检（v3 · 多隧道版）
#  用法: bash diag.sh
#  在“部署不了 / 跑不快”的那台机器上直接跑，把输出完整贴出来即可定位
# ==============================================================================
set -uo pipefail

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; B=$'\033[1m'; N=$'\033[0m'
PASS=0; WARN=0; FAIL=0
head1(){ echo -e "\n${C}━━━ $* ━━━${N}"; }
k(){ echo -e "         ${B}>${N} $*"; }
p_ok(){   PASS=$((PASS+1)); echo -e "  ${G}[PASS]${N} $*"; }
p_warn(){ WARN=$((WARN+1)); echo -e "  ${Y}[WARN]${N} $*"; }
p_fail(){ FAIL=$((FAIL+1)); echo -e "  ${R}[FAIL]${N} $*"; }

# 从 systemd 单元里读出实际配置
UNIT=/etc/systemd/system/vpngate.service
getenv_unit(){ sed -n "s/^Environment=$1=//p" "$UNIT" 2>/dev/null | head -1; }
TUNNELS=$(getenv_unit TUNNELS); TUNNELS=${TUNNELS:-3}
ROUTE_TABLE=$(getenv_unit ROUTE_TABLE); ROUTE_TABLE=${ROUTE_TABLE:-100}
PANEL_PORT=$(getenv_unit PANEL_PORT); PANEL_PORT=${PANEL_PORT:-5000}
INSTALL_DIR=$(getenv_unit INSTALL_DIR); INSTALL_DIR=${INSTALL_DIR:-/opt/gate_proxy}
MSSFIX=$(getenv_unit MSSFIX); MSSFIX=${MSSFIX:-1300}
GOST_REBIND=$(getenv_unit GOST_REBIND); GOST_REBIND=${GOST_REBIND:-0}
FAST_POLL=$(getenv_unit FAST_POLL); FAST_POLL=${FAST_POLL:-1.0}
HEALTH_POLL=$(getenv_unit HEALTH_POLL); HEALTH_POLL=${HEALTH_POLL:-3.0}
PING_RESTART=$(getenv_unit PING_RESTART); PING_RESTART=${PING_RESTART:-20}
IFACES=$(sed -n 's/.*interface=\([a-z0-9,]*\).*/\1/p' /etc/systemd/system/vpngate-gost.service 2>/dev/null | head -1)
IFACES=${IFACES:-tun0}

echo -e "${C}================================================================${N}"
echo -e "${C}   gate_proxy 环境体检   $(date '+%F %T %Z')${N}"
echo -e "${C}   配置: ${TUNNELS} 条隧道 / table ${ROUTE_TABLE}+ / mssfix ${MSSFIX}${N}"
echo -e "${C}   自愈: 设备轮询 ${FAST_POLL}s / 出网探测 ${HEALTH_POLL}s / OVPN ping-restart ${PING_RESTART}s${N}"
echo -e "${C}   gost 出口接口: ${IFACES}   GOST_REBIND=${GOST_REBIND}${N}"
echo -e "${C}================================================================${N}"

# ------------------------------------------------------------------ 1
head1 "1. 系统与虚拟化"
OS=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
VIRT=$(systemd-detect-virt 2>/dev/null || echo unknown)
k "OS: ${OS:-?}  Kernel: $(uname -r)  Arch: $(uname -m)"
k "虚拟化: $VIRT"
case "$VIRT" in
  kvm|vmware|microsoft|xen|amazon|oracle|none) p_ok "KVM/裸机，支持 tun + ip rule" ;;
  lxc|openvz|systemd-nspawn|docker|podman)
      p_fail "容器型虚拟化 ($VIRT)：无 tun / 无 ip rule，跑不起来 → 换 KVM 机型" ;;
  *) p_warn "虚拟化未识别: $VIRT" ;;
esac

# ------------------------------------------------------------------ 2
head1 "2. TUN 与策略路由能力"
if [ -c /dev/net/tun ]; then
  p_ok "/dev/net/tun 存在"
  if python3 - <<'PY' >/dev/null 2>&1
import fcntl, struct, os, sys
try:
    fd = os.open("/dev/net/tun", os.O_RDWR)
    fcntl.ioctl(fd, 0x400454CA, struct.pack("16sH", b"dgprobe0", 0x0001|0x1000))
    os.close(fd); sys.exit(0)
except Exception: sys.exit(1)
PY
  then p_ok "TUN 可打开（内核模块正常）"; else p_fail "TUN 打不开（模块禁用）"; fi
else p_fail "/dev/net/tun 不存在"; fi

if ip rule add priority 59996 table "$ROUTE_TABLE" 2>/dev/null; then
  ip rule del priority 59996 table "$ROUTE_TABLE" 2>/dev/null
  p_ok "ip rule 可写"
else p_fail "ip rule 不可写 → 隧道通了流量也不走隧道"; fi

# ------------------------------------------------------------------ 3
head1 "3. 内核提速参数"
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
QD=$(sysctl -n net.core.default_qdisc 2>/dev/null)
CT=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "?")
[ "$CC" = "bbr" ] && p_ok "拥塞控制: BBR (qdisc=${QD})" || p_warn "拥塞控制: ${CC:-?}（未开 BBR，跨境吞吐会打折）"
k "conntrack_max=${CT}   rp_filter=$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null)"
[ "$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null)" = "1" ] && p_warn "rp_filter=1 严格模式会丢隧道回包"
lsmod 2>/dev/null | grep -q "^tcp_bbr" && k "tcp_bbr 模块已加载"

# ------------------------------------------------------------------ 4
head1 "4. 资源"
MEM=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo 2>/dev/null)
DISK=$(df -Pm / | awk 'NR==2{print $4}')
k "CPU $(nproc) 核 / RAM ${MEM}MB / 磁盘剩 ${DISK}MB"
[ "${MEM:-0}" -ge 700 ] && p_ok "内存充足" || p_warn "内存 ${MEM}MB 偏小，${TUNNELS} 条 OpenVPN 可能 OOM"
if [ "$(nproc)" -lt "$TUNNELS" ]; then
  p_warn "只有 $(nproc) 核却跑 ${TUNNELS} 条隧道，OpenVPN 是单线程会互相抢核（建议 TUNNELS=$(nproc)）"
fi

# ------------------------------------------------------------------ 5
head1 "5. 组件"
OV=$(openvpn --version 2>/dev/null | head -1)
[ -n "$OV" ] && p_ok "$OV" || p_fail "openvpn 未安装"
command -v python3 >/dev/null 2>&1 && p_ok "python3 $(python3 -V 2>&1 | awk '{print $2}')" || p_fail "python3 缺失"
command -v curl >/dev/null 2>&1 && p_ok "curl 存在" || p_fail "curl 缺失（健康检查依赖）"
command -v ping >/dev/null 2>&1 && p_ok "ping 存在" || p_warn "ping 缺失：apt install iputils-ping"
if [ -x /usr/local/bin/gost ]; then p_ok "gost: $(/usr/local/bin/gost -V 2>&1 | head -1)"
elif command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q vpngate-proxy
then p_ok "gost: docker 容器模式"
else p_fail "gost 不存在（二进制与容器都没有）"; fi

# ------------------------------------------------------------------ 6
head1 "6. 服务"
for S in vpngate vpngate-gost; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^$S.service"; then
    ST=$(systemctl is-active "$S" 2>/dev/null)
    [ "$ST" = "active" ] && p_ok "$S: active" || p_fail "$S: $ST"
    systemctl status "$S" --no-pager -n 3 2>/dev/null | tail -4 | sed 's/^/         /'
  else k "$S.service 未安装"; fi
done
docker ps --filter name=vpngate --format '         {{.Names}}  {{.Status}}' 2>/dev/null

# ------------------------------------------------------------------ 7
head1 "7. 逐条隧道"
OK_N=0
for i in $(seq 0 $((TUNNELS-1))); do
  DEV="tun$i"; TB=$((ROUTE_TABLE+i))
  if ip link show "$DEV" >/dev/null 2>&1; then
    IP4=$(ip -4 addr show "$DEV" 2>/dev/null | awk '/inet /{print $2}')
    PEER=$(ip -4 addr show "$DEV" 2>/dev/null | sed -n 's/.*peer \([0-9.]*\).*/\1/p' | head -1)
    RT=$(ip route show table "$TB" 2>/dev/null | head -1)
    RULE=$(ip rule show 2>/dev/null | grep -c "lookup $TB")
    PRTT=""
    if [ -n "$PEER" ]; then
      PRTT=$(ping -I "$DEV" -c 3 -W 2 -q "$PEER" 2>/dev/null | sed -n 's/.*min\/avg\/max[^=]*= [0-9.]*\/\([0-9.]*\)\/.*/\1/p')
      PRTT=${PRTT:+"  真实RTT=${PRTT}ms"}
    fi
    OUT=$(curl --interface "$DEV" -m 6 -s https://ipinfo.io/json 2>/dev/null)
    if echo "$OUT" | grep -q '"ip"'; then
      OK_N=$((OK_N+1))
      p_ok "$DEV  UP  ${IP4:-?}${PRTT} → $(echo "$OUT" | tr -d '\n' | head -c 100)"
    else
      p_fail "$DEV  UP 但出不去（MTU/路由/被拒）  ip=${IP4:-?}  route=${RT:-无}  rules=${RULE}"
      k "试: curl --interface $DEV -m 8 -v http://connectivitycheck.gstatic.com/generate_204"
    fi
  else
    p_warn "$DEV 未建立"
  fi
done
k "健康隧道: ${OK_N}/${TUNNELS}"
[ "$OK_N" -gt 1 ] && p_ok "聚合生效（${OK_N} 条独立出口）" || true

# ------------------------------------------------------------------ 8
head1 "8. 节点库质量"
CACHE="$INSTALL_DIR/vpngate_cache.csv"
if [ -f "$CACHE" ]; then
  python3 - "$CACHE" <<'PY' 2>/dev/null || p_fail "节点库解析失败"
import csv, io, sys
raw = open(sys.argv[1], encoding="utf-8-sig", errors="ignore").read()
raw = raw.replace("\r\r\n","\n").replace("\r\n","\n").replace("\r","\n")
lines = [l for l in raw.split("\n") if l.strip() and not l.startswith("*")]
hi = next((i for i,l in enumerate(lines) if "OpenVPN_ConfigData_Base64" in l), None)
if hi is None:
    print("         \033[31m✘\033[0m 找不到表头（内容可能是 Cloudflare 挑战页）"); sys.exit(0)
h = [x.strip().lstrip("#").strip() for x in lines[hi].split(",")]
rows = [dict(zip(h,r)) for r in csv.reader(io.StringIO("\n".join(lines[hi+1:]))) if len(r) >= len(h)]
rows = [r for r in rows if r.get("IP") and r.get("OpenVPN_ConfigData_Base64")]
def n(r,k):
    v=(r.get(k) or "").strip(); return int(v) if v.isdigit() else 0
free = [r for r in rows if n(r,"NumVpnSessions") <= 20]
jp   = [r for r in free if (r.get("CountryShort") or "")=="JP"]
kr   = [r for r in free if (r.get("CountryShort") or "")=="KR"]
print("         \033[32m✔\033[0m 节点 %d 个 | 并发≤20 的冷门节点 %d 个 | 其中 JP %d / KR %d"
      % (len(rows), len(free), len(jp), len(kr)))
print("         并发中位数: %d 人（这就是带宽被分掉的程度）"
      % sorted(n(r,"NumVpnSessions") for r in rows)[len(rows)//2])
PY
else p_warn "无节点缓存 $CACHE"; fi

# ------------------------------------------------------------------ 9
head1 "9. 端口与面板"
SS2022_PORT=$(getenv_unit SS2022_PORT); SS2022_PORT=${SS2022_PORT:-10810}
SSU_PORT=$(getenv_unit SSU_PORT); SSU_PORT=${SSU_PORT:-10811}
STICKY=$(getenv_unit STICKY); STICKY=${STICKY:-1}
STICKY_BASE=$(getenv_unit STICKY_BASE); STICKY_BASE=${STICKY_BASE:-10818}

TCP_LIST="$PANEL_PORT 10808 10809 $SS2022_PORT"
[ "$STICKY" = "1" ] && for i in $(seq 0 $((TUNNELS-1))); do TCP_LIST="$TCP_LIST $((STICKY_BASE+i))"; done
for P in $TCP_LIST; do
  C=$(ss -lntp 2>/dev/null | grep -c ":$P ")
  [ "$C" -gt 0 ] && p_ok "TCP $P 已监听" || p_warn "TCP $P 未监听"
done
C=$(ss -lnup 2>/dev/null | grep -c ":$SSU_PORT ")
[ "$C" -gt 0 ] && p_ok "UDP $SSU_PORT 已监听（SS UDP 中继）" || p_warn "UDP $SSU_PORT 未监听"
[ -x "$INSTALL_DIR/vpngate_gost_run.sh" ] && p_ok "gost 启动脚本存在（$(grep -c '  -L ' "$INSTALL_DIR/vpngate_gost_run.sh") 个入站）" \
  || p_warn "缺 $INSTALL_DIR/vpngate_gost_run.sh（旧版安装？重装即可）"
for EP in tunnels autowatch diag endpoints settings; do
  R2=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PANEL_PORT}/api/$EP" 2>/dev/null)
  case "$R2" in
    200) p_ok "/api/$EP -> 200（未鉴权可访问，说明面板没设密码）" ;;
    401) p_ok "/api/$EP -> 401（需要登录，正常）" ;;
    *)   p_warn "/api/$EP -> $R2" ;;
  esac
done
[ -f "$INSTALL_DIR/vpngate_credentials.json" ] && p_ok "面板凭据文件存在（$INSTALL_DIR/vpngate_credentials.json）" \
  || p_warn "缺凭据文件，面板会退回用 systemd 环境变量里的密码"
[ -f "$INSTALL_DIR/vpngate_runtime.json" ] && k "已保存的面板参数: $(tr -d '\n' < "$INSTALL_DIR/vpngate_runtime.json" | head -c 200)"
command -v ufw >/dev/null 2>&1 && k "ufw: $(ufw status 2>/dev/null | head -1)"

# ------------------------------------------------------------------ 汇总
echo; echo -e "${C}================================================================${N}"
echo -e "  体检结果:  ${G}PASS ${PASS}${N}   ${Y}WARN ${WARN}${N}   ${R}FAIL ${FAIL}${N}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "  ${Y}按概率排序的原因：${N}"
  echo -e "   1) LXC/OpenVZ 容器机 → 无 tun/无 ip rule → 换 KVM"
  echo -e "   2) 云安全组没放行 ${PANEL_PORT}/10808/10809（本机 iptables ≠ 云防火墙）"
  echo -e "   3) tun 在但出不去 → MTU；调 MSSFIX=1240 或 FIX_MTU=1 重装"
  echo -e "   4) 机房封 UDP 出站 → PREFER_TCP=1 重装"
else
  echo -e "  ${G}未发现硬性阻断项。${N}"
fi
echo -e "${C}================================================================${N}"
