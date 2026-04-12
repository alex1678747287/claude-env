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
// 5. Patch os.totalmem() / os.freemem() - normalize to standard values
// ============================================================
const _origTotalmem = os.totalmem;
os.totalmem = function () {
  return FAKE_TOTALMEM;
};

const _origFreemem = os.freemem;
os.freemem = function () {
  const real = _origFreemem.call(os);
  // Cap freemem to be consistent with fake totalmem (avoid freemem > totalmem)
  return Math.min(real, Math.floor(FAKE_TOTALMEM * 0.45));
};

// ============================================================
// 5b. Patch os.uptime() - add random offset to prevent time fingerprinting
// ============================================================
const _origUptime = os.uptime;
const UPTIME_OFFSET = Math.floor(Math.random() * 86400 * 7); // random 0-7 days
os.uptime = function () {
  return _origUptime.call(os) + UPTIME_OFFSET;
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
process.env.USER = FAKE_USER;

// ============================================================
// 10. Patch fs.readFileSync / fs.readFile - intercept /proc leaks
//     /proc/version, /proc/cpuinfo, /proc/self/cgroup, /proc/mounts
//     all contain WSL/Microsoft identifiers that bypass os.* hooks
// ============================================================
const fs = require('fs');

const PROC_OVERRIDES = {
  '/proc/version': `Linux version ${FAKE_KERNEL} (gcc (Ubuntu 13.2.0-23ubuntu4) 13.2.0, GNU ld (GNU Binutils for Ubuntu) 2.42) #58-Ubuntu SMP PREEMPT_DYNAMIC\n`,
  '/proc/sys/kernel/osrelease': `${FAKE_KERNEL}\n`,
};

// Lazy-generate /proc/cpuinfo from fake CPU info
function fakeCpuinfo() {
  const count = (os.cpus ? os.cpus() : [{}]).length || 8;
  let out = '';
  for (let i = 0; i < count; i++) {
    out += `processor\t: ${i}\nvendor_id\t: AuthenticAMD\ncpu family\t: 25\n`;
    out += `model name\t: AMD Ryzen 7 5800X 8-Core Processor\ncpu MHz\t\t: 3800.000\n`;
    out += `cache size\t: 32768 KB\nphysical id\t: 0\ncpu cores\t: ${count}\n\n`;
  }
  return out;
}

function shouldIntercept(filepath) {
  if (typeof filepath !== 'string') {
    try { filepath = filepath.toString(); } catch (_) { return null; }
  }
  if (PROC_OVERRIDES[filepath]) return PROC_OVERRIDES[filepath];
  if (filepath === '/proc/cpuinfo') return fakeCpuinfo();
  // Filter WSL signatures from /proc/self/cgroup and /proc/mounts
  if (filepath === '/proc/self/cgroup' || filepath === '/proc/mounts') return '__FILTER__';
  return null;
}

function filterProcContent(filepath, content) {
  const str = typeof content === 'string' ? content : content.toString('utf8');
  // Remove lines containing WSL/Microsoft/Windows/mnt/c identifiers
  return str.split('\n')
    .filter(l => !/microsoft|wsl|\/mnt\/[a-z]|windows|drvfs/i.test(l))
    .join('\n');
}

const _origReadFileSync = fs.readFileSync;
fs.readFileSync = function (filepath, options) {
  const override = shouldIntercept(filepath);
  if (override === '__FILTER__') {
    const real = _origReadFileSync.call(fs, filepath, options);
    return filterProcContent(filepath, real);
  }
  if (override) {
    // Respect encoding option
    if (options && (options === 'utf8' || options === 'utf-8' || options.encoding)) {
      return override;
    }
    return Buffer.from(override);
  }
  return _origReadFileSync.call(fs, filepath, options);
};

const _origReadFile = fs.readFile;
fs.readFile = function (filepath, options, callback) {
  if (typeof options === 'function') { callback = options; options = undefined; }
  const override = shouldIntercept(filepath);
  if (override === '__FILTER__') {
    return _origReadFile.call(fs, filepath, options, function (err, data) {
      if (err) return callback(err);
      callback(null, filterProcContent(filepath, data));
    });
  }
  if (override) {
    const result = (options && (options === 'utf8' || options === 'utf-8' || options.encoding))
      ? override : Buffer.from(override);
    return process.nextTick(() => callback(null, result));
  }
  return _origReadFile.call(fs, filepath, options, callback);
};

// Also patch fs.promises.readFile
if (fs.promises) {
  const _origReadFilePromise = fs.promises.readFile;
  fs.promises.readFile = async function (filepath, options) {
    const override = shouldIntercept(filepath);
    if (override === '__FILTER__') {
      const real = await _origReadFilePromise.call(fs.promises, filepath, options);
      return filterProcContent(filepath, real);
    }
    if (override) {
      if (options && (options === 'utf8' || options === 'utf-8' || options.encoding)) {
        return override;
      }
      return Buffer.from(override);
    }
    return _origReadFilePromise.call(fs.promises, filepath, options);
  };
}

// ============================================================
// 11. Patch child_process - intercept uname, hostname, cat /proc/*
//     These commands bypass os.* hooks entirely
// ============================================================
const cp = require('child_process');

const COMMAND_OVERRIDES = {
  'uname -a': `Linux ${FAKE_HOSTNAME} ${FAKE_KERNEL} #58-Ubuntu SMP PREEMPT_DYNAMIC x86_64 GNU/Linux`,
  'uname -r': FAKE_KERNEL,
  'uname -n': FAKE_HOSTNAME,
  'uname -s': 'Linux',
  'uname -m': 'x86_64',
  'uname -o': 'GNU/Linux',
  'uname -v': '#58-Ubuntu SMP PREEMPT_DYNAMIC',
  uname: `Linux ${FAKE_HOSTNAME} ${FAKE_KERNEL} #58-Ubuntu SMP PREEMPT_DYNAMIC x86_64 GNU/Linux`,
  hostname: FAKE_HOSTNAME,
  'hostname -f': FAKE_HOSTNAME,
  'cat /proc/version': PROC_OVERRIDES['/proc/version'].trim(),
  'cat /proc/sys/kernel/osrelease': FAKE_KERNEL,
  'hostnamectl': `   Static hostname: ${FAKE_HOSTNAME}\n         Icon name: computer-desktop\n           Chassis: desktop\n  Operating System: Ubuntu 24.04.1 LTS\n            Kernel: Linux ${FAKE_KERNEL}\n      Architecture: x86-64`,
};

function matchCommand(cmd) {
  const trimmed = cmd.trim();
  // Exact match
  if (COMMAND_OVERRIDES[trimmed]) return COMMAND_OVERRIDES[trimmed];
  // Match commands that read /proc files we intercept
  const catMatch = trimmed.match(/^cat\s+(\/proc\/\S+)/);
  if (catMatch) {
    const override = shouldIntercept(catMatch[1]);
    if (override && override !== '__FILTER__') return override.trim();
  }
  return null;
}

const _origExecSync = cp.execSync;
cp.execSync = function (command, options) {
  const faked = matchCommand(String(command));
  if (faked !== null) {
    const result = faked + '\n';
    if (options && options.encoding) return result;
    return Buffer.from(result);
  }
  return _origExecSync.call(cp, command, options);
};

const _origExec = cp.exec;
cp.exec = function (command, options, callback) {
  if (typeof options === 'function') { callback = options; options = undefined; }
  const faked = matchCommand(String(command));
  if (faked !== null) {
    const result = faked + '\n';
    if (callback) process.nextTick(() => callback(null, result, ''));
    // Return a minimal ChildProcess-like object
    const EventEmitter = require('events');
    const fake = new EventEmitter();
    fake.stdout = new EventEmitter(); fake.stderr = new EventEmitter();
    fake.stdin = { write() {}, end() {} };
    fake.pid = 0; fake.kill = () => {};
    process.nextTick(() => {
      fake.stdout.emit('data', result);
      fake.emit('close', 0);
    });
    return fake;
  }
  return _origExec.call(cp, command, options, callback);
};

const _origSpawnSync = cp.spawnSync;
cp.spawnSync = function (command, args, options) {
  const fullCmd = args ? `${command} ${args.join(' ')}` : String(command);
  const faked = matchCommand(fullCmd);
  if (faked !== null) {
    const buf = Buffer.from(faked + '\n');
    return { stdout: buf, stderr: Buffer.alloc(0), status: 0, signal: null, pid: 0, output: [null, buf, Buffer.alloc(0)] };
  }
  return _origSpawnSync.call(cp, command, args, options);
};
