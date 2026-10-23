#!/bin/bash

# ================= 动态生成随机密码与端口 =================
PANEL_PORT="5000"
SOCKS5_PORT="10808"
SS_PORT="10809"

SOCKS5_USER="admin"
# 为 SOCKS5 随机生成 12 位密码
SOCKS5_PASS=$(head -c 32 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 12)
# 为 Shadowsocks 随机生成 16 位高强度密码
SS_PASS=$(head -c 32 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)
# ==========================================================

echo -e "\033[36m========================================================\033[0m"
echo -e "\033[36m    🚀 VPN Gate 家宽落地与自动化面板 一键部署程序       \033[0m"
echo -e "\033[36m========================================================\033[0m"

echo -e "\033[32m[1/6] 正在配置系统环境并安装依赖组件...\033[0m"
export DEBIAN_FRONTEND=noninteractive

# 解除可能的后台锁
killall apt apt-get 2>/dev/null || true
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* 2>/dev/null || true
dpkg --configure -a >/dev/null 2>&1 || true

apt-get update -y >/dev/null 2>&1 || true
apt-get install -y software-properties-common curl iproute2 iptables >/dev/null 2>&1 || true
add-apt-repository -y universe >/dev/null 2>&1 || true
apt-get update -y >/dev/null 2>&1 || true

# 安装核心依赖
apt-get install -y openvpn python3 python3-flask python3-requests docker.io || {
    apt-get install -y openvpn python3 python3-flask python3-requests
}

