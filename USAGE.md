# Claude Code 安全环境 - 使用指南

## 快速开始

双击 `setup.bat` 即可。首次运行自动安装，后续直接启动。

## 安装流程（首次自动完成）

1. 检查并安装 WSL2 + Ubuntu（需要管理员权限，可能需要重启）
2. 同步脚本文件到 WSL
3. 自动配置：代理检测、身份伪装、DNS 屏蔽、遥测屏蔽、cc-gateway

## 日常使用

### 方式一：双击启动（推荐）
双击 `setup.bat`，自动同步最新脚本并启动。

### 方式二：WSL 终端
```bash
# 打开 Ubuntu 终端后
cs
```

### 方式三：Windows 命令行
```cmd
wsl -d Ubuntu -- bash -ic "source ~/.claude-safe/config.env; source ~/.claude-safe/claude-safe.sh && claude-run"
```

## 四层防护

| 层级 | 功能 | 说明 |
|------|------|------|
| Layer 1 | Node.js 钩子 | 拦截 os.hostname/userInfo/platform 等 |
| Layer 2 | 环境/DNS/防火墙 | 遥测屏蔽、身份伪装、DNS 防泄漏 |
| Layer 3 | cc-gateway | 重写 device_id、计费头、40+ 维度 |
| Layer 4 | 代理检测 | 出口 IP 国家验证、自动匹配身份 |

## 修改配置

编辑 WSL 中的配置文件：
```bash
wsl -d Ubuntu -- nano ~/.claude-safe/config.env
```

主要配置项：
```
CLAUDE_PROXY_HOST=127.0.0.1      # 代理地址
CLAUDE_PROXY_PORT=10809           # 代理端口
CLAUDE_PROXY_PROTOCOL=http        # http 或 socks5
CLAUDE_TZ=America/New_York        # 时区（自动匹配代理出口）
CLAUDE_HOSTNAME=dev-workstation   # 伪装主机名
CLAUDE_USER=developer             # 伪装用户名
CLAUDE_ENABLE_FIREWALL=true       # iptables 白名单
```

## 重新安装

```bash
wsl -d Ubuntu -- bash -c "cd ~/claude-env && bash install.sh --auto"
```

## 卸载

```bash
wsl -d Ubuntu -- bash -c "cd ~/claude-env && bash uninstall.sh"
```

## 常见问题

**Q: 提示 "localhost 代理配置未镜像到 WSL"**
这是 WSL 提示信息，不影响使用。如果代理不通，检查代理软件是否开启了"允许局域网连接"。

**Q: cc-gateway 配置失败**
需要先在 WSL 中登录 Claude Code：`claude --login`，然后重新运行安装。

**Q: 代理检测不到**
确保代理软件正在运行，端口正确。支持的默认端口：HTTP 10809/7890/1080，SOCKS5 10808/7890/1080。
