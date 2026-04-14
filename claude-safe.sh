#!/usr/bin/env bash
# claude-safe.sh v3 - Claude Code environment isolation wrapper for WSL2
# Four-layer protection: Node.js os hook + env/DNS/firewall + cc-gateway + proxy quality
# Usage: source ~/.claude-safe/claude-safe.sh && claude-run [claude args...]

# Do NOT use set -e here - this file is sourced into the user's shell,
# and any non-zero exit would kill the terminal.
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# Configuration (loaded from config.env or defaults)
# ============================================================
PROXY_HOST="${CLAUDE_PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${CLAUDE_PROXY_PORT:-7890}"
PROXY_PROTOCOL="${CLAUDE_PROXY_PROTOCOL:-http}"
TARGET_TZ="${CLAUDE_TZ:-America/Los_Angeles}"
TARGET_LANG="${CLAUDE_LANG:-en_US.UTF-8}"
TARGET_HOSTNAME="${CLAUDE_HOSTNAME:-dev-workstation}"
TARGET_USER="${CLAUDE_USER:-developer}"
ENABLE_FIREWALL="${CLAUDE_ENABLE_FIREWALL:-false}"
ENABLE_GATEWAY="${CLAUDE_ENABLE_GATEWAY:-auto}"
GATEWAY_PORT="${CC_GATEWAY_PORT:-8443}"
DNS_SERVER="${CLAUDE_DNS:-1.1.1.1}"
GATEWAY_DIR="${CC_GATEWAY_DIR:-$HOME/.cc-gateway}"
PROXY_CHECK="${CLAUDE_PROXY_CHECK:-true}"

# ============================================================
# Color output
# ============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; DIM='\033[2m'; NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; }
dim()   { echo -e "${DIM}    $*${NC}"; }

# Protection score tracker
PROTECTION_SCORE=0
PROTECTION_MAX=10
PROXY_EXIT_IP=""

# ============================================================
# Layer 1: Node.js os module hook
# ============================================================
setup_node_hook() {
    local override_js="$SCRIPT_DIR/os-override.js"
    local override_mjs="$SCRIPT_DIR/os-override.mjs"
    if [ ! -f "$override_js" ]; then
        override_js="$HOME/.claude-safe/os-override.js"
        override_mjs="$HOME/.claude-safe/os-override.mjs"
    fi

    if [ -f "$override_js" ]; then
        # Inject via NODE_OPTIONS --require (CJS) + --import (ESM)
        local node_opts="--require $override_js"
        if [ -f "$override_mjs" ]; then
            node_opts="$node_opts --import file://$override_mjs"
        fi
        if [ -n "${NODE_OPTIONS:-}" ]; then
            export NODE_OPTIONS="$node_opts $NODE_OPTIONS"
        else
            export NODE_OPTIONS="$node_opts"
        fi
        # Also set Bun preload (Claude Code may run under Bun runtime)
        export BUN_CONFIG_PRELOAD="$override_js"
        # Pass config to os-override.js via env
        export CLAUDE_HOSTNAME="$TARGET_HOSTNAME"
        export CLAUDE_USER="$TARGET_USER"

        # Create homedir symlink so /home/$TARGET_USER -> real home
        # os-override.js patches os.homedir() to return /home/$TARGET_USER
        local real_user
        real_user="$(whoami)"
        if [ "$TARGET_USER" != "$real_user" ] && [ ! -e "/home/$TARGET_USER" ]; then
            sudo ln -sfn "$HOME" "/home/$TARGET_USER" 2>/dev/null || true
        fi

        info "Node.js/Bun os 钩子已加载 (CJS --require + ESM --import)"
        PROTECTION_SCORE=$((PROTECTION_SCORE + 2))
    else
        warn "os-override.js 未找到 - Node.js 层伪装已禁用"
        dim "请将 os-override.js 复制到 $SCRIPT_DIR/"
    fi
}

