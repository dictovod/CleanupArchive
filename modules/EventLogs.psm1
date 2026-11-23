#Requires -Version 5.1
<#
.SYNOPSIS
    Полная очистка журналов событий Windows (Event Viewer).
#>

function Clear-OldEventLogs {
    <#
    .SYNOPSIS
        Полностью очищает выбранные журналы событий Windows через wevtutil.
    .DESCRIPTION
        Журнал "Security" по умолчанию ИСКЛЮЧЁН из очистки (параметр
        Exclude) — его очистка требует отдельного, осознанного решения
        администратора и обычно контролируется политиками аудита
        организации, а не бытовой утилитой очистки диска. Команда wevtutil
        удаляет все события выбранного журнала, а не только старые записи.
        Поэтому задача является явно включаемой опцией и все её действия
        протоколируются.
    .PARAMETER Exclude
        Список имён журналов, которые нужно оставить нетронутыми.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Exclude = @('Security')
    )
    $result = New-CleanupResult -TaskName 'Полная очистка журналов событий'
    $windowsDirectory = Get-CleanupKnownFolderPath -Name Windows
    $wevtutilPath = if ($windowsDirectory) { Join-Path $windowsDirectory 'System32\wevtutil.exe' } else { $null }
    if (-not $wevtutilPath -or -not (Test-Path -LiteralPath $wevtutilPath)) {
        Add-CleanupResultIssue -TaskResult $result -Status Failed `
            -Message 'Не найден доверенный системный файл wevtutil.exe.' -Path $wevtutilPath
        return $result
    }

    try {
        $logs = & $wevtutilPath el 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "wevtutil el завершился с кодом $LASTEXITCODE"
        }
    } catch {
        $message = "Не удалось получить список журналов событий: $($_.Exception.Message)"
        Add-CleanupResultIssue -TaskResult $result -Status Failed -Message $message `
            -ExceptionType $($_.Exception.GetType().FullName)
        Write-CleanupLog -Message $message -Level ERROR
        return $result
    }

    foreach ($logName in $logs) {
        $logName = "$logName".Trim()
        if ([string]::IsNullOrWhiteSpace($logName)) { continue }
        if ($Exclude -contains $logName) {
            $result.Skipped.Add($logName)
            continue
        }

        try {
            $sizeBefore = 0L
            $infoRaw = @()
            try {
                $infoRaw = & $wevtutilPath gli "$logName" 2>&1
                $sizeLine = $infoRaw | Where-Object { $_ -match '^fileSize:\s*(\d+)' } | Select-Object -First 1
                if ($sizeLine -and $sizeLine -match '^fileSize:\s*(\d+)') { $sizeBefore = [long]$Matches[1] }
            } catch { }

            # План фиксирует идентичность канала, а не изменчивое содержимое.
            # Активные журналы закономерно получают новые записи между
            # предпросмотром и подтверждением пользователя.
            if (-not (Use-CleanupPlanAction -ActionId ("event-log." + $logName) `
                    -Description ("Очистка журнала событий '" + $logName + "'"))) {
                Add-CleanupResultIssue -TaskResult $result -Status SkippedNotPlanned `
                    -Message 'Журнал отсутствовал в подтверждённом плане очистки.' -Path $logName
                continue
            }

            if ($global:WhatIfPreference) {
                $result.FilesRemoved++
                $result.BytesFreed += $sizeBefore
                Write-CleanupLog -Message "Журнал '$logName' будет очищен ($(Format-Bytes $sizeBefore))." -Level INFO -NoConsole
                continue
            }

            $clearOutput = @(& $wevtutilPath cl "$logName" 2>&1)
            $clearExitCode = $LASTEXITCODE
            if ($clearExitCode -eq 0) {
                $result.FilesRemoved++
                $result.BytesFreed += $sizeBefore
                Write-CleanupLog -Message "Журнал '$logName' очищен ($(Format-Bytes $sizeBefore))." -Level OK -NoConsole
            } else {
                $clearDetails = ($clearOutput | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' '
                $message = "wevtutil не смог очистить журнал (код $clearExitCode)"
                if ($clearDetails) { $message += ": $clearDetails" } else { $message += '.' }
                $status = if ($clearExitCode -eq 5) { 'SkippedAccessDenied' } else { 'SkippedExternalFailure' }
                Add-CleanupResultIssue -TaskResult $result -Status $status -Message $message -Path $logName
            }
        } catch {
            $status = if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::PermissionDenied) {
                'SkippedAccessDenied'
            } else {
                'SkippedExternalFailure'
            }
            Add-CleanupResultIssue -TaskResult $result -Status $status `
                -Message $_.Exception.Message -Path $logName -ExceptionType $($_.Exception.GetType().FullName)
        }
    }

    Write-CleanupLog -Message "Журналы событий: очищено $($result.FilesRemoved), пропущено $($result.Skipped.Count) (включая исключённые: $($Exclude -join ', '))." -Level OK
    return $result
}

Export-ModuleMember -Function Clear-OldEventLogs
