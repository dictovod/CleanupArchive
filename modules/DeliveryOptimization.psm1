#Requires -Version 5.1
<#
.SYNOPSIS
    Очистка кэша Delivery Optimization (P2P-доставка обновлений).
#>

function Clear-DeliveryOptimizationCache {
    <#
    .SYNOPSIS
        Очищает кэш Delivery Optimization.
    .DESCRIPTION
        В первую очередь используется штатный командлет
        Delete-DeliveryOptimizationCache (модуль DeliveryOptimization,
        встроен в Windows 10/11) — он не зависит от точного расположения
        кэша на конкретной сборке. Дополнительно, на случай его отсутствия
        или частичного отказа, проверяются все известные варианты пути,
        которые встречаются в разных версиях Windows.
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Кэш Delivery Optimization'
    $windowsDirectory = Get-CleanupKnownFolderPath -Name Windows
    $programData = Get-CleanupKnownFolderPath -Name CommonApplicationData
    if (-not $windowsDirectory -or -not $programData) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message 'Не удалось получить доверенные системные пути из API Windows.'
        return $result
    }

    try {
        if (Get-Command -Name Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
            if (-not (Use-CleanupPlanAction -ActionId 'delivery-optimization.native' `
                    -Description 'Штатная очистка кэша Delivery Optimization')) {
                Add-CleanupResultIssue -TaskResult $result -Status SkippedNotPlanned `
                    -Message 'Штатная очистка отсутствовала в подтверждённом плане.'
            } elseif ($global:WhatIfPreference) {
                Write-CleanupLog -Message 'Будет выполнена очистка кэша Delivery Optimization штатным командлетом.' -Level INFO -NoConsole
            } else {
                Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null
                Write-CleanupLog -Message 'Кэш Delivery Optimization очищен через штатный командлет.' -Level OK
            }
        }
    } catch {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedExternalFailure `
            -Message "Штатный командлет не выполнился; применяются безопасные резервные пути: $($_.Exception.Message)" `
            -Path 'Delete-DeliveryOptimizationCache' -ExceptionType $($_.Exception.GetType().FullName)
        Write-CleanupLog -Message "Delete-DeliveryOptimizationCache завершился с ошибкой: $($_.Exception.Message)" -Level WARN -NoConsole -ErrorRecord $_
    }

    # Резервные пути — расположение кэша менялось между сборками Windows.
    $fallbackPaths = @(
        (Join-Path $windowsDirectory 'SoftwareDistribution\DeliveryOptimization\Cache')
        (Join-Path $programData 'Microsoft\Windows\DeliveryOptimization\Cache')
        (Join-Path $windowsDirectory 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache')
    )
    foreach ($target in $fallbackPaths) {
        if (-not (Test-Path -LiteralPath $target)) { continue }
        Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $isContainer = $_.PSIsContainer
            $itemResult = Remove-ItemSafely -Path $_.FullName -AllowedRoot $target -Recurse:$isContainer
            Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $isContainer
        }
    }

    Write-CleanupLog -Message "Delivery Optimization: освобождено $(Format-Bytes $result.BytesFreed)." -Level OK
    return $result
}

Export-ModuleMember -Function Clear-DeliveryOptimizationCache
