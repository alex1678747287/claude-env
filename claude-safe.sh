#!/usr/bin/env bash
# claude-safe.sh v3 - Claude Code environment isolation wrapper for WSL2
# Four-layer protection: Node.js os hook + env/DNS/firewall + cc-gateway + proxy quality
# Usage: source ~/.claude-safe/claude-safe.sh && claude-run [claude args...]

set -euo pipefail

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
        info "Node.js/Bun os hook loaded (CJS --require + ESM --import)"
        PROTECTION_SCORE=$((PROTECTION_SCORE + 2))
    else
        warn "os-override.js not found - Node.js level disguise disabled"
        dim "Copy os-override.js to $SCRIPT_DIR/"
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

    info "Telemetry env vars blocked (20+ mechanisms)"
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

    info "Environment disguised: $TARGET_HOSTNAME / $TARGET_TZ / $TARGET_LANG"
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
                info "DNS set to $DNS_SERVER (was $current_dns)" || \
                warn "DNS still pointing to $current_dns (could not override)"
        else
            warn "DNS pointing to $current_dns - may leak queries"
            dim "Fix: add to /etc/wsl.conf: [network] generateResolvConf=false"
            dim "Then: echo 'nameserver $DNS_SERVER' | sudo tee /etc/resolv.conf"
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
        # Statsig / GrowthBook
        "statsig.anthropic.com"
        "featuregates.org"
        "api.statsig.com"
    )

    local missing=0
    for domain in "${domains[@]}"; do
        if ! grep -q "$domain" /etc/hosts 2>/dev/null; then
            missing=$((missing + 1))
        fi
    done

    if [ "$missing" -gt 0 ]; then
        warn "$missing telemetry domains not in /etc/hosts"
        dim "Run: sudo bash -c 'cat >> /etc/hosts << EOF"
        dim ""
        dim "# Claude Code telemetry block"
        for domain in "${domains[@]}"; do
            dim "0.0.0.0 $domain"
        done
        dim "EOF'"
    else
        info "Telemetry domains blocked in /etc/hosts (${#domains[@]} domains)"
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
            info "Proxy connectivity OK: $proxy_url"
        else
            warn "Proxy not reachable at $proxy_url"
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

    # Get exit IP info via proxy
    local ip_info
    ip_info=$(curl -s --connect-timeout 5 --proxy "$proxy_url" "https://ipinfo.io/json" 2>/dev/null || echo "")

    if [ -z "$ip_info" ]; then
        warn "Could not check proxy IP quality (ipinfo.io unreachable)"
        return
    fi

    local exit_ip exit_country exit_org ip_type
    exit_ip=$(echo "$ip_info" | grep -o '"ip"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
    exit_country=$(echo "$ip_info" | grep -o '"country"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
    exit_org=$(echo "$ip_info" | grep -o '"org"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")

    info "Proxy exit: $exit_ip ($exit_country) - $exit_org"

    # Check if country matches timezone
    local tz_region="${TARGET_TZ%%/*}"
    case "$exit_country" in
        US) [ "$tz_region" = "America" ] && PROTECTION_SCORE=$((PROTECTION_SCORE + 1)) || warn "TZ mismatch: $TARGET_TZ but exit IP is US" ;;
        JP) [ "$tz_region" = "Asia" ] && PROTECTION_SCORE=$((PROTECTION_SCORE + 1)) || warn "TZ mismatch: $TARGET_TZ but exit IP is JP" ;;
        SG|HK|TW|KR) PROTECTION_SCORE=$((PROTECTION_SCORE + 1)) ;;
        CN) error "Exit IP is in China! Proxy is not working correctly." ;;
        *) PROTECTION_SCORE=$((PROTECTION_SCORE + 1)) ;;
    esac

    # Warn about datacenter/shared IPs
    if echo "$exit_org" | grep -qi 'hosting\|datacenter\|cloud\|server\|vps\|digital.ocean\|vultr\|linode\|hetzner\|ovh'; then
        warn "Datacenter IP detected - higher risk of shared usage"
        dim "Residential/ISP proxy recommended for lower detection risk"
    else
        PROTECTION_SCORE=$((PROTECTION_SCORE + 1))
        info "Proxy IP type: residential/ISP (good)"
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
        warn "Activating iptables firewall (requires sudo)..."
        sudo bash "$fw_script" "$PROXY_HOST" "$PROXY_PORT" "$DNS_SERVER" && {
            PROTECTION_SCORE=$((PROTECTION_SCORE + 1))
            info "Firewall active: only proxy + essential domains allowed"
        } || \
            warn "Firewall setup failed (iptables may not be available in WSL2)"
    else
        warn "iptables-whitelist.sh not found"
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

    # Check if cc-gateway is already running
    if curl -s --connect-timeout 2 "$gateway_url/health" &>/dev/null 2>&1 || \
       curl -s --connect-timeout 2 "$gateway_url" &>/dev/null 2>&1; then
        export ANTHROPIC_BASE_URL="$gateway_url"
        PROTECTION_SCORE=$((PROTECTION_SCORE + 3))
        info "cc-gateway active at $gateway_url"
        dim "Device fingerprint, billing header, env dimensions will be rewritten"
        return
    fi

    # Not running - try to auto-start if installed
    if [ -f "$GATEWAY_DIR/start.sh" ]; then
        info "Starting cc-gateway..."
        bash "$GATEWAY_DIR/start.sh" &>/dev/null
        # Wait for startup
        local retries=0
        while [ $retries -lt 5 ]; do
            sleep 1
            if curl -s --connect-timeout 1 "$gateway_url/health" &>/dev/null 2>&1 || \
               curl -s --connect-timeout 1 "$gateway_url" &>/dev/null 2>&1; then
                export ANTHROPIC_BASE_URL="$gateway_url"
                PROTECTION_SCORE=$((PROTECTION_SCORE + 3))
                info "cc-gateway started at $gateway_url"
                return
            fi
            retries=$((retries + 1))
        done
        warn "cc-gateway failed to start within 5s"
    elif [ "$ENABLE_GATEWAY" = "true" ] || [ "$ENABLE_GATEWAY" = "auto" ]; then
        # Not installed - offer to install
        if [ -f "$SCRIPT_DIR/cc-gateway-setup.sh" ] || [ -f "$HOME/.claude-safe/cc-gateway-setup.sh" ]; then
            warn "cc-gateway not installed (recommended for maximum protection)"
            dim "Install: bash ~/.claude-safe/cc-gateway-setup.sh"
            dim "It rewrites device_id, billing header, and 40+ env dimensions"
        fi
    fi
}