# ============================================================
# Layer 2a: Telemetry blocking - environment variables
# Reference: https://github.com/ultrmgns/claude-private
# ============================================================
setup_telemetry_block() {
    # Core Claude Code telemetry kill switches
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    export DISABLE_TELEMETRY=1
    export DISABLE_AUTOUPDATER=1
    export CLAUDE_CODE_ENABLE_TELEMETRY=0

    # Disable billing/attribution header (contains session fingerprint hash)
    export CLAUDE_CODE_ATTRIBUTION_HEADER=false

    # OpenTelemetry exporters - disable all
    export OTEL_METRICS_EXPORTER=none
    export OTEL_LOGS_EXPORTER=none
    export OTEL_TRACES_EXPORTER=none
    export OTEL_SDK_DISABLED=true

    # Datadog
    export DD_TRACE_ENABLED=false
    export DD_INSTRUMENTATION_TELEMETRY_ENABLED=false
    export DD_REMOTE_CONFIGURATION_ENABLED=false

    # Sentry
    export SENTRY_DSN=""
    export SENTRY_ENVIRONMENT=""

    # GrowthBook / Statsig feature flags
    export GROWTHBOOK_CLIENT_KEY=""
    export STATSIG_CLIENT_KEY=""

    # Generic telemetry opt-out
    export DO_NOT_TRACK=1
    export NEXT_TELEMETRY_DISABLED=1

    info "遥测环境变量已屏蔽 (20+ 机制)"
    PROTECTION_SCORE=$((PROTECTION_SCORE + 1))
}

# ============================================================
# Layer 2b: Environment disguise - mask OS/user fingerprint
# ============================================================
setup_env_disguise() {
    # Timezone & locale
    export TZ="$TARGET_TZ"
    export LANG="$TARGET_LANG"
    export LC_ALL="$TARGET_LANG"
    export LANGUAGE="${TARGET_LANG%%.*}"

    # Hostname
    export HOSTNAME="$TARGET_HOSTNAME"
    export HOST="$TARGET_HOSTNAME"
    export COMPUTERNAME="$TARGET_HOSTNAME"
    export NAME="$TARGET_HOSTNAME"

    # User
    export LOGNAME="$TARGET_USER"

    # Remove ALL Windows-leaking env vars (comprehensive list)
    local win_vars=(
        WSLENV WSL_DISTRO_NAME WSL_INTEROP
        WINDOWS_USERNAME USERPROFILE APPDATA LOCALAPPDATA
        PROGRAMFILES ProgramFiles ProgramW6432 WINDIR SystemRoot
        OS PROCESSOR_ARCHITECTURE PROCESSOR_IDENTIFIER NUMBER_OF_PROCESSORS
        CommonProgramFiles CommonProgramW6432 ProgramData
        SystemDrive TEMP TMP HOMEDRIVE HOMEPATH
        # Windows Terminal identifiers
        WT_SESSION WT_PROFILE_ID
        # WSL GUI / audio
        PULSE_SERVER WAYLAND_DISPLAY
        # X11 forwarding (reveals WSL)
        DISPLAY
        # VS Code WSL
        VSCODE_WSL_EXT_LOCATION VSCODE_IPC_HOOK_CLI
        # PowerShell
        PSModulePath
        # .NET
        DOTNET_ROOT
    )

    for var in "${win_vars[@]}"; do
        unset "$var" 2>/dev/null || true
    done

    # Filter /mnt/c and /mnt/d paths from PATH
    export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '/mnt/[a-z]' | tr '\n' ':' | sed 's/:$//')

    # Override platform-revealing vars
    export TERM="xterm-256color"
    export SHELL="/bin/bash"
    export EDITOR="vim"
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"

    info "环境已伪装: $TARGET_HOSTNAME / $TARGET_TZ / $TARGET_LANG"
}

# ============================================================
# Layer 2b2: Git identity sanitization (session-only)
# ============================================================
setup_git_config() {
    export GIT_AUTHOR_NAME="$TARGET_USER"
    export GIT_AUTHOR_EMAIL="${TARGET_USER}@users.noreply.github.com"
    export GIT_COMMITTER_NAME="$TARGET_USER"
    export GIT_COMMITTER_EMAIL="${TARGET_USER}@users.noreply.github.com"
    info "Git 身份: $TARGET_USER (仅当前会话，~/.gitconfig 不受影响)"
}

