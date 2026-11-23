#Requires -Version 5.1
<#
.SYNOPSIS
    Обслуживание хранилища компонентов Windows (DISM) и проверка
    целостности системных файлов (SFC).
#>

function Invoke-ComponentStoreCleanup {
    <#
    .SYNOPSIS
        Выполняет DISM /Online /Cleanup-Image /StartComponentCleanup.
    .PARAMETER RestoreHealth
        Дополнительно выполнить /RestoreHealth (config.json: RunRestoreHealth).
        Отключено по умолчанию, т.к. это долгая операция, скачивающая
        данные через Windows Update при обнаружении повреждений.
    #>
    [CmdletBinding()]
    param(
        [switch]$RestoreHealth
    )
    $result = New-CleanupResult -TaskName 'Хранилище компонентов (DISM)'
    $windowsDirectory = Get-CleanupKnownFolderPath -Name Windows
    $dismPath = if ($windowsDirectory) { Join-Path $windowsDirectory 'System32\dism.exe' } else { $null }
    if (-not $dismPath -or -not (Test-Path -LiteralPath $dismPath)) {
        Add-CleanupResultIssue -TaskResult $result -Status Failed `
            -Message 'Не найден доверенный системный файл DISM.exe.' -Path $dismPath
        return $result
    }
    $startCleanupPlanned = Use-CleanupPlanAction -ActionId 'dism.start-component-cleanup' `
        -Description 'DISM /StartComponentCleanup'
    $restoreHealthPlanned = $false
    if ($RestoreHealth) {
        $restoreHealthPlanned = Use-CleanupPlanAction -ActionId 'dism.restore-health' `
            -Description 'DISM /RestoreHealth'
    }

    if ($global:WhatIfPreference) {
        Write-CleanupLog -Message 'Будет выполнена DISM /StartComponentCleanup (объём заранее неизвестен, не включён в оценку предпросмотра).' -Level INFO -NoConsole
        if ($RestoreHealth) {
            Write-CleanupLog -Message 'Будет выполнена DISM /RestoreHealth (может скачивать данные через Windows Update).' -Level INFO -NoConsole
        }
        return $result
    }

    if (-not $startCleanupPlanned) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedNotPlanned `
            -Message 'DISM /StartComponentCleanup отсутствовал в подтверждённом плане.'
    } else {
        try {
            Write-CleanupLog -Message 'DISM /StartComponentCleanup — запуск (может занять несколько минут)...' -Level INFO -NoConsole
            $output = & $dismPath /Online /Cleanup-Image /StartComponentCleanup 2>&1
            $exitCode = $LASTEXITCODE
            $output | ForEach-Object { Write-CleanupLog -Message "DISM: $_" -Level INFO -NoConsole }
            if ($exitCode -ne 0) {
                $result.Errors.Add("DISM StartComponentCleanup завершился с кодом $exitCode")
                Write-CleanupLog -Message "DISM StartComponentCleanup завершился с кодом $exitCode." -Level ERROR
            } else {
                Write-CleanupLog -Message 'Очистка хранилища компонентов завершена успешно.' -Level OK
            }
        } catch {
            $result.Errors.Add($_.Exception.Message)
            Write-CleanupLog -Message "Ошибка DISM StartComponentCleanup: $($_.Exception.Message)" -Level ERROR -ErrorRecord $_
        }
    }

    if ($RestoreHealth) {
        if (-not $restoreHealthPlanned) {
            Add-CleanupResultIssue -TaskResult $result -Status SkippedNotPlanned `
                -Message 'DISM /RestoreHealth отсутствовал в подтверждённом плане.'
        } else {
            try {
                Write-CleanupLog -Message 'DISM /RestoreHealth — запуск (может занять продолжительное время)...' -Level INFO
                $output2 = & $dismPath /Online /Cleanup-Image /RestoreHealth 2>&1
                $exitCode2 = $LASTEXITCODE
                $output2 | ForEach-Object { Write-CleanupLog -Message "DISM: $_" -Level INFO -NoConsole }
                if ($exitCode2 -ne 0) {
                    $result.Errors.Add("DISM RestoreHealth завершился с кодом $exitCode2")
                    Write-CleanupLog -Message "DISM RestoreHealth завершился с кодом $exitCode2." -Level ERROR
                } else {
                    Write-CleanupLog -Message 'DISM RestoreHealth завершён успешно.' -Level OK
                }
            } catch {
                $result.Errors.Add($_.Exception.Message)
                Write-CleanupLog -Message "Ошибка DISM RestoreHealth: $($_.Exception.Message)" -Level ERROR -ErrorRecord $_
            }
        }
    }

    return $result
}

function Invoke-SystemFileCheck {
    <#
    .SYNOPSIS
        Выполняет sfc /scannow (config.json: RunSFC). Отключено по
        умолчанию — это долгая операция полной проверки системных файлов.
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Проверка системных файлов (SFC)'
    $windowsDirectory = Get-CleanupKnownFolderPath -Name Windows
    $sfcPath = if ($windowsDirectory) { Join-Path $windowsDirectory 'System32\sfc.exe' } else { $null }
    if (-not $sfcPath -or -not (Test-Path -LiteralPath $sfcPath)) {
        Add-CleanupResultIssue -TaskResult $result -Status Failed `
            -Message 'Не найден доверенный системный файл SFC.exe.' -Path $sfcPath
        return $result
    }
    $sfcPlanned = Use-CleanupPlanAction -ActionId 'sfc.scannow' -Description 'SFC /scannow'
    if ($global:WhatIfPreference) {
        Write-CleanupLog -Message 'Будет выполнена проверка SFC /scannow.' -Level INFO -NoConsole
        return $result
    }
    if (-not $sfcPlanned) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedNotPlanned `
            -Message 'SFC /scannow отсутствовал в подтверждённом плане.'
        return $result
    }
    try {
        Write-CleanupLog -Message 'SFC /scannow — запуск (может занять продолжительное время)...' -Level INFO
        $output = & $sfcPath /scannow 2>&1
        $exitCode = $LASTEXITCODE
        $output | ForEach-Object { Write-CleanupLog -Message "SFC: $_" -Level INFO -NoConsole }
        if ($exitCode -ne 0) {
            $result.Errors.Add("SFC /scannow завершился с кодом $exitCode")
            Write-CleanupLog -Message "SFC /scannow завершился с кодом $exitCode." -Level ERROR
        } else {
            Write-CleanupLog -Message 'Проверка целостности системных файлов завершена.' -Level OK
        }
    } catch {
        $result.Errors.Add($_.Exception.Message)
        Write-CleanupLog -Message "Ошибка SFC /scannow: $($_.Exception.Message)" -Level ERROR -ErrorRecord $_
    }
    return $result
}

Export-ModuleMember -Function Invoke-ComponentStoreCleanup, Invoke-SystemFileCheck
