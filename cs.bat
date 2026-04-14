@echo off
chcp 65001 >nul 2>&1
wsl -d Ubuntu -- bash -ic "source ~/.claude-safe/config.env 2>/dev/null; source ~/.claude-safe/claude-safe.sh && claude-run"
