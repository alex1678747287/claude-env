@echo off
REM setup.bat - Launcher for setup.ps1
REM Automatically runs the PowerShell installer with admin privileges
powershell -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
if %errorlevel% neq 0 (
    echo.
    echo If PowerShell is blocked, run manually:
    echo   powershell -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
    echo.
    pause
)
