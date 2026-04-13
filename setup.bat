@echo off
REM setup.bat - Claude Code Safe Environment Windows 引导安装
REM 自动安装 WSL2 + Ubuntu，然后在 WSL 中运行 install.sh
REM 使用方法：右键 -> 以管理员身份运行

chcp 936 >nul 2>&1
setlocal EnableDelayedExpansion

echo.
echo   ============================================
echo   Claude Code Safe Environment - Windows 安装
echo   ============================================
echo.

REM ============================================================
REM 1. 检查管理员权限
REM ============================================================
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [!] 需要管理员权限
    echo     请右键 setup.bat 选择"以管理员身份运行"
    echo.
    echo     按任意键尝试自动提权...
    pause >nul
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

echo [OK] 已获取管理员权限
echo.

REM ============================================================
REM 2. 检查 WSL 是否已安装
REM ============================================================
echo [*] 正在检查 WSL 状态...

wsl --status >nul 2>&1
if %errorlevel% neq 0 (
    echo [!] WSL 未安装，正在安装 WSL2...
    echo     这可能需要几分钟，请耐心等待...
    echo.
    wsl --install --no-distribution
    if !errorlevel! neq 0 (
        echo [X] WSL 安装失败
        echo     请手动运行: wsl --install
        echo.
        pause
        exit /b 1
    )
    echo.
    echo [OK] WSL2 安装完成，需要重启电脑
    echo.
    choice /C YN /M "是否立即重启？(Y=是 N=否)"
    if !errorlevel! equ 1 shutdown /r /t 5 /c "正在重启以完成 WSL2 安装"
    echo.
    echo     重启后请再次运行此脚本
    pause
    exit /b 0
) else (
    echo [OK] WSL2 已安装
)

REM ============================================================
REM 3. 检查 Ubuntu 是否已安装
REM ============================================================
echo [*] 正在检查 Ubuntu 发行版...

set DISTRO_FOUND=0
for /f "tokens=*" %%i in ('wsl -l -q 2^>nul') do (
    echo %%i | findstr /i "ubuntu" >nul 2>&1
    if !errorlevel! equ 0 set DISTRO_FOUND=1
)

if !DISTRO_FOUND! equ 0 (
    echo [!] 未找到 Ubuntu，正在安装...
    echo     首次安装需要下载约 500MB，请耐心等待...
    echo.
    wsl --install -d Ubuntu
    if !errorlevel! neq 0 (
        echo [X] Ubuntu 安装失败
        echo     请手动运行: wsl --install -d Ubuntu
        echo.
        pause
        exit /b 1
    )
    echo.
    echo [OK] Ubuntu 安装完成
    echo [!] Ubuntu 会打开一个窗口让你设置用户名和密码
    echo     设置完成后，请再次运行此脚本
    echo.
    pause
    exit /b 0
) else (
    echo [OK] Ubuntu 已安装
)

REM ============================================================
REM 4. 设置 WSL2 为默认版本
REM ============================================================
wsl --set-default-version 2 >nul 2>&1
echo [OK] WSL2 已设为默认版本
echo.

REM ============================================================
REM 5. 复制项目文件到 WSL 并运行安装脚本
REM ============================================================
echo [*] 正在将文件复制到 WSL 中...
echo.

REM 获取脚本所在目录
set "SCRIPT_DIR=%~dp0"

REM 在 WSL 中创建目录
wsl -d Ubuntu -- bash -c "mkdir -p ~/claude-env"

REM 复制所有需要的文件
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
            REM 备用方案：使用 /mnt/c 路径
            for %%d in ("%SCRIPT_DIR%.") do set "WIN_PATH=%%~fd"
            set "WSL_PATH=!WIN_PATH:\=/!"
            set "WSL_PATH=/mnt/!WSL_PATH::=!"
            wsl -d Ubuntu -- bash -c "cp '!WSL_PATH!/%%f' ~/claude-env/%%f" >nul 2>&1
        )
    )
)

echo [OK] 文件已复制到 WSL ~/claude-env/
echo.
echo ============================================================
echo  即将进入 WSL 交互式安装引导
echo  按照提示配置代理、地区、DNS、cc-gateway、防火墙
echo ============================================================
echo.

REM 运行安装脚本
wsl -d Ubuntu -- bash -c "cd ~/claude-env && chmod +x *.sh && bash install.sh"

echo.
echo ============================================================
echo.
echo [OK] 安装完成！
echo.
echo     使用方法：
echo       1. 打开 WSL：在开始菜单搜索 Ubuntu 或运行 wsl
echo       2. 输入：cs
echo.
echo     也可以从 Windows 直接启动：
echo       wsl -d Ubuntu -- bash -c "cs"
echo.
echo     重新配置：wsl -d Ubuntu -- bash -c "cd ~/claude-env && bash install.sh"
echo     卸载：    wsl -d Ubuntu -- bash -c "cd ~/claude-env && bash uninstall.sh"
echo.
pause
