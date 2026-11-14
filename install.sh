#!/usr/bin/env bash
# ==============================================================================
#  VPN Gate 家宽落地代理 + 多隧道聚合自愈看门狗  (v3)
#
#  核心变化（相对 v2）：
#   1) 多隧道聚合：N 条独立 tun（默认 3），gost 用 interface=tun0,tun1,tun2
#      → 按连接轮询分流 + 失败自动降级到下一隧道，等效带宽叠加
#   2) 逐隧道独立自愈：某条断了只重连那一条，其余继续服务，业务不中断
#   3) 节点评分重写：NumVpnSessions / Uptime / Speed / Ping 四维加权，
#      优先抢「并发人数少 + 在线久 + 测速高」的冷门节点（对流媒体最关键）
#   4) 区域绑定：默认 JP → KR，不再掉到美国；默认不跨洲
#   5) 内核层：BBR + fq + conntrack 调优，MSS 可调
#
#  适配: Ubuntu 18.04/20.04/22.04/24.04, Debian 10/11/12, x86_64 / aarch64
#  依赖: 零 Flask / 零 Docker 硬依赖
# ==============================================================================
set -uo pipefail

# ---------------------------- 可覆盖配置 --------------------------------------
PANEL_PORT="${PANEL_PORT:-5000}"
SOCKS5_PORT="${SOCKS5_PORT:-10808}"     # 聚合入口（SOCKS5 + HTTP 同一端口，自动识别）
SS_PORT="${SS_PORT:-10809}"             # Shadowsocks (aes-256-gcm)
SS2022_PORT="${SS2022_PORT:-10810}"     # Shadowsocks 2022 (blake3 aes-256-gcm)
SSU_PORT="${SSU_PORT:-10811}"           # Shadowsocks UDP 中继（UDP 端口）
STICKY_BASE="${STICKY_BASE:-10818}"     # 粘性端口起始号，第 i 条隧道占 STICKY_BASE+i
STICKY="${STICKY:-1}"                   # 1=为每条隧道单独开一个固定出口端口（出口 IP 不跳动）
INSTALL_DIR="${INSTALL_DIR:-/opt/gate_proxy}"   # 所有项目文件都放这里，/opt 下不再散落一堆
ROUTE_TABLE="${ROUTE_TABLE:-100}"        # 起始路由表号，第 i 条隧道用 100+i
TUNNELS="${TUNNELS:-3}"                 # 隧道条数（1~6），3 条是带宽/CPU 的甜点
PANEL_USER="${PANEL_USER:-admin}"
CANDIDATES="${CANDIDATES:-5}"           # 每条隧道最多试几个候选节点
SESSION_CAP="${SESSION_CAP:-60}"        # 并发会话数超过此值直接排除
FIX_MTU="${FIX_MTU:-1}"                 # 1=自动加 mssfix
MSSFIX="${MSSFIX:-1300}"                # 跨境高丢包可降到 1240 / 1200
FORCE_DOCKER="${FORCE_DOCKER:-0}"
PREFER_TCP="${PREFER_TCP:-0}"
ENABLE_BBR="${ENABLE_BBR:-1}"
GOST_REBIND="${GOST_REBIND:-0}"      # 1=隧道换节点后重启 gost（通常不需要，重启会掐断其它隧道的连接）
PING_RESTART="${PING_RESTART:-20}"   # OpenVPN 多久没收到对端回应就自我退出（秒）
DEFAULT_P1="${DEFAULT_P1:-AUTO}"        # AUTO = 不限国家，按评分（含地理优先）自己挑
DEFAULT_P2="${DEFAULT_P2:-NONE}"
DEFAULT_P3="${DEFAULT_P3:-NONE}"        # 默认不跨洲：跨到美国 RTT 会到 180ms+
# -----------------------------------------------------------------------------

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; W=$'\033[1;37m'; N=$'\033[0m'
ok(){   echo -e "  ${G}✔${N} $*"; }
warn(){ echo -e "  ${Y}▲${N} $*"; }
err(){  echo -e "  ${R}✘${N} $*"; }

# ---------------------------- 安装进度条 ----------------------------
STEP_TOTAL=9
T0=$SECONDS
BAR_W=30

bar_str(){                      # $1=百分比 -> 填充好的进度条
  local pct="$1" fill i out=""
  fill=$(( pct * BAR_W / 100 ))
  for ((i = 0; i < BAR_W; i++)); do
    if [ "$i" -lt "$fill" ]; then out="${out}█"; else out="${out}░"; fi
  done
  printf '%s' "$out"
}

step(){                          # $1="3/9"  $2=标题
  local idx="${1%%/*}"
  local pct=$(( idx * 100 / STEP_TOTAL ))
  [ "$pct" -gt 100 ] && pct=100
  echo
  printf '%s[%s]%s %3d%%  %s%s%s   %s(%ds)%s\n' \
    "$C" "$(bar_str "$pct")" "$N" "$pct" "$W" "$2" "$N" "$C" "$(( SECONDS - T0 ))" "$N"
}

# 跑长命令时显示转圈 + 秒数，避免看起来像卡死
spin_run(){                      # $1=说明  $2..=命令
  local label="$1"; shift
  local log=/tmp/_vpngate_step.log
  if [ ! -t 1 ]; then            # 非终端（网页控制台 / 日志重定向）不刷屏，只打一行
    echo -e "  ${C}…${N} ${label}（进行中，请稍候）"
    "$@" >"$log" 2>&1
    local rc=$?
    if [ "$rc" -ne 0 ]; then
      echo -e "  ${Y}▲${N} ${label} 返回 $rc，日志末尾："
      tail -n 3 "$log" 2>/dev/null | sed 's/^/      /'
    else
      echo -e "  ${G}✔${N} ${label}"
    fi
    return "$rc"
  fi
  "$@" >"$log" 2>&1 &
  local pid=$!
  local sp='|/-\' i=0 t0=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % 4 ))
    printf '\r  %s %s  %ds\033[K' "${sp:$i:1}" "$label" "$(( SECONDS - t0 ))"
    sleep 0.25
  done
  wait "$pid" 2>/dev/null
  local rc=$?
  printf '\r\033[K'
  if [ "$rc" -ne 0 ]; then
    echo -e "  ${Y}▲${N} ${label} 返回 $rc，日志末尾："
    tail -n 3 "$log" 2>/dev/null | sed 's/^/      /'
  else
    echo -e "  ${G}✔${N} ${label}  $(( SECONDS - t0 ))s"
  fi
  return "$rc"
}

