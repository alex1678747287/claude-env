@echo off
chcp 65001 >nul 2>&1
title Claude Code 安全环境
REM setup.bat - 一键安装+启动 Claude Code 安全环境
REM 双击运行即可
powershell -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
if %errorlevel% neq 0 (
    echo.
    echo 如果 PowerShell 被阻止，请手动运行:
    echo   powershell -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
    echo.
    pause
)
