#Requires -Version 5.1
<#
.SYNOPSIS
    Сведения о точках восстановления и (опционально) удаление старых.
.DESCRIPTION
    Точки восстановления системы — это средство аварийного отката, а не
    "мусор", поэтому их удаление в CleanupArchive ОТКЛЮЧЕНО по умолчанию
    (config.json: CleanRestorePoints = false) и никогда не удаляет все
    точки полностью — только сверх заданного числа последних (KeepLatest).
#>

function Get-RestorePointsUsage {
    <#
    .SYNOPSIS
        Возвращает количество и список текущих точек восстановления.
        Только чтение, ничего не удаляет.
    #>
    [CmdletBinding()]
    param()
    try {
        $points = @(Get-ComputerRestorePoint -ErrorAction Stop)
        [PSCustomObject]@{
            Count  = $points.Count
            Points = $points
        }
    } catch {
        [PSCustomObject]@{
            Count  = 0
            Points = @()
        }
    }
}

function Remove-OldRestorePoints {
    <#
    .SYNOPSIS
        Оставляет только $KeepLatest самых новых точек восстановления,
        остальные удаляет через официальный VSS/CIM API.
    .DESCRIPTION
        Удаление выполняется через Remove-CimInstance над
        Win32_ShadowCopy — это единственный поддерживаемый Windows способ.
        Папка System Volume Information никогда не открывается и не
        удаляется напрямую (она в списке защищённых путей Utils.psm1).
    .PARAMETER KeepLatest
        Сколько самых новых точек оставить нетронутыми.
    #>
    [CmdletBinding()]
    param(
        [int]$KeepLatest = 3
    )
    $result = New-CleanupResult -TaskName 'Старые точки восстановления'
    try {
        # ВАЖНО: фильтр Context='ClientAccessible' — это именно та отметка,
        # которую Windows ставит теневым копиям, созданным System Restore.
        # Без этого фильтра запрос вернул бы ВСЕ теневые копии тома, включая
        # созданные сторонним ПО резервного копирования (обычно Context
        # 'Backup'/'Persistent'/'AppRollback') — их удалять отсюда нельзя,
        # это не "мусор", а чужие данные восстановления.
        $shadowCopies = @(Get-CimInstance -ClassName Win32_ShadowCopy `
            -Filter "Context='ClientAccessible'" -ErrorAction Stop |
            Sort-Object -Property InstallDate -Descending)

        # Информационная сверка с официальным списком точек восстановления —
        # не блокирует работу, только пишется в лог при явном расхождении.
        try {
            $officialCount = @(Get-ComputerRestorePoint -ErrorAction Stop).Count
            if ($officialCount -ne $shadowCopies.Count) {
                Write-CleanupLog -Message "Для справки: Get-ComputerRestorePoint показывает $officialCount точек, а ClientAccessible-копий VSS — $($shadowCopies.Count) (небольшое расхождение возможно из-за момента снятия срезов)." -Level INFO -NoConsole
            }
        } catch { }

        if ($shadowCopies.Count -le $KeepLatest) {
            Write-CleanupLog -Message "Точек восстановления (ClientAccessible) $($shadowCopies.Count), удалять нечего (порог: $KeepLatest)." -Level INFO
            return $result
        }

        $toRemove = $shadowCopies | Select-Object -Skip $KeepLatest
        foreach ($copy in $toRemove) {
            $actionId = "restore-point.$($copy.ID)"
            if (-not (Use-CleanupPlanAction -ActionId $actionId `
                    -Description "Удаление точки восстановления от $($copy.InstallDate)")) {
                Add-CleanupResultIssue -TaskResult $result -Status SkippedNotPlanned `
                    -Message 'Точка восстановления отсутствовала в подтверждённом плане.' -Path "$($copy.ID)"
                continue
            }
            if ($global:WhatIfPreference) {
                $result.FoldersRemoved++
                Write-CleanupLog -Message "Будет удалена теневая копия (точка восстановления) от $($copy.InstallDate)." -Level INFO -NoConsole
                continue
            }
            try {
                Remove-CimInstance -InputObject $copy -ErrorAction Stop
                $result.FoldersRemoved++
                Write-CleanupLog -Message "Удалена теневая копия (точка восстановления) от $($copy.InstallDate)." -Level OK -NoConsole
            } catch {
                Add-CleanupResultIssue -TaskResult $result -Status Failed -Message $_.Exception.Message `
                    -Path "$($copy.ID)" -ExceptionType $($_.Exception.GetType().FullName)
                Write-CleanupLog -Message "Не удалось удалить теневую копию от $($copy.InstallDate): $($_.Exception.Message)" -Level ERROR -NoConsole -ErrorRecord $_
            }
        }
        Write-CleanupLog -Message "Точки восстановления: оставлено $KeepLatest новых, удалено (или будет удалено) $($result.FoldersRemoved)." -Level OK
    } catch {
        Add-CleanupResultIssue -TaskResult $result -Status Failed -Message $_.Exception.Message `
            -ExceptionType $($_.Exception.GetType().FullName)
        Write-CleanupLog -Message "Ошибка при удалении точек восстановления: $($_.Exception.Message)" -Level ERROR -ErrorRecord $_
    }
    return $result
}

Export-ModuleMember -Function Get-RestorePointsUsage, Remove-OldRestorePoints