# ============================================================
# OAuth browser login helper (WSL2 -> Windows browser)
# ============================================================
setup_browser_auth() {
    if command -v wslview &>/dev/null; then
        export BROWSER="wslview"
        info "OAuth browser: wslview (opens Windows browser)"
    elif command -v xdg-open &>/dev/null; then
        export BROWSER="xdg-open"
        info "OAuth browser: xdg-open"
    else
        warn "No browser bridge. Install: sudo apt install wslu"
        dim "Or manually copy the OAuth URL when prompted"
        export BROWSER="echo"
    fi
}

# ============================================================
# Verification & Protection Score
# ============================================================
verify_env() {
    echo ""
    echo -e "${CYAN}========== Environment Status ==========${NC}"
    echo -e "  Hostname:    ${HOSTNAME:-unknown}"
    echo -e "  Timezone:    ${TZ:-unknown}"
    echo -e "  Locale:      ${LANG:-unknown}"
    echo -e "  Proxy:       ${HTTPS_PROXY:-not set}"
    echo -e "  Gateway:     ${ANTHROPIC_BASE_URL:-direct (no cc-gateway)}"
    echo -e "  Browser:     ${BROWSER:-not set}"
    echo -e "  Node hook:   $([ -n "${NODE_OPTIONS:-}" ] && echo 'active (CJS+ESM)' || echo 'inactive')"
    echo -e "  Firewall:    $([ "$ENABLE_FIREWALL" = "true" ] && echo 'active' || echo 'inactive')"
    echo -e "  Telemetry:   BLOCKED"

    # Leak check
    local leaks=""
    for var in WSLENV WSL_DISTRO_NAME WINDIR USERPROFILE WT_SESSION DISPLAY OS PROCESSOR_ARCHITECTURE; do
        [ -n "${!var:-}" ] && leaks+="$var "
    done

    if [ -n "$leaks" ]; then
        echo -e "  ${RED}Leaks:       $leaks${NC}"
    else
        echo -e "  Leaks:       ${GREEN}none detected${NC}"
    fi

    # Kernel leak check
    if uname -r | grep -qi 'microsoft\|wsl'; then
        echo -e "  ${YELLOW}Kernel:      WSL signature in uname -r (Node hook will mask os.release())${NC}"
    fi

    # /proc filesystem leak check
    if [ -f /proc/version ] && grep -qi 'microsoft\|wsl' /proc/version 2>/dev/null; then
        echo -e "  ${YELLOW}/proc:       WSL signature in /proc/version (Node hook intercepts fs.readFile)${NC}"
    fi

    # Protection score display
    echo -e "${CYAN}========== Protection Score ============${NC}"
    local bar=""
    local i
    for ((i=0; i<PROTECTION_SCORE; i++)); do bar+="█"; done
    for ((i=PROTECTION_SCORE; i<PROTECTION_MAX; i++)); do bar+="░"; done

    local color="$RED"
    local level="LOW"
    if [ "$PROTECTION_SCORE" -ge 8 ]; then
        color="$GREEN"; level="MAXIMUM"
    elif [ "$PROTECTION_SCORE" -ge 6 ]; then
        color="$GREEN"; level="HIGH"
    elif [ "$PROTECTION_SCORE" -ge 4 ]; then
        color="$YELLOW"; level="MEDIUM"
    fi

    echo -e "  Score:       ${color}${bar} ${PROTECTION_SCORE}/${PROTECTION_MAX} (${level})${NC}"

    # Recommendations for missing points
    if [ -z "${ANTHROPIC_BASE_URL:-}" ]; then
        echo -e "  ${DIM}+3 Install cc-gateway: bash ~/.claude-safe/cc-gateway-setup.sh${NC}"
    fi
    if [ "$ENABLE_FIREWALL" != "true" ]; then
        echo -e "  ${DIM}+1 Enable firewall: CLAUDE_ENABLE_FIREWALL=true in config.env${NC}"
    fi

    echo -e "${CYAN}========================================${NC}"
    echo ""
}

