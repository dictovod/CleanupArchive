#Requires -Version 5.1
<#
.SYNOPSIS
    Создаёт обезличенный пакет по последнему запуску CleanupArchive.
#>
[CmdletBinding()]
param([switch]$NoPause)

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$utilsModule = Join-Path $PSScriptRoot 'modules\Utils.psm1'
$supportModule = Join-Path $PSScriptRoot 'modules\Support.psm1'
Import-Module $utilsModule -Force -DisableNameChecking
Import-Module $supportModule -Force -DisableNameChecking

$logDir = Join-Path $PSScriptRoot 'logs'
$latestLog = Get-ChildItem -LiteralPath $logDir -Filter 'cleanup_*.log' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $latestLog) {
    Write-Host 'Журналов очистки пока нет. Сначала запустите CleanupArchive.' -ForegroundColor Yellow
    if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' }
    exit 1
}

$jsonPath = [System.IO.Path]::ChangeExtension($latestLog.FullName, '.jsonl')
if (-not (Test-Path -LiteralPath $jsonPath)) { $jsonPath = '' }

try {
    $bundle = New-CleanupSupportBundle -OutputDirectory (Join-Path $PSScriptRoot 'support') `
        -LogPath $latestLog.FullName -JsonLogPath $jsonPath `
        -ConfigPath (Join-Path $PSScriptRoot 'config.json') -ProjectRoot $PSScriptRoot
    Write-Host ''
    Write-Host 'Обезличенный диагностический пакет создан:' -ForegroundColor Green
    Write-Host $bundle -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Перед отправкой при желании откройте ZIP и проверьте его содержимое.' -ForegroundColor DarkGray
    $exitCode = 0
} catch {
    Write-Host "Не удалось создать пакет: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
if (-not $NoPause) { Read-Host 'Нажмите Enter для выхода' }
exit $exitCode
