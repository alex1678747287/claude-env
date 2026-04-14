#!/usr/bin/env bash
# install.sh v3 - Claude Code Safe Environment 全自动安装器
# 四层防护: Node.js 钩子 + 环境/DNS/防火墙 + cc-gateway + 代理质量
# Usage: bash install.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; }
step()  { echo -e "\n${BOLD}${CYAN}── $* ──${NC}\n"; }

# Auto mode: --auto or -y skips all interactive prompts
AUTO_MODE=false
for arg in "$@"; do
    case "$arg" in --auto|-y) AUTO_MODE=true ;; esac
done

# Prompt with default value: ask "prompt" "default" -> writes to $REPLY
ask() {
    local prompt="$1" default="${2:-}"
    if [ -n "$default" ]; then
        echo -ne "  ${BOLD}?${NC} ${prompt} [${CYAN}${default}${NC}]: "
    else
        echo -ne "  ${BOLD}?${NC} ${prompt}: "
    fi
    read -r REPLY
    REPLY="${REPLY:-$default}"
}

# Yes/No prompt: confirm "prompt" "Y" -> return 0 if yes
confirm() {
    local prompt="$1" default="${2:-Y}"
    if [ "$default" = "Y" ]; then
        echo -ne "  ${BOLD}?${NC} ${prompt} [${CYAN}Y/n${NC}]: "
    else
        echo -ne "  ${BOLD}?${NC} ${prompt} [${CYAN}y/N${NC}]: "
    fi
    read -r REPLY
    REPLY="${REPLY:-$default}"
    [[ "$REPLY" =~ ^[Yy] ]]
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.claude-safe"
GATEWAY_DIR="$HOME/.cc-gateway"

echo -e "${CYAN}"
cat << 'BANNER'
   _____ _                 _        ____         __
  / ____| |               | |      / ___|  __ _ / _| ___
 | |    | | __ _ _   _  __| | ___ \___ \ / _` | |_ / _ \
 | |    | |/ _` | | | |/ _` |/ _ \ ___) | (_| |  _|  __/
 |  \___| | (_| | |_| | (_| |  __/|____/ \__,_|_|  \___|
  \_____|_|\__,_|\__,_|\__,_|\___|  Environment v3
BANNER
echo -e "${NC}"
echo -e "  WSL2 上 Claude Code 的四层防护系统"
echo ""

# ============================================================
# Step 0: System dependencies (silent)
# ============================================================
step "步骤 0/5: 检查依赖"

install_pkg() {
    local cmd=$1 pkg=${2:-$1}
    if ! command -v "$cmd" &>/dev/null; then
        info "正在安装 $pkg..."
        sudo apt-get update -qq 2>/dev/null && sudo apt-get install -y -qq "$pkg" 2>/dev/null
    fi
}

install_pkg wslview wslu
install_pkg curl curl
install_pkg git git
install_pkg jq jq

if ! command -v iptables &>/dev/null; then
    sudo apt-get install -y -qq iptables ipset 2>/dev/null || true
fi

# Node.js (cc-gateway needs >= 22)
if ! command -v node &>/dev/null; then
    info "正在通过 nvm 安装 Node.js..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    nvm install 22
    nvm use 22
else
    NODE_VER=$(node -v | sed 's/v//' | cut -d. -f1)
    if [ "$NODE_VER" -lt 22 ]; then
        warn "Node.js $(node -v) 已找到，但 cc-gateway 需要 >= 22"
        if command -v nvm &>/dev/null || [ -s "$HOME/.nvm/nvm.sh" ]; then
            [ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh"
            info "正在通过 nvm 升级..."
            nvm install 22 && nvm use 22 && nvm alias default 22
        else
            warn "请手动升级 Node.js 到 >= 22"
        fi
    else
        info "Node.js $(node -v) 正常"
    fi
fi

# Claude Code
if ! command -v claude &>/dev/null && ! command -v claude-private &>/dev/null; then
    info "正在安装 Claude Code..."
    npm install -g @anthropic-ai/claude-code
else
    info "Claude Code 已找到"
fi

info "依赖检查完成"

# ============================================================
# Step 1: Proxy configuration (interactive)
# ============================================================
step "步骤 1/5: 代理配置"

# Auto-detect Windows host IP (try multiple methods)
WIN_HOST_IP=""
# Method 1: /etc/resolv.conf nameserver
if [ -f /etc/resolv.conf ]; then
    detected_ip=$(grep -m1 nameserver /etc/resolv.conf | awk '{print $2}' || echo "")
    if [ -n "$detected_ip" ] && [ "$detected_ip" != "127.0.0.1" ]; then
        WIN_HOST_IP="$detected_ip"
    fi
fi
# Method 2: default gateway
if [ -z "$WIN_HOST_IP" ]; then
    WIN_HOST_IP=$(ip route show default 2>/dev/null | awk '{print $3}' || echo "")
fi
# Method 3: WSL interop
if [ -z "$WIN_HOST_IP" ]; then
    WIN_HOST_IP=$(cat /proc/net/tcp 2>/dev/null | awk 'NR>1{print $3}' | head -1 | sed 's/:.*//' | \
        while read hex; do printf '%d.%d.%d.%d\n' 0x${hex:6:2} 0x${hex:4:2} 0x${hex:2:2} 0x${hex:0:2}; done || echo "")
fi
[ -z "$WIN_HOST_IP" ] && WIN_HOST_IP="127.0.0.1"
info "检测到 Windows 主机 IP: $WIN_HOST_IP"

# Auto-detect proxy: try HTTP and SOCKS5 on common ports
PROXY_HOST=""
PROXY_PORT=""
PROXY_PROTOCOL=""
PROXY_URL=""

info "正在自动检测代理（扫描常用端口）..."
for try_host in "$WIN_HOST_IP" "127.0.0.1"; do
    [ -n "$PROXY_HOST" ] && break
    # HTTP ports first (more common for v2rayN HTTP proxy)
    for port in 10809 7890 7891 1080 8080 20171; do
        if curl -s --connect-timeout 2 --proxy "http://${try_host}:${port}" https://httpbin.org/ip -o /dev/null 2>/dev/null; then
            PROXY_HOST="$try_host"; PROXY_PORT="$port"; PROXY_PROTOCOL="http"
            break
        fi
    done
    [ -n "$PROXY_HOST" ] && break
    # SOCKS5 ports
    for port in 10808 7890 1080 20170; do
        if curl -s --connect-timeout 2 --proxy "socks5://${try_host}:${port}" https://httpbin.org/ip -o /dev/null 2>/dev/null; then
            PROXY_HOST="$try_host"; PROXY_PORT="$port"; PROXY_PROTOCOL="socks5"
            break
        fi
    done
done

if [ -n "$PROXY_HOST" ]; then
    PROXY_URL="${PROXY_PROTOCOL}://${PROXY_HOST}:${PROXY_PORT}"
    info "代理已找到: ${GREEN}${PROXY_URL}${NC}"
else
    warn "未自动检测到代理"
    if [ "$AUTO_MODE" = true ]; then
        info "自动模式: 使用默认代理 http://${WIN_HOST_IP}:10809"
        PROXY_HOST="$WIN_HOST_IP"
        PROXY_PORT="10809"
        PROXY_PROTOCOL="http"
        PROXY_URL="${PROXY_PROTOCOL}://${PROXY_HOST}:${PROXY_PORT}"
    else
        warn "请确保 v2rayN 正在运行且已开启「允许局域网连接」"
        ask "代理主机" "$WIN_HOST_IP"
        PROXY_HOST="$REPLY"
        ask "代理端口" "10809"
        PROXY_PORT="$REPLY"
        echo -e "  ${DIM}1) http  2) socks5${NC}"
        ask "代理协议" "http"
        PROXY_PROTOCOL="$REPLY"
        PROXY_URL="${PROXY_PROTOCOL}://${PROXY_HOST}:${PROXY_PORT}"
        echo -ne "  正在测试代理... "
        if curl -s --connect-timeout 5 --proxy "$PROXY_URL" https://httpbin.org/ip -o /dev/null 2>/dev/null; then
            echo -e "${GREEN}成功${NC}"
        else
            echo -e "${RED}失败${NC}"
            warn "代理不可达，稍后可修改 config.env"
        fi
    fi
fi

# ============================================================
# Step 2: Identity disguise (auto-detect from proxy exit IP)
# ============================================================
step "步骤 2/5: 身份伪装"

# Auto-detect region from proxy exit IP
DETECTED_COUNTRY=""
DETECTED_TZ=""
DETECTED_LANG=""

if [ -n "$PROXY_URL" ]; then
    echo -ne "  正在检测代理出口地区... "
    ip_info=$(curl -s --connect-timeout 5 --proxy "$PROXY_URL" "https://ipinfo.io/json" 2>/dev/null || echo "")
    if [ -n "$ip_info" ]; then
        DETECTED_COUNTRY=$(echo "$ip_info" | grep -o '"country"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
        detected_tz=$(echo "$ip_info" | grep -o '"timezone"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
        detected_city=$(echo "$ip_info" | grep -o '"city"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
        detected_ip=$(echo "$ip_info" | grep -o '"ip"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

        if [ -n "$DETECTED_COUNTRY" ]; then
            echo -e "${GREEN}${DETECTED_COUNTRY}${NC} ($detected_city, $detected_ip)"

            # Map country to timezone and locale
            case "$DETECTED_COUNTRY" in
                US)
                    DETECTED_TZ="${detected_tz:-America/Los_Angeles}"
                    DETECTED_LANG="en_US.UTF-8"
                    ;;
                JP)
                    DETECTED_TZ="${detected_tz:-Asia/Tokyo}"
                    DETECTED_LANG="ja_JP.UTF-8"
                    ;;
                SG)
                    DETECTED_TZ="${detected_tz:-Asia/Singapore}"
                    DETECTED_LANG="en_SG.UTF-8"
                    ;;
                GB|UK)
                    DETECTED_TZ="${detected_tz:-Europe/London}"
                    DETECTED_LANG="en_GB.UTF-8"
                    ;;
                DE)
                    DETECTED_TZ="${detected_tz:-Europe/Berlin}"
                    DETECTED_LANG="de_DE.UTF-8"
                    ;;
                KR)
                    DETECTED_TZ="${detected_tz:-Asia/Seoul}"
                    DETECTED_LANG="ko_KR.UTF-8"
                    ;;
                HK)
                    DETECTED_TZ="${detected_tz:-Asia/Hong_Kong}"
                    DETECTED_LANG="en_HK.UTF-8"
                    ;;
                TW)
                    DETECTED_TZ="${detected_tz:-Asia/Taipei}"
                    DETECTED_LANG="zh_TW.UTF-8"
                    ;;
                CA)
                    DETECTED_TZ="${detected_tz:-America/Toronto}"
                    DETECTED_LANG="en_CA.UTF-8"
                    ;;
                AU)
                    DETECTED_TZ="${detected_tz:-Australia/Sydney}"
                    DETECTED_LANG="en_AU.UTF-8"
                    ;;
                FR)
                    DETECTED_TZ="${detected_tz:-Europe/Paris}"
                    DETECTED_LANG="fr_FR.UTF-8"
                    ;;
                *)
                    # Use ipinfo timezone directly if available
                    DETECTED_TZ="${detected_tz:-America/Los_Angeles}"
                    DETECTED_LANG="en_US.UTF-8"
                    ;;
            esac

            if [ "$DETECTED_COUNTRY" = "CN" ]; then
                echo -e "  ${RED}警告: 代理出口 IP 在中国！代理未正常工作，将使用默认美国配置${NC}"
                DETECTED_TZ="America/New_York"
                DETECTED_LANG="en_US.UTF-8"
            fi
        else
            echo -e "${YELLOW}检测失败${NC}"
        fi
    else
        echo -e "${YELLOW}检测失败（ipinfo.io 不可达）${NC}"
    fi
fi

# Use detected values or default
if [ -n "$DETECTED_TZ" ] && [ -n "$DETECTED_LANG" ]; then
    info "自动匹配: $DETECTED_TZ / $DETECTED_LANG"
    TARGET_TZ="$DETECTED_TZ"
    TARGET_LANG="$DETECTED_LANG"
else
    # Auto-detection failed, use defaults
    info "自动检测失败，使用默认配置: America/New_York / en_US.UTF-8"
    TARGET_TZ="America/New_York"
    TARGET_LANG="en_US.UTF-8"
fi

TARGET_HOSTNAME="dev-workstation"
TARGET_USER="developer"

info "身份配置: $TARGET_HOSTNAME / $TARGET_TZ / $TARGET_LANG"

# ============================================================
# Step 3: DNS + Hosts + System config (auto)
# ============================================================
step "步骤 3/5: DNS 和遥测屏蔽"

# Block telemetry domains in /etc/hosts
TELEMETRY_DOMAINS=(
    "http-intake.logs.us5.datadoghq.com"
    "browser-intake-us5-datadoghq.com"
    "us5.datadoghq.com"
    "sentry.io"
    "o4507603404627968.ingest.us.sentry.io"
    "statsig.anthropic.com"
    "featuregates.org"
    "api.statsig.com"
    "statsig.com"
    "api.growthbook.io"
    "cdn.growthbook.io"
    "amplitude.com"
    "api.amplitude.com"
    "api2.amplitude.com"
)

missing=0
for domain in "${TELEMETRY_DOMAINS[@]}"; do
    grep -q "$domain" /etc/hosts 2>/dev/null || missing=$((missing + 1))
done

if [ "$missing" -gt 0 ]; then
    info "正在屏蔽 $missing 个遥测域名..."
    {
        echo ""
        echo "# Claude Code telemetry block - added by claude-safe installer"
        for domain in "${TELEMETRY_DOMAINS[@]}"; do
            grep -q "$domain" /etc/hosts 2>/dev/null || echo "0.0.0.0 $domain"
        done
    } | sudo tee -a /etc/hosts > /dev/null
    info "遥测域名已屏蔽"
else
    info "遥测域名已屏蔽（之前已配置）"
fi

# DNS leak check
DNS_SERVER="1.1.1.1"
current_dns=$(grep -m1 nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' || echo "")
if [ -n "$current_dns" ] && [ "$current_dns" != "$DNS_SERVER" ] && [ "$current_dns" != "127.0.0.1" ]; then
    warn "DNS 指向 $current_dns（Windows 主机，有泄漏风险）"
    # Auto-fix DNS
    if sudo bash -c "echo 'nameserver $DNS_SERVER' > /etc/resolv.conf" 2>/dev/null; then
        info "DNS 已设置为 $DNS_SERVER"
    else
        warn "无法自动修复 DNS"
    fi
    # Check wsl.conf
    if ! grep -q "generateResolvConf" /etc/wsl.conf 2>/dev/null; then
        warn "请在 /etc/wsl.conf 中添加以下内容使 DNS 修复永久生效:"
        echo -e "  ${DIM}[network]${NC}"
        echo -e "  ${DIM}generateResolvConf = false${NC}"
    fi
else
    info "DNS: $current_dns（正常）"
fi

# Hostname check
CURRENT_HOSTNAME=$(hostname)
if echo "$CURRENT_HOSTNAME" | grep -qi 'desktop\|laptop\|pc\|win\|admin'; then
    warn "系统主机名 '$CURRENT_HOSTNAME' 可能暴露身份"
    if ! grep -q "hostname" /etc/wsl.conf 2>/dev/null; then
        echo -e "  ${DIM}请在 /etc/wsl.conf 中添加: [network] hostname = $TARGET_HOSTNAME${NC}"
    fi
fi

# ============================================================
# Step 4: cc-gateway installation (built-in, required)
# ============================================================
step "步骤 4/5: cc-gateway（API 身份代理）"

info "cc-gateway 重写 device_id、计费头、40+ 环境维度"
info "这是 API 级指纹防护最重要的保护层"
echo ""

if [ -d "$GATEWAY_DIR" ] && [ -f "$GATEWAY_DIR/package.json" ]; then
    info "cc-gateway 已安装，正在更新..."
    cd "$GATEWAY_DIR" && git pull --quiet 2>/dev/null || true
    npm install --quiet 2>/dev/null
    info "cc-gateway 已更新"
else
    info "正在克隆 cc-gateway..."
    git clone --quiet https://github.com/motiful/cc-gateway.git "$GATEWAY_DIR" 2>/dev/null
    cd "$GATEWAY_DIR"
    info "正在安装依赖..."
    npm install --quiet 2>/dev/null
    info "cc-gateway 安装完成"
fi

# Create start/stop scripts
cat > "$GATEWAY_DIR/start.sh" << 'STARTEOF'
#!/usr/bin/env bash
cd "$(dirname "$0")"
PORT="${CC_GATEWAY_PORT:-8443}"
if [ -f .gateway.pid ] && kill -0 "$(cat .gateway.pid)" 2>/dev/null; then
    echo "cc-gateway already running (PID $(cat .gateway.pid))"
    exit 0
fi
echo "Starting cc-gateway on port $PORT..."
nohup node src/index.js > /dev/null 2>&1 &
echo $! > .gateway.pid
echo "Gateway PID: $(cat .gateway.pid)"
STARTEOF
chmod +x "$GATEWAY_DIR/start.sh"

cat > "$GATEWAY_DIR/stop.sh" << 'STOPEOF'
#!/usr/bin/env bash
cd "$(dirname "$0")"
if [ -f .gateway.pid ]; then
    kill "$(cat .gateway.pid)" 2>/dev/null && echo "Gateway stopped" || echo "Gateway not running"
    rm -f .gateway.pid
fi
STOPEOF
chmod +x "$GATEWAY_DIR/stop.sh"

# Skip quick-setup during install (credentials won't exist yet)
# cc-gateway will auto-configure on second `cs` run after OAuth login
if [ ! -f "$GATEWAY_DIR/config.yaml" ]; then
    info "cc-gateway 将在首次登录后自动配置"
fi

# Create systemd service if available
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/cc-gateway.service"
if command -v systemctl &>/dev/null && [ ! -f "$SERVICE_FILE" ]; then
    mkdir -p "$SERVICE_DIR"
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=CC Gateway - Claude Code API Identity Proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=$GATEWAY_DIR
ExecStart=$(which node) $GATEWAY_DIR/src/index.js
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=${CC_GATEWAY_PORT:-8443}

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload 2>/dev/null || true
    info "Systemd 服务已创建（可选: systemctl --user enable cc-gateway）"
fi

info "cc-gateway 就绪"

# ============================================================
# Step 5: Firewall + config generation + aliases
# ============================================================
step "步骤 5/5: 防火墙和最终配置"

ENABLE_FIREWALL="true"

# Copy scripts to install directory
mkdir -p "$INSTALL_DIR"
for f in claude-safe.sh os-override.js os-override.mjs iptables-whitelist.sh cc-gateway-setup.sh uninstall.sh; do
    if [ -f "$SCRIPT_DIR/$f" ]; then
        cp "$SCRIPT_DIR/$f" "$INSTALL_DIR/$f"
        chmod +x "$INSTALL_DIR/$f" 2>/dev/null || true
    fi
done
info "脚本已安装到 $INSTALL_DIR"

# Generate config.env from interactive answers
CONFIG_FILE="$INSTALL_DIR/config.env"
install -m 600 /dev/null "$CONFIG_FILE"
cat > "$CONFIG_FILE" << CONF
# Claude Safe Environment v3 - Auto-generated by installer
# Re-run install.sh to reconfigure, or edit manually

CLAUDE_PROXY_HOST=$PROXY_HOST
CLAUDE_PROXY_PORT=$PROXY_PORT
CLAUDE_PROXY_PROTOCOL=$PROXY_PROTOCOL
CLAUDE_TZ=$TARGET_TZ
CLAUDE_LANG=$TARGET_LANG
CLAUDE_HOSTNAME=$TARGET_HOSTNAME
CLAUDE_USER=$TARGET_USER
CLAUDE_DNS=$DNS_SERVER
CLAUDE_ENABLE_FIREWALL=$ENABLE_FIREWALL
CLAUDE_ENABLE_GATEWAY=auto
CC_GATEWAY_PORT=8443
CLAUDE_PROXY_CHECK=true
CONF
info "配置已生成: $CONFIG_FILE"

# Add shell aliases
SHELL_RC="$HOME/.bashrc"
[ -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.zshrc"

if ! grep -q "claude-safe" "$SHELL_RC" 2>/dev/null; then
    cat >> "$SHELL_RC" << 'SHELLBLOCK'

# Claude Code Safe Environment v3 - auto-loaded on shell start
# Config: ~/.claude-safe/config.env | Re-install: bash ~/claude-env/install.sh
if [ -f ~/.claude-safe/config.env ]; then
    set -a
    source ~/.claude-safe/config.env
    set +a
fi

# Proxy env vars (always available, not just inside cs)
if [ -n "${CLAUDE_PROXY_HOST:-}" ] && [ -n "${CLAUDE_PROXY_PORT:-}" ]; then
    _claude_proxy="${CLAUDE_PROXY_PROTOCOL:-http}://${CLAUDE_PROXY_HOST}:${CLAUDE_PROXY_PORT}"
    export HTTP_PROXY="$_claude_proxy" HTTPS_PROXY="$_claude_proxy"
    export http_proxy="$_claude_proxy" https_proxy="$_claude_proxy"
    export ALL_PROXY="$_claude_proxy" all_proxy="$_claude_proxy"
    export NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    export no_proxy="$NO_PROXY"
    unset _claude_proxy
fi

# Identity disguise (always active)
export TZ="${CLAUDE_TZ:-America/Los_Angeles}"
export LANG="${CLAUDE_LANG:-en_US.UTF-8}"
export LC_ALL="${CLAUDE_LANG:-en_US.UTF-8}"
export HOSTNAME="${CLAUDE_HOSTNAME:-dev-workstation}"
export LOGNAME="${CLAUDE_USER:-developer}"
export TERM="xterm-256color"
export SHELL="/bin/bash"

# Remove WSL-leaking Windows env vars
for _v in WSLENV WSL_DISTRO_NAME WSL_INTEROP WINDOWS_USERNAME USERPROFILE \
    APPDATA LOCALAPPDATA PROGRAMFILES ProgramFiles ProgramW6432 WINDIR \
    SystemRoot OS PROCESSOR_ARCHITECTURE PROCESSOR_IDENTIFIER \
    NUMBER_OF_PROCESSORS CommonProgramFiles CommonProgramW6432 ProgramData \
    SystemDrive TEMP TMP HOMEDRIVE HOMEPATH WT_SESSION WT_PROFILE_ID \
    PULSE_SERVER WAYLAND_DISPLAY DISPLAY VSCODE_WSL_EXT_LOCATION \
    VSCODE_IPC_HOOK_CLI PSModulePath DOTNET_ROOT; do
    unset "$_v" 2>/dev/null
done
unset _v

# Filter /mnt/c paths from PATH
export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '/mnt/[a-z]' | tr '\n' ':' | sed 's/:$//')

# Telemetry kill switches (always active)
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_TELEMETRY=1 DISABLE_AUTOUPDATER=1
export CLAUDE_CODE_ENABLE_TELEMETRY=0
export CLAUDE_CODE_ATTRIBUTION_HEADER=false
export DO_NOT_TRACK=1 NEXT_TELEMETRY_DISABLED=1
export OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none OTEL_TRACES_EXPORTER=none OTEL_SDK_DISABLED=true
export DD_TRACE_ENABLED=false DD_INSTRUMENTATION_TELEMETRY_ENABLED=false DD_REMOTE_CONFIGURATION_ENABLED=false
export SENTRY_DSN="" SENTRY_ENVIRONMENT=""
export GROWTHBOOK_CLIENT_KEY="" STATSIG_CLIENT_KEY=""

# Git identity (session-only, does not modify ~/.gitconfig)
export GIT_AUTHOR_NAME="${CLAUDE_USER:-developer}"
export GIT_AUTHOR_EMAIL="${CLAUDE_USER:-developer}@users.noreply.github.com"
export GIT_COMMITTER_NAME="${CLAUDE_USER:-developer}"
export GIT_COMMITTER_EMAIL="${CLAUDE_USER:-developer}@users.noreply.github.com"

# cs = launch Claude Code with full four-layer protection
alias cs="source ~/.claude-safe/claude-safe.sh && claude-run"
SHELLBLOCK
    info "Shell 集成已添加到 $SHELL_RC（环境变量在登录时自动加载）"
else
    # Already has claude-safe block - check if it's the old alias-only version and upgrade
    if grep -q 'alias claude-safe="source' "$SHELL_RC" 2>/dev/null; then
        warn "正在升级 Shell 集成..."
        # Remove old block
        sed -i '/# Claude Code Safe Environment v3/,/alias cs=/d' "$SHELL_RC"
        # Re-run this section (recursive call avoided - just append)
        cat >> "$SHELL_RC" << 'SHELLBLOCK'

# Claude Code Safe Environment v3 - auto-loaded on shell start
# Config: ~/.claude-safe/config.env | Re-install: bash ~/claude-env/install.sh
if [ -f ~/.claude-safe/config.env ]; then
    set -a
    source ~/.claude-safe/config.env
    set +a
fi

# Proxy env vars (always available, not just inside cs)
if [ -n "${CLAUDE_PROXY_HOST:-}" ] && [ -n "${CLAUDE_PROXY_PORT:-}" ]; then
    _claude_proxy="${CLAUDE_PROXY_PROTOCOL:-http}://${CLAUDE_PROXY_HOST}:${CLAUDE_PROXY_PORT}"
    export HTTP_PROXY="$_claude_proxy" HTTPS_PROXY="$_claude_proxy"
    export http_proxy="$_claude_proxy" https_proxy="$_claude_proxy"
    export ALL_PROXY="$_claude_proxy" all_proxy="$_claude_proxy"
    export NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    export no_proxy="$NO_PROXY"
    unset _claude_proxy
fi

# Identity disguise (always active)
export TZ="${CLAUDE_TZ:-America/Los_Angeles}"
export LANG="${CLAUDE_LANG:-en_US.UTF-8}"
export LC_ALL="${CLAUDE_LANG:-en_US.UTF-8}"
export HOSTNAME="${CLAUDE_HOSTNAME:-dev-workstation}"
export LOGNAME="${CLAUDE_USER:-developer}"
export TERM="xterm-256color"
export SHELL="/bin/bash"

# Remove WSL-leaking Windows env vars
for _v in WSLENV WSL_DISTRO_NAME WSL_INTEROP WINDOWS_USERNAME USERPROFILE \
    APPDATA LOCALAPPDATA PROGRAMFILES ProgramFiles ProgramW6432 WINDIR \
    SystemRoot OS PROCESSOR_ARCHITECTURE PROCESSOR_IDENTIFIER \
    NUMBER_OF_PROCESSORS CommonProgramFiles CommonProgramW6432 ProgramData \
    SystemDrive TEMP TMP HOMEDRIVE HOMEPATH WT_SESSION WT_PROFILE_ID \
    PULSE_SERVER WAYLAND_DISPLAY DISPLAY VSCODE_WSL_EXT_LOCATION \
    VSCODE_IPC_HOOK_CLI PSModulePath DOTNET_ROOT; do
    unset "$_v" 2>/dev/null
done
unset _v

# Filter /mnt/c paths from PATH
export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '/mnt/[a-z]' | tr '\n' ':' | sed 's/:$//')

# Telemetry kill switches (always active)
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_TELEMETRY=1 DISABLE_AUTOUPDATER=1
export CLAUDE_CODE_ENABLE_TELEMETRY=0
export CLAUDE_CODE_ATTRIBUTION_HEADER=false
export DO_NOT_TRACK=1 NEXT_TELEMETRY_DISABLED=1
export OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none OTEL_TRACES_EXPORTER=none OTEL_SDK_DISABLED=true
export DD_TRACE_ENABLED=false DD_INSTRUMENTATION_TELEMETRY_ENABLED=false DD_REMOTE_CONFIGURATION_ENABLED=false
export SENTRY_DSN="" SENTRY_ENVIRONMENT=""
export GROWTHBOOK_CLIENT_KEY="" STATSIG_CLIENT_KEY=""

# Git identity (session-only, does not modify ~/.gitconfig)
export GIT_AUTHOR_NAME="${CLAUDE_USER:-developer}"
export GIT_AUTHOR_EMAIL="${CLAUDE_USER:-developer}@users.noreply.github.com"
export GIT_COMMITTER_NAME="${CLAUDE_USER:-developer}"
export GIT_COMMITTER_EMAIL="${CLAUDE_USER:-developer}@users.noreply.github.com"

# cs = launch Claude Code with full four-layer protection
alias cs="source ~/.claude-safe/claude-safe.sh && claude-run"
SHELLBLOCK
        info "Shell 集成已升级"
    else
        info "Shell 集成已配置（之前已设置）"
    fi
fi

# ============================================================
# Done
# ============================================================
# Detect actual exit IP for display
EXIT_IP=""
if [ -n "$PROXY_URL" ]; then
    EXIT_IP=$(curl -s --connect-timeout 5 --proxy "$PROXY_URL" https://httpbin.org/ip 2>/dev/null | grep -o '"origin"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || echo "")
fi

echo ""
echo -e "${GREEN}${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}  安装完成！${NC}"
echo -e "${GREEN}${BOLD}========================================${NC}"
echo ""
echo -e "  ${BOLD}快速开始:${NC}"
echo -e "    ${CYAN}source $SHELL_RC && cs${NC}"
echo ""
echo -e "  ${BOLD}首次使用流程:${NC}"
echo -e "    1. 运行 ${CYAN}cs${NC} -> Claude Code 启动并提示 OAuth 登录"
echo -e "    2. 在浏览器中完成登录"
echo -e "    3. 再次运行 ${CYAN}cs${NC} -> cc-gateway 自动配置，获得完整 10/10 防护"
echo ""
echo -e "  ${BOLD}保护层:${NC}"
echo -e "    ${GREEN}Layer 1${NC} Node.js 钩子     os.*/fs.*/child_process.* 已拦截"
echo -e "    ${GREEN}Layer 2${NC} 环境/DNS/防火墙  20+ 遥测已屏蔽，iptables 白名单"
echo -e "    ${GREEN}Layer 3${NC} cc-gateway       device_id + 计费头 + 40+ 维度"
echo -e "    ${GREEN}Layer 4${NC} 代理检测         出口 IP 国家 + 类型验证"
echo ""
echo -e "  ${BOLD}你的配置:${NC}"
echo -e "    代理:     ${CYAN}${PROXY_URL}${NC} -> ${CYAN}${EXIT_IP:-未知}${NC}"
echo -e "    地区:     ${CYAN}${TARGET_TZ}${NC}"
echo -e "    身份:     ${CYAN}${TARGET_USER}@${TARGET_HOSTNAME}${NC}"
echo -e "    防火墙:   ${CYAN}${ENABLE_FIREWALL}${NC}"
echo -e "    网关:     ${CYAN}auto (登录后自动配置)${NC}"
echo ""
echo -e "  ${DIM}重新配置: bash $SCRIPT_DIR/install.sh${NC}"
echo -e "  ${DIM}卸载:     bash $SCRIPT_DIR/uninstall.sh${NC}"
echo ""
