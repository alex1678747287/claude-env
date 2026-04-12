#!/usr/bin/env bash
# install.sh v2 - Claude Code Safe Environment installer for WSL2
# Sets up three-layer protection: Node.js hook + env/DNS/firewall + cc-gateway

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.claude-safe"

echo -e "${CYAN}"
echo "  Claude Code Safe Environment v2 Installer"
echo "  Three-layer protection for WSL2"
echo -e "${NC}"

# ============================================================
# 1. Install system dependencies
# ============================================================
info "Checking dependencies..."

install_pkg() {
    local cmd=$1 pkg=${2:-$1}
    if ! command -v "$cmd" &>/dev/null; then
        info "Installing $pkg..."
        sudo apt-get update -qq 2>/dev/null && sudo apt-get install -y -qq "$pkg" 2>/dev/null
    fi
}

install_pkg wslview wslu      # WSL browser bridge for OAuth
install_pkg curl curl
install_pkg git git
install_pkg jq jq             # JSON parsing for IP geolocation check

# iptables for optional firewall
if ! command -v iptables &>/dev/null; then
    info "Installing iptables..."
    sudo apt-get install -y -qq iptables ipset 2>/dev/null || true
fi

# ============================================================
# 2. Install Node.js if needed
# ============================================================
if ! command -v node &>/dev/null; then
    info "Installing Node.js via nvm..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    nvm install --lts
    nvm use --lts
else
    info "Node.js $(node --version) found"
fi

# ============================================================
# 3. Install Claude Code
# ============================================================
if ! command -v claude &>/dev/null; then
    info "Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code
else
    info "Claude Code found"
fi

# ============================================================
# 4. Copy files to install directory
# ============================================================
mkdir -p "$INSTALL_DIR"

for f in claude-safe.sh os-override.js os-override.mjs iptables-whitelist.sh cc-gateway-setup.sh; do
    if [ -f "$SCRIPT_DIR/$f" ]; then
        cp "$SCRIPT_DIR/$f" "$INSTALL_DIR/$f"
        chmod +x "$INSTALL_DIR/$f" 2>/dev/null || true
        info "Installed: $f"
    fi
done

# ============================================================
# 5. Block telemetry domains in /etc/hosts
# ============================================================
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

# ============================================================
# 6. Configure WSL2 DNS (prevent DNS leak)
# ============================================================
WSL_CONF="/etc/wsl.conf"
if ! grep -q "generateResolvConf" "$WSL_CONF" 2>/dev/null; then
    warn "WSL2 auto-generates DNS config (potential DNS leak)"
    echo ""
    echo -e "  ${CYAN}To fix DNS leak, add to /etc/wsl.conf:${NC}"
    echo "  [network]"
    echo "  generateResolvConf = false"
    echo ""
    echo -e "  ${CYAN}Then set DNS manually:${NC}"
    echo "  echo 'nameserver 1.1.1.1' | sudo tee /etc/resolv.conf"
    echo ""
    echo -e "  ${CYAN}Then restart WSL: wsl --shutdown${NC}"
    echo ""
fi

# ============================================================
# 7. Configure WSL2 hostname
# ============================================================
TARGET_HOSTNAME="dev-workstation"
CURRENT_HOSTNAME=$(hostname)
if echo "$CURRENT_HOSTNAME" | grep -qi 'desktop\|laptop\|pc\|win\|admin'; then
    warn "Hostname '$CURRENT_HOSTNAME' may reveal identity"
    if ! grep -q "hostname" "$WSL_CONF" 2>/dev/null; then
        echo -e "  ${CYAN}Add to /etc/wsl.conf:${NC}"
        echo "  [network]"
        echo "  hostname = $TARGET_HOSTNAME"
        echo ""
    fi
fi

# ============================================================
# 8. Generate config file
# ============================================================
CONFIG_FILE="$INSTALL_DIR/config.env"

