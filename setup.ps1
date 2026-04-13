# setup.ps1 - Claude Code Safe Environment Windows Setup
# Usage: Right-click -> Run with PowerShell (as Administrator)
# Or: powershell -ExecutionPolicy Bypass -File setup.ps1

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host "  Claude Code Safe Environment - Windows Setup" -ForegroundColor Cyan
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# 1. Check admin privileges
# ============================================================
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[!!] Need Administrator. Re-launching..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}
Write-Host "[OK] Administrator confirmed" -ForegroundColor Green

# ============================================================
# 2. Check WSL
# ============================================================
Write-Host "[..] Checking WSL..." -ForegroundColor White
$wslOk = $false
try {
    $null = wsl --status 2>&1
    if ($LASTEXITCODE -eq 0) { $wslOk = $true }
} catch {}

if (-not $wslOk) {
    Write-Host "[!!] WSL not installed. Installing WSL2..." -ForegroundColor Yellow
    Write-Host "     This may take a few minutes..." -ForegroundColor Gray
    wsl --install --no-distribution
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] WSL install failed. Try: wsl --install" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Host "[OK] WSL2 installed. Reboot required." -ForegroundColor Green
    $reboot = Read-Host "Reboot now? (Y/N)"
    if ($reboot -eq "Y" -or $reboot -eq "y") {
        shutdown /r /t 5 /c "Rebooting for WSL2"
    }
    Write-Host "Run this script again after reboot." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 0
}
Write-Host "[OK] WSL2 is installed" -ForegroundColor Green

# ============================================================
# 3. Check Ubuntu
# ============================================================
Write-Host "[..] Checking Ubuntu..." -ForegroundColor White
$ubuntuOk = $false
try {
    $result = wsl -d Ubuntu -- echo ok 2>&1
    if ($result -match "ok") { $ubuntuOk = $true }
} catch {}

if (-not $ubuntuOk) {
    Write-Host "[!!] Ubuntu not found. Installing (~500MB)..." -ForegroundColor Yellow
    wsl --install -d Ubuntu
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] Ubuntu install failed. Try: wsl --install -d Ubuntu" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Host "[OK] Ubuntu installed." -ForegroundColor Green
    Write-Host "[!!] Ubuntu will open for initial setup (create username/password)." -ForegroundColor Yellow
    Write-Host "     After setup, run this script again." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 0
}
Write-Host "[OK] Ubuntu is installed" -ForegroundColor Green

# ============================================================
# 4. Set WSL2 default
# ============================================================
wsl --set-default-version 2 2>&1 | Out-Null
Write-Host "[OK] WSL2 set as default" -ForegroundColor Green
Write-Host ""

# ============================================================
# 5. Copy files to WSL
# ============================================================
Write-Host "[..] Copying files to WSL..." -ForegroundColor White

$scriptDir = Split-Path -Parent $PSCommandPath
wsl -d Ubuntu -- bash -c "mkdir -p ~/claude-env"

$files = @(
    "claude-safe.sh", "os-override.js", "os-override.mjs",
    "iptables-whitelist.sh", "cc-gateway-setup.sh",
    "install.sh", "uninstall.sh", "cs-quick.sh"
)

# Convert Windows path to WSL /mnt/c/... path
$drive = $scriptDir.Substring(0,1).ToLower()
$rest = $scriptDir.Substring(2) -replace '\\','/'
$wslPath = "/mnt/$drive$rest"

foreach ($f in $files) {
    if (Test-Path "$scriptDir\$f") {
        wsl -d Ubuntu -- bash -c "cp '$wslPath/$f' ~/claude-env/$f 2>/dev/null" 2>&1 | Out-Null
    }
}

Write-Host "[OK] Files copied to WSL ~/claude-env/" -ForegroundColor Green
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Starting interactive installer in WSL..." -ForegroundColor Cyan
Write-Host " Follow the prompts to configure proxy, region, etc." -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# 6. Run installer
# ============================================================
wsl -d Ubuntu -- bash -c "cd ~/claude-env && chmod +x *.sh && bash install.sh"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Setup complete!" -ForegroundColor Green
Write-Host "" -ForegroundColor Green
Write-Host " How to use:" -ForegroundColor White
Write-Host "   1. Open WSL: search 'Ubuntu' in Start menu" -ForegroundColor White
Write-Host "   2. Type: cs" -ForegroundColor Cyan
Write-Host "" -ForegroundColor White
Write-Host " Or from Windows: wsl -d Ubuntu -- bash -c 'cs'" -ForegroundColor Gray
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Read-Host "Press Enter to exit"
