#Requires -Version 5.1
<#
.SYNOPSIS
    Очистка кэша Windows Update и кэша Microsoft Store.
#>

function Clear-WindowsUpdateCache {
    <#
    .SYNOPSIS
        Очищает C:\Windows\SoftwareDistribution\Download.
    .DESCRIPTION
        Перед очисткой кратковременно останавливает службы wuauserv, bits
        и cryptsvc (они удерживают файлы открытыми), после очистки — всегда
        запускает их обратно, даже если удаление завершилось с ошибкой
        (см. try/finally).
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Кэш Windows Update'
    $windowsDirectory = Get-CleanupKnownFolderPath -Name Windows
    if (-not $windowsDirectory) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message 'Не удалось получить доверенный каталог Windows из системного API.'
        return $result
    }
    $servicesToStop = @('wuauserv', 'bits', 'cryptsvc')
    $stopped = @()

    # В предпросмотре помощник только регистрирует остановку/запуск в плане;
    # реальные службы при этом не изменяются.
    foreach ($svc in $servicesToStop) {
        if (Stop-ServiceSafely -Name $svc -TaskResult $result) { $stopped += $svc }
    }

    try {
        $target = Join-Path $windowsDirectory 'SoftwareDistribution\Download'
        if (Test-Path -LiteralPath $target) {
            Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $isContainer = $_.PSIsContainer
                $itemResult = Remove-ItemSafely -Path $_.FullName -AllowedRoot $target -Recurse:$isContainer
                Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $isContainer
            }
        }
    } finally {
        foreach ($svc in $stopped) { Start-ServiceSafely -Name $svc -TaskResult $result }
    }

    Write-CleanupLog -Message "Кэш Windows Update: удалено файлов $($result.FilesRemoved), папок $($result.FoldersRemoved), освобождено $(Format-Bytes $result.BytesFreed)." -Level OK
    return $result
}

function Clear-MicrosoftStoreCache {
    <#
    .SYNOPSIS
        Сбрасывает кэш Microsoft Store через штатную утилиту wsreset.exe.
    .DESCRIPTION
        wsreset.exe — официальный инструмент Windows для сброса кэша
        Store; после завершения он в норме сам открывает приложение
        Store — это ожидаемое поведение, а не ошибка модуля.
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Кэш Microsoft Store'
    try {
        $windowsDirectory = Get-CleanupKnownFolderPath -Name Windows
        if (-not $windowsDirectory) {
            Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
                -Message 'Не удалось получить доверенный каталог Windows из системного API.'
            return $result
        }
        $wsreset = Join-Path $windowsDirectory 'System32\wsreset.exe'
        if (-not (Test-Path -LiteralPath $wsreset)) {
            $result.Skipped.Add('wsreset.exe не найден в этой редакции/сборке Windows.')
            Write-CleanupLog -Message 'wsreset.exe не найден, пропущено.' -Level WARN -NoConsole
            return $result
        }

        if (-not (Use-CleanupPlanAction -ActionId 'microsoft-store.reset' -Description 'Сброс кэша Microsoft Store через wsreset.exe')) {
            Add-CleanupResultIssue -TaskResult $result -Status SkippedNotPlanned `
                -Message 'Сброс Microsoft Store отсутствовал в подтверждённом плане.'
            return $result
        }

        if ($global:WhatIfPreference) {
            Write-CleanupLog -Message 'Будет выполнен сброс кэша Microsoft Store (wsreset.exe).' -Level INFO -NoConsole
            return $result
        }

        $proc = Start-Process -FilePath $wsreset -WindowStyle Hidden -PassThru -ErrorAction Stop
        if (-not $proc.WaitForExit(60000)) {
            throw 'wsreset.exe не завершился за 60 секунд.'
        }
        if ($proc.ExitCode -ne 0) { throw "wsreset.exe завершился с кодом $($proc.ExitCode)" }
        Write-CleanupLog -Message 'Кэш Microsoft Store сброшен через wsreset.exe.' -Level OK
    } catch {
        Add-CleanupResultIssue -TaskResult $result -Status Failed -Message $_.Exception.Message `
            -ExceptionType $($_.Exception.GetType().FullName)
        Write-CleanupLog -Message "Ошибка при сбросе кэша Microsoft Store: $($_.Exception.Message)" -Level ERROR -ErrorRecord $_
    }
    return $result
}

Export-ModuleMember -Function Clear-WindowsUpdateCache, Clear-MicrosoftStoreCache
