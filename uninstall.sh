#!/usr/bin/env bash
# uninstall.sh - Remove Claude Code Safe Environment
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }

INSTALL_DIR="$HOME/.claude-safe"

echo -e "${CYAN}Claude Code Safe Environment - Uninstaller${NC}"
echo ""

# 1. Remove iptables rules (IPv4 + IPv6)
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
    info "IPv4 iptables rules removed"
fi
if command -v ip6tables &>/dev/null && sudo ip6tables -L CLAUDE-OUT6 &>/dev/null 2>&1; then
    sudo ip6tables -D OUTPUT -j CLAUDE-OUT6 2>/dev/null || true
    sudo ip6tables -F CLAUDE-OUT6 2>/dev/null || true
    sudo ip6tables -X CLAUDE-OUT6 2>/dev/null || true
    info "IPv6 iptables rules removed"
fi

# 2. Remove /etc/hosts entries
if grep -q "claude-safe installer" /etc/hosts 2>/dev/null; then
    warn "Removing telemetry blocks from /etc/hosts..."
    sudo sed -i '/claude-safe installer/,/^$/d' /etc/hosts 2>/dev/null || true
    sudo sed -i '/Claude Code telemetry block/d' /etc/hosts 2>/dev/null || true
    info "/etc/hosts cleaned"
fi

# 3. Remove shell block (handles both old alias-only and new full SHELLBLOCK)
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rc" ] && grep -q "Claude Code Safe Environment" "$rc"; then
        # Delete from marker to the alias cs= line (inclusive)
        sed -i '/# Claude Code Safe Environment/,/^alias cs=/d' "$rc"
        # Also clean any leftover old-style aliases
        sed -i '/claude-safe/d' "$rc"
        # Remove consecutive blank lines
        sed -i '/^$/N;/^\n$/d' "$rc"
        info "Shell block removed from $rc"
    fi
done

# 4. Remove install directory
if [ -d "$INSTALL_DIR" ]; then
    warn "Removing $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
    info "Install directory removed"
fi

# 5. Stop and optionally remove cc-gateway
if [ -d "$HOME/.cc-gateway" ]; then
    if [ -f "$HOME/.cc-gateway/.gateway.pid" ]; then
        kill "$(cat "$HOME/.cc-gateway/.gateway.pid")" 2>/dev/null && info "cc-gateway stopped" || true
        rm -f "$HOME/.cc-gateway/.gateway.pid"
    fi
    systemctl --user stop cc-gateway 2>/dev/null || true
    systemctl --user disable cc-gateway 2>/dev/null || true
    warn "cc-gateway directory kept at ~/.cc-gateway"
    echo -e "  Remove manually: ${CYAN}rm -rf ~/.cc-gateway${NC}"
fi

# 6. Remove homedir symlink if created
FAKE_USER="${CLAUDE_USER:-developer}"
if [ -L "/home/$FAKE_USER" ]; then
    sudo rm -f "/home/$FAKE_USER" 2>/dev/null || true
    info "Symlink /home/$FAKE_USER removed"
fi

echo ""
info "Uninstall complete. Reload your shell: source ~/.bashrc"
