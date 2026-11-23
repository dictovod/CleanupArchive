@echo off
chcp 65001 >nul
title CleanupArchive - Support Bundle
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SupportBundle.ps1"

exit /b %errorlevel%
