#Requires -Version 5.1
<#
.SYNOPSIS
    Безопасная остановка и запуск служб Windows.
.DESCRIPTION
    Некоторые каталоги (например, SoftwareDistribution\Download) блокируются
    работающими службами, поэтому их нужно кратковременно останавливать
    перед очисткой и обязательно запускать заново после. Обе функции никогда
    не выбрасывают исключение наружу — при любой ошибке пишут предупреждение
    в лог и возвращают управление вызывающему коду.
#>

function Stop-ServiceSafely {
    <#
    .SYNOPSIS
        Останавливает службу, если она запущена.
    .OUTPUTS
        [bool] $true, если служба была запущена и её нужно будет запустить
        обратно. В предпросмотре действия только вносятся в план, без
        фактической остановки службы.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [AllowNull()]$TaskResult
    )
    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        if ($svc.Status -eq 'Running') {
            if (-not (Use-CleanupPlanAction -ActionId "service.stop.$Name" `
                    -Description "Временная остановка службы '$Name'")) {
                if ($TaskResult) {
                    Add-CleanupResultIssue -TaskResult $TaskResult -Status SkippedNotPlanned `
                        -Message "Остановка службы '$Name' отсутствовала в подтверждённом плане." -Path "service:$Name"
                }
                return $false
            }
            # При формировании плана фиксируем действие, но службу не трогаем.
            # Возвращаем true, чтобы вызывающий код также запланировал её запуск.
            if ($global:WhatIfPreference -or (Get-CleanupPlanMode) -eq 'Capture') {
                return $true
            }
            Stop-Service -Name $Name -Force -ErrorAction Stop
            Write-CleanupLog -Message "Служба '$Name' остановлена на время очистки." -Level INFO -NoConsole
            return $true
        }
        return $false
    } catch {
        if ($TaskResult) {
            Add-CleanupResultIssue -TaskResult $TaskResult -Status SkippedAccessDenied `
                -Message "Не удалось остановить службу '$Name'; связанные занятые файлы будут пропущены: $($_.Exception.Message)" `
                -Path "service:$Name" -ExceptionType $($_.Exception.GetType().FullName)
        }
        Write-CleanupLog -Message "Не удалось остановить службу '$Name': $($_.Exception.Message)" -Level WARN -NoConsole
        return $false
    }
}

function Start-ServiceSafely {
    <#
    .SYNOPSIS
        Запускает службу, если она не запущена.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [AllowNull()]$TaskResult
    )
    if (-not (Use-CleanupPlanAction -ActionId "service.start.$Name" `
            -Description "Повторный запуск службы '$Name'")) {
        if ($TaskResult) {
            Add-CleanupResultIssue -TaskResult $TaskResult -Status Failed `
                -Message "Повторный запуск службы '$Name' отсутствовал в подтверждённом плане." -Path "service:$Name"
        }
        return
    }
    if ($global:WhatIfPreference -or (Get-CleanupPlanMode) -eq 'Capture') { return }
    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        if ($svc.Status -ne 'Running') {
            Start-Service -Name $Name -ErrorAction Stop
            Write-CleanupLog -Message "Служба '$Name' запущена заново." -Level INFO -NoConsole
        }
    } catch {
        if ($TaskResult) {
            Add-CleanupResultIssue -TaskResult $TaskResult -Status Failed `
                -Message "Не удалось снова запустить ранее остановленную службу '$Name': $($_.Exception.Message)" `
                -Path "service:$Name" -ExceptionType $($_.Exception.GetType().FullName)
        }
        Write-CleanupLog -Message "Не удалось запустить службу '$Name' заново: $($_.Exception.Message)" -Level ERROR -NoConsole -ErrorRecord $_
    }
}

Export-ModuleMember -Function Stop-ServiceSafely, Start-ServiceSafely
