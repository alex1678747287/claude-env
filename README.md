# Claude Code Safe Environment

[English](README_EN.md) | 中文

WSL2 环境隔离工具，四层防护体系，让你在受限地区安全使用 Claude Code / Cowork。

## 为什么需要这个工具

2026 年 3 月 Claude Code 源码泄漏揭示了其遥测机制：

- **640+ 种遥测事件**通过 3 个并行通道上报
- **40+ 环境维度**被采集（OS、hostname、CPU、内存、终端类型等）
- 每 **15 秒**向 Datadog 发送日志
- 每 **5 分钟**向 BigQuery 上报指标
- **device_id** 持久化设备标识
- **x-anthropic-billing-header** 包含会话指纹哈希

这些信息足以识别你的真实环境，导致账号被封。

## 架构

```
Layer 1: Node.js/Bun os 模块 Hook (os-override.js)
  ├── monkey-patch os.hostname/release/cpus/totalmem/freemem/uptime/userInfo
  ├── 拦截 fs.readFileSync/readFile 清洗 /proc/version, /proc/cpuinfo 等
  ├── 拦截 child_process 命令 (uname, hostname, cat /proc/*)
  ├── 清零网卡 MAC 地址
  ├── 清除 process.env 中的 Windows 变量
  └── 同时支持 Node.js (--require + --import) 和 Bun (BUN_CONFIG_PRELOAD)

Layer 2: 环境变量 + DNS + Hosts + 防火墙 (claude-safe.sh)
  ├── 屏蔽 20+ 遥测机制 (Datadog/Sentry/Statsig/OTEL/GrowthBook)
  ├── 清除 30+ WSL 泄漏的 Windows 环境变量
  ├── DNS 防泄漏（避免走 Windows 宿主机 DNS）
  ├── /etc/hosts 屏蔽遥测域名
  └── iptables 出站白名单（自定义 chain，gateway 限端口）

Layer 3: cc-gateway API 反向代理（自动启动）
  ├── 重写 40+ 环境维度和 device_id
  ├── 剥离 x-anthropic-billing-header 会话指纹
  ├── 归一化进程指标（内存/堆大小）
  └── 清洗 system prompt 中的 <env> 块

Layer 4: 代理 IP 质量检测
  ├── 检测出口 IP 国家和时区匹配
  ├── 识别数据中心 IP vs 住宅/ISP IP
  └── 启动时显示防护评分 (0-10)
```

## 快速开始

### Windows 用户（推荐）

```
1. 克隆仓库到本地
2. 右键 setup.bat -> 以管理员身份运行
3. 脚本会自动安装 WSL2 + Ubuntu（已安装则跳过）
4. 自动进入 WSL 交互式安装引导
5. 安装完成后，打开 WSL 输入 cs 即可
```

### WSL / Linux 用户

```bash
# 1. 克隆仓库
git clone https://github.com/alex1678747287/claude-env.git
cd claude-env

# 2. 交互式安装（自动引导配置代理、地区、DNS、cc-gateway、防火墙）
bash install.sh

# 3. 启动
cs
```

安装过程会引导你完成所有配置，无需手动编辑任何文件。

一键启动也可以用：

```bash
bash cs-quick.sh
```

## 安装引导流程

```
Step 1: 代理配置
  - 自动检测 Windows 宿主机 IP
  - 自动探测代理端口 (7890/1080/10808)
  - 测试代理连通性

Step 2: 身份伪装
  - 选择地区预设（美西/美东/日本/新加坡/英国/自定义）
  - 自动匹配时区、语言、主机名

Step 3: DNS + 遥测屏蔽
  - 自动修复 DNS 泄漏
  - 自动屏蔽 8 个遥测域名

Step 4: cc-gateway 安装（必装）
  - 自动 clone + npm install
  - 自动生成启动脚本
  - 启动时自动拉起

Step 5: 防火墙 + 配置生成
  - iptables 出站白名单
  - 自动生成 config.env
```

