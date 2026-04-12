@echo off
REM setup.bat - Windows bootstrap for Claude Code Safe Environment
REM Installs WSL2 + Ubuntu if needed, then runs install.sh inside WSL
REM Usage: Right-click -> Run as Administrator, or: setup.bat

chcp 65001 >nul 2>&1
setlocal EnableDelayedExpansion

echo.
echo   Claude Code Safe Environment - Windows Setup
echo   =============================================
echo.

REM ============================================================
REM 1. Check admin privileges
REM ============================================================
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [!] Administrator privileges required.
    echo     Right-click setup.bat and select "Run as administrator"
    echo.
    echo     Press any key to try auto-elevate...
    pause >nul
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo [+] Running as Administrator

REM ============================================================
REM 2. Check if WSL is installed
REM ============================================================
echo.
echo [*] Checking WSL status...

wsl --status >nul 2>&1
if %errorlevel% neq 0 (
    echo [!] WSL not installed. Installing WSL2...
    echo.
    wsl --install --no-distribution
    if %errorlevel% neq 0 (
        echo [x] WSL installation failed.
        echo     Try manually: wsl --install
        pause
        exit /b 1
    )
    echo.
    echo [+] WSL2 installed. A reboot may be required.
    echo     After reboot, run this script again.
    echo.
    choice /M "Reboot now?"
    if !errorlevel! equ 1 shutdown /r /t 5 /c "Rebooting for WSL2 installation"
    exit /b 0
) else (
    echo [+] WSL2 already installed
)

REM ============================================================
REM 3. Check if Ubuntu is installed
REM ============================================================
echo [*] Checking Ubuntu distribution...

set DISTRO_FOUND=0
for /f "tokens=*" %%i in ('wsl -l -q 2^>nul') do (
    echo %%i | findstr /i "ubuntu" >nul 2>&1
    if !errorlevel! equ 0 set DISTRO_FOUND=1
)

if !DISTRO_FOUND! equ 0 (
    echo [!] Ubuntu not found. Installing Ubuntu...
    echo.
    wsl --install -d Ubuntu
    if %errorlevel% neq 0 (
        echo [x] Ubuntu installation failed.
        echo     Try manually: wsl --install -d Ubuntu
        pause
        exit /b 1
    )
    echo.
    echo [+] Ubuntu installed.
    echo [!] Ubuntu will open for initial setup (create username/password).
    echo     After setup completes, run this script again.
    echo.
    pause
    exit /b 0
) else (
    echo [+] Ubuntu already installed
)

REM ============================================================
REM 4. Ensure WSL2 is the default version
REM ============================================================
wsl --set-default-version 2 >nul 2>&1
echo [+] WSL2 set as default

REM ============================================================
REM 5. Copy project files to WSL and run installer
REM ============================================================
echo.
echo [*] Setting up Claude Safe Environment in WSL...
echo.

REM Get the directory where this script is located
set "SCRIPT_DIR=%~dp0"

REM Copy files to WSL home directory
wsl -d Ubuntu -- bash -c "mkdir -p ~/claude-env"

for %%f in (
    claude-safe.sh
    os-override.js
    os-override.mjs
    iptables-whitelist.sh
    cc-gateway-setup.sh
    install.sh
    uninstall.sh
    cs-quick.sh
) do (
    if exist "%SCRIPT_DIR%%%f" (
        wsl -d Ubuntu -- bash -c "cp '$(wslpath '%SCRIPT_DIR%%%f')' ~/claude-env/%%f 2>/dev/null" >nul 2>&1
        if !errorlevel! neq 0 (
            REM Fallback: use /mnt/c path
            for %%d in ("%SCRIPT_DIR%.") do set "WIN_PATH=%%~fd"
            set "WSL_PATH=!WIN_PATH:\=/!"
            set "WSL_PATH=/mnt/!WSL_PATH::=!"
            wsl -d Ubuntu -- bash -c "cp '!WSL_PATH!/%%f' ~/claude-env/%%f" >nul 2>&1
        )
    )
)

echo [+] Files copied to WSL ~/claude-env/
echo.
echo [*] Launching interactive installer in WSL...
echo     Follow the prompts to configure proxy, region, etc.
echo.
echo ============================================================

REM Run the installer interactively
wsl -d Ubuntu -- bash -c "cd ~/claude-env && chmod +x *.sh && bash install.sh"

echo.
echo ============================================================
echo.
echo [+] Setup complete!
echo.
echo     To use Claude Code safely:
echo       1. Open WSL: wsl
echo       2. Run: cs
echo.
echo     Or directly from Windows:
echo       wsl -d Ubuntu -- bash -c "source ~/.claude-safe/config.env; source ~/.claude-safe/claude-safe.sh; claude-run"
echo.
pause
