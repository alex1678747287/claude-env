# setup.ps1 - Claude Code 安全环境 Windows 安装+启动一体化脚本
# 首次运行: 安装 WSL + Ubuntu + 安全环境
# 后续运行: 直接启动 Claude Code 安全环境
# Usage: powershell -ExecutionPolicy Bypass -File setup.ps1

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host "  Claude Code 安全环境" -ForegroundColor Cyan
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""

$scriptDir = Split-Path -Parent $PSCommandPath
$drive = $scriptDir.Substring(0,1).ToLower()
$rest = $scriptDir.Substring(2) -replace '\\','/'
$wslPath = "/mnt/$drive$rest"

# ============================================================
# 1. 检查 WSL + Ubuntu 是否就绪
# ============================================================
$needInstall = $false

$wslOk = $false
try {
    $null = wsl --status 2>&1
    if ($LASTEXITCODE -eq 0) { $wslOk = $true }
} catch {}

if (-not $wslOk) { $needInstall = $true }

$ubuntuOk = $false
if ($wslOk) {
    try {
        $result = wsl -d Ubuntu -- echo ok 2>&1
        if ($result -match "ok") { $ubuntuOk = $true }
    } catch {}
    if (-not $ubuntuOk) { $needInstall = $true }
}

# ============================================================
# 2. 需要安装时，请求管理员权限
# ============================================================
if ($needInstall) {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "[!!] 需要管理员权限安装 WSL，正在提权..." -ForegroundColor Yellow
        Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        exit
    }

    if (-not $wslOk) {
        Write-Host "[..] 正在安装 WSL2..." -ForegroundColor White
        wsl --install --no-distribution
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[x] WSL 安装失败，请手动运行: wsl --install" -ForegroundColor Red
            Read-Host "按回车退出"
            exit 1
        }
        Write-Host "[+] WSL2 已安装，需要重启。" -ForegroundColor Green
        $reboot = Read-Host "现在重启? (Y/N)"
        if ($reboot -eq "Y" -or $reboot -eq "y") {
            shutdown /r /t 5 /c "重启以完成 WSL2 安装"
        }
        Write-Host "重启后再次运行此脚本。" -ForegroundColor Yellow
        Read-Host "按回车退出"
        exit 0
    }

    if (-not $ubuntuOk) {
        Write-Host "[..] 正在安装 Ubuntu (~500MB)..." -ForegroundColor Yellow
        wsl --install -d Ubuntu
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[x] Ubuntu 安装失败，请手动运行: wsl --install -d Ubuntu" -ForegroundColor Red
            Read-Host "按回车退出"
            exit 1
        }
        Write-Host "[+] Ubuntu 已安装。" -ForegroundColor Green
        Write-Host "[!!] Ubuntu 将打开进行初始设置（创建用户名/密码）。" -ForegroundColor Yellow
        Write-Host "     设置完成后再次运行此脚本。" -ForegroundColor Yellow
        Read-Host "按回车退出"
        exit 0
    }
}

wsl --set-default-version 2 2>&1 | Out-Null
Write-Host "[+] WSL2 + Ubuntu 就绪" -ForegroundColor Green

# ============================================================
# 3. 同步文件到 WSL
# ============================================================
Write-Host "[..] 同步文件到 WSL..." -ForegroundColor White
wsl -d Ubuntu -- bash -c "mkdir -p ~/claude-env && cp $wslPath/*.sh $wslPath/*.js $wslPath/*.mjs ~/claude-env/ 2>/dev/null; chmod +x ~/claude-env/*.sh 2>/dev/null"
Write-Host "[+] 文件已同步" -ForegroundColor Green

# ============================================================
# 4. 检查是否已安装，未安装则自动安装
# ============================================================
$installed = wsl -d Ubuntu -- bash -c "test -f ~/.claude-safe/config.env && echo YES || echo NO" 2>&1
if ($installed -match "NO") {
    Write-Host ""
    Write-Host "[..] 首次运行，正在自动安装安全环境..." -ForegroundColor Cyan
    Write-Host ""
    wsl -d Ubuntu -- bash -c "cd ~/claude-env && bash install.sh --auto"
    Write-Host ""
    Write-Host "[+] 安装完成!" -ForegroundColor Green
}

# ============================================================
# 5. 启动 Claude Code 安全环境
# ============================================================
Write-Host ""
Write-Host "  正在启动 Claude Code 安全环境..." -ForegroundColor Cyan
Write-Host ""
wsl -d Ubuntu -- bash -ic "source ~/.claude-safe/config.env 2>/dev/null; source ~/.claude-safe/claude-safe.sh && claude-run"

Read-Host "按回车退出"
