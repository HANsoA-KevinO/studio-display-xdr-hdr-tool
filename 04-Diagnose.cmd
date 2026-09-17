@echo off
setlocal
title Studio Display XDR HDR Tool - Diagnose
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0XdrHdrTool.ps1" -Mode Diagnose
echo.
pause

