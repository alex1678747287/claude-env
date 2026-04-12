#!/usr/bin/env bash
# install.sh v3 - Claude Code Safe Environment interactive installer
# Four-layer protection: Node.js hook + env/DNS/firewall + cc-gateway + proxy quality
# Usage: bash install.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; }
step()  { echo -e "\n${BOLD}${CYAN}── $* ──${NC}\n"; }

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
echo -e "  Four-layer protection for Claude Code on WSL2"
echo ""

# ============================================================
# Step 0: System dependencies (silent)
# ============================================================
step "Step 0/5: Checking dependencies"

install_pkg() {
    local cmd=$1 pkg=${2:-$1}
    if ! command -v "$cmd" &>/dev/null; then
        info "Installing $pkg..."
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
    info "Installing Node.js via nvm..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    nvm install 22
    nvm use 22
else
    NODE_VER=$(node -v | sed 's/v//' | cut -d. -f1)
    if [ "$NODE_VER" -lt 22 ]; then
        warn "Node.js $(node -v) found, but cc-gateway needs >= 22"
        if command -v nvm &>/dev/null || [ -s "$HOME/.nvm/nvm.sh" ]; then
            [ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh"
            info "Upgrading via nvm..."
            nvm install 22 && nvm use 22 && nvm alias default 22
        else
            warn "Please upgrade Node.js manually to >= 22"
        fi
    else
        info "Node.js $(node -v) OK"
    fi
fi

# Claude Code
if ! command -v claude &>/dev/null && ! command -v claude-private &>/dev/null; then
    info "Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code
else
    info "Claude Code found"
fi

info "Dependencies OK"

# ============================================================
# Step 1: Proxy configuration (interactive)
# ============================================================
step "Step 1/5: Proxy Configuration"

# Auto-detect Windows host IP
WIN_HOST_IP="127.0.0.1"
if [ -f /etc/resolv.conf ]; then
    detected_ip=$(grep -m1 nameserver /etc/resolv.conf | awk '{print $2}' || echo "")
    if [ -n "$detected_ip" ] && [ "$detected_ip" != "127.0.0.1" ]; then
        WIN_HOST_IP="$detected_ip"
    fi
fi
info "Detected Windows host IP: $WIN_HOST_IP"

# Auto-detect proxy port
DETECTED_PORT=""
for port in 7890 7891 1080 10808 20171 10809; do
    if curl -s --connect-timeout 1 --proxy "http://${WIN_HOST_IP}:${port}" https://httpbin.org/ip &>/dev/null 2>&1; then
        DETECTED_PORT="$port"
        break
    fi
done

if [ -n "$DETECTED_PORT" ]; then
    info "Auto-detected proxy at ${WIN_HOST_IP}:${DETECTED_PORT}"
fi

ask "Proxy host" "$WIN_HOST_IP"
PROXY_HOST="$REPLY"

ask "Proxy port" "${DETECTED_PORT:-7890}"
PROXY_PORT="$REPLY"

echo -e "  ${DIM}1) http  2) socks5${NC}"
ask "Proxy protocol" "http"
PROXY_PROTOCOL="$REPLY"

# Test connectivity
PROXY_URL="${PROXY_PROTOCOL}://${PROXY_HOST}:${PROXY_PORT}"
echo -ne "  Testing proxy... "
if curl -s --connect-timeout 5 --proxy "$PROXY_URL" https://httpbin.org/ip -o /dev/null 2>/dev/null; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAILED${NC}"
    warn "Proxy not reachable. You can fix config.env later."
fi

# ============================================================
# Step 2: Identity disguise (auto-detect from proxy exit IP)
# ============================================================
step "Step 2/5: Identity Disguise"

# Auto-detect region from proxy exit IP
DETECTED_COUNTRY=""
DETECTED_TZ=""
DETECTED_LANG=""

if [ -n "$PROXY_URL" ]; then
    echo -ne "  Detecting proxy exit region... "
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
                echo -e "  ${RED}WARNING: Proxy exit IP is in China! Proxy is not working.${NC}"
                DETECTED_TZ=""
                DETECTED_LANG=""
            fi
        else
            echo -e "${YELLOW}failed${NC}"
        fi
    else
        echo -e "${YELLOW}failed (ipinfo.io unreachable)${NC}"
    fi
fi

# Use detected values or fall back to manual selection
if [ -n "$DETECTED_TZ" ] && [ -n "$DETECTED_LANG" ]; then
    info "Auto-matched: $DETECTED_TZ / $DETECTED_LANG"
    TARGET_TZ="$DETECTED_TZ"
    TARGET_LANG="$DETECTED_LANG"

    if ! confirm "Use auto-detected region?" "Y"; then
        echo -e "\n  Select a region manually:\n"
        echo -e "    ${CYAN}1)${NC} US West     (Los Angeles, en_US)"
        echo -e "    ${CYAN}2)${NC} US East     (New York, en_US)"
        echo -e "    ${CYAN}3)${NC} Japan       (Tokyo, ja_JP)"
        echo -e "    ${CYAN}4)${NC} Singapore   (Singapore, en_SG)"
        echo -e "    ${CYAN}5)${NC} UK          (London, en_GB)"
        echo -e "    ${CYAN}6)${NC} Custom"
        echo ""
        ask "Region" "1"
        REGION_CHOICE="$REPLY"
        case "$REGION_CHOICE" in
            1) TARGET_TZ="America/Los_Angeles"; TARGET_LANG="en_US.UTF-8" ;;
            2) TARGET_TZ="America/New_York";    TARGET_LANG="en_US.UTF-8" ;;
            3) TARGET_TZ="Asia/Tokyo";          TARGET_LANG="ja_JP.UTF-8" ;;
            4) TARGET_TZ="Asia/Singapore";      TARGET_LANG="en_SG.UTF-8" ;;
            5) TARGET_TZ="Europe/London";       TARGET_LANG="en_GB.UTF-8" ;;
            6)
                ask "Timezone" "America/Los_Angeles"
                TARGET_TZ="$REPLY"
                ask "Locale" "en_US.UTF-8"
                TARGET_LANG="$REPLY"
                ;;
            *) TARGET_TZ="America/Los_Angeles"; TARGET_LANG="en_US.UTF-8" ;;
        esac
    fi
