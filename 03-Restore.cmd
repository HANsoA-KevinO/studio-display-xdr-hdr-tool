@echo off
setlocal
title Studio Display XDR HDR Tool - Restore
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0XdrHdrTool.ps1" -Mode Restore -Interactive
echo.
pause