# ============================================================
# Layer 2c: DNS leak prevention
# ============================================================
setup_dns() {
    # Check if WSL DNS is pointing to Windows host (leak risk)
    local current_dns
    current_dns=$(grep -m1 nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' || echo "")

    if [ -n "$current_dns" ] && [ "$current_dns" != "$DNS_SERVER" ] && [ "$current_dns" != "127.0.0.1" ]; then
        # DNS is pointing to Windows host - potential leak
        if [ -w /etc/resolv.conf ]; then
            # Temporarily override DNS for this session
            sudo bash -c "echo 'nameserver $DNS_SERVER' > /etc/resolv.conf" 2>/dev/null && \
                info "DNS 已设置为 $DNS_SERVER (原: $current_dns)" || \
                warn "DNS 仍指向 $current_dns (无法覆盖)"
        else
            warn "DNS 指向 $current_dns - 可能泄漏查询"
            dim "修复: 在 /etc/wsl.conf 添加: [network] generateResolvConf=false"
            dim "然后: echo 'nameserver $DNS_SERVER' | sudo tee /etc/resolv.conf"
        fi
    else
        info "DNS: $current_dns"
    fi
}

# ============================================================
# Layer 2d: /etc/hosts telemetry domain blocking
# ============================================================
setup_hosts_block() {
    # Complete list of telemetry domains from claude-private analysis
    local domains=(
        # Datadog (15-second flush)
        "http-intake.logs.us5.datadoghq.com"
        "browser-intake-us5-datadoghq.com"
        "us5.datadoghq.com"
        # Sentry
        "sentry.io"
        "o4507603404627968.ingest.us.sentry.io"
        # Statsig / GrowthBook / Amplitude
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

    local missing=0
    for domain in "${domains[@]}"; do
        if ! grep -q "$domain" /etc/hosts 2>/dev/null; then
            missing=$((missing + 1))
        fi
    done

    if [ "$missing" -gt 0 ]; then
        warn "$missing 个遥测域名未在 /etc/hosts 中屏蔽"
        dim "Run: sudo bash -c 'cat >> /etc/hosts << EOF"
        dim ""
        dim "# Claude Code telemetry block"
        for domain in "${domains[@]}"; do
            dim "0.0.0.0 $domain"
        done
        dim "EOF'"
    else
        info "遥测域名已在 /etc/hosts 中屏蔽 (${#domains[@]} 个域名)"
    fi
}

# ============================================================
# Layer 2e: Proxy configuration
# ============================================================
setup_proxy() {
    local proxy_url="${PROXY_PROTOCOL}://${PROXY_HOST}:${PROXY_PORT}"

    export HTTP_PROXY="$proxy_url"
    export HTTPS_PROXY="$proxy_url"
    export http_proxy="$proxy_url"
    export https_proxy="$proxy_url"
    export ALL_PROXY="$proxy_url"
    export all_proxy="$proxy_url"
    export NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    export no_proxy="$NO_PROXY"

    # Test proxy connectivity (use neutral URL to avoid exposing Claude usage to proxy logs)
    if command -v curl &>/dev/null; then
        if curl -s --connect-timeout 3 --proxy "$proxy_url" https://httpbin.org/ip -o /dev/null 2>/dev/null; then
            PROTECTION_SCORE=$((PROTECTION_SCORE + 2))
            info "代理连接正常: $proxy_url"
        else
            warn "代理不可达: $proxy_url"
        fi
    fi
}

# ============================================================
# Layer 4: Proxy IP quality check (shared IP detection)
# ============================================================
setup_proxy_check() {
    if [ "$PROXY_CHECK" != "true" ]; then
        return
    fi

    local proxy_url="${PROXY_PROTOCOL}://${PROXY_HOST}:${PROXY_PORT}"
    local cache_file="$HOME/.claude-safe/.ipinfo_cache"
    local cache_ttl=3600  # 1 hour
    local ip_info=""

    # Check cache first (avoid repeated ipinfo.io requests)
    if [ -f "$cache_file" ]; then
        local cache_age
        cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
        if [ "$cache_age" -lt "$cache_ttl" ]; then
            ip_info=$(cat "$cache_file")
            dim "代理 IP 信息来自缓存 (${cache_age}s 前)"
        fi
    fi

    # Fetch via proxy if no cache (MUST go through proxy, never direct)
    if [ -z "$ip_info" ]; then
        ip_info=$(curl -s --connect-timeout 5 --proxy "$proxy_url" "https://ipinfo.io/json" 2>/dev/null || echo "")
        if [ -n "$ip_info" ]; then
            mkdir -p "$(dirname "$cache_file")"
            echo "$ip_info" > "$cache_file"
        fi
    fi

    if [ -z "$ip_info" ]; then
        warn "无法检查代理 IP 质量 (ipinfo.io 不可达)"
        return
    fi

    local exit_country exit_org detected_tz
    PROXY_EXIT_IP=$(echo "$ip_info" | grep -o '"ip"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
    exit_country=$(echo "$ip_info" | grep -o '"country"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
    exit_org=$(echo "$ip_info" | grep -o '"org"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
    detected_tz=$(echo "$ip_info" | grep -o '"timezone"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

    info "代理出口: $PROXY_EXIT_IP ($exit_country) - $exit_org"

    if [ "$exit_country" = "CN" ]; then
        error "出口 IP 在中国！代理未正常工作。"
        return
    fi

    # Auto-match identity to current exit IP country
    local new_tz="" new_lang="" new_hostname=""
    case "$exit_country" in
        US)
            new_tz="${detected_tz:-America/Los_Angeles}"
            new_lang="en_US.UTF-8"
            new_hostname="dev-workstation"
            ;;
        JP)
            new_tz="${detected_tz:-Asia/Tokyo}"
            new_lang="ja_JP.UTF-8"
            new_hostname="dev-workstation"
            ;;
        SG)
            new_tz="${detected_tz:-Asia/Singapore}"
            new_lang="en_SG.UTF-8"
            new_hostname="dev-workstation"
            ;;
        GB|UK)
            new_tz="${detected_tz:-Europe/London}"
            new_lang="en_GB.UTF-8"
            new_hostname="dev-workstation"
            ;;
        DE)
            new_tz="${detected_tz:-Europe/Berlin}"
            new_lang="de_DE.UTF-8"
            new_hostname="dev-workstation"
            ;;
        KR)
            new_tz="${detected_tz:-Asia/Seoul}"
            new_lang="ko_KR.UTF-8"
            new_hostname="dev-workstation"
            ;;
        HK)
            new_tz="${detected_tz:-Asia/Hong_Kong}"
            new_lang="en_HK.UTF-8"
            new_hostname="dev-workstation"
            ;;
        TW)
            new_tz="${detected_tz:-Asia/Taipei}"
            new_lang="zh_TW.UTF-8"
            new_hostname="dev-workstation"
            ;;
        CA)
            new_tz="${detected_tz:-America/Toronto}"
            new_lang="en_CA.UTF-8"
            new_hostname="dev-workstation"
            ;;
        AU)
            new_tz="${detected_tz:-Australia/Sydney}"
            new_lang="en_AU.UTF-8"
            new_hostname="dev-workstation"
            ;;
        FR)
            new_tz="${detected_tz:-Europe/Paris}"
            new_lang="fr_FR.UTF-8"
            new_hostname="dev-workstation"
            ;;
        *)
            # Use ipinfo timezone directly
            new_tz="${detected_tz:-$TARGET_TZ}"
            new_lang="en_US.UTF-8"
            new_hostname="dev-workstation"
            ;;
    esac

    # Apply if different from current config
    if [ -n "$new_tz" ] && [ "$new_tz" != "$TARGET_TZ" ]; then
        warn "IP 地区变更: $TARGET_TZ -> $new_tz (自动调整)"
        TARGET_TZ="$new_tz"
        export TZ="$new_tz"
        export CLAUDE_TZ="$new_tz"
    fi
    if [ -n "$new_lang" ] && [ "$new_lang" != "$TARGET_LANG" ]; then
        TARGET_LANG="$new_lang"
        export LANG="$new_lang"
        export LC_ALL="$new_lang"
        export CLAUDE_LANG="$new_lang"
    fi

    # Pass updated values to os-override.js
    export CLAUDE_HOSTNAME="${TARGET_HOSTNAME}"
    export CLAUDE_USER="${TARGET_USER}"

    PROTECTION_SCORE=$((PROTECTION_SCORE + 1))
    info "身份已匹配出口 IP: $new_tz / $new_lang"

    # Warn about datacenter/shared IPs
    if echo "$exit_org" | grep -qi 'hosting\|datacenter\|cloud\|server\|vps\|digital.ocean\|vultr\|linode\|hetzner\|ovh'; then
        warn "检测到数据中心 IP - 共享使用风险较高"
        dim "建议使用住宅/ISP 代理以降低检测风险"
    else
        PROTECTION_SCORE=$((PROTECTION_SCORE + 1))
        info "代理 IP 类型: 住宅/ISP (良好)"
    fi
}

