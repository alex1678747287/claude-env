#!/usr/bin/env bash
# cc-gateway-setup.sh - Optional cc-gateway installation for maximum fingerprint protection
# Reference: https://github.com/motiful/cc-gateway
# cc-gateway rewrites 40+ environment dimensions, device ID, billing headers in API requests

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

GATEWAY_DIR="$HOME/.cc-gateway"
GATEWAY_PORT="${CC_GATEWAY_PORT:-8443}"

echo -e "${CYAN}"
echo "  CC Gateway Setup - API Identity Proxy"
echo "  Rewrites device fingerprint, telemetry, billing headers"
echo -e "${NC}"

# ============================================================
# 1. Check prerequisites
# ============================================================
if ! command -v node &>/dev/null; then
    error "Node.js required. Install it first."
    exit 1
fi

NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
if [ "$NODE_VERSION" -lt 22 ]; then
    warn "cc-gateway requires Node.js 22+. Current: $(node -v)"
    warn "Install newer version: nvm install 22 && nvm use 22"
    exit 1
fi

# ============================================================
# 2. Clone or update cc-gateway
# ============================================================
if [ -d "$GATEWAY_DIR" ]; then
    info "Updating existing cc-gateway..."
    cd "$GATEWAY_DIR" && git pull --quiet
else
    info "Cloning cc-gateway..."
    git clone https://github.com/motiful/cc-gateway.git "$GATEWAY_DIR"
    cd "$GATEWAY_DIR"
fi

# ============================================================
# 3. Install dependencies
# ============================================================
info "Installing dependencies..."
npm install --quiet 2>/dev/null

# ============================================================
# 4. Generate config if not exists
# ============================================================
CONFIG_FILE="$GATEWAY_DIR/config.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
    info "Running quick setup..."
    echo ""
    warn "cc-gateway needs your Claude OAuth credentials."
    warn "If you haven't logged in to Claude Code yet, do that first:"
    echo -e "  ${CYAN}claude --login${NC}"
    echo ""

    # Try auto-setup
    if [ -f "$GATEWAY_DIR/scripts/quick-setup.sh" ]; then
        # Pass proxy if configured
        if [ -n "${HTTPS_PROXY:-}" ]; then
            HTTPS_PROXY="$HTTPS_PROXY" bash "$GATEWAY_DIR/scripts/quick-setup.sh"
        else
            bash "$GATEWAY_DIR/scripts/quick-setup.sh"
        fi
    else
        warn "quick-setup.sh not found. Manual config needed."
        warn "See: https://github.com/motiful/cc-gateway#quick-start"
    fi
else
    info "Config already exists: $CONFIG_FILE"
fi

# ============================================================
# 5. Create systemd user service (optional)
# ============================================================
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
Environment=PORT=$GATEWAY_PORT

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    info "Systemd service created. Start with:"
    echo -e "  ${CYAN}systemctl --user start cc-gateway${NC}"
    echo -e "  ${CYAN}systemctl --user enable cc-gateway${NC}  # auto-start"
fi

# ============================================================
# 6. Create start/stop scripts
# ============================================================
cat > "$GATEWAY_DIR/start.sh" << 'STARTEOF'
#!/usr/bin/env bash
cd "$(dirname "$0")"
PORT="${CC_GATEWAY_PORT:-8443}"
echo "Starting cc-gateway on port $PORT..."
if [ -n "${HTTPS_PROXY:-}" ]; then
    echo "Using proxy: $HTTPS_PROXY"
fi
node src/index.js &
echo $! > .gateway.pid
echo "Gateway PID: $(cat .gateway.pid)"
echo "Set in claude-safe: ANTHROPIC_BASE_URL=http://localhost:$PORT"
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

# ============================================================
# Done
# ============================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  cc-gateway setup complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Usage:"
echo -e "  ${CYAN}$GATEWAY_DIR/start.sh${NC}    # Start gateway"
echo -e "  ${CYAN}$GATEWAY_DIR/stop.sh${NC}     # Stop gateway"
echo ""
echo "claude-safe.sh will auto-detect the gateway and route traffic through it."
echo "Gateway port: $GATEWAY_PORT"
echo ""
echo "What cc-gateway does:"
echo "  - Rewrites device_id, email, env object (40+ fields)"
echo "  - Strips x-anthropic-billing-header (session fingerprint)"
echo "  - Normalizes process metrics (RAM, heap)"
echo "  - Sanitizes system prompt <env> block"
echo "  - Manages OAuth token refresh centrally"
echo ""