# 确保 TUN/TAP 设备在内核中就绪
if [ ! -c /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 666 /dev/net/tun 2>/dev/null || true
fi

# 智能识别 Docker
if ! command -v docker &> /dev/null; then
    apt-get install -y docker.io || true
fi
systemctl enable --now docker >/dev/null 2>&1 || systemctl restart docker >/dev/null 2>&1 || true

# 准备 VPN Gate 全球通用认证凭据文件
cat << 'EOF_AUTH' > /opt/vpngate_auth.txt
vpn
vpn
EOF_AUTH
chmod 600 /opt/vpngate_auth.txt

# 初始化自动看门狗配置文件
cat << 'EOF_CFG' > /opt/vpngate_auto.json
{
  "mode": "auto",
  "p1": "JP",
  "p2": "KR",
  "p3": "US",
  "interval": 30,
  "status_msg": "正在初始化自愈看门狗...",
  "last_check": "尚未检测"
}
EOF_CFG

echo -e "\033[32m[2/6] 配置策略路由与守护规则 (/opt/up.sh)...\033[0m"
cat << 'EOF_UP' > /opt/up.sh
#!/bin/bash
ip route flush table 100 2>/dev/null || true
while ip rule del table 100 2>/dev/null; do :; done
ip route replace default via $route_vpn_gateway dev $dev table 100
ip rule add from $ifconfig_local table 100
docker restart vpngate-proxy >/dev/null 2>&1 &
exit 0
EOF_UP
chmod +x /opt/up.sh

echo -e "\033[32m[3/6] 启动多协议 Gost 网关服务 (独立双密码隔离)...\033[0m"
docker rm -f vpngate-proxy vpngate-socks5 vpngate-ss 2>/dev/null || true
docker run -d --name vpngate-proxy \
  --net=host \
  --restart=always \
  gogost/gost \
  -L "socks5://${SOCKS5_USER}:${SOCKS5_PASS}@0.0.0.0:${SOCKS5_PORT}?interface=tun0" \
  -L "ss://aes-256-gcm:${SS_PASS}@0.0.0.0:${SS_PORT}?interface=tun0" >/dev/null 2>&1

echo -e "\033[32m[4/6] 同步 VPN Gate 官方节点缓存...\033[0m"
curl -sL -m 20 "https://www.vpngate.net/api/iphone/" -o /opt/vpngate_cache.csv || touch /opt/vpngate_cache.csv

echo -e "\033[32m[5/6] 部署 Web 控制面板与自愈看门狗 (Port: ${PANEL_PORT})...\033[0m"
cat << 'EOF_PY' > /opt/vpngate_panel.py
import os, sys, time, json, math, base64, subprocess, threading, re, socket, urllib.request, csv, io, concurrent.futures
from flask import Flask, jsonify, render_template_string, request

csv.field_size_limit(sys.maxsize)
app = Flask(__name__)

CACHE_FILE = "/opt/vpngate_cache.csv"
ACTIVE_OVPN = "/tmp/vpngate_current.ovpn"
CONFIG_FILE = "/opt/vpngate_auto.json"
AUTH_FILE = "/opt/vpngate_auth.txt"
OVPN_LOG = "/var/log/openvpn_vpngate.log"

cached_nodes, node_list_cache = {}, []
last_connect_time = 0

auto_cfg = {
    "mode": "auto",
    "p1": "JP",
    "p2": "KR",
    "p3": "US",
    "interval": 30,
    "status_msg": "正在初始化守护线程...",
    "last_check": "尚未检测"
}

def load_config():
    global auto_cfg
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                auto_cfg.update(json.load(f))
        except Exception: pass

def save_config():
    try:
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump(auto_cfg, f, ensure_ascii=False, indent=2)
    except Exception: pass

load_config()

def get_openvpn_ver():
    try:
        out = subprocess.run(["openvpn", "--version"], capture_output=True, text=True).stdout
        m = re.search(r"OpenVPN\s+(\d+)\.(\d+)", out)
        if m: return int(m.group(1)), int(m.group(2))
    except Exception: pass
    return 2, 4

def check_tun0_health():
    if subprocess.run(["ip", "link", "show", "tun0"], capture_output=True).returncode != 0:
        return False
    res = subprocess.run(["curl", "--interface", "tun0", "-m", "4", "-s", "-o", "/dev/null", "-w", "%{http_code}", "http://connectivitycheck.gstatic.com/generate_204"], capture_output=True, text=True)
    return res.stdout.strip() in ["204", "200"]

def do_connect_node(nid):
    global last_connect_time
    last_connect_time = time.time()
    if nid not in cached_nodes: return False
    
    maj, min_v = get_openvpn_ver()
    raw_ovpn = base64.b64decode(cached_nodes[nid]).decode("utf-8", "ignore")
    
    # 基础安全头（绝不污染系统主路由）
    headers = [
        "route-nopull",
        "route-noexec",
        "auth-user-pass " + AUTH_FILE,
        "auth-retry nointeract",
        "script-security 2",
        "up /opt/up.sh"
    ]
    
    cleaned_lines = []
    if (maj, min_v) >= (2, 6):
        headers.extend([
            "tls-cert-profile insecure",
            "data-ciphers AES-128-CBC:AES-256-CBC:AES-128-GCM:AES-256-GCM",
            "data-ciphers-fallback AES-128-CBC"
        ])
        cleaned_lines = raw_ovpn.splitlines()
    elif (maj, min_v) == (2, 5):
        headers.extend([
            "data-ciphers AES-128-CBC:AES-256-CBC:AES-128-GCM:AES-256-GCM",
            "data-ciphers-fallback AES-128-CBC"
        ])
        cleaned_lines = raw_ovpn.splitlines()
    else:
        # 针对 OpenVPN 2.4.x（如 Ubuntu 20.04）进行深度清洗
        headers.extend([
            "ignore-unknown-option data-ciphers data-ciphers-fallback tls-cert-profile",
            "cipher AES-128-CBC",
            "ncp-ciphers AES-128-GCM:AES-256-GCM:AES-128-CBC:AES-256-CBC"
        ])
        # 彻底剔除原始配置中导致 2.4 崩溃的第 104 行 data-ciphers 等新语法
        for line in raw_ovpn.splitlines():
            s = line.strip()
            if re.match(r'^(data-ciphers|data-ciphers-fallback|tls-cert-profile)\b', s, re.IGNORECASE):
                continue
            cleaned_lines.append(line)
            
    final_ovpn = "\n".join(headers) + "\n" + "\n".join(cleaned_lines)
    with open(ACTIVE_OVPN, "w") as f:
        f.write(final_ovpn)
        
    subprocess.run(["pkill", "-9", "-f", "openvpn"])
    subprocess.run(["ip", "link", "delete", "tun0"], capture_output=True)
    time.sleep(1)

    cmd = [
        "openvpn", "--config", ACTIVE_OVPN, "--dev", "tun0",
        "--log", OVPN_LOG, "--daemon"
    ]
    subprocess.Popen(cmd)
    return True

def watchdog_thread():
    global auto_cfg
    time.sleep(3)
    while True:
        if auto_cfg.get("mode", "auto") == "manual":
            auto_cfg["status_msg"] = "📌 手动锁定模式中，自动切线已暂停"
            time.sleep(auto_cfg.get("interval", 30))
            continue

        auto_cfg["last_check"] = time.strftime("%H:%M:%S")
        if check_tun0_health():
            auto_cfg["status_msg"] = "网络健康，当前节点持续正常运行"
            time.sleep(auto_cfg.get("interval", 30))
            continue

        auto_cfg["status_msg"] = "⚠️ 检测到节点离线，正在按优先级自动重连..."
        priorities = [auto_cfg.get("p1", "JP"), auto_cfg.get("p2", "KR"), auto_cfg.get("p3", "US")]
        connected_success = False
        
        for country in priorities:
            if country == "NONE": continue
            candidates = [n for n in node_list_cache if (country == "ALL" or n["country"] == country)]
            candidates.sort(key=lambda x: x["ping"])
            
            for cand in candidates[:8]:
                auto_cfg["status_msg"] = f"正在尝试连接 {cand['country']} ({cand['ip']})..."
                do_connect_node(cand["id"])
                time.sleep(9)
                if check_tun0_health():
                    auto_cfg["status_msg"] = f"✅ 已成功建立连接，当前落地: {cand['country']} ({cand['ip']})"
                    connected_success = True
                    break
            if connected_success: break
            
        if not connected_success:
            auto_cfg["status_msg"] = "❌ 本轮重连未成功，等待下次巡检重试"
            
        time.sleep(auto_cfg.get("interval", 30))

def parse_cache():
    global cached_nodes, node_list_cache
    if not os.path.exists(CACHE_FILE): return
    with open(CACHE_FILE, "r", encoding="utf-8", errors="ignore") as f:
        lines = [l for l in f.read().splitlines() if not l.startswith("*")]
    new_c, new_l = {}, []
    for r in csv.DictReader(io.StringIO("\n".join(lines))):
        cfg, ip = r.get("OpenVPN_ConfigData_Base64"), r.get("IP")
        if cfg and ip:
            new_c[ip] = cfg
            p = int(r.get("Ping") or 9999) if str(r.get("Ping")).isdigit() else 9999
            s = int(r.get("Speed") or 0) if str(r.get("Speed")).isdigit() else 0
            score = int(r.get("Score") or 0) if str(r.get("Score")).isdigit() else 0
            port, proto = "1194", "udp"
            try:
                ovpn_text = base64.b64decode(cfg).decode("utf-8", "ignore")
                m_port = re.search(r"^remote\s+[\d\.\w\-]+\s+(\d+)", ovpn_text, re.M)
                if m_port: port = m_port.group(1)
                if "proto tcp" in ovpn_text.lower(): proto = "tcp"
            except Exception: pass
            new_l.append({
                "id": ip, "ip": ip, "port": port, "proto": proto.upper(),
                "country": r.get("CountryShort", "UN"), "country_long": r.get("CountryLong", "Unknown"),
                "ping": p, "speed": round(s/1000000, 1), "score": score
            })
    cached_nodes, node_list_cache = new_c, new_l

parse_cache()
threading.Thread(target=watchdog_thread, daemon=True).start()

HTML = """<!DOCTYPE html><html><head><meta charset="utf-8"><title>VPN Gate 落地控制中心</title>
<style>
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#edf2f7;padding:20px;color:#2d3748}
.card{background:#fff;padding:24px;border-radius:10px;max-width:1150px;margin:auto;box-shadow:0 4px 6px rgba(0,0,0,0.05)}
.header{display:flex;justify-content:space-between;align-items:center;margin-bottom:15px}
.status{background:#e6fffa;border:1px solid #b2f5ea;padding:12px 16px;border-radius:8px;margin-bottom:15px;font-weight:600;color:#234e52;display:flex;justify-content:space-between;align-items:center}
.mode-btn{border:none;border-radius:20px;padding:6px 16px;font-weight:bold;cursor:pointer;font-size:13px;transition:0.2s;box-shadow:0 2px 4px rgba(0,0,0,0.08)}
.mode-auto{background:#38a169;color:#fff}
.mode-auto:hover{background:#2f855a}
.mode-manual{background:#ed8936;color:#fff}
.mode-manual:hover{background:#dd6b20}
.auto-card{background:#fffaf0;border:1px solid #feebc8;border-radius:8px;padding:14px;margin-bottom:18px}
.auto-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:10px}
.auto-body{display:flex;flex-wrap:wrap;gap:12px;align-items:center;font-size:14px}
.filters{display:flex;flex-wrap:wrap;gap:12px;background:#f7fafc;padding:14px;border-radius:8px;margin-bottom:18px;align-items:center;font-size:14px}
.filter-item{display:flex;align-items:center;gap:6px}
select,input[type="number"],button{padding:6px 12px;border:1px solid #cbd5e0;border-radius:6px;font-size:14px;background:#fff}
button{background:#3182ce;color:#fff;border:none;cursor:pointer;font-weight:500;transition:0.2s}
button:hover{background:#2b6cb0}
button.update-btn{background:#38a169}
button.update-btn:hover{background:#2f855a}
button.gray{background:#a0aec0}
table{width:100%;border-collapse:collapse;margin-top:10px}
th,td{padding:10px 12px;border-bottom:1px solid #e2e8f0;text-align:left;font-size:13px}
th{background:#f8fafc;color:#4a5568}
.badge-online{background:#c6f6d5;color:#22543d;padding:2px 8px;border-radius:4px;font-size:12px;font-weight:bold}
.badge-offline{background:#fed7d7;color:#742a2a;padding:2px 8px;border-radius:4px;font-size:12px}
.pagination{display:flex;justify-content:space-between;align-items:center;margin-top:16px;font-size:14px}
.page-btns{display:flex;gap:8px}
</style></head>
<body><div class="card">
<div class="header">
  <h2 style="margin:0;">🌐 VPN Gate 落地控制中心</h2>
  <button class="update-btn" onclick="updateCache()" id="btn-sync">📥 更新官方节点库</button>
</div>

<div class="status">
  <div><span id="st">出口状态检测中...</span></div>
  <div style="display:flex;align-items:center;gap:12px;">
    <button id="btn-mode" class="mode-btn mode-auto" onclick="toggleMode()">🟢 模式：自动保活 (点击切为手动)</button>
    <span style="font-size:12px;color:#4a5568">每 10 秒同步</span>
  </div>
</div>

<div class="auto-card">
  <div class="auto-header">
    <div style="font-weight:bold;color:#c05621;display:flex;align-items:center;gap:8px;">
      <span>🤖 自动断线重连守护 (Auto-Failover)</span>
    </div>
    <span id="auto_status_msg" style="font-size:13px;color:#744210;">正在获取守护状态...</span>
  </div>
  <div class="auto-body">
    <div class="filter-item">第一顺位: <select id="p1" onchange="saveAutoSettings()"></select></div>
    <div class="filter-item">第二顺位: <select id="p2" onchange="saveAutoSettings()"></select></div>
    <div class="filter-item">第三顺位: <select id="p3" onchange="saveAutoSettings()"></select></div>
    <div class="filter-item">巡检间隔: <input type="number" id="auto_int" value="30" min="15" max="300" style="width:65px" onchange="saveAutoSettings()"> 秒</div>
    <button onclick="saveAutoSettings()">💾 保存优先级配置</button>
  </div>
</div>

<div class="filters">
  <div class="filter-item">查看国家: <select id="c" onchange="goPage(1)"></select></div>
  <div class="filter-item">协议: <select id="proto" onchange="goPage(1)"><option value="ALL">全部协议</option><option value="UDP">仅 UDP</option><option value="TCP">仅 TCP</option></select></div>
  <div class="filter-item">排序: <select id="sort" onchange="goPage(1)"><option value="ping">最低延迟 (Ping)</option><option value="speed">最高带宽 (Speed)</option><option value="score">最高评分 (Score)</option></select></div>
  <div class="filter-item">每页: <select id="size" onchange="goPage(1)"><option value="15">15 条</option><option value="25" selected>25 条</option><option value="50">50 条</option></select></div>
  <button onclick="loadNodes()">🔄 刷新列表</button>
</div>

<table>
  <thead><tr><th>国家/地区</th><th>IP:端口</th><th>协议</th><th>Ping</th><th>带宽</th><th>操作</th></tr></thead>
  <tbody id="tb"><tr><td colspan=6>加载中...</td></tr></tbody>
</table>

<div class="pagination">
  <span id="page-info">第 1 页 / 共 1 页 (0 个节点)</span>
  <div class="page-btns">
    <button id="btn-prev" onclick="changePage(-1)">上一页</button>
    <button id="btn-next" onclick="changePage(1)">下一页</button>
  </div>
</div>
</div>

<script>
let currentPage = 1, totalPages = 1;

function renderModeBtn(mode){
  let btn = document.getElementById("btn-mode");
  if(mode === "manual"){
    btn.className = "mode-btn mode-manual";
    btn.innerHTML = "📌 模式：手动锁定 (点击切为自动)";
  } else {
    btn.className = "mode-btn mode-auto";
    btn.innerHTML = "🟢 模式：自动保活 (点击切为手动)";
  }
}

function toggleMode(){
  let btn = document.getElementById("btn-mode");
  btn.disabled = true;
  fetch("/api/toggle_mode", {method: "POST"}).then(r=>r.json()).then(d=>{
    renderModeBtn(d.mode);
    document.getElementById("auto_status_msg").innerText = d.msg;
    btn.disabled = false;
  }).catch(()=>{ btn.disabled = false; });
}

function up(){
  fetch("/api/status").then(r=>r.json()).then(d=>{
    document.getElementById("st").innerText = d.ip ? "🟢 当前落地: " + d.ip + " (" + d.country + " " + d.city + ") | " + d.org : "🔴 尚未连接节点 (离线状态)";
  }).catch(()=>{ document.getElementById("st").innerText = "🔴 状态获取失败"; });

  fetch("/api/autowatch").then(r=>r.json()).then(cfg=>{
    renderModeBtn(cfg.mode || "auto");
    document.getElementById("auto_status_msg").innerText = `[${cfg.last_check}] ${cfg.status_msg}`;
  });
}

function loadCountriesAndPriorities(){
  fetch("/api/countries").then(r=>r.json()).then(list=>{
    let s = document.getElementById("c");
    let p1 = document.getElementById("p1"), p2 = document.getElementById("p2"), p3 = document.getElementById("p3");
    let optHtml = '<option value="ALL">全部国家 / 任意</option>';
    list.forEach(i=>{ optHtml += `<option value="${i.code}">${i.name} (${i.code}) [${i.count}个]</option>`; });
    s.innerHTML = optHtml;
    let prioOptHtml = '<option value="NONE">-- 不选 --</option>' + optHtml;
    p1.innerHTML = prioOptHtml; p2.innerHTML = prioOptHtml; p3.innerHTML = prioOptHtml;
    fetch("/api/autowatch").then(r=>r.json()).then(cfg=>{
      renderModeBtn(cfg.mode || "auto");
      document.getElementById("p1").value = cfg.p1 || "JP";
      document.getElementById("p2").value = cfg.p2 || "KR";
      document.getElementById("p3").value = cfg.p3 || "US";
      document.getElementById("auto_int").value = cfg.interval || 30;
    });
  });
}

function saveAutoSettings(){
  let payload = {
    p1: document.getElementById("p1").value,
    p2: document.getElementById("p2").value,
    p3: document.getElementById("p3").value,
    interval: parseInt(document.getElementById("auto_int").value) || 30
  };
  fetch("/api/autowatch", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(payload)})
    .then(r=>r.json()).then(res=>{ document.getElementById("auto_status_msg").innerText = "优先级参数已保存"; });
}

function loadNodes(){
  let c = document.getElementById("c").value || "ALL";
  let proto = document.getElementById("proto").value;
  let sort = document.getElementById("sort").value;
  let size = document.getElementById("size").value;
  document.getElementById("tb").innerHTML = "<tr><td colspan=6 style='text-align:center;'>正在读取节点列表...</td></tr>";
  fetch(`/api/nodes?country=${c}&proto=${proto}&sort=${sort}&page=${currentPage}&size=${size}`).then(r=>r.json()).then(data=>{
    currentPage = data.page; totalPages = data.total_pages || 1;
    document.getElementById("page-info").innerText = `第 ${data.page} 页 / 共 ${totalPages} 页 (符合筛选: ${data.total} 个)`;
    document.getElementById("btn-prev").disabled = (currentPage <= 1);
    document.getElementById("btn-next").disabled = (currentPage >= totalPages);
    let h = "";
    data.nodes.forEach(n=>{
      let btn = `<button onclick="conn('${n.id}')">连接此节点</button>`;
      h += `<tr><td>${n.country_long} (${n.country})</td><td>${n.ip}:${n.port}</td><td><b>${n.proto}</b></td><td>${n.ping}ms</td><td>${n.speed}Mbps</td><td>${btn}</td></tr>`;
    });
    document.getElementById("tb").innerHTML = h || "<tr><td colspan=6 style='text-align:center;'>该筛选条件下暂无节点</td></tr>";
  });
}

function goPage(p){ currentPage = p; loadNodes(); }
function changePage(delta){ let target = currentPage + delta; if(target >= 1 && target <= totalPages){ currentPage = target; loadNodes(); } }
function updateCache(){
  let btn = document.getElementById("btn-sync");
  btn.disabled = true; btn.innerText = "⏳ 正在同步最新官方节点池...";
  fetch("/api/refresh_cache", {method:"POST"}).then(r=>r.json()).then(res=>{
    alert(res.msg); btn.disabled = false; btn.innerText = "📥 更新官方节点库";
    loadCountriesAndPriorities(); goPage(1);
  }).catch(e=>{ alert("更新失败: " + e); btn.disabled = false; btn.innerText = "📥 更新官方节点库"; });
}

function conn(id){
  document.getElementById("st").innerText = "正在连接 " + id + "，请等待 8 秒...";
  fetch("/api/connect", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id})})
    .then(r=>r.json()).then(d=>{
      renderModeBtn("manual");
      alert(d.msg + "（已自动转为手动锁定模式）");
      setTimeout(up, 7000);
    });
}

up(); loadCountriesAndPriorities(); setTimeout(loadNodes, 300); setInterval(up, 10000);
</script></body></html>"""

@app.route("/")
def index(): return render_template_string(HTML)

@app.route("/api/status")
def status():
    if subprocess.run(["ip", "link", "show", "tun0"], capture_output=True).returncode != 0: return jsonify({"ip": None})
    res = subprocess.run(["curl", "--interface", "tun0", "-m", "4", "-s", "https://ipinfo.io/json"], capture_output=True, text=True)
    return (res.stdout, 200, {"Content-Type": "application/json"}) if res.returncode == 0 and res.stdout.strip() else jsonify({"ip": None})

@app.route("/api/toggle_mode", methods=["POST"])
def toggle_mode():
    global auto_cfg
    new_mode = "manual" if auto_cfg.get("mode", "auto") == "auto" else "auto"
    auto_cfg["mode"] = new_mode
    if new_mode == "auto":
        auto_cfg["status_msg"] = "🟢 已切换为【自动模式】，后台将按优先级持续保活"
    else:
        auto_cfg["status_msg"] = "📌 已切换为【手动模式】，后台暂停自动跨国切线"
    save_config()
    return jsonify({"mode": new_mode, "msg": auto_cfg["status_msg"]})

@app.route("/api/autowatch", methods=["GET", "POST"])
def autowatch():
    global auto_cfg
    if request.method == "POST":
        data = request.get_json() or {}
        if "mode" in data: auto_cfg["mode"] = data.get("mode")
        auto_cfg["p1"] = data.get("p1", "JP")
        auto_cfg["p2"] = data.get("p2", "KR")
        auto_cfg["p3"] = data.get("p3", "US")
        auto_cfg["interval"] = max(15, int(data.get("interval", 30)))
        save_config()
        return jsonify({"msg": "配置已保存", "cfg": auto_cfg})
    return jsonify(auto_cfg)

@app.route("/api/countries")
def get_countries():
    counts, names = {}, {}
    for n in node_list_cache:
        c = n["country"]
        counts[c] = counts.get(c, 0) + 1
        names[c] = n["country_long"]
    sorted_countries = sorted(counts.items(), key=lambda x: x[1], reverse=True)
    return jsonify([{"code": code, "name": names.get(code, code), "count": count} for code, count in sorted_countries])

@app.route("/api/refresh_cache", methods=["POST"])
def refresh_cache():
    try:
        req = urllib.request.Request("https://www.vpngate.net/api/iphone/", headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            content = resp.read().decode("utf-8", "ignore")
            if "OpenVPN_ConfigData_Base64" in content:
                with open(CACHE_FILE, "w", encoding="utf-8") as f: f.write(content)
                parse_cache()
                return jsonify({"msg": f"成功更新官方节点库！当前总共 {len(node_list_cache)} 个节点"})
            return jsonify({"msg": "数据格式异常"}), 500
    except Exception as e: return jsonify({"msg": f"获取失败: {str(e)}"}), 500

@app.route("/api/nodes")
def get_nodes():
    c = request.args.get("country", "ALL")
    proto = request.args.get("proto", "ALL")
    sort_by = request.args.get("sort", "ping")
    page = int(request.args.get("page", 1))
    size = int(request.args.get("size", 25))
    filtered = node_list_cache
    if c != "ALL": filtered = [n for n in filtered if n["country"] == c]
    if proto != "ALL": filtered = [n for n in filtered if n["proto"] == proto]
    if sort_by == "speed": filtered.sort(key=lambda x: x["speed"], reverse=True)
    elif sort_by == "score": filtered.sort(key=lambda x: x["score"], reverse=True)
    else: filtered.sort(key=lambda x: x["ping"])
    total = len(filtered)
    total_pages = math.ceil(total / size) if total > 0 else 1
    page = max(1, min(page, total_pages))
    page_nodes = filtered[(page - 1) * size : page * size]
    return jsonify({"total": total, "page": page, "page_size": size, "total_pages": total_pages, "nodes": page_nodes})

@app.route("/api/connect", methods=["POST"])
def connect():
    nid = (request.get_json() or {}).get("id")
    if do_connect_node(nid):
        auto_cfg["mode"] = "manual"
        auto_cfg["status_msg"] = f"📌 已手动发起连接节点 {nid}，模式锁定为手动"
        save_config()
        return jsonify({"msg": "已发起连接: " + nid, "mode": "manual"})
    return jsonify({"msg": "节点不存在"}), 400

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
EOF_PY

# 注册为 systemd 系统守护进程，开机自启
cat << 'EOF_SERVICE' > /etc/systemd/system/vpngate.service
[Unit]
Description=VPN Gate Panel and Watchdog
After=network.target docker.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt
ExecStart=/usr/bin/python3 /opt/vpngate_panel.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable --now vpngate >/dev/null 2>&1

echo -e "\033[32m[6/6] 放行防火墙端口与生成配置清单...\033[0m"
iptables -I INPUT -p tcp --dport ${PANEL_PORT} -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport ${SOCKS5_PORT} -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport ${SS_PORT} -j ACCEPT 2>/dev/null || true

# 获取公网 IP
SERVER_IP=$(curl -s4 https://api.ipify.org || curl -s4 https://ip.sb || curl -s4 https://ifconfig.me || echo "你的VPS公网IP")

# 生成 Shadowsocks 的标准 Base64 链接
SS_RAW="aes-256-gcm:${SS_PASS}"
SS_BASE64=$(echo -n "${SS_RAW}" | base64 | tr -d '\n')
SS_LINK="ss://${SS_BASE64}@${SERVER_IP}:${SS_PORT}#🌐 VPN-Gate | 动态家宽出口"
SOCKS5_LINK="socks5://${SOCKS5_USER}:${SOCKS5_PASS}@${SERVER_IP}:${SOCKS5_PORT}#VPN-Gate家宽落地"

cat << EOF_INFO > /opt/vpngate_info.txt
========================================================
           VPN Gate 家宽落地节点信息清单
========================================================
1. 控制面板地址:
   http://${SERVER_IP}:${PANEL_PORT}

2. SOCKS5 代理信息 (软路由链式代理专用):
   - 链接: ${SOCKS5_LINK}
   - 用户名: ${SOCKS5_USER}
   - 密  码: ${SOCKS5_PASS}
   - 端  口: ${SOCKS5_PORT}

3. Shadowsocks 代理信息 (全客户端直接导入 / 软路由直连):
   - 一键导入链接: ${SS_LINK}
   - 加密方式: aes-256-gcm
   - 密  码: ${SS_PASS}
   - 端  口: ${SS_PORT}
========================================================
EOF_INFO

echo -e "\n\033[32m========================================================================\033[0m"
echo -e "\033[32m🎉 恭喜！VPN Gate 家宽落地代理及可视化控制面板已成功部署！\033[0m"
echo -e "\033[32m========================================================================\033[0m"
echo -e "🌐 \033[1;37m可视化控制面板:\033[0m \033[36mhttp://${SERVER_IP}:${PANEL_PORT}\033[0m"
echo -e "   (内置全版本 OpenVPN 自适应清洗引擎、自愈守护与双模切换机制)\n"
echo -e "\033[33m------------------------------------------------------------------------\033[0m"
echo -e "📦 \033[1;33m协议一：SOCKS5 代理（专用于软路由链式代理）\033[0m"
echo -e "------------------------------------------------------------------------"
echo -e "🔗 节点链接: \033[33m${SOCKS5_LINK}\033[0m"
echo -e "   [账密明细] 账号: ${SOCKS5_USER} | 密码: ${SOCKS5_PASS} | 端口: ${SOCKS5_PORT}\n"
echo -e "\033[34m------------------------------------------------------------------------\033[0m"
echo -e "🛡️  \033[1;34m协议二：Shadowsocks 代理（支持小火箭直连 / 软路由直连）\033[0m"
echo -e "------------------------------------------------------------------------"
echo -e "🔗 一键导入链接: \033[36m${SS_LINK}\033[0m"
echo -e "   [配置明细] 加密: aes-256-gcm | 密码: ${SS_PASS} | 端口: ${SS_PORT}\n"
echo -e "\033[35m------------------------------------------------------------------------\033[0m"
echo -e "💡 \033[1;35m日常维护提示:\033[0m"
echo -e "------------------------------------------------------------------------"
echo -e "1. 随时查看连接信息可运行命令: \033[33mcat /opt/vpngate_info.txt\033[0m"
echo -e "2. 查看底层 OpenVPN 隧道实时运行日志: \033[33mtail -f /var/log/openvpn_vpngate.log\033[0m"
echo -e "\033[32m========================================================================\033[0m\n"
