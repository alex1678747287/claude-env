#!/usr/bin/env bash
# cs-quick.sh - One-command Claude Code safe launcher
# Just run: bash cs-quick.sh
# Or after install: cs

set -euo pipefail

INSTALL_DIR="$HOME/.claude-safe"

# Auto-install if not set up yet
if [ ! -f "$INSTALL_DIR/claude-safe.sh" ]; then
    echo "First run detected. Running installer..."
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$SCRIPT_DIR/install.sh" ]; then
        bash "$SCRIPT_DIR/install.sh"
    else
        echo "Error: install.sh not found in $SCRIPT_DIR"
        exit 1
    fi
fi

# Load config and environment
source "$INSTALL_DIR/config.env" 2>/dev/null || true
source "$INSTALL_DIR/claude-safe.sh"

# Launch Claude Code
claude-run "$@"