genpass(){
  local n="$1" ph=""
  ph=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "$n" 2>/dev/null || true)
  if [ "${#ph}" -ne "$n" ]; then
    ph=$(head -c 256 /dev/urandom 2>/dev/null | base64 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c "$n")
  fi
  printf '%s' "$ph"
}
SOCKS5_PASS=$(genpass 14)
SS_PASS=$(genpass 18)
PANEL_PASS=$(genpass 16)
# SS2022 的密码必须是一段 base64 编码的 32 字节密钥（aes-256-gcm 用 32 字节）。
# 避开 + 和 / 两个字符，否则塞进 ss:// 链接时部分客户端解析会出错。
SS2022_PASS=""
for _try in 1 2 3 4 5 6 7 8 9 10; do
  SS2022_PASS=$(head -c 32 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -d '\n')
  case "$SS2022_PASS" in
    ""|*+*|*/*) continue ;;
  esac
  [ "${#SS2022_PASS}" -eq 44 ] && break
done
[ "${#SS2022_PASS}" -eq 44 ] || SS2022_PASS="ERERERERERERERERERERERERERERERERERERERERERA="

ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l)        ARCH=armv7 ;;
  *)             ARCH=amd64 ;;
esac

echo -e "${C}========================================================${N}"
echo -e "${C}    🚀 VPN Gate 多隧道聚合面板  (v3)                    ${N}"
echo -e "${C}    arch=${ARCH_RAW}  tunnels=${TUNNELS}  table=${ROUTE_TABLE}..$((ROUTE_TABLE+TUNNELS-1))${N}"
echo -e "${C}========================================================${N}"

if [ "$(id -u)" != "0" ]; then
  err "请用 root 运行： sudo bash install.sh"
  exit 1
fi

mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/run"
chmod 0755 "$INSTALL_DIR" "$INSTALL_DIR/run"

# ==============================================================================
step "0/9" "环境预检与旧版本清理"
# ==============================================================================
CLEAN="${CLEAN:-0}"          # CLEAN=1 时做深度清理（删 docker 镜像、压缩日志、清下载缓存）

# ---------------------------- 旧版本残留清理 ----------------------------
# 这一步对 v1（Flask + docker）、以及本项目的各个历史版本都做了兼容清理。
# 不做也没关系（安装是幂等的），但会留下 docker 镜像 / 旧容器 / 旧 systemd 单元。
CLEANED=0
c_ok(){ CLEANED=$((CLEANED+1)); ok "$1"; }

# 1) 旧 systemd 单元（v1 的 vpngate.service 与新版同名，会被覆盖；其余是历史命名）
for U in vpngate vpngate-gost vpngate-panel vpngate-watchdog; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${U}\.service"; then
    systemctl stop "$U" >/dev/null 2>&1 || true
    systemctl disable "$U" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${U}.service" "/lib/systemd/system/${U}.service"
    c_ok "移除旧服务 ${U}.service"
  fi
done
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed >/dev/null 2>&1 || true

# 2) 旧进程：只按本项目特征匹配，不会碰你机器上别的 openvpn
if pkill -9 -f "vpngate_panel\.py" 2>/dev/null; then c_ok "结束旧面板进程"; fi
if pkill -9 -f "vpngate_current\.ovpn" 2>/dev/null; then c_ok "结束 v1 遗留的 OpenVPN"; fi
if pkill -9 -f "/usr/local/bin/gost" 2>/dev/null; then c_ok "结束旧 gost 进程"; fi
for _i in 0 1 2 3 4 5; do pkill -9 -f "/tmp/vpngate_${_i}\.ovpn" 2>/dev/null || true; done

# 3) v1 用 docker 跑 gost，容器会一直占着 10808/10809
if command -v docker >/dev/null 2>&1; then
  for C in vpngate-proxy vpngate-socks5 vpngate-ss; do
    if docker inspect "$C" >/dev/null 2>&1; then
      docker rm -f "$C" >/dev/null 2>&1 && c_ok "移除旧容器 ${C}"
    fi
  done
fi

# 4) v1 的单隧道配置文件和日志
[ -f /tmp/vpngate_current.ovpn ] && rm -f /tmp/vpngate_current.ovpn && c_ok "删除 v1 遗留配置 /tmp/vpngate_current.ovpn"
[ -f /tmp/vpngate_panel.log ] && rm -f /tmp/vpngate_panel.log && c_ok "删除 v1 遗留日志 /tmp/vpngate_panel.log"

# 5) 干净模式：额外清镜像、下载缓存、压缩日志、旧 tun/路由
if [ "$CLEAN" = "1" ]; then
  if command -v docker >/dev/null 2>&1; then
    if docker image inspect gogost/gost >/dev/null 2>&1; then
      docker rmi -f gogost/gost >/dev/null 2>&1 && c_ok "删除 docker 镜像 gogost/gost"
    fi
  fi
  rm -rf /tmp/gost_x /tmp/gost.tgz /tmp/gost_rel.json /tmp/_vpngate_step.log \
         /tmp/gost_selftest.log /tmp/vb.raw /tmp/vb.csv /tmp/_vpngate_step.log
  c_ok "清理下载缓存与临时文件"
  if [ -f "$INSTALL_DIR/openvpn.log" ]; then
    tail -n 2000 "$INSTALL_DIR/openvpn.log" > /tmp/_ovpnlog.$$ 2>/dev/null \
      && mv /tmp/_ovpnlog.$$ "$INSTALL_DIR/openvpn.log" \
      && c_ok "OpenVPN 日志压缩到最近 2000 行"
  fi
  for _i in 0 1 2 3 4 5; do ip link delete "tun${_i}" 2>/dev/null || true; done
  for _tb in $(seq 100 $((ROUTE_TABLE + TUNNELS + 5))); do
    ip route flush table "$_tb" 2>/dev/null || true
    while ip rule del table "$_tb" 2>/dev/null; do :; done
  done
  c_ok "清理旧 tun 设备与策略路由"
fi

[ "$CLEANED" -eq 0 ] || true
if [ -d /opt ] && ls /opt/vpngate_* >/dev/null 2>&1; then
  MIG=0
  for f in vpngate_cache.csv vpngate_pool.json vpngate_runtime.json \
           vpngate_auto.json vpngate_credentials.json; do
    if [ -f "/opt/$f" ] && [ ! -f "$INSTALL_DIR/$f" ]; then
      mv "/opt/$f" "$INSTALL_DIR/$f" 2>/dev/null && MIG=$((MIG+1))
    fi
  done
  # 其余旧文件（脚本/信息/日志）会被重新生成，直接删掉
  for f in vpngate_panel.py vpngate_auto.json.tmp vpngate_info.txt vpngate_auth.txt \
           vpngate_gost_mode vpngate_status.json vpngate_gost_run.sh up.sh; do
    rm -f "/opt/$f" 2>/dev/null || true
  done
  [ "$MIG" -gt 0 ] && ok "已把 /opt 下的 ${MIG} 个数据文件迁移到 ${INSTALL_DIR}（节点池/缓存不丢）"
fi

if [ "$CLEANED" -eq 0 ]; then
  ok "没有发现旧版本残留（全新安装）"
else
  ok "共清理 ${CLEANED} 项旧残留"
fi

# ---------------------------- 环境预检 ----------------------------
FAIL=0
note_fail(){ err "$1"; FAIL=$((FAIL+1)); }

VIRT=$(systemd-detect-virt 2>/dev/null || echo unknown)
ok "虚拟化: ${VIRT}"
case "$VIRT" in
  lxc|openvz|systemd-nspawn)
     note_fail "容器型虚拟化（$VIRT）无法创建 tun / 无法操作 ip rule → 请换 KVM 机型" ;;
esac

if [ ! -c /dev/net/tun ]; then
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200 2>/dev/null || true
  chmod 666 /dev/net/tun 2>/dev/null || true
fi
if [ -c /dev/net/tun ]; then
  if command -v python3 >/dev/null 2>&1; then
    if python3 - <<'PY' >/dev/null 2>&1
import fcntl, struct, os, sys
try:
    fd = os.open("/dev/net/tun", os.O_RDWR)
    fcntl.ioctl(fd, 0x400454CA, struct.pack("16sH", b"probe0", 0x0001 | 0x1000))
    os.close(fd); sys.exit(0)
except Exception:
    sys.exit(1)
PY
    then ok "TUN 设备可用"
    else note_fail "TUN 存在但打不开（内核模块禁用）"; fi
  else ok "/dev/net/tun 存在"; fi
else note_fail "无 /dev/net/tun"; fi

if ip rule add priority 59997 table "$ROUTE_TABLE" 2>/dev/null; then
  ip rule del priority 59997 table "$ROUTE_TABLE" 2>/dev/null || true
  ok "策略路由 (ip rule) 可用"
else
  note_fail "ip rule 不可用（需要 CAP_NET_ADMIN）→ 隧道能连上但流量不走隧道"
fi

MEM_MB=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo 2>/dev/null || echo 0)
DISK_MB=$(df -Pm / | awk 'NR==2{print $4}' 2>/dev/null || echo 0)
CPU_N=$(nproc 2>/dev/null || echo 1)
ok "CPU ${CPU_N} 核 / 内存 ${MEM_MB}MB / 磁盘剩 ${DISK_MB}MB"

# 自适应隧道数：小机器上 3 条 OpenVPN 会抢满单核
if [ "$TUNNELS" -gt 1 ]; then
  if [ "${CPU_N:-1}" -le 1 ] && [ "$TUNNELS" -gt 2 ]; then
    warn "只有 1 个 vCPU，隧道数 3 → 2（OpenVPN 是单线程，3 条会互相抢核）"
    TUNNELS=2
  fi
  if [ "${MEM_MB:-0}" -lt 400 ] && [ "$TUNNELS" -gt 1 ]; then
    warn "内存 ${MEM_MB}MB 偏小，隧道数 → 1"
    TUNNELS=1
  fi
fi
ok "最终隧道数: ${TUNNELS}"

if curl -fsS -m 10 -o /dev/null https://www.vpngate.net/ 2>/dev/null; then
  ok "可访问 vpngate.net"
else
  warn "直连 vpngate.net 失败，稍后用多源兜底拉缓存"
fi

if python3 - <<'PY' >/dev/null 2>&1
import socket,sys
try:
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(2)
    s.sendto(b"\x00"*8,("8.8.8.8",53)); s.close(); sys.exit(0)
except Exception: sys.exit(1)
PY
then ok "UDP 出站正常"; else warn "UDP 出站可能被拦截 → 建议 PREFER_TCP=1"; fi

if [ "$FAIL" -gt 0 ]; then
  echo; err "预检未通过 ${FAIL} 项，继续安装不会工作。"; exit 1
fi

# ==============================================================================
step "1/9" "安装依赖"
# ==============================================================================
export DEBIAN_FRONTEND=noninteractive
pkill -9 -f "apt-get install" 2>/dev/null || true
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* 2>/dev/null || true
dpkg --configure -a >/dev/null 2>&1 || true

APT_OPTS="-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
spin_run "更新软件源清单 (apt-get update)" apt-get update $APT_OPTS \
  || spin_run "更新软件源清单 (重试)" apt-get update || true
spin_run "安装基础工具 (curl/iptables/iproute2...)" \
  apt-get install $APT_OPTS ca-certificates curl iproute2 iptables procps iputils-ping >/dev/null 2>&1 || true
command -v add-apt-repository >/dev/null 2>&1 && add-apt-repository -y universe >/dev/null 2>&1 || true
apt-get update $APT_OPTS >/dev/null 2>&1 || true

if ! command -v openvpn >/dev/null 2>&1; then
  spin_run "安装 openvpn（核心依赖，可能要 1~2 分钟）" \
    apt-get install $APT_OPTS openvpn || spin_run "安装 openvpn（重试）" apt-get install -y openvpn || true
fi
command -v openvpn >/dev/null 2>&1 || { err "openvpn 安装失败： apt-get update && apt-get install -y openvpn"; exit 1; }
command -v python3 >/dev/null 2>&1 || { spin_run "安装 python3" apt-get install $APT_OPTS python3 || true; }
command -v python3 >/dev/null 2>&1 || { err "python3 缺失"; exit 1; }

OVPN_VER=$(openvpn --version 2>/dev/null | head -1 | awk '{print $2}')
ok "openvpn ${OVPN_VER:-?} / python3 $(python3 -V 2>&1 | awk '{print $2}')"
python3 -c "from http.server import ThreadingHTTPServer" 2>/dev/null || { err "python3 <3.7，面板无法运行"; exit 1; }
ok "面板运行环境 OK（纯标准库，零第三方依赖）"

[ -c /dev/net/tun ] || { mkdir -p /dev/net; mknod /dev/net/tun c 10 200 2>/dev/null; chmod 666 /dev/net/tun 2>/dev/null; }
printf 'vpn\nvpn\n' > "$INSTALL_DIR/vpngate_auth.txt"
chmod 600 "$INSTALL_DIR/vpngate_auth.txt"

# ==============================================================================
step "2/9" "内核网络调优（BBR / fq / conntrack）"
# ==============================================================================
if [ "$ENABLE_BBR" = "1" ]; then
  modprobe tcp_bbr 2>/dev/null || true
  cat > /etc/sysctl.d/99-vpngate.conf <<'EOF_SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.netfilter.nf_conntrack_max = 262144
net.ipv4.ip_local_port_range = 10000 65000
EOF_SYSCTL
  sysctl -q --system >/dev/null 2>&1 || true
  CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  QD=$(sysctl -n net.core.default_qdisc 2>/dev/null)
  if [ "$CC" = "bbr" ]; then ok "BBR 已启用 (qdisc=${QD})"
  else warn "BBR 未生效（当前 ${CC:-?}），内核可能不支持，不影响功能"; fi

  # 给已存在的 tun 设备也关掉 fq 以外的奇怪 qdisc；新设备由 up.sh 处理
  CONF_CT=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "?")
  ok "conntrack_max=${CONF_CT}"
else
  warn "ENABLE_BBR=0，跳过内核调优"
fi

# ==============================================================================
step "3/9" "部署 gost 网关（优先静态二进制）"
# ==============================================================================
GOST_MODE=""
IFACE_LIST="tun0"
for i in $(seq 1 $((TUNNELS-1))); do IFACE_LIST="${IFACE_LIST},tun${i}"; done
ok "gost 出口接口列表: ${IFACE_LIST}  (轮询分流 + 故障自动降级)"

# ---- 组装全部入站监听（每个入口都共用同一组 tun，所以都自动获得多隧道无感切换）----
# auto 处理器 = SOCKS5 + HTTP 在同一端口自动识别（已实测 gost 3.3.3 支持）
GOST_LS=()
GOST_LS+=("auto://${PANEL_USER}:${SOCKS5_PASS}@0.0.0.0:${SOCKS5_PORT}?interface=${IFACE_LIST}")
GOST_LS+=("ss://aes-256-gcm:${SS_PASS}@0.0.0.0:${SS_PORT}?interface=${IFACE_LIST}")
GOST_LS+=("ss://2022-blake3-aes-256-gcm:${SS2022_PASS}@0.0.0.0:${SS2022_PORT}?interface=${IFACE_LIST}")
GOST_LS+=("ssu://2022-blake3-aes-256-gcm:${SS2022_PASS}@0.0.0.0:${SSU_PORT}?interface=${IFACE_LIST}")
# 粘性端口：每条隧道一个固定监听口，出口 IP 不跳动（不做"哪个节点快就换哪个"）
if [ "$STICKY" = "1" ]; then
  for i in $(seq 0 $((TUNNELS-1))); do
    GOST_LS+=("auto://${PANEL_USER}:${SOCKS5_PASS}@0.0.0.0:$((STICKY_BASE+i))?interface=tun${i}")
  done
fi

# 注意：gost v3 的合法参数只有 -C/-D/-DD/-F/-L/-O/-R/-V/-api/-metrics，
# 没有 --log-level / --log-output 之类的选项。写错一个不存在的参数，
# gost 会 "flag provided but not defined" 直接 exit 2，整套代理端口全都不会监听。
build_gost_runner(){
  local a
  {
    echo '#!/bin/bash'
    echo '# 由 install.sh 生成，重新安装会覆盖'
    printf 'exec /usr/local/bin/gost'
    for a in "${GOST_LS[@]}"; do
      printf ' \\\n  -L %q' "$a"
    done
    printf '\n'
  } > "$INSTALL_DIR/vpngate_gost_run.sh"
  chmod 0755 "$INSTALL_DIR/vpngate_gost_run.sh"
}

# 起服务前先自己跑一遍参数，参数错了立刻报出来，而不是留一个静默崩溃的单元
gost_selftest(){
  [ -x /usr/local/bin/gost ] || { err "gost 二进制不存在"; return 1; }
  bash -n "$INSTALL_DIR/vpngate_gost_run.sh" || { err "gost 启动脚本语法错误"; return 1; }
  local rc logf=/tmp/gost_selftest.log
  timeout 3 "$INSTALL_DIR/vpngate_gost_run.sh" >"$logf" 2>&1
  rc=$?
  # timeout 杀掉说明它一直在跑（正常）；0 说明自己退了（异常）
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 0 ]; then
    if grep -q "flag provided but not defined\|unknown flag\|invalid argument" "$logf" 2>/dev/null; then
      err "gost 参数不被接受："; tail -n 4 "$logf" | sed 's/^/      /'; return 1
    fi
    return 0
  fi
  err "gost 启动自检失败（exit=$rc）："
  tail -n 6 "$logf" 2>/dev/null | sed 's/^/      /'
  return 1
}

pkill -9 -f "/usr/local/bin/gost" 2>/dev/null || true

fetch_gost_bin(){
  local tmp=/tmp/gost_rel.json url="" cand
  if curl -fsSL -m 20 "https://api.github.com/repos/go-gost/gost/releases/latest" -o "$tmp" 2>/dev/null; then
    url=$(python3 - "$tmp" "$ARCH" <<'PY' 2>/dev/null
import json,sys
try:
    d=json.load(open(sys.argv[1])); arch=sys.argv[2]
    for a in d.get("assets",[]):
        n=a.get("name","")
        if n.endswith(".tar.gz") and "linux" in n and arch in n and "gost" in n:
            print(a["browser_download_url"]); break
except Exception: pass
PY
)
  fi
  [ -n "$url" ] || url="https://github.com/go-gost/gost/releases/download/v3.3.3/gost_3.3.3_linux_${ARCH}.tar.gz"
  for cand in "$url" "${GOST_MIRROR:+${GOST_MIRROR}${url}}"; do
    [ -n "$cand" ] || continue
    curl -fL --retry 3 -m 150 "$cand" -o /tmp/gost.tgz 2>/dev/null || continue
    rm -rf /tmp/gost_x && mkdir -p /tmp/gost_x
    tar -xzf /tmp/gost.tgz -C /tmp/gost_x 2>/dev/null || continue
    local bin
    bin=$(find /tmp/gost_x -type f -name 'gost*' -perm -u+x | head -1)
    [ -n "$bin" ] || bin=$(find /tmp/gost_x -type f -name 'gost*' | head -1)
    [ -n "$bin" ] || continue
    install -m 0755 "$bin" /usr/local/bin/gost || continue
    /usr/local/bin/gost -V >/dev/null 2>&1 || continue
    return 0
  done
  return 1
}

install_gost_docker(){
  command -v docker >/dev/null 2>&1 || apt-get install $APT_OPTS docker.io >/dev/null 2>&1 || true
  command -v docker >/dev/null 2>&1 || return 1
  systemctl enable --now docker >/dev/null 2>&1 || systemctl restart docker >/dev/null 2>&1 || true
  docker rm -f vpngate-proxy >/dev/null 2>&1 || true
  docker pull gogost/gost:latest >/dev/null 2>&1 || true
  local args=() a
  for a in "${GOST_LS[@]}"; do args+=(-L "$a"); done
  docker run -d --name vpngate-proxy --net=host --restart=always gogost/gost "${args[@]}" >/dev/null 2>&1 || return 1
  sleep 2
  [ "$(docker inspect -f '{{.State.Running}}' vpngate-proxy 2>/dev/null)" = "true" ] || return 1
  return 0
}

if [ "$FORCE_DOCKER" = "1" ]; then
  spin_run "启动 gost 容器" install_gost_docker && GOST_MODE="docker"
else
  if command -v /usr/local/bin/gost >/dev/null 2>&1 && /usr/local/bin/gost -V >/dev/null 2>&1; then
    GOST_MODE="bin"
  elif spin_run "下载 gost 静态二进制（约 15MB）" fetch_gost_bin; then
    GOST_MODE="bin"
  elif spin_run "启动 gost 容器（备用方案）" install_gost_docker; then
    GOST_MODE="docker"
  fi
fi
[ -n "$GOST_MODE" ] || { err "gost 部署失败：GitHub 与 docker 都不可用。可用 GOST_MIRROR=https://ghproxy.net/ 重试"; exit 1; }
build_gost_runner
if [ "$GOST_MODE" = "bin" ]; then
  if spin_run "gost 启动参数自检" gost_selftest; then
    ok "gost 参数自检通过（${#GOST_LS[@]} 个入站）"
  else
    err "gost 参数自检失败，先修好再继续，否则代理端口一个都不会通。"
    exit 1
  fi
fi
ok "gost 部署方式: ${GOST_MODE}，入站监听 ${#GOST_LS[@]} 个"
echo "$GOST_MODE" > "$INSTALL_DIR/vpngate_gost_mode"

# ==============================================================================
step "4/9" "生成策略路由脚本 ${INSTALL_DIR}/up.sh（按 tun 序号自动分配路由表）"
# ==============================================================================
cat > "$INSTALL_DIR/up.sh" <<'EOF_UP'
#!/bin/bash
# OpenVPN --up 钩子：每条 tun 独立路由表，互不影响
DEV="${dev:-$1}"
LOCAL_IP="${ifconfig_local:-$4}"
BASE="${VPNGATE_TABLE:-100}"
IDX="${DEV#tun}"; case "$IDX" in ''|*[!0-9]*) IDX=0 ;; esac
TABLE=$(( BASE + IDX ))
GOST_MODE_FILE="${INSTALL_DIR:-/opt/gate_proxy}/vpngate_gost_mode"

# 非对称路由放行（部分机房 rp_filter=1 会丢隧道回包）
sysctl -qw net.ipv4.conf.all.rp_filter=2 2>/dev/null
sysctl -qw net.ipv4.conf.default.rp_filter=2 2>/dev/null
sysctl -qw "net.ipv4.conf.${DEV}.rp_filter=0" 2>/dev/null
sysctl -qw net.ipv4.ip_forward=1 2>/dev/null

[ -n "$DEV" ] || exit 0

ip route flush table "$TABLE" 2>/dev/null
while ip rule del table "$TABLE" 2>/dev/null; do :; done

ip route replace default dev "$DEV" table "$TABLE" 2>/dev/null

if [ -n "$LOCAL_IP" ]; then
  ip rule add from "$LOCAL_IP" table "$TABLE" priority $((1000 + IDX * 10)) 2>/dev/null
  ip rule add to   "$LOCAL_IP" table "$TABLE" priority $((1001 + IDX * 10)) 2>/dev/null
fi
ip rule add oif "$DEV" table "$TABLE" priority $((1002 + IDX * 10)) 2>/dev/null

# gost 按设备名 SO_BINDTODEVICE，隧道换节点【不需要】重启 gost。
# 只有 GOST_REBIND=1（某些 gost 版本会缓存解析结果）时才重启，否则重启会掐断其它隧道的连接。
if [ "${GOST_REBIND:-0}" = "1" ]; then
  if [ -f "$GOST_MODE_FILE" ] && [ "$(cat "$GOST_MODE_FILE" 2>/dev/null)" = "docker" ]; then
    ( sleep 5; docker restart vpngate-proxy >/dev/null 2>&1 ) &
  else
    ( sleep 5; systemctl restart vpngate-gost >/dev/null 2>&1 ) &
  fi
fi
exit 0
EOF_UP
chmod 0755 "$INSTALL_DIR/up.sh"
ok "${INSTALL_DIR}/up.sh 已生成（tunN → table ${ROUTE_TABLE}+N）"

# ==============================================================================
step "5/9" "注册 gost 服务"
# ==============================================================================
if [ "$GOST_MODE" = "bin" ]; then
  command -v docker >/dev/null 2>&1 && docker rm -f vpngate-proxy >/dev/null 2>&1 || true
  cat > /etc/systemd/system/vpngate-gost.service <<EOF_GOST
[Unit]
Description=GOST Proxy Gateway (multi-tunnel: ${IFACE_LIST})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
Environment=VPNGATE_TABLE=${ROUTE_TABLE}
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 45); do ip link show tun0 >/dev/null 2>&1 && exit 0; sleep 1; done; exit 0'
ExecStart=${INSTALL_DIR}/vpngate_gost_run.sh
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_GOST
  systemctl daemon-reload
  systemctl enable --now vpngate-gost >/dev/null 2>&1
  sleep 3
  if systemctl is-active --quiet vpngate-gost; then
    ok "vpngate-gost 已运行"
  else
    # 区分「正常等待 tun0」和「真的启动失败」—— 旧版本把这两种混成一句 warn，掩盖了错误
    UNIT_STATE=$(systemctl show -p ActiveState --value vpngate-gost 2>/dev/null)
    UNIT_RESULT=$(systemctl show -p Result --value vpngate-gost 2>/dev/null)
    if [ "$UNIT_RESULT" = "exit-code" ] || [ "$UNIT_STATE" = "failed" ]; then
      err "vpngate-gost 启动失败（Result=${UNIT_RESULT}），代理端口不会监听："
      journalctl -u vpngate-gost -n 12 --no-pager 2>/dev/null | sed 's/^/      /'
      GO_ON=0
    else
      warn "vpngate-gost 正在等 tun0（状态 ${UNIT_STATE}，连上节点后会自动拉起）"
      GO_ON=1
    fi
  fi
  if [ "${GO_ON:-1}" = "0" ]; then
    err "先解决上面的报错，否则 10808/10809/10818 等端口一个都不会通。"
    exit 1
  fi
else
  systemctl disable --now vpngate-gost >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/vpngate-gost.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "使用 docker 容器 vpngate-proxy"
fi

cat > /usr/local/bin/vg <<'EOF_VG'
#!/bin/bash
# vg —— 不开面板也能看状态 / 排故障
# 安装目录从 systemd 单元里读，改了 INSTALL_DIR 也不会失效
DIR=$(systemctl show vpngate -p Environment --value 2>/dev/null | tr ' ' '\n' | sed -n 's/^INSTALL_DIR=//p' | head -1)
DIR=${DIR:-/opt/gate_proxy}
S="$DIR/vpngate_status.json"
c(){ printf '\033[%sm%s\033[0m' "$1" "$2"; }
case "${1:-}" in
  log)     tail -n "${2:-40}" "$DIR/openvpn.log" ;;
  gost)    systemctl status vpngate-gost --no-pager -n "${2:-15}" ;;
  panel)   systemctl status vpngate --no-pager -n "${2:-15}" ;;
  dir)     echo "$DIR"; ls -la "$DIR" ;;
  ports)   ss -lntup 2>/dev/null | grep -E ':(5000|1080[89]|1081[0-9])\s' ;;
  restart) systemctl restart vpngate vpngate-gost && echo "已重启 vpngate + vpngate-gost" ;;
  ip)      for i in $(seq 0 5); do
             ip link show "tun$i" >/dev/null 2>&1 && \
               echo "tun$i -> $(curl -s --interface "tun$i" -m 6 https://api.ipify.org 2>/dev/null)"
           done ;;
  *)       python3 - "$S" <<'PY'
import json, sys, time, os

def _fmt(v):
    v = int(v or 0)
    if v < 60: return "%ds" % v
    if v < 3600: return "%dm" % (v // 60)
    if v < 86400: return "%.1fh" % (v / 3600)
    return "%.1fd" % (v / 86400)

p = sys.argv[1]
if not os.path.exists(p):
    print("还没有状态文件，服务可能刚启动。先看 systemctl status vpngate")
    sys.exit(0)
d = json.load(open(p, encoding="utf-8"))
age = int(time.time()) - d.get("ts", 0)
ts = d.get("tunnels", [])
ok = sum(1 for t in ts if t.get("healthy"))
G, R, Y, C, D, N = "\033[32m", "\033[31m", "\033[33m", "\033[36m", "\033[90m", "\033[0m"
flag = (G + "●" if ts and ok == len(ts) else (Y + "◐" if ok else R + "○")) + N
print("%s  %d/%d 隧道在线   节点池 在线%d / 累积%d（US %d）   %s" % (
    flag, ok, len(ts), d.get("nodes", 0), d.get("pool_total", d.get("nodes", 0)),
    d.get("pool_us", 0),
    (D + "更新于 %ds 前" % age + N) if age < 120 else (Y + "状态已 %ds 没更新" % age + N)))
for t in ts:
    if t.get("healthy"):
        spd = t.get("speed_mbps")
        spd_s = ("%5.1fMbps" % spd) if spd else "    未测"
        print("  %s  %-10s %-8s 出口 %-15s RTT %-7s 带宽 %-11s 已连 %s" % (
            G + "up  " + N, t["dev"], (t.get("country") or "-"),
            t.get("exit_ip") or "-", (str(t.get("rtt")) + "ms") if t.get("rtt") else "-",
            spd_s, _fmt(t.get("up", 0))))
    else:
        print("  %s  %-10s %s" % (R + "down" + N, t["dev"],
                                  Y + "已断 %ds，后台恢复中" % t.get("down", 0) + N))
print("  %s %s" % (D + "状态:" + N, d.get("status_msg", "-")))
print("  %s %s   优选:%s   测速:%s   通知:%s   面板: %s" % (
    D + "上次巡检:" + N, d.get("last_check", "-"),
    (G + "开" + N) if d.get("auto_optimize") else (D + "关" + N),
    (G + "开" + N) if d.get("speedtest_on") else (D + "关" + N),
    (G + "开" + N) if d.get("notify_on") else (D + "关" + N),
    C + "http://%s:%s/" % (d.get("public_ip") or "IP", d.get("panel_port", 5000)) + N))
print("  %s" % (D + "更多: vg dir / vg log / vg gost / vg ports / vg ip / vg restart" + N))
PY
       ;;
esac
EOF_VG
chmod 0755 /usr/local/bin/vg
ok "已安装 /usr/local/bin/vg（vg / vg log / vg gost / vg ports / vg ip / vg restart）"

# ==============================================================================
step "6/9" "拉取节点库"
# ==============================================================================
VB_CACHE="$INSTALL_DIR/vpngate_cache.csv"
: > "$VB_CACHE"
fetch_cache(){
  local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
  curl -fsSL -m 30 -A "$ua" -H "Accept-Language: en-US,en;q=0.9" "$1" -o /tmp/vb.raw 2>/dev/null || return 1
  # 统一换行：带 Chrome UA 时服务端会返回 \r\r\n（双 CR），会撑出空行把表头挤掉
  tr -d '\r' < /tmp/vb.raw > /tmp/vb.csv 2>/dev/null || return 1
  grep -q "OpenVPN_ConfigData_Base64" /tmp/vb.csv || return 1
  mv /tmp/vb.csv "$VB_CACHE"; return 0
}
CACHE_OK=0
for SRC in "https://www.vpngate.net/api/iphone/" "http://www.vpngate.net/api/iphone/" \
           "https://www.vpngate.net/api/iphone/?host=1" "https://vpngate.net/api/iphone/" ; do
  if fetch_cache "$SRC"; then ok "节点库来源: $SRC"; CACHE_OK=1; break; fi
  warn "抓取失败: $SRC"
done
if [ "$CACHE_OK" = "1" ]; then
  python3 - "$VB_CACHE" <<'PY' || true
import csv, io, sys
raw = open(sys.argv[1], encoding="utf-8-sig", errors="ignore").read()
raw = raw.replace("\r\r\n", "\n").replace("\r\n", "\n").replace("\r", "\n")
lines = [l for l in raw.split("\n") if l.strip() and not l.startswith("*")]
hi = next((i for i, l in enumerate(lines) if "OpenVPN_ConfigData_Base64" in l), None)
if hi is None:
    print("  \033[31m✘\033[0m 节点库格式异常（找不到表头）"); raise SystemExit
header = [h.strip().lstrip("#").strip() for h in lines[hi].split(",")]
rows = []
for r in csv.reader(io.StringIO("\n".join(lines[hi+1:]))):
    if len(r) >= len(header):
        rows.append(dict(zip(header, r)))
def num(r, k):
    v = (r.get(k) or "").strip()
    return int(v) if v.isdigit() else 0
rows = [r for r in rows if r.get("OpenVPN_ConfigData_Base64") and r.get("IP")]
free = [r for r in rows if num(r, "NumVpnSessions") <= 20]
jp = [r for r in free if (r.get("CountryShort") or "") == "JP"]
print("  \033[32m✔\033[0m 节点总数 %d，并发≤20 的冷门节点 %d 个，其中日本 %d 个"
      % (len(rows), len(free), len(jp)))
if len(jp) < 3:
    print("  \033[33m▲\033[0m 冷门日本节点不足 3 个，可调 SESSION_CAP=100 放宽，或加 KR 兜底")
PY
else
  warn "官方 API 全部抓取失败，面板启动后点『更新节点库』，或挂代理再试"
fi

# ==============================================================================
step "7/9" "写面板与多隧道守护 ${INSTALL_DIR}/vpngate_panel.py"
# ==============================================================================
cat > "$INSTALL_DIR/vpngate_panel.py" <<'EOF_PY'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""VPN Gate multi-tunnel panel - zero third-party deps, session login, editable settings"""
import os, sys, time, json, math, base64, subprocess, threading, re, socket
import urllib.request, csv, io, concurrent.futures, ipaddress, shutil, secrets
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PANEL_PORT  = int(os.environ.get("PANEL_PORT", "5000"))
SOCKS5_PORT = int(os.environ.get("SOCKS5_PORT", "10808"))
SS_PORT     = int(os.environ.get("SS_PORT", "10809"))
SS2022_PORT = int(os.environ.get("SS2022_PORT", "10810"))
SSU_PORT    = int(os.environ.get("SSU_PORT", "10811"))
STICKY_BASE = int(os.environ.get("STICKY_BASE", "10818"))
STICKY      = os.environ.get("STICKY", "1") == "1"
TUNNELS     = max(1, min(6, int(os.environ.get("TUNNELS", "3"))))
ROUTE_TABLE = int(os.environ.get("ROUTE_TABLE", "100"))
SOCKS5_PASS = os.environ.get("SOCKS5_PASS", "")
SS_PASS     = os.environ.get("SS_PASS", "")
SS2022_PASS = os.environ.get("SS2022_PASS", "")
PUBLIC_IP   = os.environ.get("PUBLIC_IP", "")

# 所有项目文件集中在一个目录，/opt 下面不会散落一堆 vpngate_*
INSTALL_DIR  = os.environ.get("INSTALL_DIR", "/opt/gate_proxy")
RUN_DIR      = os.path.join(INSTALL_DIR, "run")
CACHE_FILE   = os.path.join(INSTALL_DIR, "vpngate_cache.csv")
POOL_FILE    = os.path.join(INSTALL_DIR, "vpngate_pool.json")
CONFIG_FILE  = os.path.join(INSTALL_DIR, "vpngate_auto.json")
RUNTIME_FILE = os.path.join(INSTALL_DIR, "vpngate_runtime.json")
CRED_FILE    = os.path.join(INSTALL_DIR, "vpngate_credentials.json")
STATUS_FILE  = os.path.join(INSTALL_DIR, "vpngate_status.json")
AUTH_FILE    = os.path.join(INSTALL_DIR, "vpngate_auth.txt")
GOST_MODE    = os.path.join(INSTALL_DIR, "vpngate_gost_mode")
OVPN_LOG     = os.path.join(INSTALL_DIR, "openvpn.log")
UP_SCRIPT    = os.path.join(INSTALL_DIR, "up.sh")
_status_ts   = [0.0]
_exit_job    = {"busy": set(), "lock": threading.Lock()}

DEFAULTS = {
    "session_cap": int(os.environ.get("SESSION_CAP", "60")),
    "candidates": int(os.environ.get("CANDIDATES", "5")),
    "prefer_tcp": os.environ.get("PREFER_TCP", "0") == "1",
    "fast_poll": float(os.environ.get("FAST_POLL", "1.0")),
    "health_poll": float(os.environ.get("HEALTH_POLL", "3.0")),
    "mssfix": str(os.environ.get("MSSFIX", "1300")),
    "ping_restart": int(os.environ.get("PING_RESTART", "20")),
    "fix_mtu": os.environ.get("FIX_MTU", "1") == "1",
    "gost_rebind": os.environ.get("GOST_REBIND", "0") == "1",
    # ---- 自动优选：当前节点明显比池子里的好节点差太多时，主动换掉 ----
    "auto_optimize": os.environ.get("AUTO_OPTIMIZE", "1") == "1",
    "optimize_ratio": float(os.environ.get("OPTIMIZE_RATIO", "2.5")),   # 慢几倍才换
    "optimize_floor": int(os.environ.get("OPTIMIZE_FLOOR", "150")),     # 且至少慢到多少 ms
    "optimize_interval": int(os.environ.get("OPTIMIZE_INTERVAL", "3600")),  # 多久评估一次（秒）
    # ---- 通知（只在出问题时打扰你，平时完全静默）----
    "notify_url": os.environ.get("NOTIFY_URL", ""),
    "notify_kind": os.environ.get("NOTIFY_KIND", "json"),      # json | telegram
    "notify_chat": os.environ.get("NOTIFY_CHAT", ""),
    "notify_min_gap": int(os.environ.get("NOTIFY_MIN_GAP", "1800")),  # 同类告警最短间隔（秒）
    # ---- 实测带宽（会给每条隧道额外产生流量，默认 12 小时一次、每次 3MB）----
    "speedtest": os.environ.get("SPEEDTEST", "1") == "1",
    "speedtest_mb": float(os.environ.get("SPEEDTEST_MB", "3")),
    "speedtest_interval": int(os.environ.get("SPEEDTEST_INTERVAL", "43200")),
    # ---- 地理优先 + 历史节点池 ----
    "geo_prefer": os.environ.get("GEO_PREFER", "1") == "1",   # 优先靠近 VPS 的节点
    "pool_extra": os.environ.get("POOL_EXTRA", "1") == "1",   # 在线节点不够时启用历史节点
    "pool_ttl_days": int(os.environ.get("POOL_TTL_DAYS", "14")),  # 历史节点保留天数
}

runtime = {}
runtime_lock = threading.RLock()

def load_runtime():
    runtime.clear()
    runtime.update(dict(DEFAULTS))
    if os.path.exists(RUNTIME_FILE):
        try:
            with open(RUNTIME_FILE, "r", encoding="utf-8") as f:
                runtime.update(json.load(f))
        except Exception:
            pass

def save_runtime():
    try:
        tmp = RUNTIME_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(runtime, f, ensure_ascii=False, indent=2)
        os.replace(tmp, RUNTIME_FILE)
    except Exception:
        pass

def rt(k, d=None):
    v = runtime.get(k)
    if v is None:
        v = DEFAULTS.get(k, d)
    return v

load_runtime()

try:
    csv.field_size_limit(sys.maxsize)
except Exception:
    csv.field_size_limit(10 ** 9)

cached_nodes, node_list_cache = {}, []
pool_extra_cache = []        # 历史节点（当前不在 API 快照里，但池子里还有）
node_pool = {}               # ip -> {meta, first_seen, last_seen, ok, fail}
VPS_COUNTRY = None           # 本机所在国家（两位码），用于地理优先
bad_nodes = {}
cfg_lock = threading.RLock()

auto_cfg = {
    "mode": "auto", "p1": "JP", "p2": "KR", "p3": "NONE", "interval": 30,
    "status_msg": "正在初始化守护线程...", "last_check": "尚未检测",
}

def load_config():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                auto_cfg.update(json.load(f))
        except Exception:
            pass

def save_config():
    try:
        tmp = CONFIG_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(auto_cfg, f, ensure_ascii=False, indent=2)
        os.replace(tmp, CONFIG_FILE)
    except Exception:
        pass

load_config()

def load_cred():
    user = os.environ.get("PANEL_USER", "admin") or "admin"
    passwd = os.environ.get("PANEL_PASS", "")
    if os.path.exists(CRED_FILE):
        try:
            with open(CRED_FILE, "r", encoding="utf-8") as f:
                d = json.load(f)
            user = d.get("user") or user
            passwd = d.get("pass") or passwd
        except Exception:
            pass
    return user, passwd

CRED_USER, CRED_PASS = load_cred()

def save_cred(user, passwd):
    global CRED_USER, CRED_PASS
    CRED_USER, CRED_PASS = user, passwd
    try:
        tmp = CRED_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"user": user, "pass": passwd}, f, ensure_ascii=False)
        os.replace(tmp, CRED_FILE)
        os.chmod(CRED_FILE, 0o600)
        with open(CRED_FILE, "r", encoding="utf-8") as f:
            _ = f.read()
    except Exception:
        pass

_sessions = {}
_sess_lock = threading.Lock()
_fails = {}
SESSION_TTL = 12 * 3600
LOGIN_MAX_FAIL = 6
LOGIN_LOCK_SEC = 120

def new_session():
    sid = secrets.token_urlsafe(32)
    with _sess_lock:
        _sessions[sid] = time.time() + SESSION_TTL
        if len(_sessions) > 64:
            now = time.time()
            for k in [k for k, v in _sessions.items() if v < now]:
                _sessions.pop(k, None)
    return sid

def valid_session(sid):
    if not sid:
        return False
    with _sess_lock:
        exp = _sessions.get(sid)
        if not exp:
            return False
        if exp < time.time():
            _sessions.pop(sid, None)
            return False
        return True

def drop_session(sid):
    with _sess_lock:
        _sessions.pop(sid or "", None)

class _R:
    returncode = 1
    stdout = ""
    stderr = ""

def run(cmd, timeout=10, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)
    except Exception:
        return _R()

def get_openvpn_ver():
    m = re.search(r"OpenVPN\s+(\d+)\.(\d+)", run(["openvpn", "--version"]).stdout)
    return (int(m.group(1)), int(m.group(2))) if m else (2, 4)

def dev_exists(dev):
    return run(["ip", "link", "show", dev], timeout=5).returncode == 0

def dev_gone(dev, timeout=8):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if not dev_exists(dev):
            return True
        time.sleep(0.3)
    return False

def icmp_blocked():
    if not shutil.which("ping"):
        return False
    return run(["ping", "-c", "1", "-W", "1", "1.1.1.1"], timeout=4).returncode != 0

ICMP_BLOCKED = icmp_blocked()

def make_tunnels(n):
    out = []
    for i in range(n):
        out.append({
            "idx": i, "dev": "tun%d" % i,
            "table": str(ROUTE_TABLE + i),
            "ovpn": os.path.join(RUN_DIR, "tun%d.ovpn" % i),
            "pid": os.path.join(RUN_DIR, "tun%d.pid" % i),
            "node": None, "country": "", "healthy": False,
            "exit_ip": None, "exit_ts": 0.0, "since": 0.0,
            "down_since": 0.0, "rtt": None, "rtt_ts": 0.0,
            "fails": 0, "attempts": 0, "pinned": None, "enabled": True,
            "speed_mbps": None, "speed_ts": 0.0, "testing": False,
        })
    return out

TUNS = make_tunnels(TUNNELS)

_wake = threading.Event()
_stop = threading.Event()

_pending = [0.0]
_started = [False]

def restart_gost():
    mode = "bin"
    try:
        mode = open(GOST_MODE).read().strip()
    except Exception:
        pass
    if mode == "docker":
        run(["docker", "restart", "vpngate-proxy"], timeout=30)
    else:
        run(["systemctl", "restart", "vpngate-gost"], timeout=30)

def _restart_worker():
    while True:
        time.sleep(1.0)
        if _pending[0] and time.time() >= _pending[0]:
            _pending[0] = 0.0
            restart_gost()

def schedule_gost_restart(delay=5.0):
    if not rt("gost_rebind", False):
        return
    _pending[0] = time.time() + delay
    if not _started[0]:
        _started[0] = True
        threading.Thread(target=_restart_worker, daemon=True).start()

def health(t, timeout=4):
    if not dev_exists(t["dev"]):
        return False
    r = run(["curl", "--interface", t["dev"], "-m", str(timeout), "-s", "-o", "/dev/null",
             "-w", "%{http_code}", "http://connectivitycheck.gstatic.com/generate_204"],
            timeout=timeout + 3)
    if r.returncode == 0 and (r.stdout or "").strip() in ("204", "200"):
        return True
    if not ICMP_BLOCKED:
        return run(["ping", "-I", t["dev"], "-c", "1", "-W", "2", "1.1.1.1"], timeout=6).returncode == 0
    return False

def probe_node(ip, port, proto="udp"):
    if str(proto).lower() == "tcp":
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1.2)
            t0 = time.time()
            rc = s.connect_ex((ip, int(port)))
            dt = (time.time() - t0) * 1000.0
            s.close()
            return (rc == 0, round(dt, 1) if rc == 0 else None)
        except Exception:
            return (False, None)
    if ICMP_BLOCKED:
        return (None, None)
    r = run(["ping", "-c", "1", "-W", "1", ip], timeout=4)
    if r.returncode != 0:
        return (False, None)
    m = re.search(r"time=([\d.]+)", r.stdout or "")
    return (True, round(float(m.group(1)), 1) if m else None)

def check_node_alive(ip, port, proto="udp"):
    return probe_node(ip, port, proto)[0]

def measure_rtts(nodes, workers=24):
    def one(n):
        d = dict(n)
        try:
            alive, rtt = probe_node(n["ip"], n["port"], n["proto"].lower())
            d["online"] = alive
            d["rtt"] = rtt
        except Exception:
            d["online"] = None
            d["rtt"] = None
        return d
    if not nodes:
        return []
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(len(nodes), workers)) as ex:
        return list(ex.map(one, nodes))

def tunnel_peer_rtt(t):
    if not t["healthy"]:
        return None
    r = run(["ip", "-4", "addr", "show", "dev", t["dev"]], timeout=5)
    m = re.search(r"inet\s+[\d.]+\S*\s+peer\s+([\d.]+)", r.stdout or "")
    if not m:
        return None
    r2 = run(["ping", "-I", t["dev"], "-c", "3", "-W", "2", "-q", m.group(1)], timeout=12)
    mm = re.search(r"min/avg/max[^=]*=\s*[\d.]+/([\d.]+)/", r2.stdout or "")
    return round(float(mm.group(1)), 1) if mm else None

# ---------------------------- 通知（平时静默，出事才响） ----------------------------
_notify_state = {"last": {}, "lock": threading.Lock()}

def notify(key, text, force=False):
    """webhook 通知。key 用于限频：同类消息 notify_min_gap 秒内只发一次，避免刷屏"""
    url = str(rt("notify_url", "") or "").strip()
    if not url:
        return False
    now = time.time()
    gap = int(rt("notify_min_gap", 1800))
    with _notify_state["lock"]:
        if not force and now - _notify_state["last"].get(key, 0) < gap:
            return False
        _notify_state["last"][key] = now
    kind = str(rt("notify_kind", "json") or "json")
    if kind == "telegram":
        payload = {"chat_id": rt("notify_chat", ""), "text": text,
                   "disable_web_page_preview": True}
    else:
        payload = {"title": "VPN Gate", "text": text, "host": socket.gethostname()}
    body = json.dumps(payload, ensure_ascii=False)
    r = run(["curl", "-fsS", "-m", "10", "-H", "Content-Type: application/json",
             "--data-binary", body, url], timeout=15)
    return r.returncode == 0

def build_ovpn(raw_ovpn, idx):
    maj, mi = get_openvpn_ver()
    keep = []
    for line in raw_ovpn.splitlines():
        s = line.strip()
        if re.match(r"^(auth-user-pass|redirect-gateway|route-gateway|route-noexec|route-nopull|"
                    r"script-security|up|down|log|log-append|status|daemon|writepid)\b", s, re.I):
            continue
        if (maj, mi) < (2, 5) and re.match(r"^(data-ciphers|data-ciphers-fallback|tls-cert-profile)\b", s, re.I):
            continue
        keep.append(line)

    h = ["client", "dev tun%d" % idx, "route-nopull", "route-noexec",
         "auth-user-pass " + AUTH_FILE, "auth-retry nointeract", "auth-nocache",
         "script-security 2", "up " + UP_SCRIPT,
         "connect-retry-max 1", "connect-timeout 15", "resolv-retry 1",
         "nobind", "persist-key",
         "ping 3", "ping-restart %s" % int(rt("ping_restart", 20))]
    if rt("fix_mtu", True):
        h += ["mssfix %s" % rt("mssfix", "1300"), "sndbuf 0", "rcvbuf 0"]

    if (maj, mi) >= (2, 6):
        h += ["tls-cert-profile insecure",
              "data-ciphers AES-128-GCM:AES-256-GCM:AES-128-CBC:AES-256-CBC",
              "data-ciphers-fallback AES-128-CBC"]
    elif (maj, mi) == (2, 5):
        h += ["data-ciphers AES-128-GCM:AES-256-GCM:AES-128-CBC:AES-256-CBC",
              "data-ciphers-fallback AES-128-CBC"]
    else:
        h += ["cipher AES-128-CBC",
              "ncp-ciphers AES-128-GCM:AES-256-GCM:AES-128-CBC:AES-256-CBC"]
    return "\n".join(h) + "\n" + "\n".join(keep) + "\n"

def get_node_cfg(nid):
    """在线节点从 cached_nodes 取；历史节点从 node_pool 取"""
    if nid in cached_nodes:
        return cached_nodes[nid]
    e = node_pool.get(nid) or {}
    return e.get("cfg") or None

def connect_tunnel(t, nid, wait=13):
    with cfg_lock:
        raw_cfg = get_node_cfg(nid)
        if not raw_cfg:
            return False
        raw = base64.b64decode(raw_cfg).decode("utf-8", "ignore")
        ctry = ""
        for n in node_list_cache:
            if n["id"] == nid:
                ctry = n["country"]
                break

    with open(t["ovpn"], "w", encoding="utf-8") as f:
        f.write(build_ovpn(raw, t["idx"]))
    os.chmod(t["ovpn"], 0o600)

    run(["pkill", "-9", "-f", t["ovpn"]], timeout=8)
    if not dev_gone(t["dev"], 5):
        run(["ip", "link", "set", t["dev"], "down"], timeout=5)
        run(["ip", "link", "delete", t["dev"]], timeout=5)
        dev_gone(t["dev"], 4)
    run(["bash", "-c", "ip route flush table %s 2>/dev/null; while ip rule del table %s 2>/dev/null; do :; done"
         % (t["table"], t["table"])], timeout=10)

    try:
        with open(OVPN_LOG, "a") as lf:
            lf.write("\n===== %s  %s <- %s =====\n" % (time.strftime("%F %T"), t["dev"], nid))
            subprocess.Popen(["openvpn", "--config", t["ovpn"], "--daemon", "--writepid", t["pid"]],
                             stdout=lf, stderr=lf, start_new_session=True)
    except Exception:
        return False

    t0 = time.time()
    while time.time() - t0 < wait:
        if health(t):
            with cfg_lock:
                t["node"] = nid
                t["country"] = ctry
                t["healthy"] = True
                t["exit_ip"] = None
                t["exit_ts"] = 0.0
                t["since"] = time.time()
                t["down_since"] = 0.0
                t["fails"] = 0
                t["attempts"] = 0
                t["rtt"] = None
                t["rtt_ts"] = 0.0
                t["pinned"] = nid
            schedule_gost_restart()
            return True
        time.sleep(0.5)
    with cfg_lock:
        t["healthy"] = False
        t["down_since"] = time.time()
    return False

def disconnect_tunnel(t):
    run(["pkill", "-9", "-f", t["ovpn"]], timeout=8)
    dev_gone(t["dev"], 5)
    run(["ip", "link", "set", t["dev"], "down"], timeout=5)
    run(["ip", "link", "delete", t["dev"]], timeout=5)
    run(["bash", "-c", "ip route flush table %s 2>/dev/null; while ip rule del table %s 2>/dev/null; do :; done"
         % (t["table"], t["table"])], timeout=10)
    with cfg_lock:
        t["healthy"] = False
        t["node"] = None
        t["country"] = ""
        t["exit_ip"] = None
        t["rtt"] = None
        t["down_since"] = time.time()
    _wake.set()

def node_score(n):
    sess = n.get("sessions", 0) or 0
    cap = int(rt("session_cap", 60))
    if sess > cap:
        return -1.0
    spd = n.get("speed", 0.0) or 0.0
    usr = n.get("users", 0) or 0
    up = n.get("uptime", 0) or 0
    s = 50.0 / (1.0 + sess / 2.0)
    s += 18.0 * min(spd / 200.0, 1.0)
    s += 12.0 * max(0.0, 1.0 - usr / 8000000.0)
    s += 10.0 if up >= 86400 else (5.0 if up >= 3600 else 0.0)
    rtt = n.get("rtt")
    if rtt:
        s += 10.0 / (1.0 + rtt / 20.0)
    else:
        ping = n.get("ping", 9999) or 9999
        s += 5.0 / (1.0 + ping / 20.0)

    # 地理优先：和 VPS 同国的节点 +8 分（权重刻意低于"并发"50 分，
    # 只是轻微倾向，不会为了同国去选一个人挤人的节点）
    if rt("geo_prefer", True) and VPS_COUNTRY and n.get("country") == VPS_COUNTRY:
        s += 8.0
    if n.get("stale"):
        s -= 15.0        # 历史节点只在在线节点不够时才用，排后面
    return s

def rank_nodes(countries, exclude=None, limit=None, ignore_cap=False, measure=True, allow_extra=False):
    exclude = exclude or set()
    now = time.time()
    cap = int(rt("session_cap", 60))
    pref_tcp = bool(rt("prefer_tcp", False))

    def pool_source():
        src = list(node_list_cache)
        # 在线节点不够时（尤其是小国家只有 1~3 个），把历史池里同国的节点拿出来当后备
        if allow_extra and rt("pool_extra", True):
            src = src + [n for n in pool_extra_cache if countries is None or n["country"] in countries]
        return src

    cands = []
    for n in pool_source():
        if n["id"] in exclude:
            continue
        if n["id"] in bad_nodes and now - bad_nodes[n["id"]] < 600:
            continue
        if countries and n["country"] not in countries:
            continue
        sc = node_score(dict(n, sessions=min(n["sessions"], cap)) if ignore_cap else n)
        if sc < 0:
            continue
        cands.append((sc, n))
    cands.sort(key=lambda x: ((0 if x[1]["proto"] == "TCP" else 1) if pref_tcp
                              else (0 if x[1]["proto"] == "UDP" else 1), -x[0]))
    pool = [n for _, n in cands]
    if measure and pool:
        top = measure_rtts(pool[:24])
        for d in top:
            d["_sc"] = node_score(d)
        pref = (lambda x: 0 if x["proto"] == "TCP" else 1) if pref_tcp \
               else (lambda x: 0 if x["proto"] == "UDP" else 1)
        top.sort(key=lambda x: (pref(x), -x["_sc"]))
        pool = top + pool[24:]
    return pool[:limit] if limit else pool

def tunnel_monitor(t):
    fails = 0
    last_probe = 0.0
    last_rtt = 0.0
    while not _stop.is_set():
        try:
            if _stop.wait(max(0.5, float(rt("fast_poll", 1.0)))):
                break
            now = time.time()
            if not t.get("enabled", True):
                fails = 0
                continue
            if not dev_exists(t["dev"]):
                if t["healthy"]:
                    with cfg_lock:
                        t["healthy"] = False
                        t["down_since"] = now
                        t["fails"] = 0
                    _wake.set()
                fails = 0
                continue
            if now - last_probe >= max(2.0, float(rt("health_poll", 3.0))):
                last_probe = now
                if health(t):
                    fails = 0
                    if not t["healthy"]:
                        with cfg_lock:
                            t["healthy"] = True
                            t["down_since"] = 0.0
                            t["since"] = now
                        _wake.set()
                else:
                    fails += 1
                    if fails >= 2 and t["healthy"]:
                        with cfg_lock:
                            t["healthy"] = False
                            t["down_since"] = now
                        _wake.set()
            if t["healthy"] and now - last_rtt >= 20:
                last_rtt = now
                rtt = tunnel_peer_rtt(t)
                if rtt:
                    with cfg_lock:
                        t["rtt"] = rtt
                        t["rtt_ts"] = now
        except Exception:
            time.sleep(2)

# ---------------------------- 实测带宽 ----------------------------
# 做法：curl --interface tunN 从一个靠近节点的大带宽 CDN 下固定大小的数据，
# 读 curl 自己的 speed_download。测的是「VPS→家宽节点→CDN」这条完整链路，
# 正好就是这条隧道真实能跑多快。测一条时串行执行，避免两条互相抢 VPS 上行口。
SPEED_URLS = (
    "https://speed.cloudflare.com/__down?bytes=%d",
    "http://speed.cloudflare.com/__down?bytes=%d",
)

def speedtest_tunnel(t, mb=None, timeout=18):
    """返回 Mbps；失败返回 None。测完写回 t["speed_mbps"] / t["speed_ts"]"""
    if not t["healthy"]:
        return None
    nbytes = int((mb if mb is not None else rt("speedtest_mb", 3)) * 1000000)
    nbytes = max(1000000, min(nbytes, 50000000))
    with cfg_lock:
        t["testing"] = True
    best = 0.0
    try:
        for tpl in SPEED_URLS:
            url = tpl % nbytes
            r = run(["curl", "--interface", t["dev"], "-s", "-o", "/dev/null",
                     "--max-time", str(timeout),
                     "-w", "%{size_download} %{speed_download} %{http_code}", url],
                    timeout=timeout + 8)
            parts = (r.stdout or "").strip().split()
            if len(parts) < 3 or parts[2] != "200":
                continue
            try:
                size = float(parts[0] or 0)
                spd = float(parts[1] or 0)
            except ValueError:
                continue
            # 至少下到 30% 或者 800KB 才算有效样本
            if spd > 0 and size >= min(nbytes * 0.3, 800000):
                best = max(best, spd * 8.0 / 1e6)
            if best > 0:
                break
        if best > 0:
            with cfg_lock:
                t["speed_mbps"] = round(best, 1)
                t["speed_ts"] = time.time()
            return t["speed_mbps"]
        return None
    finally:
        with cfg_lock:
            t["testing"] = False

def speedtest_all(background=True):
    """串行测所有隧道（串行才不会互相抢带宽，测出来的数才有意义）"""
    def worker():
        for t in TUNS:
            if not t["healthy"]:
                continue
            auto_cfg["status_msg"] = "正在测速 %s ..." % t["dev"]
            try:
                speedtest_tunnel(t)
            except Exception:
                pass
        auto_cfg["status_msg"] = "测速完成"
        write_status(force=True)
    if background:
        threading.Thread(target=worker, daemon=True, name="speedtest").start()
        return None
    worker()
    return {t["dev"]: t.get("speed_mbps") for t in TUNS}

def country_rtt_report():
    """
    从本机实测每个国家节点的最低 RTT —— 用来回答「加拿大还是新加坡更快」这种问题。
    只看节点数最多的前 8 个国家、每国 2 个，控制总耗时（不做全量，避免面板转圈）。
    """
    by = {}
    for n in node_list_cache:
        by.setdefault(n["country"], []).append(n)
    picks, meta = [], {}
    order = sorted(by.items(), key=lambda kv: -len(kv[1]))[:8]
    for c, arr in order:
        arr.sort(key=lambda x: (x["sessions"], x["ping"]))
        picks.extend(arr[:2])
        meta[c] = {"name": arr[0]["country_long"], "nodes": len(arr)}
    res = measure_rtts(picks, workers=16)
    agg = {}
    for r in res:
        if r.get("rtt"):
            agg.setdefault(r["country"], []).append(r["rtt"])
    out = []
    for c, rtts in agg.items():
        out.append({
            "country": c,
            "name": meta.get(c, {}).get("name", c),
            "nodes": meta.get(c, {}).get("nodes", 0),
            "rtt": round(min(rtts), 1),
            "tested": len(rtts),
        })
    out.sort(key=lambda x: x["rtt"])
    return out

def optimize_check():
    """
    自动优选：只换「明显更差」的节点，不追求每次都挑最快的。
    这样既能避免长期挂在慢节点上，又不会因为微小差异频繁换 IP。
    判定：当前真实 RTT > max(optimize_floor, optimize_ratio × 候选最优 RTT)
    """
    if not rt("auto_optimize", True):
        return []
    if any(not t["healthy"] for t in TUNS):
        return []          # 有不健康的先修好，别同时做两件事
    pool = rank_nodes(None, limit=12, measure=True)   # 全池测一次真实 RTT
    rtts = [n["rtt"] for n in pool if n.get("rtt")]
    if not rtts:
        return []
    best = min(rtts)
    ratio = float(rt("optimize_ratio", 2.5))
    floor = int(rt("optimize_floor", 150))
    limit_rtt = max(floor, ratio * best)
    rotated = []
    for t in TUNS:
        cur = t.get("rtt")
        if not cur or cur <= limit_rtt:
            continue
        if time.time() - t["since"] < 900:
            continue                     # 刚连上的先观察 15 分钟
        cand = next((n for n in pool if n["id"] != t["node"] and n.get("rtt")), None)
        if not cand:
            continue
        auto_cfg["status_msg"] = "节点偏慢（%sms > %sms），%s 换到 %s" % (
            cur, int(limit_rtt), t["dev"], cand["ip"])
        with cfg_lock:
            t["healthy"] = False
            t["down_since"] = time.time()
            t["pinned"] = None           # 清掉粘性，允许换新节点
        rotated.append((t["dev"], t["node"], cur, cand["id"], cand.get("rtt")))
        break                            # 一轮最多换一条，避免整体抖动
    if rotated:
        d, old, o_rtt, new, n_rtt = rotated[0]
        notify("optimize", "已自动换节点：%s\n旧 %s (%sms) → 新 %s (%sms)" % (
            d, old, o_rtt, new, n_rtt))
        _wake.set()
    return rotated

def write_status(force=False):
    """把运行状态写一份到 vpngate_status.json，供 `vg` 命令直接读取，不用开面板"""
    now = time.time()
    if not force and now - _status_ts[0] < 15:
        return
    _status_ts[0] = now
    d = {
        "ts": int(now), "time": time.strftime("%F %T"), "panel_port": PANEL_PORT,
        "public_ip": public_ip() or "",
        "nodes": len(node_list_cache),
        "pool_total": len(node_pool),
        "pool_us": len([1 for e in node_pool.values()
                        if (e.get("meta") or {}).get("country") == "US"]),
        "vps_country": VPS_COUNTRY,
        "free_nodes": len([n for n in node_list_cache
                           if n["sessions"] <= max(1, int(rt("session_cap", 60)) // 3)]),
        "status_msg": auto_cfg.get("status_msg", ""),
        "last_check": auto_cfg.get("last_check", ""),
        "auto_optimize": bool(rt("auto_optimize", True)),
        "notify_on": bool(str(rt("notify_url", "") or "").strip()),
        "speedtest_on": bool(rt("speedtest", True)),
        "tunnels": [{
            "dev": t["dev"], "healthy": bool(t["healthy"]), "node": t["node"],
            "country": t["country"], "exit_ip": t["exit_ip"], "rtt": t["rtt"],
            "speed_mbps": t.get("speed_mbps"),
            "up": int(now - t["since"]) if t["since"] else 0,
            "down": int(now - t["down_since"]) if t["down_since"] else 0,
        } for t in TUNS],
    }
    try:
        tmp = STATUS_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=1)
        os.replace(tmp, STATUS_FILE)
    except Exception:
        pass

def watchdog_thread():
    time.sleep(3)
    last_refresh = time.time()
    last_opt = time.time()
    last_speed = time.time() - int(rt("speedtest_interval", 43200)) + 120  # 启动 2 分钟后先测一次
    down_rounds = 0
    was_down = False
    while not _stop.is_set():
        try:
            now = time.time()
            auto_cfg["last_check"] = time.strftime("%H:%M:%S")
            if (now - last_refresh > 6 * 3600) or not node_list_cache:
                try:
                    refresh_cache_internal()
                except Exception:
                    pass
                last_refresh = time.time()
            active = [t for t in TUNS if t.get("enabled", True)]
            alive = [t for t in active if t["healthy"]]
            n_ok = len(alive)

            # ---- 故障 / 恢复 通知（只在状态翻转时发一次）----
            if n_ok == 0 and active:
                down_rounds += 1
                if down_rounds >= 3:
                    was_down = True
                    notify("alldown", "所有隧道都不通了，已经连续 %d 轮恢复失败。\n"
                                      "面板: http://%s:%d/\n最近状态: %s" % (
                                          down_rounds, public_ip() or "服务器IP",
                                          PANEL_PORT, auto_cfg.get("status_msg", "")))
            elif n_ok > 0 and was_down:
                was_down = False
                down_rounds = 0
                notify("recover", "已恢复：%d/%d 条隧道在线，出口 %s" % (
                    n_ok, len(active), next((t["exit_ip"] for t in alive if t["exit_ip"]), "-")))

            if n_ok == len(active):
                down_rounds = 0
                auto_cfg["status_msg"] = "OK %d/%d 条隧道健康，聚合出口正常" % (n_ok, len(active))
                # 全部健康时才评估要不要择优
                if now - last_opt >= int(rt("optimize_interval", 3600)):
                    last_opt = now
                    try:
                        if not optimize_check():
                            pass
                    except Exception:
                        pass
                # 实测带宽：串行跑在后台线程里，不阻塞守护
                if rt("speedtest", True) and now - last_speed >= int(rt("speedtest_interval", 43200)):
                    last_speed = now
                    try:
                        speedtest_all(background=True)
                    except Exception:
                        pass
                write_status()
                _wake.clear()
                _wake.wait(max(10, int(auto_cfg.get("interval", 30))))
                continue
            auto_cfg["status_msg"] = "正在后台恢复 %d 条隧道（其余继续服务）" % (len(active) - n_ok)
            write_status()
            used = set(t["node"] for t in alive if t["node"])
            pri = [auto_cfg.get("p1"), auto_cfg.get("p2"), auto_cfg.get("p3")]
            if pri and pri[0] == "AUTO":
                countries = None      # 自动：不限国家，靠评分（含地理优先）自己挑
            else:
                countries = [c for c in pri if c and c not in ("NONE", "AUTO")]
            if not countries and countries is not None:
                countries = ["JP"]
            for t in active:
                if t["healthy"]:
                    continue
                with cfg_lock:
                    t["attempts"] += 1
                limit = int(rt("candidates", 5))
                pool = rank_nodes(countries, exclude=used, limit=limit, allow_extra=True)
                if not pool:
                    pool = rank_nodes(countries, exclude=used, limit=limit, ignore_cap=True, allow_extra=True)
                if not pool and auto_cfg.get("mode", "auto") != "lock":
                    auto_cfg["status_msg"] = "优先国家无可用节点，临时放开到全部国家"
                    pool = rank_nodes(None, exclude=used, limit=limit, ignore_cap=True, allow_extra=True)
                pin = t.get("pinned")
                if pin and get_node_cfg(pin) and pin not in used \
                        and not (pin in bad_nodes and time.time() - bad_nodes[pin] < 600):
                    pool = [{"id": pin, "ip": pin, "country": t["country"] or "?",
                             "sessions": 0, "proto": "UDP"}] + \
                           [c for c in pool if c.get("id") != pin]
                got = False
                for cand in pool:
                    auto_cfg["status_msg"] = "恢复 %s：尝试 %s (%s) 并发%d" % (
                        t["dev"], cand.get("country", "?"), cand["ip"], cand.get("sessions", 0))
                    if connect_tunnel(t, cand["id"], wait=12):
                        used.add(cand["id"])
                        got = True
                        break
                    bad_nodes[cand["id"]] = time.time()
                if not got:
                    auto_cfg["status_msg"] = "本轮未找到可用节点 (%s)" % t["dev"]
        except Exception as e:
            auto_cfg["status_msg"] = "守护线程异常: %s" % e
        _wake.clear()
        if any((not t["healthy"]) and t.get("enabled", True) for t in TUNS):
            _wake.wait(5)
        else:
            _wake.wait(max(10, int(auto_cfg.get("interval", 30))))

def parse_cache():
    global cached_nodes, node_list_cache
    if not os.path.exists(CACHE_FILE):
        return
    with open(CACHE_FILE, "r", encoding="utf-8-sig", errors="ignore") as f:
        raw = f.read()
    raw = raw.replace("\r\r\n", "\n").replace("\r\n", "\n").replace("\r", "\n")
    lines = [l for l in raw.split("\n") if l.strip() and not l.startswith("*")]
    hi = next((i for i, l in enumerate(lines) if "OpenVPN_ConfigData_Base64" in l), None)
    if hi is None:
        return
    header = [h.strip().lstrip("#").strip() for h in lines[hi].split(",")]
    new_c, new_l = {}, []

    def num(r, k, d=0):
        v = (r.get(k) or "").strip()
        return int(v) if v.isdigit() else d

    for row in csv.reader(io.StringIO("\n".join(lines[hi + 1:]))):
        if len(row) < len(header):
            continue
        r = dict(zip(header, row))
        cfg, ip = r.get("OpenVPN_ConfigData_Base64"), (r.get("IP") or "").strip()
        if not cfg or not ip:
            continue
        try:
            ipaddress.ip_address(ip)
        except Exception:
            continue
        new_c[ip] = cfg
        port, proto = "1194", "udp"
        try:
            txt = base64.b64decode(cfg).decode("utf-8", "ignore")
            m = re.search(r"^remote\s+\S+\s+(\d+)", txt, re.M)
            if m:
                port = m.group(1)
            if re.search(r"^\s*proto\s+tcp", txt, re.M | re.I):
                proto = "tcp"
        except Exception:
            pass
        new_l.append({
            "id": ip, "ip": ip, "port": port, "proto": proto.upper(),
            "country": (r.get("CountryShort") or "UN").strip(),
            "country_long": (r.get("CountryLong") or "Unknown").strip(),
            "hostname": (r.get("HostName") or "").strip(),
            "operator": (r.get("Operator") or "").strip(),
            "message": (r.get("Message") or "").strip(),
            "ping": num(r, "Ping", 9999) or 9999,
            "speed": round(num(r, "Speed", 0) / 1000000.0, 1),
            "score": num(r, "Score", 0),
            "sessions": num(r, "NumVpnSessions", 0),
            "uptime": num(r, "Uptime", 0),
            "users": num(r, "TotalUsers", 0),
            "traffic": num(r, "TotalTraffic", 0),
        })
    for n in new_l:
        n["calc"] = round(node_score(n), 1)
    cached_nodes, node_list_cache = new_c, new_l
    merge_pool(new_l)
    build_pool_extra()

def refresh_cache_internal():
    ua = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")
    last = None
    for url in ("https://www.vpngate.net/api/iphone/", "http://www.vpngate.net/api/iphone/"):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": ua})
            with urllib.request.urlopen(req, timeout=25) as resp:
                content = resp.read().decode("utf-8", "ignore")
            if "OpenVPN_ConfigData_Base64" in content:
                content = content.replace("\r\r\n", "\n").replace("\r\n", "\n").replace("\r", "\n")
                with open(CACHE_FILE, "w", encoding="utf-8") as f:
                    f.write(content)
                parse_cache()
                return len(node_list_cache)
            last = "数据格式异常"
        except Exception as e:
            last = str(e)
    raise RuntimeError(last or "unknown")

def is_private_ip(ip):
    """私有/回环/链路本地地址不能出现在给客户端的链接里"""
    try:
        a = ipaddress.ip_address(ip)
    except Exception:
        return True
    return bool(a.is_private or a.is_loopback or a.is_link_local or a.is_reserved or a.is_multicast)

_IP_SOURCES = (
    "https://api.ipify.org", "https://ifconfig.me/ip", "https://ip.sb",
    "https://icanhazip.com", "https://ident.me", "https://api64.ipify.org",
)
_ip_cache = {"ip": (PUBLIC_IP if PUBLIC_IP and not is_private_ip(PUBLIC_IP) else ""),
             "ts": (time.time() if PUBLIC_IP and not is_private_ip(PUBLIC_IP) else 0.0)}

def detect_vps_country():
    """探测本机自己所在的国家（走本机原生出口，不经过任何隧道）"""
    global VPS_COUNTRY
    for url in ("https://ipinfo.io/json", "https://ipapi.co/json/", "https://ip-api.com/json/"):
        r = run(["curl", "-fsS4", "-m", "6", url], timeout=9)
        txt = (r.stdout or "").strip()
        if not txt.startswith("{"):
            continue
        try:
            d = json.loads(txt)
            cc = (d.get("country") or d.get("country_code") or "").strip().upper()
            if re.match(r"^[A-Z]{2}$", cc):
                VPS_COUNTRY = cc
                return cc
        except Exception:
            continue
    return None

# ---------------------------- 历史节点池 ----------------------------
_pool_ts = [0.0]

def load_pool():
    global node_pool
    node_pool = {}
    if os.path.exists(POOL_FILE):
        try:
            with open(POOL_FILE, "r", encoding="utf-8") as f:
                node_pool = json.load(f)
        except Exception:
            node_pool = {}

def save_pool(force=False):
    """历史池落盘。节流 10 分钟，别每次都写盘。"""
    now = time.time()
    if not force and now - _pool_ts[0] < 600:
        return
    _pool_ts[0] = now
    try:
        tmp = POOL_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(node_pool, f, ensure_ascii=False)
        os.replace(tmp, POOL_FILE)
    except Exception:
        pass

def merge_pool(live_nodes):
    """
    把本次 API 快照合并进历史池。
      在线节点：last_seen 更新、标记 live
      池里没出现的：保留，标记 !live（这是"越用越多"的关键 —— 不删）
      超过 pool_ttl_days 没再出现的：淘汰
    """
    now = time.time()
    ttl = int(rt("pool_ttl_days", 14)) * 86400
    live_ips = set()
    for n in live_nodes:
        ip = n["id"]
        live_ips.add(ip)
        e = node_pool.get(ip) or {"first_seen": now, "ok": 0, "fail": 0}
        e.update({
            "meta": {k: n[k] for k in ("ip", "port", "proto", "country", "country_long",
                                       "sessions", "speed", "ping", "users", "traffic",
                                       "hostname", "operator", "score", "calc") if k in n},
            "cfg": cached_nodes.get(ip, ""),      # 存下 .ovpn 才能重连历史节点
            "last_seen": now, "live": True,
        })
        node_pool[ip] = e
    # 标记本次没出现的
    for ip, e in list(node_pool.items()):
        if ip in live_ips:
            continue
        e["live"] = False
        if now - float(e.get("last_seen", 0)) > ttl:
            node_pool.pop(ip, None)
    save_pool()

def build_pool_extra():
    """当前不在快照里的历史节点，按最后在线时间倒序"""
    global pool_extra_cache
    out = []
    for ip, e in node_pool.items():
        if e.get("live"):
            continue
        m = dict(e.get("meta") or {})
        if not m.get("ip"):
            continue
        m["id"] = ip
        m["stale"] = True
        m["last_seen"] = int(e.get("last_seen", 0))
        m.setdefault("sessions", 0)
        m.setdefault("speed", 0.0)
        m.setdefault("ping", 9999)
        m.setdefault("users", 0)
        m.setdefault("traffic", 0)
        m["calc"] = round(node_score(m), 1)
        out.append(m)
    out.sort(key=lambda x: -x["last_seen"])
    pool_extra_cache = out
    return out

def pool_stats():
    live = len([1 for e in node_pool.values() if e.get("live")])
    us = len([1 for e in node_pool.values() if (e.get("meta") or {}).get("country") == "US"])
    return {"total": len(node_pool), "live": live,
            "extra": len(node_pool) - live, "us_total": us}

_ip_job = {"busy": False, "lock": threading.Lock()}

def _public_ip_worker():
    try:
        for url in _IP_SOURCES:
            r = run(["curl", "-fsS4", "-m", "4", url], timeout=6)
            ip = (r.stdout or "").strip().splitlines()[0].strip() if r.stdout else ""
            if re.match(r"^(\d{1,3}\.){3}\d{1,3}$", ip) and not is_private_ip(ip):
                _ip_cache["ip"] = ip
                _ip_cache["ts"] = time.time()
                return
        _ip_cache["ts"] = time.time() - 3000   # 失败后 5 分钟再试
    finally:
        with _ip_job["lock"]:
            _ip_job["busy"] = False

def public_ip():
    """永不阻塞：有缓存就返回，没有就先返回旧值并让后台线程去探测"""
    now = time.time()
    if _ip_cache["ip"] and now - _ip_cache["ts"] < 3600:
        return _ip_cache["ip"]
    with _ip_job["lock"]:
        if not _ip_job["busy"]:
            _ip_job["busy"] = True
            threading.Thread(target=_public_ip_worker, daemon=True, name="pubip").start()
    return _ip_cache["ip"]

def _parse_ss(text):
    """解析 ss -lntuH 的输出 -> (tcp端口集合, udp端口集合)"""
    tcp, udp = set(), set()
    for line in (text or "").splitlines():
        s = line.strip()
        if not s:
            continue
        proto = s.split()[0].lower() if s.split() else ""
        if not (proto.startswith("tcp") or proto.startswith("udp")):
            continue
        # 本地地址在倒数第二个字段：0.0.0.0:10808 / 127.0.0.1:8501 / [::]:10808 / *:5000
        fields = s.split()
        addr = ""
        for f in fields:
            if re.match(r"^(\*|[\d.]+|\[[0-9a-fA-F:]*\]):\d+$", f) or re.match(r"^\[[0-9a-fA-F:]*\]:\d+$", f):
                addr = f
                break
        if not addr:
            m = re.search(r":(\d+)\s", s)
            if not m:
                continue
            port = int(m.group(1))
        else:
            port = int(addr.rsplit(":", 1)[1])
        (udp if proto.startswith("udp") else tcp).add(port)
    return tcp, udp

def port_status():
    """本机实际监听情况 —— 用来区分『没监听』和『云防火墙没放行』"""
    want_tcp = {PANEL_PORT, SOCKS5_PORT, SS_PORT, SS2022_PORT}
    if STICKY:
        want_tcp |= {STICKY_BASE + i for i in range(TUNNELS)}
    want_udp = {SSU_PORT}
    tcp_set, udp_set = set(), set()
    for args in (["ss", "-lntuH"], ["ss", "-lntu"], ["netstat", "-lntu"]):
        r = run(args, timeout=8)
        if (r.stdout or "").strip():
            tcp_set, udp_set = _parse_ss(r.stdout)
            if tcp_set or udp_set:
                break
    if not tcp_set and not udp_set:
        # ss/netstat 都不可用 —— 不要误报"端口没监听"
        return {"tcp": {}, "udp": {}, "missing": [], "unknown": True,
                "gost_active": (run(["systemctl", "is-active", "vpngate-gost"], timeout=5).stdout or "").strip()}
    tcp = {p: (p in tcp_set) for p in sorted(want_tcp)}
    udp = {p: (p in udp_set) for p in sorted(want_udp)}
    missing = [p for p, ok in list(tcp.items()) + list(udp.items()) if not ok]
    return {
        "tcp": tcp, "udp": udp, "missing": missing, "unknown": False,
        "gost_active": (run(["systemctl", "is-active", "vpngate-gost"], timeout=5).stdout or "").strip(),
    }

def build_endpoints():
    ip = public_ip()
    host_ok = bool(ip)
    u = CRED_USER
    out = []

    def add(group, name, proto, port, socks, http, note, state):
        out.append({
            "group": group, "name": name, "proto": proto, "port": port,
            "user": u, "host": ip, "host_ok": host_ok,
            "socks": socks, "http": http, "note": note, "state": state,
        })

    if STICKY:
        for t in TUNS:
            p = STICKY_BASE + t["idx"]
            add("sticky", "%s 粘性出口" % t["dev"], "SOCKS5 + HTTP", p,
                "socks5://%s:%s@%s:%d" % (u, SOCKS5_PASS, ip, p),
                "http://%s:%s@%s:%d" % (u, SOCKS5_PASS, ip, p),
                "固定只走 %s，出口 IP 不跳动（该节点掉线时会重新选节点，IP 也会随之变化）" % t["dev"],
                ("%s %s" % (t["country"] or "-", t["exit_ip"] or "")) if t["healthy"] else "该隧道当前离线")
    add("agg", "聚合出口", "SOCKS5 + HTTP", SOCKS5_PORT,
        "socks5://%s:%s@%s:%d" % (u, SOCKS5_PASS, ip, SOCKS5_PORT),
        "http://%s:%s@%s:%d" % (u, SOCKS5_PASS, ip, SOCKS5_PORT),
        "出口在 %d 条隧道间轮询，速度叠加，但 IP 会变" % TUNNELS,
        "轮询 %d 条隧道" % TUNNELS)

    ss_b64 = base64.b64encode(("aes-256-gcm:%s" % SS_PASS).encode()).decode()
    add("ss", "Shadowsocks", "ss aes-256-gcm", SS_PORT,
        "ss://%s@%s:%d#VPN-Gate-SS" % (ss_b64, ip, SS_PORT), "",
        "老客户端兼容性最好", "TCP")
    if SS2022_PASS:
        s22 = base64.b64encode(("2022-blake3-aes-256-gcm:%s" % SS2022_PASS).encode()).decode()
        add("ss", "Shadowsocks 2022", "ss blake3-aes-256-gcm", SS2022_PORT,
            "ss://%s@%s:%d#VPN-Gate-SS2022" % (s22, ip, SS2022_PORT), "",
            "防重放，需要客户端支持 SS2022", "TCP")
        add("udp", "SS UDP 中继", "ssu 2022-blake3", SSU_PORT,
            "ssu://2022-blake3-aes-256-gcm:%s@%s:%d" % (SS2022_PASS, ip, SSU_PORT), "",
            "Telegram 语音 / 游戏 / QUIC 网站", "UDP")
    return out

load_pool()          # 先载入历史池，parse_cache 才能把新快照合并进去
try:
    os.makedirs(RUN_DIR, exist_ok=True)
except Exception:
    pass
parse_cache()
build_pool_extra()
threading.Thread(target=detect_vps_country, daemon=True, name="geo").start()
threading.Thread(target=watchdog_thread, daemon=True, name="watchdog").start()
for _t in TUNS:
    threading.Thread(target=tunnel_monitor, args=(_t,), daemon=True, name="mon-%s" % _t["dev"]).start()

LOGIN_HTML = r"""<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>登录 · VPN Gate</title>
<style>
:root{--bg:#0b0d12;--card:#151821;--line:#242938;--txt:#e6e9f2;--dim:#8b93a7;
--acc:#4f8cff;--ok:#22c55e;--bad:#ef4444}
*{box-sizing:border-box;margin:0;padding:0}
body{min-height:100vh;display:grid;place-items:center;
background:radial-gradient(1200px 600px at 20% -10%,#1b2440 0%,transparent 60%),
radial-gradient(900px 500px at 110% 110%,#172a33 0%,transparent 55%),var(--bg);
color:var(--txt);font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,
"Helvetica Neue",Arial,"PingFang SC","Microsoft YaHei",sans-serif}
.box{width:min(92vw,380px);background:rgba(21,24,33,.92);border:1px solid var(--line);
border-radius:18px;padding:34px 30px;box-shadow:0 24px 60px rgba(0,0,0,.55)}
.logo{font-size:26px;margin-bottom:6px}
h1{font-size:19px;font-weight:650;letter-spacing:.2px}
.sub{color:var(--dim);font-size:13px;margin:6px 0 22px}
label{display:block;font-size:12px;color:var(--dim);margin:14px 0 6px;letter-spacing:.3px}
input{width:100%;padding:11px 13px;border-radius:10px;border:1px solid var(--line);
background:#0e1118;color:var(--txt);font-size:14px;outline:none;transition:.18s}
input:focus{border-color:var(--acc);box-shadow:0 0 0 3px rgba(79,140,255,.15)}
button{width:100%;margin-top:22px;padding:12px;border:0;border-radius:10px;cursor:pointer;
background:linear-gradient(180deg,#5b93ff,#3f7bf0);color:#fff;font-size:14px;font-weight:600;
transition:.18s;box-shadow:0 6px 18px rgba(79,140,255,.28)}
button:hover{filter:brightness(1.08)}button:disabled{opacity:.55;cursor:not-allowed}
.err{margin-top:14px;font-size:13px;color:#ffb4b4;background:rgba(239,68,68,.12);
border:1px solid rgba(239,68,68,.35);border-radius:9px;padding:9px 12px;display:none}
.foot{margin-top:18px;font-size:11.5px;color:#5c6478;text-align:center;line-height:1.7}
</style></head><body>
<form class="box" onsubmit="return doLogin(event)">
  <div class="logo">🌐</div>
  <h1>VPN Gate 控制台</h1>
  <div class="sub">输入账号密码进入管理面板</div>
  <label>账号</label>
  <input id="u" autocomplete="username" autofocus>
  <label>密码</label>
  <input id="p" type="password" autocomplete="current-password">
  <button id="btn" type="submit">登录</button>
  <div class="err" id="err"></div>
  <div class="foot">连续输错 6 次将锁定 2 分钟</div>
</form>
<script>
async function doLogin(e){
  e.preventDefault();
  var b=document.getElementById("btn"), er=document.getElementById("err");
  b.disabled=true; b.textContent="验证中..."; er.style.display="none";
  try{
    var r=await fetch("/api/login",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({user:document.getElementById("u").value,pass:document.getElementById("p").value})});
    var d=await r.json();
    if(r.ok&&d.ok){ location.href="/"; return false; }
    er.textContent=d.msg||"登录失败"; er.style.display="block";
  }catch(x){ er.textContent="网络错误"; er.style.display="block"; }
  b.disabled=false; b.textContent="登录";
  return false;
}
</script></body></html>"""

APP_HTML = r"""<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>VPN Gate 控制台</title>
<style>
:root{--bg:#0b0d12;--card:#151821;--card2:#1b1f2b;--line:#242938;--txt:#e6e9f2;
--dim:#8b93a7;--dim2:#5c6478;--acc:#4f8cff;--ok:#22c55e;--warn:#f59e0b;--bad:#ef4444;--r:14px;
--input:#0e1118;--th:#12151d;--hover:#171b25;--code:#0e1118;--toast:#1b2130;--top:rgba(11,13,18,.82);
--glow1:#18213a;--glow2:#152a2f;--oktxt:#8ef0b4;--warntxt:#ffd28a;--badtxt:#ffb4b4;--acctxt:#cfe0ff;
--shadow:0 12px 30px rgba(0,0,0,.5)}
body.light{--bg:#eef1f7;--card:#ffffff;--card2:#f5f7fc;--line:#dde3ee;--txt:#1b2233;
--dim:#5b657a;--dim2:#8d95a8;--acc:#2563eb;--ok:#16a34a;--warn:#d97706;--bad:#dc2626;
--input:#ffffff;--th:#f1f4fa;--hover:#eef3fc;--code:#f4f6fb;--toast:#ffffff;--top:rgba(255,255,255,.85);
--glow1:#dfe8fb;--glow2:#dff1f4;--oktxt:#15803d;--warntxt:#b45309;--badtxt:#b91c1c;--acctxt:#1d4ed8;
--shadow:0 12px 30px rgba(30,41,59,.14)}
*{box-sizing:border-box;margin:0;padding:0}
body{background:radial-gradient(1100px 500px at 8% -10%,var(--glow1) 0%,transparent 55%),
radial-gradient(900px 460px at 105% 0%,var(--glow2) 0%,transparent 50%),var(--bg);
color:var(--txt);min-height:100vh;font:14px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,
"Helvetica Neue",Arial,"PingFang SC","Microsoft YaHei",sans-serif;padding-bottom:60px;
transition:background .25s,color .25s}
.wrap{max-width:1180px;margin:0 auto;padding:0 18px}
.top{position:sticky;top:0;z-index:40;background:var(--top);border-bottom:1px solid var(--line);
backdrop-filter:blur(10px)}
.top .wrap{display:flex;align-items:center;gap:10px;height:60px;flex-wrap:wrap}
.brand{font-size:16px;font-weight:650;display:flex;align-items:center;gap:8px;white-space:nowrap}
.pill{font-size:12px;padding:4px 11px;border-radius:99px;border:1px solid var(--line);
background:var(--card2);color:var(--dim);white-space:nowrap}
.pill.ok{color:var(--oktxt);border-color:rgba(34,197,94,.45);background:rgba(34,197,94,.12)}
.pill.warn{color:var(--warntxt);border-color:rgba(245,158,11,.45);background:rgba(245,158,11,.12)}
.pill.bad{color:var(--badtxt);border-color:rgba(239,68,68,.45);background:rgba(239,68,68,.12)}
.sp{flex:1}
.iconbtn{background:var(--card2);border:1px solid var(--line);color:var(--txt);border-radius:9px;
padding:7px 12px;font-size:13px;cursor:pointer;transition:.16s;white-space:nowrap;font-family:inherit}
.iconbtn:hover{border-color:var(--acc);color:var(--acctxt)}
.iconbtn.danger:hover{border-color:var(--bad);color:var(--badtxt)}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(165px,1fr));gap:12px;margin:20px 0}
.stat{background:var(--card);border:1px solid var(--line);border-radius:var(--r);padding:15px 16px}
.stat .k{font-size:11.5px;color:var(--dim);letter-spacing:.4px}
.stat .v{font-size:21px;font-weight:680;margin-top:5px;letter-spacing:.2px}
.stat .s{font-size:11.5px;color:var(--dim2);margin-top:2px;line-height:1.5}
.flag{font-family:"Apple Color Emoji","Segoe UI Emoji","Noto Color Emoji","Twemoji Mozilla",sans-serif;
font-size:15px;letter-spacing:-.5px}
.tgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:12px;margin-bottom:14px}
.tcard{background:var(--card);border:1px solid var(--line);border-radius:var(--r);padding:15px 16px;
position:relative;overflow:hidden;transition:.18s}
.tcard::before{content:"";position:absolute;left:0;top:0;bottom:0;width:3px;background:var(--dim2)}
.tcard.up::before{background:var(--ok)}.tcard.down::before{background:var(--bad)}
.tcard:hover{border-color:var(--dim2)}
.tcard .h{display:flex;align-items:center;gap:8px;font-weight:650;font-size:14px}
.dot{width:8px;height:8px;border-radius:50%;background:var(--dim2);flex:none}
.dot.g{background:var(--ok);box-shadow:0 0 0 3px rgba(34,197,94,.16)}
.dot.r{background:var(--bad);box-shadow:0 0 0 3px rgba(239,68,68,.16)}
.tcard .row{display:flex;justify-content:space-between;gap:10px;font-size:12.5px;margin-top:7px;color:var(--dim)}
.tcard .row b{color:var(--txt);font-weight:550;text-align:right;word-break:break-all}
.tcard .acts{display:flex;gap:7px;margin-top:11px;flex-wrap:wrap}
.mini{flex:1;min-width:74px;background:var(--card2);border:1px solid var(--line);color:var(--txt);
border-radius:8px;padding:6px;font-size:12px;cursor:pointer;transition:.16s;font-family:inherit}
.mini:hover{border-color:var(--acc);color:var(--acctxt)}
.mini.accent{border-color:rgba(79,140,255,.45);color:var(--acctxt)}
.explain{background:var(--card);border:1px solid var(--line);border-radius:var(--r);
padding:0 16px;margin-bottom:14px;overflow:hidden}
.explain summary{cursor:pointer;padding:13px 0;font-weight:650;font-size:13.5px;list-style:none;
display:flex;align-items:center;gap:8px}
.explain summary::-webkit-details-marker{display:none}
.explain summary::before{content:"▸";color:var(--acc);transition:.2s}
.explain[open] summary::before{transform:rotate(90deg)}
.explain .body{padding:0 0 16px;font-size:12.8px;line-height:1.85;color:var(--dim)}
.explain .body b{color:var(--txt)}
.explain .body code{background:var(--code);border:1px solid var(--line);border-radius:5px;
padding:1px 6px;font-family:ui-monospace,Menlo,monospace;font-size:11.5px;color:var(--txt)}
.explain table{width:100%;border-collapse:collapse;margin:9px 0;font-size:12.5px}
.explain th,.explain td{border-bottom:1px solid var(--line);padding:7px 9px;text-align:left;color:var(--dim)}
.explain th{background:var(--th);color:var(--txt);font-weight:600}
.tabs{display:flex;gap:4px;border-bottom:1px solid var(--line);margin:20px 0 16px;overflow-x:auto}
.tab{padding:10px 15px;cursor:pointer;font-size:13.5px;color:var(--dim);
border-bottom:2px solid transparent;white-space:nowrap;transition:.16s}
.tab:hover{color:var(--txt)}
.tab.on{color:var(--acc);border-bottom-color:var(--acc);font-weight:600}
.panel{display:none}.panel.on{display:block}
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--r);
padding:16px 18px;margin-bottom:12px}
.card h3{font-size:14px;font-weight:650;margin-bottom:12px;display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.card h3 .tag{font-size:11px;font-weight:500;color:var(--dim);border:1px solid var(--line);
border-radius:6px;padding:1px 7px;background:var(--card2)}
.ep{border:1px solid var(--line);border-radius:11px;padding:12px 14px;margin-bottom:9px;
background:var(--card2)}
.ep .t{display:flex;align-items:center;gap:9px;flex-wrap:wrap}
.ep .nm{font-weight:600;font-size:13.5px}
.ep .pt{font-size:11.5px;color:var(--dim);border:1px solid var(--line);border-radius:6px;padding:1px 7px}
.ep .lk{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px;
margin-top:8px;color:var(--acctxt);word-break:break-all;background:var(--code);
border:1px solid var(--line);border-radius:8px;padding:8px 10px;cursor:pointer;transition:.16s}
.ep .lk:hover{border-color:var(--acc)}
.ep .nt{font-size:11.5px;color:var(--dim2);margin-top:6px}
.ep .st{font-size:11.5px;color:var(--dim);margin-left:auto}
.eye{background:none;border:1px solid var(--line);color:var(--dim);border-radius:7px;
cursor:pointer;padding:2px 9px;font-size:12px;font-family:inherit}
.eye:hover{color:var(--txt);border-color:var(--acc)}
.tw{overflow-x:auto;border:1px solid var(--line);border-radius:var(--r);background:var(--card)}
table{width:100%;border-collapse:collapse;font-size:12.5px;min-width:1120px}
table.narrow{min-width:0}
th,td{padding:9px 10px;text-align:left;border-bottom:1px solid var(--line);white-space:nowrap}
th{color:var(--dim);font-weight:550;font-size:11.5px;background:var(--th)}
tbody tr:hover td{background:var(--hover)}
td.wrap{white-space:normal;max-width:190px;line-height:1.45}
.bd{font-size:11px;padding:2px 8px;border-radius:5px;font-weight:600}
.bd.g{color:var(--oktxt);background:rgba(34,197,94,.14)}
.bd.r{color:var(--badtxt);background:rgba(239,68,68,.14)}
.bd.n{color:var(--dim);background:var(--card2)}
.hot{color:#ef4444}.cool{color:#16a34a}
.grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:13px}
.fld label{display:block;font-size:11.5px;color:var(--dim);margin-bottom:5px}
.fld input,.fld select{width:100%;padding:9px 11px;border-radius:9px;border:1px solid var(--line);
background:var(--input);color:var(--txt);font-size:13px;outline:none;transition:.16s;font-family:inherit}
.fld input:focus,.fld select:focus{border-color:var(--acc);
box-shadow:0 0 0 3px rgba(79,140,255,.16)}
.fld .hint{font-size:11px;color:var(--dim2);margin-top:4px;line-height:1.5}
.btnrow{display:flex;gap:9px;margin-top:16px;flex-wrap:wrap}
.btn{background:linear-gradient(180deg,#5b93ff,#3f7bf0);border:0;color:#fff;border-radius:9px;
padding:9px 18px;font-size:13px;font-weight:600;cursor:pointer;transition:.16s;font-family:inherit}
.btn:hover{filter:brightness(1.08)}
.btn.ghost{background:var(--card2);border:1px solid var(--line);color:var(--txt);font-weight:500}
.btn.ghost:hover{border-color:var(--acc);color:var(--acctxt)}
.btn.red{background:linear-gradient(180deg,#f36b6b,#e04a4a)}
.ro{opacity:.7}
#toast{position:fixed;right:18px;bottom:18px;display:flex;flex-direction:column;gap:9px;z-index:99}
.tst{background:var(--toast);border:1px solid var(--line);border-left:3px solid var(--acc);
border-radius:10px;padding:11px 15px;font-size:13px;box-shadow:var(--shadow);max-width:340px}
.tst.ok{border-left-color:var(--ok)}.tst.bad{border-left-color:var(--bad)}
.mut{color:var(--dim2);font-size:12px}
.banner{border-radius:11px;padding:11px 14px;font-size:12.5px;line-height:1.65;margin-bottom:14px;
border:1px solid var(--line);background:var(--card2);color:var(--dim)}
.banner.ok{border-color:rgba(34,197,94,.35);background:rgba(34,197,94,.09);color:var(--oktxt)}
.banner.warn{border-color:rgba(245,158,11,.4);background:rgba(245,158,11,.1);color:var(--warntxt)}
.banner.bad{border-color:rgba(239,68,68,.42);background:rgba(239,68,68,.1);color:var(--badtxt)}
.banner b{color:inherit;font-weight:650}
.banner code{background:var(--code);border:1px solid var(--line);border-radius:5px;
padding:1px 5px;font-family:ui-monospace,Menlo,monospace;font-size:11.5px}
#mask{position:fixed;inset:0;background:rgba(6,8,12,.72);display:none;place-items:center;
z-index:120;padding:20px}
#nodeMask{position:fixed;inset:0;background:rgba(6,8,12,.72);display:none;place-items:center;
z-index:125;padding:20px}
.modal{width:min(94vw,460px);background:var(--card);border:1px solid var(--line);
border-radius:16px;padding:24px;box-shadow:var(--shadow);max-height:86vh;overflow:auto}
.modal h4{font-size:15px;margin-bottom:4px}
.modal .fld{margin-top:14px}
.kv{display:flex;justify-content:space-between;gap:14px;padding:6px 0;
border-bottom:1px solid var(--line);font-size:12.5px}
.kv span{color:var(--dim);flex:none}
.kv b{text-align:right;word-break:break-all;font-weight:550}
</style></head><body>

<div class="top"><div class="wrap">
  <div class="brand">🌐 VPN Gate</div>
  <span class="pill" id="pHealth">检测中</span>
  <span class="pill" id="pExit">出口 -</span>
  <div class="sp"></div>
  <button class="iconbtn" id="btnTheme" onclick="toggleTheme()">🌗 主题</button>
  <button class="iconbtn" id="btnPriv" onclick="togglePriv()">🔒 隐私模式</button>
  <button class="iconbtn" onclick="reloadAll()">刷新</button>
  <button class="iconbtn" onclick="openPwd()">改密码</button>
  <button class="iconbtn danger" onclick="logout()">登出</button>
</div></div>

<div class="wrap">
  <div id="banner"></div>
  <div class="stats">
    <div class="stat"><div class="k">隧道健康</div><div class="v" id="sHealth">-</div><div class="s" id="sHealthS">-</div></div>
    <div class="stat"><div class="k">当前聚合出口</div><div class="v" id="sExit" style="font-size:16px">-</div><div class="s" id="sExitS">-</div></div>
    <div class="stat"><div class="k">可用节点</div><div class="v" id="sNodes">-</div><div class="s" id="sNodesS">-</div></div>
    <div class="stat"><div class="k">守护状态</div><div class="v" id="sMsg" style="font-size:12.5px;font-weight:500;line-height:1.5">-</div><div class="s" id="sMsgS"></div></div>
  </div>

  <details class="explain" id="explainTunnels">
    <summary>❓ 什么是「隧道」？为什么有两条？连接时到底走哪一条？</summary>
    <div class="body">
      <p><b>一条隧道 = 一条独立的 OpenVPN 连接 = 一个家宽出口。</b>
      每条隧道连到一台不同国家/不同家庭的电脑（VPN Gate 的志愿者节点），<b>各自有各自的出口 IP、带宽和延迟</b>。
      所以 <code>tun0</code> 和 <code>tun1</code> 不是"主备"关系，而是<b>两个平行的出口</b>。</p>

      <p><b>为什么要两条？</b> 三个原因：</p>
      <ul style="margin:8px 0 8px 20px">
        <li><b>带宽叠加</b>：一条隧道的速度取决于那台家宽电脑（往往只有 5~30Mbps）。两条并行，浏览器/视频的分段请求可以分摊，总吞吐接近翻倍。</li>
        <li><b>抗单点故障</b>：志愿者的电脑随时会关机。两条里掉一条，另一条继续服务，业务只损失一半而不是全断。</li>
        <li><b>故障切换不用等</b>：一条挂掉时另一条<b>已经连好在线</b>，不用临时找节点等握手。</li>
      </ul>
      <p class="mut">你的机器是 1 核，安装脚本自动把隧道数从 3 降到了 2（OpenVPN 是单线程，隧道越多越抢 CPU）。
      4 核以上可以用 <code>TUNNELS=4 bash install.sh</code>。</p>

      <p style="margin-top:14px"><b>连接时走哪一条？取决于你用哪个端口：</b></p>
      <table>
        <tr><th>你用的端口</th><th>实际走哪条隧道</th></tr>
        <tr><td>聚合口 <code>10808</code></td><td><b>不确定</b> —— gost 按<b>新建连接逐条轮询</b>分配（第 1 个连接走 tun0、第 2 个走 tun1、第 3 个又回到 tun0…），一条连不上会自动落到下一条。同一个网站的两次请求可能来自两个不同的家宽 IP。</td></tr>
        <tr><td>粘性口 <code>10818</code></td><td><b>一定</b>只走 tun0</td></tr>
        <tr><td>粘性口 <code>10819</code></td><td><b>一定</b>只走 tun1</td></tr>
      </table>
      <p><b>所以「用哪条隧道连接」不用按钮选，用端口选就行</b> —— 想固定走某一条，就复制那张隧道卡片上的「专属端口」。
      卡片上还会显示这条隧道当前的出口 IP 和真实延迟，方便你判断哪条更好。</p>

      <p style="margin-top:14px"><b>刷新频率：</b>页面每 <b id="tPanel">8</b> 秒拉一次数据；
      后端巡检正常时每 <b id="tWd">30</b> 秒一轮、出故障时每 5 秒一轮；
      隧道掉线检测是 <b>1 秒</b>级（设备消失）+ <b>3 秒</b>级（出网探测），连续 2 次失败才判死。</p>
      <p class="mut">这些数值都能在「参数设置」里改。状态卡片上的「上次巡检」是后端最近一轮的时间。</p>
    </div>
  </details>

  <div class="tgrid" id="tgrid"></div>

  <div class="tabs">
    <div class="tab on" data-t="ep" onclick="tab('ep')">接入链接</div>
    <div class="tab" data-t="nodes" onclick="tab('nodes')">节点列表</div>
    <div class="tab" data-t="cfg" onclick="tab('cfg')">参数设置</div>
    <div class="tab" data-t="diag" onclick="tab('diag')">诊断</div>
  </div>

  <div class="panel on" id="p-ep">
    <div class="card">
      <h3>接入方式 <span class="tag">密码默认打码，点「显示」才出现</span></h3>
      <div class="mut" style="margin-bottom:12px">粘性出口固定走一条隧道，出口 IP 不跳动（节点掉线重连时 IP 会变）。聚合出口在多条隧道间轮询，带宽更足但 IP 会变。</div>
      <div id="eplist"></div>
    </div>
  </div>

  <div class="panel" id="p-nodes">
    <div class="card">
      <h3>节点列表 <span class="tag" id="nodeCount">-</span></h3>
      <div class="grid2" style="margin-bottom:12px">
        <div class="fld"><label>国家</label><select id="fCountry" onchange="loadNodes(1)"></select></div>
        <div class="fld"><label>协议</label><select id="fProto" onchange="loadNodes(1)">
          <option value="ALL">全部</option><option value="UDP">仅 UDP</option><option value="TCP">仅 TCP</option></select></div>
        <div class="fld"><label>排序</label><select id="fSort" onchange="loadNodes(1)">
          <option value="calc">智能评分</option><option value="sessions">并发人数</option>
          <option value="speed">带宽</option><option value="ping">延迟</option></select></div>
        <div class="fld"><label>&nbsp;</label><button class="btn" style="width:100%" onclick="loadNodes(curPage)">刷新并测活</button></div>
      </div>
      <div class="tw"><table><thead><tr>
        <th>国家</th><th>主机 / 运营商</th><th>IP:端口</th><th>协议</th><th>并发</th>
        <th>带宽</th><th>实测RTT</th><th>累计流量</th><th>评分</th><th>状态</th><th>操作</th>
      </tr></thead><tbody id="nbody"><tr><td colspan="11" class="mut">加载中...</td></tr></tbody></table></div>
      <div class="btnrow" style="justify-content:space-between;align-items:center">
        <span class="mut" id="pageInfo">-</span>
        <span style="display:flex;gap:8px">
          <button class="btn ghost" id="btnPrev" onclick="loadNodes(curPage-1)">上一页</button>
          <button class="btn ghost" id="btnNext" onclick="loadNodes(curPage+1)">下一页</button>
        </span>
      </div>
    </div>
  </div>

  <div class="panel" id="p-cfg">
    <div class="card">
      <h3>自动切换 <span class="tag" id="vpsGeo">VPS 位置检测中...</span></h3>
      <div class="grid2">
        <div class="fld"><label>第一顺位</label><select id="cP1"></select>
          <div class="hint">选「自动」= 不限国家，让评分自己挑（同国节点有加分）</div></div>
        <div class="fld"><label>第二顺位</label><select id="cP2"></select></div>
        <div class="fld"><label>第三顺位</label><select id="cP3"></select></div>
        <div class="fld"><label>巡检间隔（秒）</label><input type="number" id="cInt" min="15" max="300">
          <div class="hint">全部健康时的轮询间隔；断线是 1 秒级事件触发，不受这个影响</div></div>
      </div>
      <div class="btnrow">
        <button class="btn ghost" onclick="loadGeo()">测一下各国实际延迟</button>
        <span class="mut" style="align-self:center">用来判断「第一顺位该选哪个国家」</span>
      </div>
      <div id="geoBox" style="margin-top:12px"></div>
    </div>
    <div class="card">
      <h3>节点池 <span class="tag" id="poolTag">-</span></h3>
      <div class="grid2">
        <div class="fld"><label>地理优先</label><select id="cGeo">
          <option value="1">开启：同国节点加分</option><option value="0">关闭</option></select>
          <div class="hint">VPS 在哪个国家，就给那个国家的节点加 8 分（总分 100）</div></div>
        <div class="fld"><label>历史节点后备</label><select id="cPoolExtra">
          <option value="1">开启：在线节点不够时用历史节点</option><option value="0">关闭</option></select>
          <div class="hint">VPN Gate 每次只给约 99 个节点。开启后会把每天见过的节点累积起来，
            小国家（如美国）的可用节点会随时间变多</div></div>
        <div class="fld"><label>历史节点保留天数</label><input type="number" id="cPoolTtl" min="1" max="365">
          <div class="hint">超过这么多天没再出现的节点自动淘汰</div></div>
      </div>
    </div>
    <div class="card">
      <h3>节点筛选 <span class="tag">保存后立即生效</span></h3>
      <div class="grid2">
        <div class="fld"><label>并发上限（超过则排除）</label><input type="number" id="cCap" min="1" max="300">
          <div class="hint">越小越能抢到冷门节点，可选节点也越少。默认 60</div></div>
        <div class="fld"><label>每条隧道最多试几个候选</label><input type="number" id="cCand" min="1" max="20"></div>
        <div class="fld"><label>优先协议</label><select id="cTcp">
          <option value="0">UDP 优先（更快）</option><option value="1">TCP 优先（机房封 UDP 时）</option></select></div>
      </div>
    </div>
    <div class="card">
      <h3>隧道调优 <span class="tag">下次重连生效</span></h3>
      <div class="grid2">
        <div class="fld"><label>MSS 钳制 mssfix</label><input type="number" id="cMss" min="1000" max="1460">
          <div class="hint">跨境高丢包或谷歌云可降到 1240</div></div>
        <div class="fld"><label>断链判定 ping-restart（秒）</label><input type="number" id="cPingR" min="5" max="120"></div>
        <div class="fld"><label>设备轮询间隔（秒）</label><input type="number" id="cFast" min="0.5" max="10" step="0.5">
          <div class="hint">越小发现掉线越快，CPU 略高</div></div>
        <div class="fld"><label>出网探测间隔（秒）</label><input type="number" id="cHealth" min="2" max="30"></div>
      </div>
      <div class="btnrow">
        <button class="btn" onclick="saveCfg()">保存参数</button>
        <button class="btn ghost" onclick="loadCfg()">放弃修改</button>
      </div>
    </div>
    <div class="card ro">
      <h3>需要重装才能改 <span class="tag">只读</span></h3>
      <div class="grid2">
        <div class="fld"><label>隧道条数</label><input id="rTun" disabled></div>
        <div class="fld"><label>粘性端口</label><input id="rSticky" disabled></div>
        <div class="fld"><label>接入端口</label><input id="rPorts" disabled></div>
        <div class="fld"><label>路由表</label><input id="rTable" disabled></div>
      </div>
      <div class="mut" style="margin-top:10px">改这些要重跑 install.sh（会改 systemd 单元和 gost 监听）。</div>
    </div>
    <div class="card">
      <h3>自动优选 <span class="tag">只换明显更差的节点</span></h3>
      <div class="grid2">
        <div class="fld"><label>启用自动优选</label><select id="cOpt">
          <option value="1">开启（推荐）</option><option value="0">关闭</option></select>
          <div class="hint">节点还活着但明显变慢时，自动换下一个。换节点时该隧道的出口 IP 会变</div></div>
        <div class="fld"><label>慢几倍才换</label><input type="number" id="cOptRatio" min="1.2" max="10" step="0.1">
          <div class="hint">当前延迟超过"最好候选"的 2.5 倍才动，避免无意义切换</div></div>
        <div class="fld"><label>延迟地板（ms）</label><input type="number" id="cOptFloor" min="50" max="2000">
          <div class="hint">低于这个值一律不换，哪怕比例超了</div></div>
        <div class="fld"><label>评估间隔（秒）</label><input type="number" id="cOptInt" min="600" max="86400"></div>
      </div>
    </div>
    <div class="card">
      <h3>出问题通知 <span class="tag">平时完全静默</span></h3>
      <div class="grid2">
        <div class="fld"><label>Webhook 地址（留空=不通知）</label><input id="cNotifyUrl" placeholder="https://...">
          <div class="hint">只有「全部隧道连续 3 轮不通」和「恢复」时才会推一条</div></div>
        <div class="fld"><label>格式</label><select id="cNotifyKind">
          <option value="json">通用 JSON {"text": "..."}</option>
          <option value="telegram">Telegram Bot（需填 chat_id）</option></select></div>
        <div class="fld"><label>Telegram chat_id（仅 telegram 格式）</label><input id="cNotifyChat" placeholder="123456789"></div>
        <div class="fld"><label>同类告警最短间隔（秒）</label><input type="number" id="cNotifyGap" min="60" max="86400"></div>
      </div>
      <div class="btnrow"><button class="btn ghost" onclick="testNotify()">发一条测试通知</button></div>
    </div>
    <div class="card">
      <h3>实测带宽 <span class="tag">会给每条隧道产生流量</span></h3>
      <div class="grid2">
        <div class="fld"><label>启用自动测速</label><select id="cSpd" onchange="updSpdEst()">
          <option value="1">开启</option><option value="0">关闭（只用按钮手动测）</option></select></div>
        <div class="fld"><label>每次下载大小（MB）</label><input type="number" id="cSpdMb" min="1" max="50" step="1" onchange="updSpdEst()">
          <div class="hint">越大越准，流量也越多。3MB 通常够看出量级</div></div>
        <div class="fld"><label>测速间隔（秒）</label><input type="number" id="cSpdInt" min="300" max="604800" onchange="updSpdEst()">
          <div class="hint">43200 = 12 小时一次；3600 = 每小时</div></div>
        <div class="fld"><label>预估流量</label><input id="cSpdEst" disabled>
          <div class="hint">按当前隧道条数 × 大小 × 频率算，含 2 倍安全余量</div></div>
      </div>
      <div class="btnrow"><button class="btn ghost" onclick="act('speedtest','立即测速')">立即测速一次</button></div>
      <div class="mut" style="margin-top:10px">
        测速原理：从 Cloudflare 边缘节点下载固定大小的数据，测的是「VPS → 家宽节点 → CDN」这条完整链路。
        串行执行（一条测完再测下一条），避免互相抢 VPS 上行口把数字测偏。
      </div>
    </div>
    <div class="card">
      <h3>维护动作</h3>
      <div class="btnrow">
        <button class="btn ghost" onclick="act('reconnect_all','全部重连')">全部重连</button>
        <button class="btn ghost" onclick="act('refresh_cache','刷新节点库')">刷新节点库</button>
        <button class="btn ghost" onclick="act('clear_bad','清空失败黑名单')">清空失败黑名单</button>
        <button class="btn ghost" onclick="act('restart_gost','重启 gost')">重启 gost</button>
        <button class="btn red" onclick="act('stop_all','断开全部隧道')">断开全部隧道</button>
      </div>
      <div class="mut" style="margin-top:10px">断开后守护线程会在下一轮自动重连，除非先把模式切成「停止」。</div>
    </div>
  </div>

  <div class="panel" id="p-diag">
    <div class="card"><h3>运行态</h3><div id="diagbox" class="mut">加载中...</div></div>
  </div>
</div>

<div id="toast"></div>
<div id="mask"><div class="modal">
  <h4>修改面板密码</h4>
  <div class="mut">改完立即生效，所有已登录会话会被踢下线</div>
  <div class="fld"><label>当前密码</label><input type="password" id="mOld"></div>
  <div class="fld"><label>新密码（至少 8 位）</label><input type="password" id="mNew"></div>
  <div class="fld"><label>再输一次</label><input type="password" id="mNew2"></div>
  <div class="btnrow">
    <button class="btn" onclick="doPwd()">确认修改</button>
    <button class="btn ghost" onclick="closePwd()">取消</button>
  </div>
</div></div>

<div id="nodeMask"><div class="modal"><div id="nodeModalBody"></div></div></div>

<script>
let curPage=1,totalPages=1,EPS=[],SHOWN={},COUNTRIES=[];
function $(id){return document.getElementById(id);}
function esc(s){return String(s==null?"":s).replace(/[&<>"']/g,function(c){
  return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];});}
function toast(msg,kind){
  var d=document.createElement("div"); d.className="tst "+(kind||""); d.textContent=msg;
  $("toast").appendChild(d);
  setTimeout(function(){d.style.opacity="0";d.style.transition=".3s";
    setTimeout(function(){d.remove();},320);},2600);
}
async function api(path,opt){
  var r=await fetch(path,Object.assign({headers:{"Content-Type":"application/json"}},opt||{}));
  if(r.status===401){location.href="/";throw new Error("未登录");}
  var d=null; try{d=await r.json();}catch(e){}
  if(!r.ok) throw new Error((d&&d.msg)||("HTTP "+r.status));
  return d;
}
function fmtUp(s){if(!s)return"-";if(s<3600)return Math.floor(s/60)+"分";
  if(s<86400)return (s/3600).toFixed(1)+"时";return (s/86400).toFixed(1)+"天";}
function fmtUsers(u){if(!u)return"-";if(u<10000)return u;
  if(u<1e8)return (u/1e4).toFixed(1)+"万";return (u/1e8).toFixed(2)+"亿";}
var PRIV = (localStorage.getItem("vg_priv") !== "0");   // 默认开启隐私模式
// ---- 主题：默认跟随系统，手动切换后记住 ----
function applyTheme(){
  var t = localStorage.getItem("vg_theme") || "auto";
  var dark = t === "dark" || (t === "auto" &&
             !(window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches));
  document.body.classList.toggle("light", !dark);
  var b = document.getElementById("btnTheme");
  if(b) b.textContent = dark ? "🌙 暗色" : "☀️ 亮色";
}
function toggleTheme(){
  var cur = localStorage.getItem("vg_theme") || "auto";
  var dark = !document.body.classList.contains("light");
  var next = dark ? "light" : "dark";
  localStorage.setItem("vg_theme", next);
  applyTheme();
  toast("已切换到" + (next === "light" ? "亮色" : "暗色") + "主题", "ok");
}
// ---- 国旗：ISO 两位国家码 -> emoji 区域指示符 ----
function flagOf(code){
  if(!code || String(code).length !== 2) return "";
  var cc = String(code).toUpperCase();
  if(!/^[A-Z]{2}$/.test(cc)) return "";
  try{
    return String.fromCodePoint(0x1F1E6 + cc.charCodeAt(0) - 65,
                                0x1F1E6 + cc.charCodeAt(1) - 65);
  }catch(e){ return ""; }
}
function flagHtml(code){
  if(code === "TW") code = "TW";
  var f = flagOf(code);
  return f ? '<span class="flag">' + f + '</span>' : "";
}
function fmtAgo(ts){
  if(!ts) return "";
  var s = Math.max(0, Math.floor(Date.now()/1000 - ts));
  if(s < 60) return s+"秒前";
  if(s < 3600) return Math.floor(s/60)+"分钟前";
  if(s < 86400) return (s/3600).toFixed(1)+"小时前";
  return Math.floor(s/86400)+"天前";
}
function fmtBytes(b){  b = Number(b) || 0;
  if(b <= 0) return "-";
  var u = ["B", "KB", "MB", "GB", "TB", "PB"];
  var i = 0;
  while(b >= 1024 && i < u.length - 1){ b /= 1024; i++; }
  return (b >= 100 ? b.toFixed(0) : b.toFixed(1)) + u[i];
}
var DOTS = "••••••";
var LAST_TUNS = [], LAST_PORTS = null, NODE_CACHE = {};
var STICKY_ON = true, STICKY_BASE = 10818;
function tab(t){
  document.querySelectorAll(".tab").forEach(function(e){e.classList.toggle("on",e.dataset.t===t);});
  document.querySelectorAll(".panel").forEach(function(e){e.classList.toggle("on",e.id==="p-"+t);});
  if(t==="diag") loadDiag();
  if(t==="nodes"&&!$("nbody").dataset.loaded) loadNodes(1);
}
function togglePriv(){
  PRIV = !PRIV;
  localStorage.setItem("vg_priv", PRIV ? "1" : "0");
  $("btnPriv").textContent = PRIV ? "🔒 隐私模式" : "🔓 已显示真实";
  SHOWN = {};                // 切换时清掉单项展开
  renderEps();
  renderTuns(LAST_TUNS);
  refresh();                 // 顶部出口 IP 也要跟着变
}
function maskHost(h){ return h ? DOTS : "未识别公网IP"; }
function maskPort(p){ return PRIV ? "••••" : String(p); }
function dispLink(e,which){
  var raw = which === "http" ? e.http : e.socks;
  if(!raw) return "";
  if(!PRIV) return raw;
  var scheme = raw.split("://")[0];
  if(scheme === "ss" || scheme === "ssu"){
    return scheme + "://" + DOTS + "@" + DOTS + ":" + maskPort(e.port);
  }
  return scheme + "://" + e.user + ":" + DOTS + "@" + DOTS + ":" + maskPort(e.port);
}
function copyText(t){
  return new Promise(function(res, rej){
    function fallback(){
      try{
        var ta = document.createElement("textarea");
        ta.value = t;
        ta.style.position = "fixed"; ta.style.top = "-9999px"; ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.focus(); ta.select();
        ta.setSelectionRange(0, ta.value.length);
        var ok = document.execCommand("copy");
        document.body.removeChild(ta);
        ok ? res() : rej(new Error("浏览器拒绝复制"));
      }catch(e){ rej(e); }
    }
    // HTTP 面板不是安全上下文，navigator.clipboard 不可用，直接走 execCommand
    if(window.isSecureContext && navigator.clipboard && navigator.clipboard.writeText){
      navigator.clipboard.writeText(t).then(res).catch(fallback);
    } else {
      fallback();
    }
  });
}
function copyLink(i, which, ev){
  if(ev) ev.preventDefault();
  var e = EPS[i] || {};
  var s = which === "http" ? e.http : e.socks;
  if(!s) return;
  copyText(s).then(function(){
    toast("已复制到剪贴板","ok");
  }).catch(function(err){
    toast("复制失败：" + (err && err.message ? err.message : "浏览器不支持") + "，请手动长按选择", "bad");
  });
}
function renderBanner(ports){
  var b = $("banner");
  if(!ports || ports.unknown){ b.innerHTML = ""; return; }
  var miss = ports.missing || [];
  var gost = ports.gost_active || "";
  var html = "";
  if(gost && gost !== "active"){
    html += '<div class="banner bad"><b>gost 未运行（' + esc(gost) + '）</b>：所有代理端口都不会响应。'
          + '执行 <code>systemctl status vpngate-gost --no-pager -n 30</code> 看原因，'
          + '或点「参数设置 → 重启 gost」。</div>';
  } else if(miss.length){
    html += '<div class="banner warn"><b>本机没有监听这些端口：' + miss.join(", ") + '</b>'
          + '。代理协议连不上就是这个原因（不是密码错，是根本没进程在听）。</div>';
  } else if(!EPS.length || !EPS[0].host_ok){
    html += '<div class="banner warn"><b>没能识别公网 IP</b>：链接里的地址是空的。'
          + '请把 <code>PUBLIC_IP=你的公网IP</code> 加到 <code>/etc/systemd/system/vpngate.service</code> 的 '
          + '<code>Environment=</code> 行后面，然后 <code>systemctl daemon-reload && systemctl restart vpngate</code>。</div>';
  } else {
    html += '<div class="banner ok">端口都在监听。如果客户端仍报「连接被拒绝 / 超时」，'
          + '那是<b>云平台安全组</b>没放行对应端口 —— 本机防火墙和云防火墙是两层东西。</div>';
  }
  b.innerHTML = html;
}
function renderEps(){
  var h = "";
  EPS.forEach(function(e, i){
    var icon = e.group === "sticky" ? "🔒 " : e.group === "agg" ? "⚡ " : "🛡 ";
    h += '<div class="ep">';
    h += '<div class="t"><span class="nm">' + icon + esc(e.name) + '</span>';
    h += '<span class="pt">:' + maskPort(e.port) + '</span><span class="pt">' + esc(e.proto) + '</span>';
    h += '<span class="st">' + esc(e.state || "") + '</span>';
    h += '<button class="eye" onclick="showEp(' + i + ')">' + (SHOWN[i] ? "🙈 隐藏" : "👁 显示") + '</button></div>';
    h += '<div class="lk" data-ep="' + i + '" onclick="copyLink(' + i + ',\'socks\',event)" title="点击直接复制">'
       + esc(SHOWN[i] ? e.socks : dispLink(e, "socks")) + '</div>';
    if(e.http){
      h += '<div class="lk" data-eph="' + i + '" onclick="copyLink(' + i + ',\'http\',event)" title="点击直接复制 HTTP 代理">'
         + esc(SHOWN[i] ? e.http : dispLink(e, "http")) + '</div>';
    }
    h += '<div class="nt">' + esc(e.note || "") + '</div></div>';
  });
  $("eplist").innerHTML = h || '<div class="mut">无</div>';
}
function showEp(i){
  SHOWN[i] = !SHOWN[i];
  renderEps();
}
async function loadEp(){
  var d = await api("/api/endpoints");
  EPS = d.endpoints || [];
  STICKY_ON = !!d.sticky_on;
  STICKY_BASE = d.sticky_base || 10818;
  LAST_PORTS = d.ports || null;
  renderEps();
  renderBanner(LAST_PORTS);
  renderTuns(LAST_TUNS);
}
function stickyPortOf(t){
  var i = parseInt(t.idx, 10);
  if(isNaN(i) || !STICKY_ON) return null;
  return STICKY_BASE + i;
}
function copySticky(dev){
  var t = LAST_TUNS.filter(function(x){return x.dev===dev;})[0];
  if(!t) return;
  var p = stickyPortOf(t);
  if(!p){ toast("没有开启粘性端口","bad"); return; }
  var ep = EPS.filter(function(e){return e.group==="sticky" && e.port===p;})[0];
  if(!ep){ toast("找不到该端口的链接","bad"); return; }
  copyText(ep.socks).then(function(){
    toast("已复制 " + dev + " 专属入口（:" + p + "）","ok");
  }).catch(function(){ toast("复制失败","bad"); });
}
function renderTuns(ts){
  var h="";
  ts.forEach(function(t){
    var sp = stickyPortOf(t);
    var f = flagHtml(t.country);
    h+='<div class="tcard '+(t.healthy?"up":"down")+'">';
    h+='<div class="h"><span class="dot '+(t.healthy?"g":"r")+'"></span>'+esc(t.dev);
    h+=' <span class="mut" style="font-weight:400">'+
       (f ? f+' ' : '')+esc(t.country_long||t.country||"未连接")+'</span></div>';
    h+='<div class="row"><span>节点 IP</span><b>'+(PRIV&&t.ip?DOTS:esc(t.ip||"-"))+'</b></div>';
    h+='<div class="row"><span>出口 IP</span><b>'+(PRIV&&t.exit_ip?DOTS:esc(t.exit_ip||"-"))+'</b></div>';
    h+='<div class="row"><span>真实 RTT</span><b>'+(t.rtt?t.rtt+" ms":"-")+'</b></div>';
    var spdCell;
    if(t.testing) spdCell='<span class="mut">测速中...</span>';
    else if(t.speed_mbps) spdCell='<b class="cool">'+t.speed_mbps+' Mbps</b> <span class="mut">'+
         fmtAgo(t.speed_ts)+'</span>';
    else spdCell='<span class="mut">未测</span>';
    h+='<div class="row"><span>实测带宽</span><b>'+spdCell+'</b></div>';
    h+='<div class="row"><span>状态</span><b>'+(t.healthy?("在线 "+fmtUp(t.up_seconds)):("已断 "+t.down_seconds+"s"))+'</b></div>';
    if(sp) h+='<div class="row"><span>专属入口</span><b>:'+sp+'（只走这条）</b></div>';
    h+='<div class="acts">';
    if(sp) h+='<button class="mini accent" onclick="copySticky(\''+esc(t.dev)+'\')">复制入口</button>';
    h+='<button class="mini" onclick="act(\'reconnect\',\'重连\',\''+esc(t.dev)+'\')">重连</button>';
    h+='<button class="mini" onclick="act(\'disconnect\',\'断开\',\''+esc(t.dev)+'\')">断开</button>';
    h+='</div></div>';
  });
  $("tgrid").innerHTML=h;
}
// 三个接口并行拉，任何一个慢/失败都不拖累其它的
function refresh(){
  var t0 = Date.now();
  var p1 = api("/api/tunnels").then(function(d){
    LAST_TUNS = d.tunnels || [];
    renderTuns(LAST_TUNS);
    var ok=(d.tunnels||[]).filter(function(x){return x.healthy;}).length;
    var all=(d.tunnels||[]).length;
    $("sHealth").textContent=ok+"/"+all;
    $("sHealthS").textContent=(ok===all?"全部正常":"正在恢复");
    $("pHealth").textContent=ok+"/"+all+" 在线";
    $("pHealth").className="pill "+(ok===all?"ok":(ok>0?"warn":"bad"));
    var eip = d.primary_ip || "-";
    $("sExit").textContent = (PRIV && d.primary_ip) ? DOTS : eip;
    $("sExitS").textContent=d.primary_country||"-";
    $("pExit").textContent="出口 "+((PRIV && d.primary_ip) ? DOTS : eip);
    var tm = d.timing || {};
    if(tm.fast_poll){
      var pEl=$("tPanel"), wEl=$("tWd");
      if(pEl) pEl.textContent = tm.panel_poll || 8;
      if(wEl) wEl.textContent = tm.watchdog || 30;
      var ex=$("explainTunnels");
      if(ex && !ex.dataset.filled){
        ex.dataset.filled="1";
        var body=ex.querySelector(".body p:last-of-type");
        if(body) body.innerHTML += " <span class=\"mut\">（设备轮询 "+tm.fast_poll+
          "s / 出网探测 "+tm.health_poll+"s / OpenVPN 断链判定 "+tm.ping_restart+"s）</span>";
      }
    }
  }).catch(function(){ $("pHealth").textContent = "状态获取失败"; });

  var p2 = api("/api/autowatch").then(function(a){
    $("sMsg").textContent=a.status_msg||"-";
    $("sMsgS").textContent="上次巡检 "+(a.last_check||"-");
  }).catch(function(){});

  var p3 = api("/api/diag").then(function(dg){
    $("sNodes").textContent=dg.nodes_cached||0;
    $("sNodesS").textContent="冷门节点 "+(dg.free_nodes||0)+" 个";
  }).catch(function(){});

  return Promise.allSettled([p1,p2,p3]);
}
async function loadCountries(){
  COUNTRIES=await api("/api/countries")||[];
  var a='<option value="ALL">全部国家</option>';
  COUNTRIES.forEach(function(c){a+='<option value="'+esc(c.code)+'">'+esc(c.name)+' ('+esc(c.code)+') ['+c.count+']</option>';});
  $("fCountry").innerHTML=a;
  var b='<option value="AUTO">🅰 自动（按 VPS 位置择优）</option><option value="NONE">-- 不选 --</option>'+
        '<option value="ALL">全部国家</option>';
  COUNTRIES.forEach(function(c){b+='<option value="'+esc(c.code)+'">'+esc(c.name)+' ('+esc(c.code)+')</option>';});
  ["cP1","cP2","cP3"].forEach(function(id){$(id).innerHTML=b;});
}
async function loadNodes(p){
  p=parseInt(p)||1;
  if(totalPages>0&&p>totalPages)p=totalPages; if(p<1)p=1; curPage=p;
  $("nbody").innerHTML='<tr><td colspan="10" class="mut">并发测活中...</td></tr>';
  var q="?country="+encodeURIComponent($("fCountry").value)+"&proto="+$("fProto").value+
        "&sort="+$("fSort").value+"&page="+p+"&size=25";
  var d=await api("/api/nodes"+q);
  totalPages=d.total_pages||1; curPage=d.page;
  $("pageInfo").textContent="第 "+d.page+" / "+totalPages+" 页 · 共 "+d.total+" 个";
  $("btnPrev").disabled=curPage<=1; $("btnNext").disabled=curPage>=totalPages;
  $("nodeCount").textContent=d.total+" 个";
  var h="";
  (d.nodes||[]).forEach(function(n){
    var st=n.online===true?'<span class="bd g">正常</span>'
          :n.online===false?'<span class="bd r">无响应</span>':'<span class="bd n">未知</span>';
    var sess=n.sessions<=5?'<span class="cool">'+n.sessions+'</span>'
            :n.sessions>=40?'<span class="hot">'+n.sessions+'</span>':n.sessions;
    var rtt=n.rtt?'<b class="'+(n.rtt<40?"cool":(n.rtt<120?"":"hot"))+'">'+n.rtt+"ms</b>"
                 :'<span class="mut">~'+n.ping+'ms</span>';
    var host = n.hostname ? esc(n.hostname) : '<span class="mut">-</span>';
    if(n.operator) host += '<div class="mut" style="font-size:11px">'+esc(n.operator.slice(0,28))+'</div>';
    var fl = flagHtml(n.country);
    h+='<tr>';
    h+='<td>'+(fl?fl+' ':'')+esc(n.country_long)+' <span class="mut">'+esc(n.country)+'</span></td>';
    h+='<td class="wrap">'+host+'</td>';
    h+='<td>'+esc(n.ip)+':'+esc(n.port)+'</td><td><b>'+esc(n.proto)+'</b></td>';
    h+='<td>'+sess+' <span class="mut">/ '+fmtUsers(n.users)+'</span></td>';
    h+='<td>'+n.speed+'M</td>';
    h+='<td>'+rtt+'</td>';
    h+='<td>'+fmtBytes(n.traffic)+'</td>';
    h+='<td><b>'+n.calc+'</b></td><td>'+st+'</td>';
    h+='<td style="white-space:nowrap">';
    h+='<button class="mini" style="flex:none;padding:3px 9px" onclick="connNode(\''+esc(n.id)+'\')">连接</button> ';
    h+='<button class="mini" style="flex:none;padding:3px 9px" onclick="nodeDetail(\''+esc(n.id)+'\')">详情</button>';
    h+='</td></tr>';
  });
  NODE_CACHE = {};
  (d.nodes||[]).forEach(function(n){ NODE_CACHE[n.id] = n; });
  $("nbody").innerHTML=h||'<tr><td colspan="11" class="mut">该筛选下暂无节点</td></tr>';
  $("nbody").dataset.loaded="1";
}
function nodeDetail(id){
  var n = NODE_CACHE[id];
  if(!n){ toast("节点信息已过期，请刷新列表","bad"); return; }
  var rows = [
    ["国家", (flagHtml(n.country)?flagHtml(n.country)+" ":"") + (n.country_long||"-") + " (" + n.country + ")"],
    ["主机名", n.hostname || "-"],
    ["运营商", n.operator || "-"],
    ["消息", n.message || "-"],
    ["IP:端口", n.ip + ":" + n.port],
    ["协议", n.proto],
    ["当前并发", n.sessions + " 人"],
    ["累计用户", fmtUsers(n.users)],
    ["历史带宽", n.speed + " Mbps"],
    ["累计流量", fmtBytes(n.traffic)],
    ["实测 RTT", n.rtt ? n.rtt + " ms" : "未测到（~" + n.ping + "ms 标称）"],
    ["vpngate 评分", n.score],
    ["本系统评分", n.calc],
    ["探活结果", n.online === true ? "正常" : (n.online === false ? "无响应" : "未知（机房封 ICMP）")],
  ];
  var h = '<h4>' + (flagHtml(n.country)?flagHtml(n.country)+" ":"") + esc(n.country_long) + '</h4>';
  h += '<div class="mut" style="margin-bottom:10px">' + esc(n.ip) + ':' + esc(n.port) + '</div>';
  rows.forEach(function(r){
    h += '<div class="kv"><span>' + esc(r[0]) + '</span><b>' + esc(r[1]) + '</b></div>';
  });
  h += '<div class="btnrow"><button class="btn" onclick="connNode(\'' + esc(n.id) + '\');closeNodeDetail()">用这个节点</button>';
  h += '<button class="btn ghost" onclick="closeNodeDetail()">关闭</button></div>';
  $("nodeModalBody").innerHTML = h;
  $("nodeMask").style.display = "grid";
}
function closeNodeDetail(){ $("nodeMask").style.display = "none"; }
async function connNode(id){
  toast("正在建立隧道，请稍候...");
  try{
    var d=await api("/api/connect",{method:"POST",body:JSON.stringify({id:id})});
    toast(d.msg||"已连接","ok"); refresh();
  }catch(e){toast("失败: "+e.message,"bad");}
}
async function loadCfg(){
  var a=await api("/api/autowatch");
  $("cP1").value=a.p1||"JP"; $("cP2").value=a.p2||"KR"; $("cP3").value=a.p3||"NONE";
  $("cInt").value=a.interval||30;
  var s=await api("/api/settings"); var v=s.values||{};
  $("cCap").value=v.session_cap; $("cCand").value=v.candidates;
  $("cTcp").value=v.prefer_tcp?"1":"0";
  $("cMss").value=v.mssfix; $("cPingR").value=v.ping_restart;
  $("cFast").value=v.fast_poll; $("cHealth").value=v.health_poll;
  $("cOpt").value=v.auto_optimize?"1":"0";
  $("cOptRatio").value=v.optimize_ratio; $("cOptFloor").value=v.optimize_floor;
  $("cOptInt").value=v.optimize_interval;
  $("cNotifyUrl").value=v.notify_url||""; $("cNotifyKind").value=v.notify_kind||"json";
  $("cNotifyChat").value=v.notify_chat||""; $("cNotifyGap").value=v.notify_min_gap;
  $("cSpd").value=v.speedtest?"1":"0";
  $("cSpdMb").value=v.speedtest_mb; $("cSpdInt").value=v.speedtest_interval;
  $("cGeo").value=v.geo_prefer?"1":"0";
  $("cPoolExtra").value=v.pool_extra?"1":"0";
  $("cPoolTtl").value=v.pool_ttl_days;
  updSpdEst();
  var ro=s.readonly||{};
  $("rTun").value=ro.tunnels; $("rSticky").value=ro.sticky;
  $("rPorts").value=ro.ports; $("rTable").value=ro.route_tables;
}
async function saveCfg(){
  try{
    await api("/api/autowatch",{method:"POST",body:JSON.stringify({
      p1:$("cP1").value,p2:$("cP2").value,p3:$("cP3").value,
      interval:parseInt($("cInt").value)||30})});
    var d=await api("/api/settings",{method:"POST",body:JSON.stringify({
      session_cap:parseInt($("cCap").value), candidates:parseInt($("cCand").value),
      prefer_tcp:$("cTcp").value==="1", mssfix:$("cMss").value,
      ping_restart:parseInt($("cPingR").value), fast_poll:parseFloat($("cFast").value),
      health_poll:parseFloat($("cHealth").value),
      auto_optimize:$("cOpt").value==="1",
      optimize_ratio:parseFloat($("cOptRatio").value),
      optimize_floor:parseInt($("cOptFloor").value),
      optimize_interval:parseInt($("cOptInt").value),
      notify_url:$("cNotifyUrl").value.trim(),
      notify_kind:$("cNotifyKind").value,
      notify_chat:$("cNotifyChat").value.trim(),
      notify_min_gap:parseInt($("cNotifyGap").value),
      speedtest:$("cSpd").value==="1",
      speedtest_mb:parseFloat($("cSpdMb").value),
      speedtest_interval:parseInt($("cSpdInt").value),
      geo_prefer:$("cGeo").value==="1",
      pool_extra:$("cPoolExtra").value==="1",
      pool_ttl_days:parseInt($("cPoolTtl").value)})});
    toast(d.msg||"已保存","ok"); await loadCfg();
  }catch(e){toast("保存失败: "+e.message,"bad");}
}
async function act(action,label,dev){
  if(action==="stop_all"&&!confirm("确定断开全部隧道？守护线程会自动重连。"))return;
  toast((label||action)+" 执行中...");
  try{
    var d=await api("/api/action",{method:"POST",body:JSON.stringify({action:action,dev:dev})});
    toast(d.msg||"完成","ok"); setTimeout(refresh,800);
  }catch(e){toast("失败: "+e.message,"bad");}
}
function updSpdEst(){
  var mb = parseFloat($("cSpdMb").value) || 3;
  var iv = parseInt($("cSpdInt").value) || 43200;
  var n  = LAST_TUNS.length || 2;
  var perMonth = 2 * n * mb * (2592000 / iv) / 1024;   // GB
  $("cSpdEst").value = perMonth < 0.1 ? "几乎为 0"
    : perMonth.toFixed(2) + " GB / 月";
}
async function loadGeo(){
  $("geoBox").innerHTML = '<span class="mut">正在测量各国节点的真实延迟（约 3~8 秒）...</span>';
  try{
    var d = await api("/api/geo");
    var vc = d.vps_country || "未知";
    $("vpsGeo").textContent = "VPS 位置：" + vc;
    var p = d.pool || {};
    $("poolTag").textContent = "在线 " + (p.live||0) + " / 历史累积 " + (p.total||0) +
                               "（美国共 " + (p.us_total||0) + "）";
    var rows = (d.countries||[]);
    if(!rows.length){ $("geoBox").innerHTML = '<span class="mut">没测到数据</span>'; return; }
    var h = '<div class="tw"><table class="narrow" style="min-width:0"><thead><tr>' +
            '<th>国家</th><th>节点数</th><th>实测最低 RTT</th><th>建议</th></tr></thead><tbody>';
    var best = rows[0].rtt;
    rows.forEach(function(c, i){
      var mark = i === 0 ? '<span class="bd g">最快</span>'
                : (c.rtt <= best * 1.6 ? '<span class="bd n">可接受</span>' : '<span class="mut">偏慢</span>');
      if(c.country === vc) mark += ' <span class="bd g">本机所在国</span>';
      h += '<tr><td>' + flagHtml(c.country) + ' ' + esc(c.name) + ' <span class="mut">' + esc(c.country) + '</span></td>' +
           '<td>' + c.nodes + '</td><td><b>' + c.rtt + ' ms</b></td><td>' + mark + '</td></tr>';
    });
    h += '</tbody></table></div>';
    h += '<div class="mut" style="margin-top:10px">这张表是<b>从你这台 VPS 实测</b>出来的，' +
         '不是按地图距离估的 —— 跨国线路质量差异很大，实测才准。' +
         '把最快的那个国家填进「第一顺位」即可。</div>';
    $("geoBox").innerHTML = h;
  }catch(e){
    $("geoBox").innerHTML = '<span class="mut">测量失败：' + esc(e.message) + '</span>';
  }
}
async function testNotify(){  var u=$("cNotifyUrl").value.trim();
  if(!u){ toast("先填 Webhook 地址","bad"); return; }
  toast("正在发送测试通知...");
  try{
    var d=await api("/api/action",{method:"POST",body:JSON.stringify({
      action:"test_notify", url:u, kind:$("cNotifyKind").value, chat:$("cNotifyChat").value})});
    toast(d.msg||"已发送","ok");
  }catch(e){ toast("发送失败: "+e.message,"bad"); }
}
async function loadDiag(){
  try{
    var d=await api("/api/diag"); var h="";
    for(var k in d){
      var v=d[k]; if(typeof v==="object") v=JSON.stringify(v);
      h+='<div style="display:flex;justify-content:space-between;gap:14px;padding:6px 0;border-bottom:1px solid #1e2331">';
      h+='<span class="mut">'+esc(k)+'</span><b style="font-family:ui-monospace,Menlo,monospace;font-size:12px;word-break:break-all;text-align:right">'+esc(v)+'</b></div>';
    }
    $("diagbox").innerHTML=h;
  }catch(e){$("diagbox").textContent="加载失败: "+e.message;}
}
function openPwd(){$("mask").style.display="grid";}
function closePwd(){$("mask").style.display="none";
  $("mOld").value="";$("mNew").value="";$("mNew2").value="";}
async function doPwd(){
  if($("mNew").value.length<8){toast("新密码至少 8 位","bad");return;}
  if($("mNew").value!==$("mNew2").value){toast("两次输入不一致","bad");return;}
  try{
    var d=await api("/api/password",{method:"POST",body:JSON.stringify({
      old:$("mOld").value,"new":$("mNew").value})});
    closePwd(); toast(d.msg||"已修改","ok");
    setTimeout(function(){location.href="/";},1500);
  }catch(e){toast("修改失败: "+e.message,"bad");}
}
async function logout(){
  try{await api("/api/logout",{method:"POST"});}catch(e){}
  location.href="/";
}
function reloadAll(){
  refresh(); loadEp(); loadCountries();
  if($("nbody").dataset.loaded) loadNodes(curPage);
}
(async function boot(){
  applyTheme();
  if(window.matchMedia){
    try{ window.matchMedia("(prefers-color-scheme: light)").addEventListener("change", function(){
      if((localStorage.getItem("vg_theme") || "auto") === "auto") applyTheme();
    }); }catch(e){}
  }
  $("btnPriv").textContent = PRIV ? "🔒 隐私模式" : "🔓 已显示真实";
  try{ await loadEp(); await loadCountries(); await refresh(); await loadCfg(); }catch(e){}
  setInterval(refresh,8000);
  setInterval(loadEp,30000);
})();
</script></body></html>"""

# ==============================================================================
#  HTTP 服务
# ==============================================================================
def _cookie_sid(handler):
    raw = handler.headers.get("Cookie", "") or ""
    for part in raw.split(";"):
        k, _, v = part.strip().partition("=")
        if k == "sid":
            return v
    return ""

def _basic_ok(handler):
    hdr = handler.headers.get("Authorization", "") or ""
    if not hdr.startswith("Basic "):
        return False
    try:
        u, _, p = base64.b64decode(hdr[6:]).decode("utf-8").partition(":")
    except Exception:
        return False
    return u == CRED_USER and p == CRED_PASS

class Handler(BaseHTTPRequestHandler):
    server_version = "VPNGatePanel/3.3"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        pass

    def _authed(self):
        if not CRED_PASS:
            return True
        return valid_session(_cookie_sid(self)) or _basic_ok(self)

    def _deny(self, page=False):
        if page:
            body = LOGIN_HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(body)
            except Exception:
                pass
            return
        body = json.dumps({"ok": False, "msg": "未登录或会话已过期"}, ensure_ascii=False).encode("utf-8")
        self.send_response(401)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def _send(self, body, ctype="application/json; charset=utf-8", code=200, cookie=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False)
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def _json_body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0 or n > 65536:
                return {}
            return json.loads(self.rfile.read(n).decode("utf-8", "ignore") or "{}")
        except Exception:
            return {}

    def do_GET(self):
        u = urlparse(self.path)
        p = u.path
        if p in ("/", "/index.html"):
            if not self._authed():
                return self._deny(page=True)
            return self._send(APP_HTML, "text/html; charset=utf-8")
        if p == "/login":
            return self._deny(page=True)
        if not p.startswith("/api/"):
            return self._send({"msg": "not found"}, code=404)
        if not self._authed():
            return self._deny()

        q = parse_qs(u.query)
        if p == "/api/endpoints":
            return self._send({"endpoints": build_endpoints(),
                               "public_ip": public_ip() or None,
                               "sticky_on": bool(STICKY),
                               "sticky_base": STICKY_BASE,
                               "ports": port_status()})
        if p == "/api/tunnels":
            out = []
            primary_ip, primary_country = None, None
            for t in TUNS:
                ip = self._exit_ip(t)
                if ip and not primary_ip:
                    primary_ip, primary_country = ip, t["country"]
                cl = ""
                for n in node_list_cache:
                    if n["id"] == t["node"]:
                        cl = n["country_long"]
                        break
                out.append({
                    "dev": t["dev"], "idx": t["idx"], "healthy": bool(t["healthy"]),
                    "ip": t["node"], "country": t["country"], "country_long": cl,
                    "exit_ip": ip, "rtt": t["rtt"], "fails": t["fails"],
                    "enabled": t.get("enabled", True),
                    "sticky_port": (STICKY_BASE + t["idx"]) if STICKY else None,
                    "speed_mbps": t.get("speed_mbps"),
                    "speed_ts": t.get("speed_ts") or 0,
                    "testing": bool(t.get("testing")),
                    "down_seconds": int(time.time() - t["down_since"]) if t["down_since"] else 0,
                    "up_seconds": int(time.time() - t["since"]) if t["since"] else 0,
                })
            return self._send({
                "tunnels": out, "primary_ip": primary_ip,
                "primary_country": primary_country, "count": TUNNELS,
                "timing": {
                    "panel_poll": 8,
                    "watchdog": max(10, int(auto_cfg.get("interval", 30))),
                    "watchdog_recover": 5,
                    "fast_poll": round(float(rt("fast_poll", 1.0)), 1),
                    "health_poll": round(float(rt("health_poll", 3.0)), 1),
                    "ping_restart": int(rt("ping_restart", 20)),
                },
            })
        if p == "/api/status":
            t = next((x for x in TUNS if x["healthy"]), None)
            return self._send({"ip": self._exit_ip(t) if t else None})
        if p == "/api/autowatch":
            return self._send(auto_cfg)
        if p == "/api/settings":
            return self._send({
                "values": dict(runtime),
                "readonly": {
                    "tunnels": TUNNELS,
                    "sticky": ("开启，%d..%d" % (STICKY_BASE, STICKY_BASE + TUNNELS - 1)) if STICKY else "关闭",
                    "ports": "聚合 %d / SS %d / SS2022 %d / ssu %d" % (
                        SOCKS5_PORT, SS_PORT, SS2022_PORT, SSU_PORT),
                    "route_tables": "%d ~ %d" % (ROUTE_TABLE, ROUTE_TABLE + TUNNELS - 1),
                },
            })
        if p == "/api/countries":
            counts, names = {}, {}
            for n in node_list_cache:
                c = n["country"]
                counts[c] = counts.get(c, 0) + 1
                names[c] = n["country_long"]
            sc = sorted(counts.items(), key=lambda x: x[1], reverse=True)
            return self._send([{"code": k, "name": names.get(k, k), "count": v} for k, v in sc])
        if p == "/api/nodes":
            return self._api_nodes(q)
        if p == "/api/diag":
            return self._send(self._diag())
        if p == "/api/geo":
            return self._send({"vps_country": VPS_COUNTRY,
                               "countries": country_rtt_report(),
                               "pool": pool_stats()})
        return self._send({"msg": "not found"}, code=404)

    def _exit_ip(self, t):
        """
        永不阻塞：缓存 60 秒内直接返回；过期就返回旧值 + 后台线程去刷新。
        旧版这里是同步 curl（每条隧道最多 9 秒），3 条隧道就是 27 秒 ——
        面板打开时一直转圈就是它导致的。
        """
        now = time.time()
        with cfg_lock:
            ip = t["exit_ip"]
            ts = t["exit_ts"]
        if ip and now - ts < 60:
            return ip
        if not t["healthy"]:
            return None
        with _exit_job["lock"]:
            if t["dev"] not in _exit_job["busy"]:
                _exit_job["busy"].add(t["dev"])
                threading.Thread(target=self._exit_ip_worker, args=(t,), daemon=True).start()
        return ip

    def _exit_ip_worker(self, t):
        try:
            r = run(["curl", "--interface", t["dev"], "-m", "4", "-s", "https://ipinfo.io/json"],
                    timeout=8)
            if r.returncode == 0 and (r.stdout or "").strip().startswith("{"):
                d = json.loads(r.stdout)
                with cfg_lock:
                    t["exit_ip"] = d.get("ip")
                    t["exit_ts"] = time.time()
        except Exception:
            pass
        finally:
            with _exit_job["lock"]:
                _exit_job["busy"].discard(t["dev"])

    def _api_nodes(self, q):
        c = (q.get("country") or ["ALL"])[0]
        proto = (q.get("proto") or ["ALL"])[0]
        sort_by = (q.get("sort") or ["calc"])[0]
        try:
            page = int((q.get("page") or ["1"])[0])
            size = min(100, max(5, int((q.get("size") or ["25"])[0])))
        except Exception:
            page, size = 1, 25
        f = list(node_list_cache)
        if c != "ALL":
            f = [n for n in f if n["country"] == c]
        if proto != "ALL":
            f = [n for n in f if n["proto"] == proto]
        if sort_by == "speed":
            f.sort(key=lambda x: x["speed"], reverse=True)
        elif sort_by == "ping":
            f.sort(key=lambda x: x["ping"])
        elif sort_by == "sessions":
            f.sort(key=lambda x: x["sessions"])
        else:
            f.sort(key=lambda x: x["calc"], reverse=True)
        total = len(f)
        total_pages = max(1, math.ceil(total / size))
        page = max(1, min(page, total_pages))
        page_nodes = f[(page - 1) * size: page * size]
        checked = measure_rtts(page_nodes)
        for d in checked:
            d["calc"] = round(node_score(d), 1)
        return self._send({"total": total, "page": page, "page_size": size,
                           "total_pages": total_pages, "nodes": checked,
                           "icmp_blocked": ICMP_BLOCKED})

    def _diag(self):
        maj, mi = get_openvpn_ver()
        rules = run(["ip", "rule", "show"], timeout=5).stdout
        cc = run(["sysctl", "-n", "net.ipv4.tcp_congestion_control"], timeout=5).stdout.strip()
        return {
            "openvpn": "%d.%d" % (maj, mi),
            "python": sys.version.split()[0],
            "tunnels": TUNNELS,
            "healthy": sum(1 for t in TUNS if t["healthy"]),
            "congestion_control": cc or "?",
            "mssfix": rt("mssfix") if rt("fix_mtu") else "off",
            "ping_restart": rt("ping_restart"),
            "session_cap": rt("session_cap"),
            "icmp_blocked": ICMP_BLOCKED,
            "nodes_cached": len(node_list_cache),
            "free_nodes": len([n for n in node_list_cache
                               if n["sessions"] <= max(1, int(rt("session_cap", 60)) // 3)]),
            "gost_mode": (open(GOST_MODE).read().strip() if os.path.exists(GOST_MODE) else "?"),
            "gost_active": run(["systemctl", "is-active", "vpngate-gost"], timeout=5).stdout.strip(),
            "vps_country": VPS_COUNTRY,
            "geo_prefer": bool(rt("geo_prefer", True)),
            "pool": pool_stats(),
            "route_tables": [str(ROUTE_TABLE + i) for i in range(TUNNELS)],
            "ip_rules": [l for l in rules.splitlines()
                         if any(("lookup %d" % (ROUTE_TABLE + i)) in l for i in range(TUNNELS))][:6],
        }

    def do_POST(self):
        p = urlparse(self.path).path
        body = self._json_body()

        if p == "/api/login":
            ip = self.client_address[0] if self.client_address else "?"
            st = _fails.get(ip)
            if st and st[1] > time.time():
                return self._send({"ok": False, "msg": "尝试过多，请 %.0f 秒后再试" % (st[1] - time.time())},
                                  code=429)
            if str(body.get("user", "")) == CRED_USER and str(body.get("pass", "")) == CRED_PASS:
                _fails.pop(ip, None)
                sid = new_session()
                return self._send({"ok": True},
                                  cookie="sid=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=%d"
                                  % (sid, SESSION_TTL))
            cur = _fails.get(ip, [0, 0.0])
            cur = [cur[0] + 1, 0.0]
            if cur[0] >= LOGIN_MAX_FAIL:
                cur = [0, time.time() + LOGIN_LOCK_SEC]
            _fails[ip] = cur
            time.sleep(0.4)
            return self._send({"ok": False, "msg": "账号或密码错误"}, code=401)

        if not self._authed():
            return self._deny()

        if p == "/api/logout":
            drop_session(_cookie_sid(self))
            return self._send({"ok": True},
                              cookie="sid=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0")

        if p == "/api/password":
            if body.get("old") != CRED_PASS:
                return self._send({"ok": False, "msg": "当前密码不正确"}, code=403)
            nw = str(body.get("new", ""))
            if len(nw) < 8:
                return self._send({"ok": False, "msg": "新密码至少 8 位"}, code=400)
            save_cred(CRED_USER, nw)
            with _sess_lock:
                _sessions.clear()
            return self._send({"ok": True, "msg": "密码已修改，请重新登录"})

        if p == "/api/toggle_mode":
            with cfg_lock:
                auto_cfg["mode"] = "lock" if auto_cfg.get("mode", "auto") == "auto" else "auto"
                auto_cfg["status_msg"] = ("自动：断线自动修复，必要时放宽国家池"
                                          if auto_cfg["mode"] == "auto"
                                          else "锁定：断线照样自动修复，但只在优先国家里找")
                save_config()
            return self._send({"mode": auto_cfg["mode"], "msg": auto_cfg["status_msg"]})

        if p == "/api/autowatch":
            with cfg_lock:
                if "mode" in body:
                    auto_cfg["mode"] = body.get("mode")
                for k in ("p1", "p2", "p3"):
                    if k in body:
                        auto_cfg[k] = body.get(k)
                try:
                    auto_cfg["interval"] = max(15, int(body.get("interval", 30)))
                except Exception:
                    auto_cfg["interval"] = 30
                save_config()
            return self._send({"msg": "已保存", "cfg": auto_cfg})

        if p == "/api/settings":
            def clamp(v, lo, hi, dflt):
                try:
                    v = float(v)
                except Exception:
                    return dflt
                return max(lo, min(hi, v))
            with runtime_lock:
                if "session_cap" in body:
                    runtime["session_cap"] = int(clamp(body["session_cap"], 1, 300, rt("session_cap")))
                if "candidates" in body:
                    runtime["candidates"] = int(clamp(body["candidates"], 1, 20, rt("candidates")))
                if "prefer_tcp" in body:
                    runtime["prefer_tcp"] = bool(body["prefer_tcp"])
                if "mssfix" in body:
                    runtime["mssfix"] = str(int(clamp(body["mssfix"], 1000, 1460, 1300)))
                if "ping_restart" in body:
                    runtime["ping_restart"] = int(clamp(body["ping_restart"], 5, 120, 20))
                if "fast_poll" in body:
                    runtime["fast_poll"] = round(clamp(body["fast_poll"], 0.5, 10, 1.0), 1)
                if "health_poll" in body:
                    runtime["health_poll"] = round(clamp(body["health_poll"], 2, 30, 3.0), 1)
                if "auto_optimize" in body:
                    runtime["auto_optimize"] = bool(body["auto_optimize"])
                if "optimize_ratio" in body:
                    runtime["optimize_ratio"] = round(clamp(body["optimize_ratio"], 1.2, 10, 2.5), 1)
                if "optimize_floor" in body:
                    runtime["optimize_floor"] = int(clamp(body["optimize_floor"], 50, 2000, 150))
                if "optimize_interval" in body:
                    runtime["optimize_interval"] = int(clamp(body["optimize_interval"], 600, 86400, 3600))
                if "notify_url" in body:
                    runtime["notify_url"] = str(body["notify_url"] or "").strip()[:300]
                if "notify_kind" in body:
                    runtime["notify_kind"] = str(body["notify_kind"] or "json")
                if "notify_chat" in body:
                    runtime["notify_chat"] = str(body["notify_chat"] or "").strip()[:64]
                if "notify_min_gap" in body:
                    runtime["notify_min_gap"] = int(clamp(body["notify_min_gap"], 60, 86400, 1800))
                if "speedtest" in body:
                    runtime["speedtest"] = bool(body["speedtest"])
                if "speedtest_mb" in body:
                    runtime["speedtest_mb"] = round(clamp(body["speedtest_mb"], 1, 50, 3), 1)
                if "speedtest_interval" in body:
                    runtime["speedtest_interval"] = int(clamp(body["speedtest_interval"], 300, 604800, 43200))
                if "geo_prefer" in body:
                    runtime["geo_prefer"] = bool(body["geo_prefer"])
                if "pool_extra" in body:
                    runtime["pool_extra"] = bool(body["pool_extra"])
                if "pool_ttl_days" in body:
                    runtime["pool_ttl_days"] = int(clamp(body["pool_ttl_days"], 1, 365, 14))
                save_runtime()
            _wake.set()
            return self._send({"msg": "参数已保存（隧道类参数下次重连生效）"})

        if p == "/api/action":
            a = body.get("action")
            dev = body.get("dev")
            now = time.time()
            if a == "refresh_cache":
                try:
                    n = refresh_cache_internal()
                    return self._send({"msg": "节点库已更新，共 %d 个节点" % n})
                except Exception as e:
                    return self._send({"msg": "更新失败: %s" % e}, code=500)
            if a == "speedtest":
                speedtest_all(background=True)
                return self._send({"msg": "已开始测速（串行进行，每条隧道约 3~15 秒）"})
            if a == "clear_bad":
                bad_nodes.clear()
                return self._send({"msg": "失败黑名单已清空"})
            if a == "test_notify":
                url = str(body.get("url") or "").strip()
                if not url:
                    return self._send({"msg": "没填 Webhook 地址"}, code=400)
                kind = str(body.get("kind") or "json")
                chat = str(body.get("chat") or "")
                text = "这是一条测试通知，来自 %s 的 VPN Gate 面板。" % socket.gethostname()
                payload = ({"chat_id": chat, "text": text} if kind == "telegram"
                           else {"title": "VPN Gate", "text": text})
                r = run(["curl", "-fsS", "-m", "10", "-H", "Content-Type: application/json",
                         "--data-binary", json.dumps(payload, ensure_ascii=False), url], timeout=15)
                if r.returncode == 0:
                    return self._send({"msg": "测试通知发送成功"})
                return self._send({"msg": "发送失败：%s" % ((r.stderr or r.stdout or "")[:120])}, code=502)
            if a == "restart_gost":
                threading.Thread(target=restart_gost, daemon=True).start()
                return self._send({"msg": "gost 重启已触发"})
            if a == "reconnect_all":
                for t in TUNS:
                    t["enabled"] = True
                    t["healthy"] = False
                    t["down_since"] = now
                    t["pinned"] = t["pinned"] or t["node"]
                _wake.set()
                return self._send({"msg": "已重置全部隧道，守护线程开始重连"})
            if a == "stop_all":
                for t in TUNS:
                    t["enabled"] = False
                    disconnect_tunnel(t)
                return self._send({"msg": "已断开全部隧道（点「全部重连」可恢复）"})
            if a in ("reconnect", "disconnect"):
                t = next((x for x in TUNS if x["dev"] == dev), None)
                if not t:
                    return self._send({"msg": "没有这条隧道: %s" % dev}, code=400)
                if a == "disconnect":
                    t["enabled"] = False
                    disconnect_tunnel(t)
                    return self._send({"msg": "%s 已断开" % dev})
                t["enabled"] = True
                t["healthy"] = False
                t["down_since"] = now
                _wake.set()
                return self._send({"msg": "%s 已重置，正在重连" % dev})
            return self._send({"msg": "未知动作: %s" % a}, code=400)

        if p == "/api/refresh_cache":
            try:
                n = refresh_cache_internal()
                return self._send({"msg": "节点库已更新，共 %d 个节点" % n})
            except Exception as e:
                return self._send({"msg": "更新失败: %s" % e}, code=500)

        if p == "/api/connect":
            nid = body.get("id")
            with cfg_lock:
                used = set(t["node"] for t in TUNS if t["healthy"])
            if nid in used:
                return self._send({"msg": "该节点已在某条隧道上使用"}, code=409)
            target = next((t for t in TUNS if not t["healthy"]), None)
            if target is None:
                target = min(TUNS, key=lambda x: x["since"] or 0)
            target["enabled"] = True
            if connect_tunnel(target, nid, wait=13):
                with cfg_lock:
                    auto_cfg["status_msg"] = "%s 已连接到 %s（断线仍会自动修复）" % (target["dev"], nid)
                    save_config()
                return self._send({"msg": "%s 已连接 %s" % (target["dev"], nid)})
            return self._send({"msg": "连接失败，见日志 " + OVPN_LOG}, code=502)

        return self._send({"msg": "not found"}, code=404)

def main():
    srv = ThreadingHTTPServer(("0.0.0.0", PANEL_PORT), Handler)
    srv.daemon_threads = True
    print("panel :%d  tunnels=%d  auth=%s" % (PANEL_PORT, TUNNELS,
                                              "session" if CRED_PASS else "OFF"), flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()
EOF_PY

python3 -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$INSTALL_DIR/vpngate_panel.py" \
  && ok "面板语法校验通过" || { err "面板语法错误，已中止"; exit 1; }

# ==============================================================================
step "8/9" "注册面板服务"
# ==============================================================================
# 先拿到公网 IP，面板要用它生成可直接复制的接入链接
PUBLIC_IP=$(curl -fsS4 -m 8 https://api.ipify.org 2>/dev/null || curl -fsS4 -m 8 https://ip.sb 2>/dev/null \
            || curl -fsS4 -m 8 https://ifconfig.me 2>/dev/null || echo "")
if ! echo "$PUBLIC_IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
  PUBLIC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
fi
echo "$PUBLIC_IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || PUBLIC_IP=""

cat > /etc/systemd/system/vpngate.service <<EOF_SVC
[Unit]
Description=VPN Gate Panel and Multi-Tunnel Watchdog
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment=PANEL_PORT=${PANEL_PORT}
Environment=SOCKS5_PORT=${SOCKS5_PORT}
Environment=SS_PORT=${SS_PORT}
Environment=ROUTE_TABLE=${ROUTE_TABLE}
Environment=VPNGATE_TABLE=${ROUTE_TABLE}
Environment=TUNNELS=${TUNNELS}
Environment=CANDIDATES=${CANDIDATES}
Environment=SESSION_CAP=${SESSION_CAP}
Environment=PANEL_USER=${PANEL_USER}
Environment=PANEL_PASS=${PANEL_PASS}
Environment=SOCKS5_PASS=${SOCKS5_PASS}
Environment=SS_PASS=${SS_PASS}
Environment=SS2022_PASS=${SS2022_PASS}
Environment=SS2022_PORT=${SS2022_PORT}
Environment=SSU_PORT=${SSU_PORT}
Environment=STICKY_BASE=${STICKY_BASE}
Environment=STICKY=${STICKY}
Environment=PUBLIC_IP=${PUBLIC_IP:-}
Environment=FIX_MTU=${FIX_MTU}
Environment=MSSFIX=${MSSFIX}
Environment=PREFER_TCP=${PREFER_TCP}
Environment=GOST_REBIND=${GOST_REBIND:-0}
Environment=FAST_POLL=${FAST_POLL:-1.0}
Environment=HEALTH_POLL=${HEALTH_POLL:-3.0}
Environment=PING_RESTART=${PING_RESTART:-20}
Environment=INSTALL_DIR=${INSTALL_DIR}
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/vpngate_panel.py
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF_SVC

cat > "$INSTALL_DIR/vpngate_auto.json" <<EOF_CFG
{
  "mode": "auto",
  "p1": "${DEFAULT_P1}",
  "p2": "${DEFAULT_P2}",
  "p3": "${DEFAULT_P3}",
  "interval": 30,
  "status_msg": "正在初始化多隧道守护...",
  "last_check": "尚未检测"
}
EOF_CFG

# 面板凭据单独落盘：重装时以这里为准，保证 info 文件里的密码和实际登录一致
python3 - "$PANEL_USER" "$PANEL_PASS" "$INSTALL_DIR/vpngate_credentials.json" <<'PYCRED'
import json, os, sys
user, pwd, path = sys.argv[1], sys.argv[2], sys.argv[3]
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump({"user": user, "pass": pwd}, f, ensure_ascii=False)
os.replace(tmp, path)
os.chmod(path, 0o600)
PYCRED
ok "面板登录凭据已写入 ${INSTALL_DIR}/vpngate_credentials.json"

systemctl daemon-reload
systemctl enable vpngate >/dev/null 2>&1
systemctl restart vpngate >/dev/null 2>&1
sleep 2
if systemctl is-active --quiet vpngate; then ok "面板已启动 (port ${PANEL_PORT})"
else
  err "面板启动失败，最近日志："
  journalctl -u vpngate -n 20 --no-pager 2>/dev/null | sed 's/^/     /'
  exit 1
fi

# ==============================================================================
step "9/9" "防火墙 + 信息清单"
# ==============================================================================
ALL_TCP_PORTS="$PANEL_PORT $SOCKS5_PORT $SS_PORT $SS2022_PORT"
[ "$STICKY" = "1" ] && for i in $(seq 0 $((TUNNELS-1))); do ALL_TCP_PORTS="$ALL_TCP_PORTS $((STICKY_BASE+i))"; done
for P in $ALL_TCP_PORTS; do
  iptables -C INPUT -p tcp --dport "$P" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport "$P" -j ACCEPT 2>/dev/null || true
done
for P in $SSU_PORT; do
  iptables -C INPUT -p udp --dport "$P" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p udp --dport "$P" -j ACCEPT 2>/dev/null || true
done
command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true

SERVER_IP="$PUBLIC_IP"
[ -n "$SERVER_IP" ] || { SERVER_IP="你的VPS公网IP"; warn "无法识别公网 IP，请自行替换"; }

SS_B64=$(printf 'aes-256-gcm:%s' "$SS_PASS" | base64 | tr -d '\n')
SS_LINK="ss://${SS_B64}@${SERVER_IP}:${SS_PORT}#VPN-Gate"
SS22_B64=$(printf '2022-blake3-aes-256-gcm:%s' "$SS2022_PASS" | base64 | tr -d '\n')
SS22_LINK="ss://${SS22_B64}@${SERVER_IP}:${SS2022_PORT}#VPN-Gate-SS2022"
SSU_LINK="ssu://2022-blake3-aes-256-gcm:${SS2022_PASS}@${SERVER_IP}:${SSU_PORT}"
SOCKS_LINK="socks5://${PANEL_USER}:${SOCKS5_PASS}@${SERVER_IP}:${SOCKS5_PORT}#VPN-Gate"
HTTP_LINK="http://${PANEL_USER}:${SOCKS5_PASS}@${SERVER_IP}:${SOCKS5_PORT}"

STICKY_INFO=""
if [ "$STICKY" = "1" ]; then
  STICKY_INFO="5. 粘性出口（每条隧道一个固定端口，出口 IP 不跳动）"
  for i in $(seq 0 $((TUNNELS-1))); do
    STICKY_INFO="${STICKY_INFO}
   tun${i}: socks5://${PANEL_USER}:${SOCKS5_PASS}@${SERVER_IP}:$((STICKY_BASE+i))
        (同一个端口也接受 HTTP 代理，如 http://${PANEL_USER}:${SOCKS5_PASS}@${SERVER_IP}:$((STICKY_BASE+i)))"
  done
fi

cat > "$INSTALL_DIR/vpngate_info.txt" <<EOF_INFO
========================================================
        VPN Gate 多隧道聚合 信息清单
========================================================
1. 控制面板:  http://${SERVER_IP}:${PANEL_PORT}
   面板账号:  ${PANEL_USER}
   面板密码:  ${PANEL_PASS}

2. 聚合入口（SOCKS5 + HTTP 同一端口，自动识别）
   SOCKS5: ${SOCKS_LINK}
   HTTP:   ${HTTP_LINK}
   用户: ${PANEL_USER}   密码: ${SOCKS5_PASS}   端口: ${SOCKS5_PORT}
   出口在 ${TUNNELS} 条隧道间轮询 —— 会换 IP，别用于账号绑定

3. Shadowsocks (aes-256-gcm):  ${SS_LINK}
4. Shadowsocks 2022 (blake3):  ${SS22_LINK}
   UDP 中继:  ${SSU_LINK}   (UDP 端口 ${SSU_PORT})

${STICKY_INFO}

6. 架构: ${TUNNELS} 条隧道聚合（tun0..tun$((TUNNELS-1))）
   聚合口出口接口列表: ${IFACE_LIST}
   路由表: ${ROUTE_TABLE} ~ $((ROUTE_TABLE+TUNNELS-1))
   拥塞控制: BBR=${ENABLE_BBR}   MSS: ${MSSFIX}
========================================================
EOF_INFO
chmod 600 "$INSTALL_DIR/vpngate_info.txt"

echo
echo -e "${G}========================================================${N}"
echo -e "${G}🎉 部署完成（${TUNNELS} 条隧道聚合）${N}"
echo -e "${G}========================================================${N}"
echo -e "🌐 面板: ${C}http://${SERVER_IP}:${PANEL_PORT}${N}  ${W}${PANEL_USER}${N} / ${W}${PANEL_PASS}${N}"
echo -e "🧦 聚合 SOCKS5+HTTP: ${Y}${SOCKS_LINK}${N}"
echo -e "🛡  SS:      ${C}${SS_LINK}${N}"
echo -e "🛡  SS2022:  ${C}${SS22_LINK}${N}"
[ "$STICKY" = "1" ] && echo -e "📌 粘性出口: ${C}${SERVER_IP}:$((STICKY_BASE))..$((STICKY_BASE+TUNNELS-1))${N}  (出口 IP 不跳动)"
echo
echo -e "${Y}===== 自检（最多 90 秒，逐条隧道确认） =====${N}"
python3 - <<'PYCHECK'
import time, subprocess, json, os, re
TUN = int(os.environ.get("TUNNELS", "3"))
PANEL = os.environ.get("PANEL_PORT", "5000")
def run(c, t=15):
    try:
        return subprocess.run(c, capture_output=True, text=True, timeout=t)
    except Exception:
        class R: returncode = 1; stdout = ""; stderr = ""
        return R()
for i in range(18):
    time.sleep(5)
    up = [d for d in ["tun%d" % k for k in range(TUN)] if run(["ip","link","show",d], 5).returncode == 0]
    if len(up) >= TUN:
        break
    print("  \033[33m…\033[0m 已建立 %d/%d 条隧道 (%ds)" % (len(up), TUN, (i+1)*5))
ips = []
for d in ["tun%d" % k for k in range(TUN)]:
    if run(["ip","link","show",d], 5).returncode != 0:
        print("  \033[31m✘\033[0m %s 未建立" % d); continue
    r = run(["curl","--interface",d,"-m","6","-s","https://ipinfo.io/json"], 10)
    if r.returncode == 0 and r.stdout.strip().startswith("{"):
        j = json.loads(r.stdout)
        ips.append(j.get("ip"))
        print("  \033[32m✔\033[0m %s -> %s (%s %s)" % (d, j.get("ip"), j.get("country"), j.get("org","")[:28]))
    else:
        print("  \033[33m▲\033[0m %s 设备在但出网未通" % d)
if len(ips) > 1:
    print("  \033[32m✔\033[0m 聚合生效：%d 条独立出口（gost 按连接轮询分流）" % len(ips))
elif len(ips) == 1:
    print("  \033[33m▲\033[0m 仅 1 条出口可用，其余隧道仍在恢复中（守护线程会自动补齐）" % ())
else:
    print("  \033[31m✘\033[0m 无可用出口，执行： bash diag.sh")
PYCHECK

echo
echo -e "${Y}维护命令:${N}"
echo -e "  vg                                     # 一眼看状态（不用开面板）"
echo -e "  vg dir                                 # 看安装目录内容"
echo -e "  cat ${INSTALL_DIR}/vpngate_info.txt   # 账号与接入链接清单"
echo -e "  curl -s -u ${PANEL_USER}:*** 127.0.0.1:${PANEL_PORT}/api/diag   # 运行态（需登录）"
echo -e "  for i in \$(seq 0 $((TUNNELS-1))); do ip -4 addr show tun\$i | grep inet; done"
echo -e "  tail -f ${INSTALL_DIR}/openvpn.log   # 隧道日志"
echo -e "${Y}提醒:${N} 云平台安全组需放行这些端口："
echo -e "      TCP ${PANEL_PORT}(面板) ${SOCKS5_PORT}(聚合) ${SS_PORT}(SS) ${SS2022_PORT}(SS2022)"
[ "$STICKY" = "1" ] && echo -e "      TCP $((STICKY_BASE))~$((STICKY_BASE+TUNNELS-1))(粘性出口)   UDP ${SSU_PORT}(SS UDP)"
echo -e "      本机 iptables ≠ 云防火墙，GCP/AWS/甲骨文 必须去控制台放行。"
echo -e "${G}========================================================${N}"