# ============================================================
# Layer 2f: iptables outbound whitelist (optional)
# ============================================================
setup_firewall() {
    if [ "$ENABLE_FIREWALL" != "true" ]; then
        return
    fi

    local fw_script="$SCRIPT_DIR/iptables-whitelist.sh"
    if [ ! -f "$fw_script" ]; then
        fw_script="$HOME/.claude-safe/iptables-whitelist.sh"
    fi

    if [ -f "$fw_script" ]; then
        warn "正在激活 iptables 防火墙 (需要 sudo)..."
        sudo bash "$fw_script" "$PROXY_HOST" "$PROXY_PORT" "$DNS_SERVER" && {
            PROTECTION_SCORE=$((PROTECTION_SCORE + 1))
            info "防火墙已激活: 仅允许代理 + 必要域名"
        } || \
            warn "防火墙设置失败 (WSL2 中 iptables 可能不可用)"
    else
        warn "iptables-whitelist.sh 未找到"
    fi
}

# ============================================================
# Layer 3: cc-gateway auto-start and integration
# ============================================================
setup_gateway() {
    local gateway_url="http://localhost:$GATEWAY_PORT"

    if [ "$ENABLE_GATEWAY" = "false" ]; then
        return
    fi

    # Auto-configure: cc-gateway installed but no config.yaml, credentials exist
    if [ -d "$GATEWAY_DIR" ] && [ ! -f "$GATEWAY_DIR/config.yaml" ] && \
       [ -f "$HOME/.claude/.credentials.json" ] && [ -f "$GATEWAY_DIR/scripts/quick-setup.sh" ]; then
        info "检测到 Claude 凭证，正在自动配置 cc-gateway..."
        local proxy_url="${PROXY_PROTOCOL}://${PROXY_HOST}:${PROXY_PORT}"
        HTTPS_PROXY="$proxy_url" bash "$GATEWAY_DIR/scripts/quick-setup.sh" &>/dev/null && \
            info "cc-gateway 配置完成" || \
            warn "cc-gateway 自动配置失败，可手动运行: bash $GATEWAY_DIR/scripts/quick-setup.sh"
    fi

    # Check if cc-gateway is already running
    if curl -s --connect-timeout 2 "$gateway_url/health" &>/dev/null 2>&1 || \
       curl -s --connect-timeout 2 "$gateway_url" &>/dev/null 2>&1; then
        export ANTHROPIC_BASE_URL="$gateway_url"
        PROTECTION_SCORE=$((PROTECTION_SCORE + 3))
        info "cc-gateway 已运行: $gateway_url"
        dim "设备指纹、计费头、环境维度将被重写"
        return
    fi

    # Not running - try to auto-start if installed and configured
    if [ -f "$GATEWAY_DIR/start.sh" ] && [ -f "$GATEWAY_DIR/config.yaml" ]; then
        info "正在启动 cc-gateway..."
        bash "$GATEWAY_DIR/start.sh" &>/dev/null
        local retries=0
        while [ $retries -lt 5 ]; do
            sleep 1
            if curl -s --connect-timeout 1 "$gateway_url/health" &>/dev/null 2>&1 || \
               curl -s --connect-timeout 1 "$gateway_url" &>/dev/null 2>&1; then
                export ANTHROPIC_BASE_URL="$gateway_url"
                PROTECTION_SCORE=$((PROTECTION_SCORE + 3))
                info "cc-gateway 已启动: $gateway_url"
                return
            fi
            retries=$((retries + 1))
        done
        warn "cc-gateway 5 秒内未启动"
    elif [ -d "$GATEWAY_DIR" ] && [ ! -f "$GATEWAY_DIR/config.yaml" ]; then
        # Installed but not configured (no credentials yet)
        if [ ! -f "$HOME/.claude/.credentials.json" ]; then
            info "cc-gateway 待配置 (请先完成 OAuth 登录，下次启动自动配置)"
        fi
    elif [ "$ENABLE_GATEWAY" = "true" ] || [ "$ENABLE_GATEWAY" = "auto" ]; then
        if [ -f "$SCRIPT_DIR/cc-gateway-setup.sh" ] || [ -f "$HOME/.claude-safe/cc-gateway-setup.sh" ]; then
            warn "cc-gateway 未安装 (建议安装以获得最大保护)"
            dim "安装: bash ~/.claude-safe/cc-gateway-setup.sh"
        fi
    fi
}