else
    # No auto-detection, manual selection
    echo -e "  Select a region (should match your proxy exit):\n"
    echo -e "    ${CYAN}1)${NC} US West     (Los Angeles, en_US)"
    echo -e "    ${CYAN}2)${NC} US East     (New York, en_US)"
    echo -e "    ${CYAN}3)${NC} Japan       (Tokyo, ja_JP)"
    echo -e "    ${CYAN}4)${NC} Singapore   (Singapore, en_SG)"
    echo -e "    ${CYAN}5)${NC} UK          (London, en_GB)"
    echo -e "    ${CYAN}6)${NC} Custom"
    echo ""
    ask "Region" "1"
    REGION_CHOICE="$REPLY"
    case "$REGION_CHOICE" in
        1) TARGET_TZ="America/Los_Angeles"; TARGET_LANG="en_US.UTF-8" ;;
        2) TARGET_TZ="America/New_York";    TARGET_LANG="en_US.UTF-8" ;;
        3) TARGET_TZ="Asia/Tokyo";          TARGET_LANG="ja_JP.UTF-8" ;;
        4) TARGET_TZ="Asia/Singapore";      TARGET_LANG="en_SG.UTF-8" ;;
        5) TARGET_TZ="Europe/London";       TARGET_LANG="en_GB.UTF-8" ;;
        6)
            ask "Timezone" "America/Los_Angeles"
            TARGET_TZ="$REPLY"
            ask "Locale" "en_US.UTF-8"
            TARGET_LANG="$REPLY"
            ;;
        *) TARGET_TZ="America/Los_Angeles"; TARGET_LANG="en_US.UTF-8" ;;
    esac