## 配置说明

安装后配置文件在 `~/.claude-safe/config.env`（由安装引导自动生成）。
如需修改，可以重新运行 `bash install.sh` 或手动编辑：

```bash
# 代理设置（改成你的 Clash/V2Ray 地址）
CLAUDE_PROXY_HOST=172.x.x.x    # Windows 宿主机 IP（自动检测）
CLAUDE_PROXY_PORT=7890
CLAUDE_PROXY_PROTOCOL=http

# 伪装身份（建议匹配代理出口地区）
CLAUDE_TZ=America/Los_Angeles
CLAUDE_LANG=en_US.UTF-8
CLAUDE_HOSTNAME=dev-workstation
CLAUDE_USER=developer

# DNS（防止 DNS 泄漏走 Windows 宿主机）
CLAUDE_DNS=1.1.1.1

# 可选：iptables 出站白名单（需要 sudo）
CLAUDE_ENABLE_FIREWALL=false

# 可选：cc-gateway API 代理（推荐）
CLAUDE_ENABLE_GATEWAY=auto
CC_GATEWAY_PORT=8443
```

## 防护覆盖

| 检测维度 | Layer 1 (os hook) | Layer 2 (env/dns/fw) | Layer 3 (cc-gateway) |
|---------|-------------------|---------------------|---------------------|
| 主机名 | os.hostname() | HOSTNAME 变量 | metadata 重写 |
| 用户名 | os.userInfo() | LOGNAME 变量 | - |
| 内核版本 | os.release() | - | env 替换 |
| CPU/内存 | os.cpus()/totalmem() | - | 进程指标归一化 |
| MAC 地址 | networkInterfaces() | - | - |
| Windows 变量 | process.env 清理 | unset 30+ 变量 | - |
| PATH 泄漏 | 过滤 /mnt/c | 过滤 /mnt/c | - |
| Datadog | - | hosts 屏蔽 | - |
| Sentry/Statsig | - | hosts + env 屏蔽 | - |
| OTEL | - | 环境变量禁用 | - |
| Device ID | - | - | canonical ID 替换 |
| Billing Header | - | 环境变量 | 剥离指纹哈希 |
| DNS 泄漏 | - | DNS 配置 | - |
| 直连泄漏 | - | iptables 白名单 | - |

## 补充工具

### claude-private（可选）

二进制补丁版本，替换 18 个遥测 URL，可与本工具叠加使用：

```bash
# 参考 https://github.com/ultrmgns/claude-private
```

## 文件说明

```
setup.bat               # Windows 一键引导（自动安装 WSL2 + Ubuntu）
claude-safe.sh          # 主脚本：四层防护编排
os-override.js          # Layer 1：Node.js/Bun os/fs/child_process hook（CJS）
os-override.mjs         # Layer 1：ESM wrapper（Node.js 20+ ESM 入口兼容）
iptables-whitelist.sh   # Layer 2：iptables 出站白名单
install.sh              # 交互式安装脚本（内置 cc-gateway 安装）
uninstall.sh            # 卸载脚本
cs-quick.sh             # 一键启动脚本
cc-gateway-setup.sh     # cc-gateway 独立安装脚本（手动使用）
config.env              # 配置文件（安装引导自动生成，不入库）
```

## 注意事项

- `/proc/version` 和 `/proc/cpuinfo` 仍可能暴露 WSL 标识，Node hook 无法拦截直接文件读取
- 建议配合代理使用，确保出口 IP 在允许地区
- `config.env` 包含代理地址，已在 `.gitignore` 中排除
- 首次使用需要 OAuth 登录，WSL2 中通过 `wslview` 打开 Windows 浏览器

## 致谢

- [cc-gateway](https://github.com/motiful/cc-gateway) - API 反向代理
- [claude-private](https://github.com/ultrmgns/claude-private) - 二进制补丁
- [claudebox](https://github.com/nicekid1/claudebox) - Docker 容器化方案

## License

MIT