# ============================================================
# OAuth browser login helper (WSL2 -> Windows browser)
# ============================================================
setup_browser_auth() {
    if command -v wslview &>/dev/null; then
        export BROWSER="wslview"
        info "OAuth 浏览器: wslview (打开 Windows 浏览器)"
    elif command -v xdg-open &>/dev/null; then
        export BROWSER="xdg-open"
        info "OAuth 浏览器: xdg-open"
    else
        warn "未找到浏览器桥接。安装: sudo apt install wslu"
        dim "或在提示时手动复制 OAuth URL"
        export BROWSER="echo"
    fi
}

# ============================================================
# Verification & Protection Score
# ============================================================
verify_env() {
    echo ""
    echo -e "${CYAN}========== 环境状态 ==========${NC}"
    echo -e "  主机名:      ${HOSTNAME:-unknown}"
    echo -e "  时区:        ${TZ:-unknown}"
    echo -e "  语言:        ${LANG:-unknown}"
    echo -e "  代理:        ${HTTPS_PROXY:-未设置} -> ${PROXY_EXIT_IP:-未检测}"
    echo -e "  网关:        ${ANTHROPIC_BASE_URL:-直连 (无 cc-gateway)}"
    echo -e "  浏览器:      ${BROWSER:-未设置}"
    echo -e "  Node 钩子:   $([ -n "${NODE_OPTIONS:-}" ] && echo '已激活 (CJS+ESM)' || echo '未激活')"
    echo -e "  防火墙:      $([ "$ENABLE_FIREWALL" = "true" ] && echo '已激活' || echo '未激活')"
    echo -e "  遥测:        已屏蔽"

    # Leak check
    local leaks=""
    for var in WSLENV WSL_DISTRO_NAME WINDIR USERPROFILE WT_SESSION DISPLAY OS PROCESSOR_ARCHITECTURE; do
        [ -n "${!var:-}" ] && leaks+="$var "
    done

    if [ -n "$leaks" ]; then
        echo -e "  ${RED}泄漏:        $leaks${NC}"
    else
        echo -e "  泄漏:        ${GREEN}未检测到${NC}"
    fi

    # Kernel leak check
    if uname -r | grep -qi 'microsoft\|wsl'; then
        echo -e "  ${YELLOW}内核:        uname -r 中有 WSL 签名 (Node 钩子会伪装 os.release())${NC}"
    fi

    # /proc filesystem leak check
    if [ -f /proc/version ] && grep -qi 'microsoft\|wsl' /proc/version 2>/dev/null; then
        echo -e "  ${YELLOW}/proc:       /proc/version 中有 WSL 签名 (Node 钩子拦截 fs.readFile)${NC}"
    fi

    # Protection score display
    echo -e "${CYAN}========== 防护评分 ============${NC}"
    local bar=""
    local i
    for ((i=0; i<PROTECTION_SCORE; i++)); do bar+="█"; done
    for ((i=PROTECTION_SCORE; i<PROTECTION_MAX; i++)); do bar+="░"; done

    local color="$RED"
    local level="低"
    if [ "$PROTECTION_SCORE" -ge 8 ]; then
        color="$GREEN"; level="最高"
    elif [ "$PROTECTION_SCORE" -ge 6 ]; then
        color="$GREEN"; level="高"
    elif [ "$PROTECTION_SCORE" -ge 4 ]; then
        color="$YELLOW"; level="中"
    fi

    echo -e "  评分:        ${color}${bar} ${PROTECTION_SCORE}/${PROTECTION_MAX} (${level})${NC}"

    # Recommendations for missing points
    if [ -z "${ANTHROPIC_BASE_URL:-}" ]; then
        echo -e "  ${DIM}+3 安装 cc-gateway: bash ~/.claude-safe/cc-gateway-setup.sh${NC}"
    fi
    if [ "$ENABLE_FIREWALL" != "true" ]; then
        echo -e "  ${DIM}+1 启用防火墙: 在 config.env 中设置 CLAUDE_ENABLE_FIREWALL=true${NC}"
    fi

    echo -e "${CYAN}========================================${NC}"
    echo -e "  ${DIM}注意: 防护仅在当前终端生效，其他终端需单独运行 cs${NC}"
    echo ""
}

