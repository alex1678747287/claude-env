#!/usr/bin/env bash
# iptables-whitelist.sh - Outbound firewall for Claude Code
# Only allows traffic to essential domains + proxy, blocks all telemetry direct connections
# Must run as root: sudo bash iptables-whitelist.sh [proxy_ip] [proxy_port]
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

# Telemetry domains to explicitly block (even if iptables default is DROP)
BLOCKED_DOMAINS=(
    "http-intake.logs.us5.datadoghq.com"
    "browser-intake-us5-datadoghq.com"
    "us5.datadoghq.com"
    "sentry.io"
    "o4507603404627968.ingest.us.sentry.io"
    "statsig.anthropic.com"
    "featuregates.org"
    "api.statsig.com"
)

# ============================================================
# Flush existing rules
# ============================================================
info "Flushing existing iptables rules..."
iptables -F OUTPUT 2>/dev/null || true
iptables -F INPUT 2>/dev/null || true

# ============================================================
# Allow loopback
# ============================================================
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# ============================================================
# Allow established connections
# ============================================================
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# ============================================================
# Allow DNS (needed for domain resolution)
# ============================================================
iptables -A OUTPUT -p udp --dport 53 -d "$DNS_SERVER" -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -d "$DNS_SERVER" -j ACCEPT
iptables -A INPUT -p udp --sport 53 -s "$DNS_SERVER" -j ACCEPT
info "DNS allowed: $DNS_SERVER"

# ============================================================
# Allow proxy connection
# ============================================================
if [ -n "$PROXY_IP" ]; then
    iptables -A OUTPUT -d "$PROXY_IP" -p tcp --dport "$PROXY_PORT" -j ACCEPT
    info "Proxy allowed: $PROXY_IP:$PROXY_PORT"
fi

# ============================================================
# Explicitly block telemetry domains
# ============================================================
for domain in "${BLOCKED_DOMAINS[@]}"; do
    ips=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' || true)
    for ip in $ips; do
        iptables -A OUTPUT -d "$ip" -j DROP
    done
done
info "Telemetry domains explicitly blocked (${#BLOCKED_DOMAINS[@]} domains)"

# ============================================================
# Allow essential domains
# ============================================================
if command -v ipset &>/dev/null; then
    ipset destroy claude-allowed 2>/dev/null || true
    ipset create claude-allowed hash:net

    for domain in "${ALLOWED_DOMAINS[@]}"; do
        ips=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' || true)
        for ip in $ips; do
            ipset add claude-allowed "$ip" 2>/dev/null || true
        done
    done
    iptables -A OUTPUT -m set --match-set claude-allowed dst -j ACCEPT
    info "Allowed domains via ipset (${#ALLOWED_DOMAINS[@]} domains)"
else
    for domain in "${ALLOWED_DOMAINS[@]}"; do
        ips=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' || true)
        for ip in $ips; do
            iptables -A OUTPUT -d "$ip" -j ACCEPT
        done
    done
    info "Allowed domains via iptables (${#ALLOWED_DOMAINS[@]} domains)"
fi

# ============================================================
# Allow WSL2 gateway (Windows host acts as NAT gateway)
# ============================================================
WSL_GATEWAY=$(ip route show default 2>/dev/null | awk '{print $3}' || echo "")
if [ -n "$WSL_GATEWAY" ]; then
    iptables -A OUTPUT -d "$WSL_GATEWAY" -j ACCEPT
    iptables -A INPUT -s "$WSL_GATEWAY" -j ACCEPT
    info "WSL2 gateway allowed: $WSL_GATEWAY"
fi

# ============================================================
# Default policy: DROP outbound, ACCEPT inbound (WSL2 needs inbound for NAT)
# ============================================================
iptables -P OUTPUT DROP
iptables -P INPUT ACCEPT

info "Firewall active. Only allowed: proxy + essential Claude domains + DNS"
info "To disable: sudo iptables -F && sudo iptables -P OUTPUT ACCEPT && sudo iptables -P INPUT ACCEPT"
