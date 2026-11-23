@echo off
chcp 65001 >nul
title CleanupArchive - Settings
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Settings.ps1"

exit /b %errorlevel%