# Auto-detect Windows host IP for proxy
WIN_HOST_IP="127.0.0.1"
if [ -f /etc/resolv.conf ]; then
    detected_ip=$(grep -m1 nameserver /etc/resolv.conf | awk '{print $2}')
    if [ -n "$detected_ip" ] && [ "$detected_ip" != "127.0.0.1" ]; then
        WIN_HOST_IP="$detected_ip"
    fi
fi

if [ ! -f "$CONFIG_FILE" ]; then
    # Create with restrictive permissions first to avoid race condition (M2)
    install -m 600 /dev/null "$CONFIG_FILE"
    cat > "$CONFIG_FILE" << CONF
# Claude Safe Environment v3 Configuration

# ============================================================
# Proxy (your local proxy, e.g., Clash/V2Ray on Windows host)
# Residential/ISP proxy recommended over datacenter for lower risk
# ============================================================
CLAUDE_PROXY_HOST=$WIN_HOST_IP
CLAUDE_PROXY_PORT=7890
CLAUDE_PROXY_PROTOCOL=http

# ============================================================
# Disguise (match your proxy exit node region)
# ============================================================
CLAUDE_TZ=America/Los_Angeles
CLAUDE_LANG=en_US.UTF-8
CLAUDE_HOSTNAME=dev-workstation
CLAUDE_USER=developer

# ============================================================
# DNS (prevent DNS leak through Windows host)
# ============================================================
CLAUDE_DNS=1.1.1.1

# ============================================================
# Firewall - iptables outbound whitelist
# Only allows traffic to proxy + essential Claude domains
# Requires sudo. Recommended for maximum isolation.
# ============================================================
CLAUDE_ENABLE_FIREWALL=true

# ============================================================
# cc-gateway - API identity proxy (recommended)
# Rewrites device fingerprint, billing header, env dimensions
# Set to: auto (auto-start if installed), true (require), false (skip)
# Install: bash ~/.claude-safe/cc-gateway-setup.sh
# ============================================================
CLAUDE_ENABLE_GATEWAY=auto
CC_GATEWAY_PORT=8443

# ============================================================
# Proxy IP quality check
# Checks exit IP country, type (residential vs datacenter)
# Set to false to skip (saves ~2s startup time)
# ============================================================
CLAUDE_PROXY_CHECK=true
CONF
    info "Config created: $CONFIG_FILE"
    warn "Edit proxy settings: vim $CONFIG_FILE"
else
    info "Config exists: $CONFIG_FILE"
fi

# ============================================================
# 9. Add shell aliases
# ============================================================
SHELL_RC="$HOME/.bashrc"
[ -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.zshrc"

if ! grep -q "claude-safe" "$SHELL_RC" 2>/dev/null; then
    cat >> "$SHELL_RC" << 'ALIASES'

# Claude Code Safe Environment v2
alias claude-safe="source ~/.claude-safe/config.env 2>/dev/null; source ~/.claude-safe/claude-safe.sh"
alias cs="claude-safe && claude-run"
ALIASES
    info "Aliases added to $SHELL_RC"
fi

# ============================================================
# Done
# ============================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Quick start:"
echo -e "  1. Edit config:  ${CYAN}vim $CONFIG_FILE${NC}"
echo -e "  2. Reload shell: ${CYAN}source $SHELL_RC${NC}"
echo -e "  3. Launch:       ${CYAN}cs${NC}"
echo ""
echo "Protection layers (all auto-enabled):"
echo -e "  ${GREEN}Layer 1${NC}: Node.js os hook          - patches os.*/fs.*/child_process.*"
echo -e "  ${GREEN}Layer 2${NC}: Env + DNS + hosts + FW    - blocks 20+ telemetry, iptables whitelist"
echo -e "  ${GREEN}Layer 3${NC}: cc-gateway (install below) - rewrites API fingerprint + billing header"
echo -e "  ${GREEN}Layer 4${NC}: Proxy IP quality check    - verifies exit IP country + type"
echo ""
echo "Recommended next steps:"
echo -e "  ${CYAN}bash $INSTALL_DIR/cc-gateway-setup.sh${NC}  # Install cc-gateway (+3 protection)"
echo -e "  Use residential/ISP proxy instead of datacenter VPS"
echo ""
