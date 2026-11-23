#Requires -Version 5.1
<#
.SYNOPSIS
    Запускает локальный веб-интерфейс настроек CleanupArchive.
.DESCRIPTION
    В отличие от Cleanup.ps1, эта точка входа НЕ запрашивает права
    администратора — редактирование config.json их не требует. Права
    администратора по-прежнему запрашиваются самим Cleanup.ps1 в момент,
    когда вы нажимаете "Запустить" или "Предпросмотр" на открывшейся
    странице (тот же путь, что и при запуске Start.bat напрямую).
.NOTES
    Запуск: Settings.bat  (или "powershell -ExecutionPolicy Bypass -File Settings.ps1")
#>

[CmdletBinding()]
param()

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$webUiModule = Join-Path $PSScriptRoot 'modules\WebUI.psm1'
if (-not (Test-Path -LiteralPath $webUiModule)) {
    Write-Host "Не найден modules\WebUI.psm1 рядом со скриптом." -ForegroundColor Red
    Read-Host 'Нажмите Enter для выхода'
    exit 1
}
Import-Module $webUiModule -Force -DisableNameChecking

Write-Host ''
Write-Host ' CleanupArchive — веб-интерфейс настроек' -ForegroundColor Cyan
Write-Host ' ---------------------------------------' -ForegroundColor DarkCyan

Start-CleanupWebUI -ProjectRoot $PSScriptRoot
