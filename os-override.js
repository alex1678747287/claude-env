/**
 * os-override.js - Node.js preload module for Claude Code environment isolation
 * Loaded via NODE_OPTIONS="--require /path/to/os-override.js"
 * Monkey-patches os module to return disguised system information
 */

'use strict';

const os = require('os');

// Read config from environment (set by claude-safe.sh)
const FAKE_HOSTNAME = process.env.CLAUDE_HOSTNAME || 'dev-workstation';
const FAKE_USER = process.env.CLAUDE_USER || 'developer';
const FAKE_SHELL = process.env.SHELL || '/bin/bash';
const FAKE_TOTALMEM = 17179869184; // 16GB - common dev machine
const FAKE_KERNEL = '6.8.0-45-generic'; // Standard Ubuntu kernel, no WSL/Microsoft tag
// Keep real home dir so Claude Code can find its config files (~/.claude/)
const REAL_HOME = os.homedir();

// ============================================================
// 1. Patch os.hostname() - remove real hostname
// ============================================================
const _origHostname = os.hostname;
os.hostname = function () {
  return FAKE_HOSTNAME;
};

// ============================================================
// 2. Patch os.userInfo() - mask real username and home dir
// ============================================================
const _origUserInfo = os.userInfo;
os.userInfo = function (options) {
  const real = _origUserInfo.call(os, options);
  return {
    uid: real.uid,
    gid: real.gid,
    username: FAKE_USER,
    homedir: real.homedir, // Keep real homedir so Claude Code finds ~/.claude/
    shell: FAKE_SHELL,
  };
};

// ============================================================
// 3. Patch os.release() - strip WSL/Microsoft kernel identifiers
// ============================================================
const _origRelease = os.release;
os.release = function () {
  const real = _origRelease.call(os);
  // WSL kernels contain "microsoft" or "WSL" in the version string
  if (/microsoft|wsl/i.test(real)) {
    return FAKE_KERNEL;
  }
  return real;
};

// ============================================================
// 4. Patch os.version() - strip WSL identifiers
// ============================================================
if (typeof os.version === 'function') {
  const _origVersion = os.version;
  os.version = function () {
    const real = _origVersion.call(os);
    if (/microsoft|wsl|windows/i.test(real)) {
      return '#58-Ubuntu SMP PREEMPT_DYNAMIC';
    }
    return real;
  };
}

// ============================================================
// 5. Patch os.totalmem() - normalize to standard value
// ============================================================
const _origTotalmem = os.totalmem;
os.totalmem = function () {
  return FAKE_TOTALMEM;
};

// ============================================================
// 6. Patch os.cpus() - return generic CPU info
// ============================================================
const _origCpus = os.cpus;
os.cpus = function () {
  const real = _origCpus.call(os);
  // Keep the count but anonymize the model
  return real.map(cpu => ({
    model: 'AMD Ryzen 7 5800X 8-Core Processor',
    speed: 3800,
    times: cpu.times,
  }));
};

// ============================================================
// 7. Patch os.networkInterfaces() - sanitize MAC addresses
//    Keep all interfaces but zero out MACs and normalize names
// ============================================================
const _origNetworkInterfaces = os.networkInterfaces;
os.networkInterfaces = function () {
  const real = _origNetworkInterfaces.call(os);
  const sanitized = {};
  for (const [name, addrs] of Object.entries(real)) {
    sanitized[name] = addrs.map(addr => ({
      ...addr,
      mac: '00:00:00:00:00:00', // Zero out MAC address
    }));
  }
  return sanitized;
};

// ============================================================
// 8. Patch os.homedir() - keep real path for config access
//    Claude Code needs ~/.claude/ to be accessible
// ============================================================
// NOT patched - real homedir is required for Claude Code to function

// ============================================================
// 9. Clean process.env of Windows-leaking variables
//    (Belt-and-suspenders with claude-safe.sh)
// ============================================================
const WINDOWS_ENV_KEYS = [
  'WSLENV', 'WSL_DISTRO_NAME', 'WSL_INTEROP',
  'WINDOWS_USERNAME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA',
  'PROGRAMFILES', 'WINDIR', 'SystemRoot', 'OS',
  'PROCESSOR_ARCHITECTURE', 'PROCESSOR_IDENTIFIER', 'NUMBER_OF_PROCESSORS',
  'CommonProgramFiles', 'ProgramData', 'ProgramW6432',
  'SystemDrive', 'TEMP', 'TMP',
  'WT_SESSION', 'WT_PROFILE_ID', // Windows Terminal
  'PULSE_SERVER', 'WAYLAND_DISPLAY', // WSL GUI
  'DISPLAY', // X11 forwarding (may reveal WSL)
];

for (const key of WINDOWS_ENV_KEYS) {
  if (key in process.env) {
    delete process.env[key];
  }
}

// Filter /mnt/c paths from PATH
if (process.env.PATH) {
  process.env.PATH = process.env.PATH
    .split(':')
    .filter(p => !p.includes('/mnt/c') && !p.includes('/mnt/d'))
    .join(':');
}

// Override hostname-related env vars
process.env.HOSTNAME = FAKE_HOSTNAME;
process.env.HOST = FAKE_HOSTNAME;
process.env.LOGNAME = FAKE_USER;
