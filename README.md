## 一、这个项目是用来干什么的？
本项目用于在海外 VPS上一键搭建 **全球真实家庭宽带（住宅 IP）出口代理**。通过该工具，你可以将 VPS 的流量中继至全球家庭宽带，解决特定网站的风控识别、账号注册检测及流媒体区域锁定问题，并自带可视化管理面板与断线自动换线守护。

## 二、可以得到什么？
部署完成后，你将获得：
- **Web 可视化控制面板（端口 5000）**：支持节点批量测活、国家筛选、一键连接，以及“手动锁定 / 自动保活”一键切换。
- **SOCKS5 代理（端口 10808）**：专用于软路由（OpenWrt / ShellCrash / sing-box）链式代理，配合前置机场节点使用。
- **Shadowsocks 代理（端口 10809）**：`aes-256-gcm` 强加密，生成标准 Base64 链接，支持手机端（Shadowrocket 小火箭）、Clash、v2rayN 直接导入使用或软路由直连。
- **后台自动自愈守护进程**：常驻后台，当家宽节点失效断开时，自动按优先级（日本 → 韩国 → 美国）自动寻找存活节点并秒级切换。

## 三、适用系统与环境
- **操作系统**：
  - Ubuntu 20.04 / 22.04 / 24.04 LTS
  - Debian 11 / 12
- **硬件架构**：`x86_64` (AMD64) 及 `aarch64` (ARM64，如甲骨文 ARM 实例)
- **网络要求**：部署前请在云服务商后台安全组（Ingress Rules）放行以下 TCP 端口：
  - `5000`（控制面板）
  - `10808`（SOCKS5 代理）
  - `10809`（Shadowsocks 代理）

## 四、使用方法

### 1. 一键安装部署
在 VPS 终端执行以下单行命令：
```bash
curl -fsSL https://raw.githubusercontent.com/ekong-aura/gate_proxy/main/install.sh | bash
```

### 2. 查看已生成的代理与账密信息
终端关闭后，可随时输入以下命令查看控制面板地址与生成的账密、导入链接：
```bash
cat /opt/vpngate_info.txt
```

### 3. 一键彻底卸载
如需清理全部组件、容器与路由规则，执行：
```bash
curl -fsSL https://raw.githubusercontent.com/ekong-aura/gate_proxy/main/uninstall.sh | bash
```
