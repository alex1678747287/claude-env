# Claude Code Safe Environment

[English](README_EN.md) | [中文](README.md)

WSL2 environment isolation tool with three-layer protection for safely using Claude Code / Cowork.

## Why

The 2026 Claude Code source leak revealed its telemetry:

- **640+ telemetry events** via 3 parallel channels
- **40+ environment dimensions** collected (OS, hostname, CPU, memory, terminal, etc.)
- Logs sent to Datadog every **15 seconds**
- Metrics to BigQuery every **5 minutes**
- Persistent **device_id** identifier
- **x-anthropic-billing-header** with session fingerprint hash

This data can identify your real environment and lead to account bans.

## Architecture

```
Layer 1: Node.js/Bun os module hook (os-override.js)
  ├── Monkey-patch os.hostname/release/cpus/totalmem/userInfo
  ├── Zero out network interface MAC addresses
  ├── Clean Windows variables from process.env
  └── Supports both Node.js (NODE_OPTIONS) and Bun (BUN_CONFIG_PRELOAD)

Layer 2: Env vars + DNS + Hosts + Firewall (claude-safe.sh)
  ├── Block 20+ telemetry mechanisms (Datadog/Sentry/Statsig/OTEL/GrowthBook)
  ├── Remove 30+ WSL-leaked Windows environment variables
  ├── DNS leak prevention (avoid Windows host DNS)
  ├── /etc/hosts telemetry domain blocking
  └── Optional iptables outbound whitelist

Layer 3: cc-gateway API reverse proxy (optional)
  ├── Rewrite 40+ environment dimensions and device_id
  ├── Strip x-anthropic-billing-header session fingerprint
  ├── Normalize process metrics (memory/heap size)
  └── Sanitize <env> block in system prompt
```

## Quick Start

```bash
# 1. Clone
git clone https://github.com/alex1678747287/claude-env.git
cd claude-env

# 2. Install (auto-installs deps, configures hosts, generates config)
bash install.sh

# 3. Edit proxy config (set your proxy address and port)
vim ~/.claude-safe/config.env

# 4. Launch
cs
```

Or use the one-command launcher: `bash cs-quick.sh`

## Configuration

Config file at `~/.claude-safe/config.env`:

```bash
# Proxy (your local Clash/V2Ray)
CLAUDE_PROXY_HOST=172.x.x.x    # Windows host IP (auto-detected)
CLAUDE_PROXY_PORT=7890
CLAUDE_PROXY_PROTOCOL=http

# Identity disguise (match your proxy exit region)
CLAUDE_TZ=America/Los_Angeles
CLAUDE_LANG=en_US.UTF-8
CLAUDE_HOSTNAME=dev-workstation
CLAUDE_USER=developer

# DNS leak prevention
CLAUDE_DNS=1.1.1.1

# Optional: iptables outbound whitelist (requires sudo)
CLAUDE_ENABLE_FIREWALL=false

# Optional: cc-gateway API proxy (recommended)
CLAUDE_ENABLE_GATEWAY=auto
CC_GATEWAY_PORT=8443
```

## Protection Coverage

| Vector | Layer 1 (os hook) | Layer 2 (env/dns/fw) | Layer 3 (cc-gateway) |
|--------|-------------------|---------------------|---------------------|
| Hostname | os.hostname() | HOSTNAME var | metadata rewrite |
| Username | os.userInfo() | LOGNAME var | - |
| Kernel | os.release() | - | env replacement |
| CPU/Memory | os.cpus()/totalmem() | - | metric normalization |
| MAC Address | networkInterfaces() | - | - |
| Windows vars | process.env cleanup | unset 30+ vars | - |
| PATH leak | filter /mnt/c | filter /mnt/c | - |
| Datadog | - | hosts block | - |
| Sentry/Statsig | - | hosts + env block | - |
| OTEL | - | env disable | - |
| Device ID | - | - | canonical ID replace |
| Billing Header | - | env var | strip fingerprint |
| DNS leak | - | DNS config | - |
| Direct connect | - | iptables whitelist | - |

## Optional Upgrades

### cc-gateway (recommended)

API reverse proxy that rewrites all fingerprint data in requests:

```bash
bash ~/.claude-safe/cc-gateway-setup.sh
```

### iptables Firewall

Only allow outbound to proxy and essential domains:

```bash
CLAUDE_ENABLE_FIREWALL=true  # in config.env
```

### claude-private

Binary-patched build replacing 18 telemetry URLs. See [claude-private](https://github.com/ultrmgns/claude-private).

## Files

```
claude-safe.sh          # Main script: three-layer orchestration
os-override.js          # Layer 1: Node.js/Bun os module hook
iptables-whitelist.sh   # Layer 2: iptables outbound whitelist
cc-gateway-setup.sh     # Layer 3: cc-gateway installer
install.sh              # One-command installer
cs-quick.sh             # One-command launcher
config.env              # Config (generated after install, gitignored)
```

## Notes

- `/proc/version` and `/proc/cpuinfo` may still expose WSL signatures (Node hook can't intercept direct file reads)
- Use with a proxy to ensure exit IP is in an allowed region
- `config.env` contains proxy address and is excluded via `.gitignore`
- First use requires OAuth login; WSL2 opens Windows browser via `wslview`

## Credits

- [cc-gateway](https://github.com/motiful/cc-gateway) - API reverse proxy
- [claude-private](https://github.com/ultrmgns/claude-private) - Binary patching
- [claudebox](https://github.com/nicekid1/claudebox) - Docker containerization

## License

MIT