fi

ask "Hostname" "dev-workstation"
TARGET_HOSTNAME="$REPLY"

ask "Username" "developer"
TARGET_USER="$REPLY"

info "Identity: $TARGET_HOSTNAME / $TARGET_TZ / $TARGET_LANG"

# ============================================================
# Step 3: DNS + Hosts + System config (auto)
# ============================================================
step "Step 3/5: DNS & Telemetry Blocking"

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
)

missing=0
for domain in "${TELEMETRY_DOMAINS[@]}"; do
    grep -q "$domain" /etc/hosts 2>/dev/null || missing=$((missing + 1))
done

if [ "$missing" -gt 0 ]; then
    info "Blocking $missing telemetry domains in /etc/hosts..."
    {
        echo ""
        echo "# Claude Code telemetry block - added by claude-safe installer"
        for domain in "${TELEMETRY_DOMAINS[@]}"; do
            grep -q "$domain" /etc/hosts 2>/dev/null || echo "0.0.0.0 $domain"
        done
    } | sudo tee -a /etc/hosts > /dev/null
    info "Telemetry domains blocked"
else
    info "Telemetry domains already blocked"
fi

# DNS leak check
DNS_SERVER="1.1.1.1"
current_dns=$(grep -m1 nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' || echo "")
if [ -n "$current_dns" ] && [ "$current_dns" != "$DNS_SERVER" ] && [ "$current_dns" != "127.0.0.1" ]; then
    warn "DNS pointing to $current_dns (Windows host - leak risk)"
    if confirm "Fix DNS to $DNS_SERVER now?" "Y"; then
        # Try direct fix
        if sudo bash -c "echo 'nameserver $DNS_SERVER' > /etc/resolv.conf" 2>/dev/null; then
            info "DNS set to $DNS_SERVER"
        else
            warn "Could not fix DNS automatically"
        fi
        # Check wsl.conf
        if ! grep -q "generateResolvConf" /etc/wsl.conf 2>/dev/null; then
            warn "Add to /etc/wsl.conf to make DNS fix permanent:"
            echo -e "  ${DIM}[network]${NC}"
            echo -e "  ${DIM}generateResolvConf = false${NC}"
        fi
    fi
else
    info "DNS: $current_dns (OK)"
fi

# Hostname check
CURRENT_HOSTNAME=$(hostname)
if echo "$CURRENT_HOSTNAME" | grep -qi 'desktop\|laptop\|pc\|win\|admin'; then
    warn "System hostname '$CURRENT_HOSTNAME' may reveal identity"
    if ! grep -q "hostname" /etc/wsl.conf 2>/dev/null; then
        echo -e "  ${DIM}Add to /etc/wsl.conf: [network] hostname = $TARGET_HOSTNAME${NC}"
    fi
fi

# ============================================================
# Step 4: cc-gateway installation (built-in, required)
# ============================================================
step "Step 4/5: cc-gateway (API Identity Proxy)"

info "cc-gateway rewrites device_id, billing header, 40+ env dimensions"
info "This is the most important protection layer for API-level fingerprinting"
echo ""

if [ -d "$GATEWAY_DIR" ] && [ -f "$GATEWAY_DIR/package.json" ]; then
    info "cc-gateway already installed, updating..."
    cd "$GATEWAY_DIR" && git pull --quiet 2>/dev/null || true
    npm install --quiet 2>/dev/null
    info "cc-gateway updated"
else
    info "Cloning cc-gateway..."
    git clone --quiet https://github.com/motiful/cc-gateway.git "$GATEWAY_DIR" 2>/dev/null
    cd "$GATEWAY_DIR"
    info "Installing dependencies..."
    npm install --quiet 2>/dev/null
    info "cc-gateway installed"
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

# Run quick-setup if config doesn't exist
if [ ! -f "$GATEWAY_DIR/config.yaml" ] && [ -f "$GATEWAY_DIR/scripts/quick-setup.sh" ]; then
    info "Running cc-gateway quick setup..."
    echo -e "  ${DIM}If you haven't logged in to Claude Code yet, do that first: claude --login${NC}"
    if [ -n "$PROXY_URL" ]; then
        HTTPS_PROXY="$PROXY_URL" bash "$GATEWAY_DIR/scripts/quick-setup.sh" || \
            warn "cc-gateway setup needs manual config. See: $GATEWAY_DIR/README.md"
    else
        bash "$GATEWAY_DIR/scripts/quick-setup.sh" || \
            warn "cc-gateway setup needs manual config. See: $GATEWAY_DIR/README.md"
    fi
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
    info "Systemd service created (optional: systemctl --user enable cc-gateway)"
fi

info "cc-gateway ready"

# ============================================================
# Step 5: Firewall + config generation + aliases
# ============================================================
step "Step 5/5: Firewall & Finalize"

ENABLE_FIREWALL="true"
if ! confirm "Enable iptables outbound whitelist? (recommended)" "Y"; then
    ENABLE_FIREWALL="false"
fi

# Copy scripts to install directory
mkdir -p "$INSTALL_DIR"
for f in claude-safe.sh os-override.js os-override.mjs iptables-whitelist.sh cc-gateway-setup.sh uninstall.sh; do
    if [ -f "$SCRIPT_DIR/$f" ]; then
        cp "$SCRIPT_DIR/$f" "$INSTALL_DIR/$f"
        chmod +x "$INSTALL_DIR/$f" 2>/dev/null || true
    fi
done
info "Scripts installed to $INSTALL_DIR"

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
info "Config generated: $CONFIG_FILE"

# Add shell aliases
SHELL_RC="$HOME/.bashrc"
[ -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.zshrc"

if ! grep -q "claude-safe" "$SHELL_RC" 2>/dev/null; then
    cat >> "$SHELL_RC" << 'ALIASES'

# Claude Code Safe Environment v3
alias claude-safe="source ~/.claude-safe/config.env 2>/dev/null; source ~/.claude-safe/claude-safe.sh"
alias cs="claude-safe && claude-run"
ALIASES
    info "Aliases added to $SHELL_RC"
fi

# ============================================================
# Done
# ============================================================
echo ""
echo -e "${GREEN}${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}  Installation complete!${NC}"
echo -e "${GREEN}${BOLD}========================================${NC}"
echo ""
echo -e "  ${BOLD}Quick start:${NC}"
echo -e "    ${CYAN}source $SHELL_RC && cs${NC}"
echo ""
echo -e "  ${BOLD}Protection layers:${NC}"
echo -e "    ${GREEN}Layer 1${NC} Node.js hook     os.*/fs.*/child_process.* patched"
echo -e "    ${GREEN}Layer 2${NC} Env/DNS/FW       20+ telemetry blocked, iptables whitelist"
echo -e "    ${GREEN}Layer 3${NC} cc-gateway       device_id + billing header + 40+ dimensions"
echo -e "    ${GREEN}Layer 4${NC} Proxy check      exit IP country + type verification"
echo ""
echo -e "  ${BOLD}Your config:${NC}"
echo -e "    Proxy:    ${CYAN}${PROXY_URL}${NC}"
echo -e "    Region:   ${CYAN}${TARGET_TZ}${NC}"
echo -e "    Identity: ${CYAN}${TARGET_USER}@${TARGET_HOSTNAME}${NC}"
echo -e "    Firewall: ${CYAN}${ENABLE_FIREWALL}${NC}"
echo -e "    Gateway:  ${CYAN}auto (cc-gateway installed)${NC}"
echo ""
echo -e "  ${DIM}To reconfigure: bash $SCRIPT_DIR/install.sh${NC}"
echo -e "  ${DIM}To uninstall:   bash $SCRIPT_DIR/uninstall.sh${NC}"
echo ""
