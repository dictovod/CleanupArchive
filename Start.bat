@echo off
chcp 65001 >nul
title CleanupArchive
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Cleanup.ps1"

exit /b %errorlevel%
