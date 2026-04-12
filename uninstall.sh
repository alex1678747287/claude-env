#!/usr/bin/env bash
# uninstall.sh - Remove Claude Code Safe Environment
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }

INSTALL_DIR="$HOME/.claude-safe"

echo -e "${CYAN}Claude Code Safe Environment - Uninstaller${NC}"
echo ""

# 1. Remove iptables rules
if command -v iptables &>/dev/null && sudo iptables -L CLAUDE-OUT &>/dev/null 2>&1; then
    warn "Removing iptables rules..."
    sudo iptables -D OUTPUT -j CLAUDE-BLOCK 2>/dev/null || true
    sudo iptables -D OUTPUT -j CLAUDE-OUT 2>/dev/null || true
    sudo iptables -F CLAUDE-OUT 2>/dev/null || true
    sudo iptables -F CLAUDE-BLOCK 2>/dev/null || true
    sudo iptables -X CLAUDE-OUT 2>/dev/null || true
    sudo iptables -X CLAUDE-BLOCK 2>/dev/null || true
    if command -v ipset &>/dev/null; then
        sudo ipset destroy claude-allowed 2>/dev/null || true
    fi
    info "iptables rules removed"
fi

# 2. Remove /etc/hosts entries
if grep -q "claude-safe installer" /etc/hosts 2>/dev/null; then
    warn "Removing telemetry blocks from /etc/hosts..."
    sudo sed -i '/claude-safe installer/,/^$/d' /etc/hosts 2>/dev/null || true
    sudo sed -i '/Claude Code telemetry block/d' /etc/hosts 2>/dev/null || true
    info "/etc/hosts cleaned"
fi

# 3. Remove shell aliases
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rc" ] && grep -q "claude-safe" "$rc"; then
        sed -i '/Claude Code Safe Environment/d' "$rc"
        sed -i '/claude-safe/d' "$rc"
        sed -i '/alias cs=/d' "$rc"
        info "Aliases removed from $rc"
    fi
done

# 4. Remove install directory
if [ -d "$INSTALL_DIR" ]; then
    warn "Removing $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
    info "Install directory removed"
fi

# 5. Remove cc-gateway if installed
if [ -d "$HOME/.cc-gateway" ]; then
    warn "cc-gateway found at ~/.cc-gateway"
    echo -e "  Remove it manually: ${CYAN}rm -rf ~/.cc-gateway${NC}"
    echo -e "  Stop service: ${CYAN}systemctl --user stop cc-gateway${NC}"
fi

echo ""
info "Uninstall complete. Reload your shell: source ~/.bashrc"
