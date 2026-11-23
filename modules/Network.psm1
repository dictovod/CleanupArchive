#Requires -Version 5.1
<#
.SYNOPSIS
    Сетевые операции обслуживания CleanupArchive.
.DESCRIPTION
    Сейчас единственная функция — сброс кэша DNS-клиента (опция FlushDNS
    в config.json). Вынесено в отдельный модуль по структуре проекта, чтобы
    в будущем сюда можно было добавить другие сетевые операции обслуживания
    без изменения остальных модулей.
#>

function Clear-DnsCache {
    <#
    .SYNOPSIS
        Сбрасывает кэш DNS-клиента.
    .DESCRIPTION
        Использует штатный командлет Clear-DnsClientCache, если он доступен
        (модуль DnsClient, Windows 8/Server 2012+). На системах без него
        выполняет резервный вариант через ipconfig /flushdns.
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Сброс кэша DNS'
    if (-not (Use-CleanupPlanAction -ActionId 'dns.flush' -Description 'Сброс кэша DNS-клиента')) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedNotPlanned `
            -Message 'Сброс DNS отсутствовал в подтверждённом плане.'
        return $result
    }
    if ($global:WhatIfPreference) {
        Write-CleanupLog -Message 'Будет выполнен сброс кэша DNS-клиента.' -Level INFO -NoConsole
        return $result
    }
    try {
        if (Get-Command -Name Clear-DnsClientCache -ErrorAction SilentlyContinue) {
            Clear-DnsClientCache -ErrorAction Stop
        } else {
            $windowsDirectory = Get-CleanupKnownFolderPath -Name Windows
            $ipconfigPath = if ($windowsDirectory) { Join-Path $windowsDirectory 'System32\ipconfig.exe' } else { $null }
            if (-not $ipconfigPath -or -not (Test-Path -LiteralPath $ipconfigPath)) {
                throw 'Не найден доверенный системный файл ipconfig.exe.'
            }
            $null = & $ipconfigPath /flushdns 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "ipconfig /flushdns завершился с кодом $LASTEXITCODE"
            }
        }
        Write-CleanupLog -Message 'Кэш DNS-клиента сброшен.' -Level OK
    } catch {
        Add-CleanupResultIssue -TaskResult $result -Status Failed -Message $_.Exception.Message `
            -ExceptionType $($_.Exception.GetType().FullName)
        Write-CleanupLog -Message "Ошибка при сбросе кэша DNS: $($_.Exception.Message)" -Level ERROR -ErrorRecord $_
    }
    return $result
}

Export-ModuleMember -Function Clear-DnsCache