# ============================================================
# Main setup
# ============================================================
claude_setup() {
    echo -e "${CYAN}Claude Code Safe Environment v3${NC}"
    echo ""

    PROTECTION_SCORE=0

    # Layer 2 env/telemetry/proxy are now auto-loaded from .bashrc
    # Only re-apply if not already set (e.g. running outside normal shell)
    if [ -z "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" ]; then
        setup_telemetry_block
        setup_env_disguise
        setup_proxy
    else
        # Already loaded from .bashrc, just count the score
        info "Environment pre-loaded from shell profile"
        PROTECTION_SCORE=$((PROTECTION_SCORE + 1))
        # Verify proxy is working
        local proxy_url="${PROXY_PROTOCOL}://${PROXY_HOST}:${PROXY_PORT}"
        if curl -s --connect-timeout 3 --proxy "$proxy_url" https://httpbin.org/ip -o /dev/null 2>/dev/null; then
            PROTECTION_SCORE=$((PROTECTION_SCORE + 2))
            info "Proxy connectivity OK: $proxy_url"
        else
            warn "Proxy not reachable at $proxy_url"
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

    info "Ready. Use 'claude-run' to launch."
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
        info "Using claude-private (binary-patched, zero telemetry)"
    elif command -v claude &>/dev/null; then
        claude_bin="claude"
        info "Using official claude (telemetry blocked via env + hooks)"
    else
        error "Claude Code not found."
        dim "npm install -g @anthropic-ai/claude-code"
        dim "Or: https://github.com/ultrmgns/claude-private"
        return 1
    fi

    exec "$claude_bin" "$@"
}

# Auto-run setup when sourced
claude_setup
