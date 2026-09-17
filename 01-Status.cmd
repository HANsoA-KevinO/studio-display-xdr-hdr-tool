@echo off
setlocal
title Studio Display XDR HDR Tool - Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0XdrHdrTool.ps1" -Mode Status
echo.
pause

