@echo off
setlocal
title Studio Display XDR HDR Tool - Apply
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0XdrHdrTool.ps1" -Mode Apply -Interactive
echo.
pause

