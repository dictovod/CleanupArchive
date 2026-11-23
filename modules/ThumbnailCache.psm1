#Requires -Version 5.1
<#
.SYNOPSIS
    Очистка кэша эскизов (миниатюр) и значков Проводника.
#>

function Clear-ThumbnailCache {
    <#
    .SYNOPSIS
        Удаляет файлы thumbcache_*.db и iconcache_*.db Проводника.
    .DESCRIPTION
        Windows автоматически пересоздаёт эти файлы при следующем
        просмотре папок. Работающий explorer.exe может удерживать часть
        баз открытыми — такие файлы безопасно пропускаются без остановки
        Проводника и без прерывания всей очистки.
    #>
    [CmdletBinding()]
    param()

    $result = New-CleanupResult -TaskName 'Кэш эскизов (миниатюр)'
    $localAppData = Get-CleanupKnownFolderPath -Name LocalApplicationData
    if (-not $localAppData) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message 'Не удалось получить доверенный каталог LocalAppData из системного API.'
        return $result
    }

    $explorerCache = Join-Path $localAppData 'Microsoft\Windows\Explorer'
    if (Test-Path -LiteralPath $explorerCache) {
        foreach ($pattern in @('thumbcache_*.db', 'iconcache_*.db')) {
            Get-ChildItem -LiteralPath $explorerCache -Filter $pattern -File -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $itemResult = Remove-ItemSafely -Path $_.FullName -AllowedRoot $explorerCache
                    Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $false
                }
        }
    }

    # На некоторых версиях Windows основной кэш значков хранится прямо в
    # LocalAppData, отдельно от баз в Microsoft\Windows\Explorer.
    $legacyIconCache = Join-Path $localAppData 'IconCache.db'
    if (Test-Path -LiteralPath $legacyIconCache) {
        $itemResult = Remove-ItemSafely -Path $legacyIconCache -AllowedRoot $localAppData
        Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $false
    }

    Write-CleanupLog -Message "Кэш эскизов: удалено файлов $($result.FilesRemoved), освобождено $(Format-Bytes $result.BytesFreed)." -Level OK
    return $result
}

Export-ModuleMember -Function Clear-ThumbnailCache
