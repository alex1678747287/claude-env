@echo off
chcp 65001 >nul 2>&1
title Claude Code Safe Environment
REM start.bat - 一键启动 Claude Code 安全环境
REM 首次运行自动安装，后续直接启动
REM 双击运行即可，无需管理员权限（安装 WSL 除外）

REM 检查 WSL Ubuntu 是否可用
wsl -d Ubuntu -- echo ok >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [!!] WSL Ubuntu 未安装，正在启动安装程序...
    echo     需要管理员权限
    echo.
    powershell -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
    if %errorlevel% neq 0 (
        echo.
        echo 安装失败，请手动运行: powershell -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
        pause
        exit /b 1
    )
)

REM 同步最新脚本到 WSL
set "DRIVE=%~d0"
set "DRIVE_LETTER=%DRIVE:~0,1%"
call :tolower DRIVE_LETTER
set "REST=%~dp0"
set "REST=%REST:~2%"
set "REST=%REST:\=/%"
set "WSL_PATH=/mnt/%DRIVE_LETTER%%REST%"

wsl -d Ubuntu -- bash -c "mkdir -p ~/claude-env && cp %WSL_PATH%*.sh %WSL_PATH%*.js %WSL_PATH%*.mjs ~/claude-env/ 2>/dev/null; chmod +x ~/claude-env/*.sh 2>/dev/null"

REM 检查是否已安装，未安装则自动安装
wsl -d Ubuntu -- bash -c "test -f ~/.claude-safe/config.env && echo INSTALLED || echo NOT_INSTALLED" > "%TEMP%\cs_check.txt" 2>&1
set /p CS_STATUS=<"%TEMP%\cs_check.txt"
del "%TEMP%\cs_check.txt" >nul 2>&1

if "%CS_STATUS%"=="NOT_INSTALLED" (
    echo.
    echo [..] 首次运行，正在自动安装...
    echo.
    wsl -d Ubuntu -- bash -c "cd ~/claude-env && bash install.sh --auto"
    echo.
)

REM 启动 Claude Code 安全环境
echo.
echo 正在启动 Claude Code 安全环境...
echo.
wsl -d Ubuntu -- bash -ic "source ~/.claude-safe/config.env 2>/dev/null; source ~/.claude-safe/claude-safe.sh && claude-run"
pause
goto :eof

:tolower
for %%i in (a b c d e f g h i j k l m n o p q r s t u v w x y z) do call set "%1=%%%1:%%i=%%i%%"
goto :eof