# ============================================================
# Main setup
# ============================================================
claude_setup() {
    echo -e "${CYAN}Claude Code 安全环境 v3${NC}"
    echo ""

    PROTECTION_SCORE=0

    # Layer 2 env/telemetry/proxy are now auto-loaded from .bashrc
    # Only re-apply if not already set (e.g. running outside normal shell)
    if [ -z "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" ]; then
        setup_telemetry_block
        setup_env_disguise
        setup_git_config
        setup_proxy
    else
        # Already loaded from .bashrc, just count the score
        info "环境已从 shell 配置文件预加载"
        PROTECTION_SCORE=$((PROTECTION_SCORE + 1))
        # Verify proxy is working
        local proxy_url="${PROXY_PROTOCOL}://${PROXY_HOST}:${PROXY_PORT}"
        if curl -s --connect-timeout 3 --proxy "$proxy_url" https://httpbin.org/ip -o /dev/null 2>/dev/null; then
            PROTECTION_SCORE=$((PROTECTION_SCORE + 2))
            info "代理连接正常: $proxy_url"
        else
            warn "代理不可达: $proxy_url"
        fi
    fi

    # These layers always need runtime activation
    setup_node_hook
    setup_dns
    setup_hosts_block
    setup_proxy_check
    setup_firewall
    setup_gateway
    setup_browser_auth
    verify_env

    info "就绪。使用 'claude-run' 启动。"
}

# ============================================================
# Launch wrapper
# ============================================================
claude-run() {
    if [ -z "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" ]; then
        claude_setup
    fi

    local claude_bin=""
    if command -v claude-private &>/dev/null; then
        claude_bin="claude-private"
        info "使用 claude-private (二进制补丁版，零遥测)"
    elif command -v claude &>/dev/null; then
        claude_bin="claude"
        info "使用官方 claude (遥测已通过环境变量 + 钩子屏蔽)"
    else
        error "Claude Code 未找到。"
        dim "npm install -g @anthropic-ai/claude-code"
        dim "或: https://github.com/ultrmgns/claude-private"
        return 1
    fi

    exec "$claude_bin" "$@"
}

# Auto-run setup when sourced
claude_setup
