#!/usr/bin/env bash
# iptables-whitelist.sh - Outbound firewall for Claude Code
# Only allows traffic to essential domains + proxy, blocks all telemetry direct connections
# Must run as root: sudo bash iptables-whitelist.sh [proxy_ip] [proxy_port] [dns_server]
# Reference: claudebox init-firewall (https://github.com/RchGrav/claudebox)

set -euo pipefail

PROXY_IP="${1:-}"
PROXY_PORT="${2:-7890}"
DNS_SERVER="${3:-1.1.1.1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[FW]${NC} $*"; }
warn()  { echo -e "${YELLOW}[FW]${NC} $*"; }
error() { echo -e "${RED}[FW]${NC} $*"; }

if [ "$(id -u)" -ne 0 ]; then
    error "Must run as root: sudo $0 [proxy_ip] [proxy_port]"
    exit 1
fi

# Essential domains that Claude Code needs to function
ALLOWED_DOMAINS=(
    "api.anthropic.com"
    "console.anthropic.com"
    "claude.ai"
    "platform.claude.com"
)

# Telemetry domains to explicitly block
BLOCKED_DOMAINS=(
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

# ============================================================
# Use custom chains to avoid clobbering user rules
# ============================================================
info "Setting up CLAUDE-OUT chain..."
iptables -N CLAUDE-OUT 2>/dev/null || iptables -F CLAUDE-OUT
iptables -N CLAUDE-BLOCK 2>/dev/null || iptables -F CLAUDE-BLOCK

# Remove old jump rules if exist, then re-add at top
iptables -D OUTPUT -j CLAUDE-BLOCK 2>/dev/null || true
iptables -D OUTPUT -j CLAUDE-OUT 2>/dev/null || true
iptables -I OUTPUT 1 -j CLAUDE-BLOCK
iptables -I OUTPUT 2 -j CLAUDE-OUT

# ============================================================
# Allow loopback
# ============================================================
iptables -A CLAUDE-OUT -o lo -j ACCEPT

# ============================================================
# Allow established connections
# ============================================================
iptables -A CLAUDE-OUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# ============================================================
# Allow DNS (only to configured DNS server)
# ============================================================
iptables -A CLAUDE-OUT -p udp --dport 53 -d "$DNS_SERVER" -j ACCEPT
iptables -A CLAUDE-OUT -p tcp --dport 53 -d "$DNS_SERVER" -j ACCEPT
info "DNS allowed: $DNS_SERVER"

# ============================================================
# Allow proxy connection
# ============================================================
if [ -n "$PROXY_IP" ]; then
    iptables -A CLAUDE-OUT -d "$PROXY_IP" -p tcp --dport "$PROXY_PORT" -j ACCEPT
    info "Proxy allowed: $PROXY_IP:$PROXY_PORT"
fi

# ============================================================
# WSL2 gateway: ONLY allow proxy port, NOT full access
# This prevents telemetry from bypassing the proxy via NAT gateway
# ============================================================
WSL_GATEWAY=$(ip route show default 2>/dev/null | awk '{print $3}' || echo "")
if [ -n "$WSL_GATEWAY" ]; then
    # Allow proxy port on gateway (if proxy runs on Windows host)
    if [ -n "$PROXY_IP" ] && [ "$PROXY_IP" = "$WSL_GATEWAY" ]; then
        info "WSL2 gateway is proxy host, already allowed on port $PROXY_PORT"
    else
        iptables -A CLAUDE-OUT -d "$WSL_GATEWAY" -p tcp --dport "$PROXY_PORT" -j ACCEPT
        info "WSL2 gateway: only port $PROXY_PORT allowed (was: full access)"
    fi
    # Allow DNS on gateway if it's the DNS server
    if [ "$WSL_GATEWAY" = "$DNS_SERVER" ] || grep -q "$WSL_GATEWAY" /etc/resolv.conf 2>/dev/null; then
        iptables -A CLAUDE-OUT -d "$WSL_GATEWAY" -p udp --dport 53 -j ACCEPT
        iptables -A CLAUDE-OUT -d "$WSL_GATEWAY" -p tcp --dport 53 -j ACCEPT
    fi
fi

# ============================================================
# Explicitly block telemetry domains (in CLAUDE-BLOCK chain, checked first)
# ============================================================
for domain in "${BLOCKED_DOMAINS[@]}"; do
    ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)
    for ip in $ips; do
        iptables -A CLAUDE-BLOCK -d "$ip" -j DROP
    done
done
info "Telemetry domains explicitly blocked (${#BLOCKED_DOMAINS[@]} domains)"

# ============================================================
# Allow essential domains (use hash:ip for single IPs)
# ============================================================
if command -v ipset &>/dev/null; then
    ipset destroy claude-allowed 2>/dev/null || true
    ipset create claude-allowed hash:ip

    for domain in "${ALLOWED_DOMAINS[@]}"; do
        ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)
        for ip in $ips; do
            ipset add claude-allowed "$ip" 2>/dev/null || true
        done
    done
    iptables -A CLAUDE-OUT -m set --match-set claude-allowed dst -j ACCEPT
    info "Allowed domains via ipset (${#ALLOWED_DOMAINS[@]} domains)"
else
    for domain in "${ALLOWED_DOMAINS[@]}"; do
        ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)
        for ip in $ips; do
            iptables -A CLAUDE-OUT -d "$ip" -j ACCEPT
        done
    done
    info "Allowed domains via iptables (${#ALLOWED_DOMAINS[@]} domains)"
fi

# ============================================================
# Default: DROP everything else outbound, ACCEPT inbound (WSL2 NAT needs it)
# ============================================================
iptables -A CLAUDE-OUT -j DROP
iptables -P INPUT ACCEPT

info "Firewall active. Only allowed: proxy + essential Claude domains + DNS"
info "To disable: sudo iptables -F CLAUDE-OUT && sudo iptables -F CLAUDE-BLOCK && sudo iptables -D OUTPUT -j CLAUDE-BLOCK && sudo iptables -D OUTPUT -j CLAUDE-OUT"

# ============================================================
# Create refresh script for IP changes (CDN domains rotate IPs)
# ============================================================
REFRESH_SCRIPT="$(dirname "$0")/iptables-refresh.sh"
cat > "$REFRESH_SCRIPT" << 'REFRESH'
#!/usr/bin/env bash
# Refresh allowed domain IPs (run periodically via cron)
# CDN IPs change frequently, this keeps the whitelist current
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo bash "$SCRIPT_DIR/iptables-whitelist.sh" "$@"
REFRESH
chmod +x "$REFRESH_SCRIPT"
info "Refresh script created: $REFRESH_SCRIPT"
info "Tip: add to crontab for auto-refresh: */30 * * * * $REFRESH_SCRIPT $PROXY_IP $PROXY_PORT $DNS_SERVER"

# ============================================================
# Block ALL IPv6 outbound (prevents telemetry bypass via IPv6)
# ============================================================
if command -v ip6tables &>/dev/null; then
    ip6tables -N CLAUDE-OUT6 2>/dev/null || ip6tables -F CLAUDE-OUT6
    ip6tables -D OUTPUT -j CLAUDE-OUT6 2>/dev/null || true
    ip6tables -I OUTPUT 1 -j CLAUDE-OUT6
    ip6tables -A CLAUDE-OUT6 -o lo -j ACCEPT
    ip6tables -A CLAUDE-OUT6 -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A CLAUDE-OUT6 -j DROP
    info "IPv6 outbound blocked (prevents telemetry bypass)"
fi
