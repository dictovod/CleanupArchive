#Requires -Version 5.1
<#
.SYNOPSIS
    CleanupArchive — утилита обслуживания и очистки Windows 10/11.
.DESCRIPTION
    Открытая, бесплатная и полностью прозрачная утилита очистки диска и
    обслуживания системы — без рекламы, телеметрии и подписок. Уровень
    функциональности сопоставим с BleachBit, CCleaner (без рекламных
    функций), Wise Disk Cleaner и Microsoft PC Manager.

    Что делает при запуске:
      1. Запрашивает права администратора (UAC), если их ещё нет.
      2. Определяет ОС, сборку, архитектуру и параметры системного диска.
      3. Показывает состояние диска ДО очистки (свободно/занято/всего).
      4. Выполняет ПРЕДПРОСМОТР: прогоняет все задачи в безопасном режиме
         (ничего не удаляя) и показывает, что будет удалено.
      5. Спрашивает подтверждение (если не указан -Force и не указан -WhatIf).
      6. Выполняет реальную очистку, показывая индикатор прогресса.
      7. Показывает состояние диска ПОСЛЕ очистки и итоговую сводку.
      8. Пишет подробный журнал (.log и .jsonl) в logs\ и, если включено,
         HTML-отчёт в reports\.

    Ничего не отправляется в сеть. Ничего не удаляется без прохождения
    через Test-ProtectedPath (см. modules\Utils.psm1), и ничего не
    удаляется вообще, пока пользователь не подтвердит предпросмотр
    (или не передан -Force).
.PARAMETER Force
    Автоматический запуск без вопросов и паузы. Безопасный план всё равно
    формируется в памяти, но не выводится в консоль.
.PARAMETER NonInteractive
    Не показывать UAC и не ожидать пользовательского ввода. Если сценарий
    запущен без прав администратора, завершиться с кодом 5.
.PARAMETER NoPause
    Не ждать Enter перед завершением.
.PARAMETER CreateSupportBundle
    После очистки создать обезличенный диагностический ZIP-пакет.
.PARAMETER WhatIf
    Стандартный параметр PowerShell: выполнить только предпросмотр,
    показать, что было бы удалено, и завершить работу, ничего не удаляя
    и не запрашивая подтверждение.
.NOTES
    Проект : CleanupArchive
    Лицензия: MIT
    Запуск  : Start.bat  (или "powershell -ExecutionPolicy Bypass -File Cleanup.ps1")
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,
    [switch]$NonInteractive,
    [switch]$NoPause,
    [switch]$CreateSupportBundle
)

$ErrorActionPreference = 'Continue'

# Что именно попросил пользователь ПРИ ЗАПУСКЕ скрипта — нужно сохранить
# до того, как ниже мы сами начнём временно переключать $global:WhatIfPreference
# для внутреннего механизма предпросмотра (иначе потеряем исходное намерение).
$UserRequestedPreviewOnly = [bool]$WhatIfPreference
if ($Force) {
    $NonInteractive = $true
    $NoPause = $true
}
if ($NonInteractive -and -not $Force -and -not $UserRequestedPreviewOnly) {
    Write-Host 'Для очистки без ввода укажите -Force. Без него автоматический запуск отменён.' -ForegroundColor Red
    exit 2
}

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# ---------------------------------------------------------------------------
# 1. Импорт всех модулей проекта. Делается в самом начале, ДО проверки прав
#    администратора — Import-Module лишь объявляет функции и сам по себе
#    ничего не изменяет в системе, поэтому прав администратора для этого
#    не требуется.
# ---------------------------------------------------------------------------
$modulesPath = Join-Path $PSScriptRoot 'modules'
if (-not (Test-Path -LiteralPath $modulesPath)) {
    Write-Host "Не найдена папка modules по пути: $modulesPath" -ForegroundColor Red
    if (-not $NoPause -and -not $NonInteractive) { Read-Host 'Нажмите Enter для выхода' }
    exit 1
}
$moduleFiles = @(Get-ChildItem -Path $modulesPath -Filter '*.psm1' -File -ErrorAction Stop |
    Sort-Object Name)
foreach ($moduleFile in $moduleFiles) {
    try {
        Import-Module $moduleFile.FullName -Force -DisableNameChecking -ErrorAction Stop
    } catch {
        Write-Host ''
        Write-Host "Не удалось загрузить обязательный модуль '$($moduleFile.Name)'." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host 'Очистка не запускалась. Переустановите целый архив CleanupArchive.' -ForegroundColor Yellow
        if (-not $NoPause -and -not $NonInteractive) { Read-Host 'Нажмите Enter для выхода' }
        exit 1
    }
}

# Повреждённый или неполный релиз должен останавливаться до запроса UAC и
# до любых операций очистки, даже если Import-Module не сообщил об ошибке.
$requiredCommands = @(
    'Test-IsAdministrator', 'Request-AdminElevation', 'Initialize-CleanupLog',
    'Initialize-CleanupPlan', 'Lock-CleanupPlan', 'Clear-UserTempFiles',
    'Clear-WindowsTempFiles', 'Clear-PrefetchFiles', 'Clear-WindowsUpdateCache',
    'Clear-MicrosoftStoreCache', 'Clear-DeliveryOptimizationCache',
    'Clear-DirectXShaderCache', 'Clear-ThumbnailCache', 'Clear-BrowserCache',
    'Clear-ErrorReportingFiles', 'Clear-CrashDumps', 'Clear-WindowsDefenderCache',
    'Clear-FontCache', 'Clear-InstallerTempFiles', 'Clear-OldWindowsLogFiles',
    'Clear-OneDriveTempFiles', 'Clear-OfficeTempFiles', 'Clear-DnsCache',
    'Clear-OldEventLogs', 'Clear-RecycleBinContents', 'Invoke-ComponentStoreCleanup',
    'Invoke-SystemFileCheck', 'Remove-OldRestorePoints', 'New-HtmlReport',
    'New-CleanupSupportBundle'
)
$missingCommands = @($requiredCommands | Where-Object {
    -not (Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue)
})
if ($missingCommands.Count -gt 0) {
    Write-Host ''
    Write-Host "Релиз неполон: отсутствуют обязательные команды: $($missingCommands -join ', ')." -ForegroundColor Red
    Write-Host 'Очистка не запускалась. Переустановите целый архив CleanupArchive.' -ForegroundColor Yellow
    if (-not $NoPause -and -not $NonInteractive) { Read-Host 'Нажмите Enter для выхода' }
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Проверка / запрос прав администратора.
# ---------------------------------------------------------------------------
if (-not (Test-IsAdministrator)) {
    if ($NonInteractive) {
        Write-Host 'Для автоматического режима запустите CleanupArchive с правами администратора.' -ForegroundColor Red
        exit 5
    }
    $relaunchArgs = [System.Collections.Generic.List[string]]::new()
    if ($Force) { $relaunchArgs.Add('-Force') }
    if ($NonInteractive) { $relaunchArgs.Add('-NonInteractive') }
    if ($NoPause) { $relaunchArgs.Add('-NoPause') }
    if ($CreateSupportBundle) { $relaunchArgs.Add('-CreateSupportBundle') }
    if ($UserRequestedPreviewOnly) { $relaunchArgs.Add('-WhatIf') }
    try {
        Request-AdminElevation -ScriptPath $PSCommandPath -ScriptArguments $relaunchArgs.ToArray() | Out-Null
        exit 0
    } catch {
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 3. Загрузка config.json (с безопасными значениями по умолчанию).
# ---------------------------------------------------------------------------
function Get-CleanupConfig {
    [CmdletBinding()]
    param([string]$Path)

    $default = [ordered]@{
        RunSFC             = $false
        RunRestoreHealth   = $false
        RunComponentCleanup = $true
        CleanPrefetch      = $false
        FlushDNS           = $true
        CreateHTMLReport   = $true
        VerboseLog         = $true
        CleanDefenderCache = $false
        CleanEventLogs     = $false
        CleanRestorePoints = $false
        KeepRestorePoints  = 3
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host " config.json не найден — используются значения по умолчанию." -ForegroundColor Yellow
        return [PSCustomObject]$default
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        foreach ($key in $default.Keys) {
            if (-not ($raw.PSObject.Properties.Name -contains $key)) {
                $raw | Add-Member -NotePropertyName $key -NotePropertyValue $default[$key] -Force
            }
        }
        return $raw
    } catch {
        Write-Host " Ошибка чтения config.json — используются значения по умолчанию: $($_.Exception.Message)" -ForegroundColor Yellow
        return [PSCustomObject]$default
    }
}

$configPath = Join-Path $PSScriptRoot 'config.json'
$config = Get-CleanupConfig -Path $configPath

# ---------------------------------------------------------------------------
# 4. Инициализация журнала и приветствие.
# ---------------------------------------------------------------------------
$logDir = Join-Path $PSScriptRoot 'logs'
$reportDir = Join-Path $PSScriptRoot 'reports'
try {
    $logPath = Initialize-CleanupLog -LogDirectory $logDir -VerboseLogging ([bool]$config.VerboseLog)
} catch {
    Write-Host "Не удалось создать журналы CleanupArchive: $($_.Exception.Message)" -ForegroundColor Red
    if (-not $NoPause -and -not $NonInteractive) { Read-Host 'Нажмите Enter для выхода' }
    exit 1
}

if ($NonInteractive) {
    Write-Host "CleanupArchive v$(Get-CleanupArchiveVersion) — автоматический режим"
} else {
    Clear-Host
    Show-Banner
}
Write-CleanupLog -Message "Запуск CleanupArchive $(Get-CleanupArchiveVersion). PowerShell $($PSVersionTable.PSVersion)." -Level INFO -NoConsole

$sysInfo = Get-SystemInfo
Write-InfoTable -Title 'Информация о системе' -Color Cyan -Data ([ordered]@{
    'CleanupArchive'       = "v$(Get-CleanupArchiveVersion)"
    'Операционная система' = $sysInfo.Name
    'Версия / сборка'      = "$($sysInfo.Version) (build $($sysInfo.Build))"
    'Архитектура'          = $sysInfo.Architecture
    'Имя компьютера'       = $sysInfo.ComputerName
})

$systemDrive = Get-CleanupSystemDrive
if (-not $systemDrive) {
    Write-CleanupLog -Message 'Не удалось определить системный диск через доверенный API Windows. Очистка остановлена.' -Level ERROR -Force
    Close-CleanupLog -Summary ([PSCustomObject]@{
        FilesRemoved = 0; FoldersRemoved = 0; FreedFormatted = '0,00 Б'; FreedBytes = 0
        ErrorCount = 1; SkippedCount = 0; Duration = '0 сек'
    })
    Write-Host 'Не удалось безопасно определить системный диск. Очистка не выполнялась.' -ForegroundColor Red
    exit 1
}
$beforeDisk = Get-DiskInfo -DriveLetter $systemDrive
Write-InfoTable -Title "Диск $($beforeDisk.Drive) — до очистки" -Color Yellow -Data ([ordered]@{
    'Тип диска'    = $beforeDisk.MediaType
    'Свободно'     = Format-Bytes $beforeDisk.FreeBytes
    'Используется' = Format-Bytes $beforeDisk.UsedBytes
    'Всего'        = Format-Bytes $beforeDisk.TotalBytes
})

# ---------------------------------------------------------------------------
# 5. Формирование списка задач согласно config.json.
# ---------------------------------------------------------------------------
$tasks = [System.Collections.Generic.List[object]]::new()

$tasks.Add(@{ Name = '%TEMP% пользователя'; Action = { Clear-UserTempFiles } })
$tasks.Add(@{ Name = 'Временные файлы Windows'; Action = { Clear-WindowsTempFiles } })
if ($config.CleanPrefetch) {
    $tasks.Add(@{ Name = 'Кэш Prefetch'; Action = { Clear-PrefetchFiles } })
}
$tasks.Add(@{ Name = 'Кэш Windows Update'; Action = { Clear-WindowsUpdateCache } })
$tasks.Add(@{ Name = 'Кэш Microsoft Store'; Action = { Clear-MicrosoftStoreCache } })
$tasks.Add(@{ Name = 'Кэш Delivery Optimization'; Action = { Clear-DeliveryOptimizationCache } })
$tasks.Add(@{ Name = 'Кэш шейдеров DirectX'; Action = { Clear-DirectXShaderCache } })
$tasks.Add(@{ Name = 'Кэш эскизов (миниатюр)'; Action = { Clear-ThumbnailCache } })
$tasks.Add(@{ Name = 'Кэш браузеров'; Action = { Clear-BrowserCache } })
$tasks.Add(@{ Name = 'Отчёты об ошибках (WER)'; Action = { Clear-ErrorReportingFiles } })
$tasks.Add(@{ Name = 'Дампы памяти и Minidump'; Action = { Clear-CrashDumps } })
if ($config.CleanDefenderCache) {
    $tasks.Add(@{ Name = 'Кэш Windows Defender'; Action = { Clear-WindowsDefenderCache } })
}
$tasks.Add(@{ Name = 'Кэш шрифтов'; Action = { Clear-FontCache } })
$tasks.Add(@{ Name = 'Временные файлы установщика'; Action = { Clear-InstallerTempFiles } })
$tasks.Add(@{ Name = 'Старые лог-файлы Windows'; Action = { Clear-OldWindowsLogFiles } })
$tasks.Add(@{ Name = 'Временные файлы OneDrive'; Action = { Clear-OneDriveTempFiles } })
$tasks.Add(@{ Name = 'Временные файлы Office'; Action = { Clear-OfficeTempFiles } })
if ($config.FlushDNS) {
    $tasks.Add(@{ Name = 'Сброс кэша DNS'; Action = { Clear-DnsCache } })
}
if ($config.CleanEventLogs) {
    $tasks.Add(@{ Name = 'Полная очистка журналов событий'; Action = { Clear-OldEventLogs } })
}
$tasks.Add(@{ Name = 'Корзина'; Action = { Clear-RecycleBinContents } })
if ($config.RunComponentCleanup) {
    $tasks.Add(@{ Name = 'Хранилище компонентов (DISM)'; Action = { Invoke-ComponentStoreCleanup -RestoreHealth:([bool]$config.RunRestoreHealth) } })
}
if ($config.RunSFC) {
    $tasks.Add(@{ Name = 'Проверка системных файлов (SFC)'; Action = { Invoke-SystemFileCheck } })
}
if ($config.CleanRestorePoints) {
    $tasks.Add(@{ Name = 'Старые точки восстановления'; Action = { Remove-OldRestorePoints -KeepLatest ([int]$config.KeepRestorePoints) } })
}

# ---------------------------------------------------------------------------
# 6. Общая функция выполнения списка задач — используется и для
#    предпросмотра (Preview, ничего не удаляет), и для реальной очистки.
# ---------------------------------------------------------------------------
function Invoke-CleanupTasks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Tasks,
        [switch]$Preview,
        [switch]$Quiet,
        [switch]$PersistPreview
    )
    $previousWhatIf = $global:WhatIfPreference
    $global:WhatIfPreference = [bool]$Preview
    try {
        $results = [System.Collections.Generic.List[object]]::new()
        $total = $Tasks.Count
        $i = 0
        foreach ($task in $Tasks) {
            $i++
            $percent = [int](($i / $total) * 100)
            Set-CleanupLogContext -TaskName $task.Name
            Set-CleanupPlanTaskContext -TaskName $task.Name
            $taskStart = Get-Date
            $taskResult = $null
            try {
                $taskIsPlanned = Register-CleanupPlanTask -TaskName $task.Name
                if (-not $taskIsPlanned) {
                    $taskResult = New-CleanupResult -TaskName $task.Name
                    Add-CleanupResultIssue -TaskResult $taskResult -Status Failed `
                        -Message 'Задача отсутствует в зафиксированном плане очистки.'
                } else {
                    $taskResult = & $task.Action
                    if (-not $taskResult) { $taskResult = New-CleanupResult -TaskName $task.Name }
                }
            } catch {
                $taskResult = New-CleanupResult -TaskName $task.Name
                Add-CleanupResultIssue -TaskResult $taskResult -Status Failed `
                    -Message "Необработанная ошибка: $($_.Exception.Message)" `
                    -ExceptionType $($_.Exception.GetType().FullName)
                Write-CleanupLog -Message "Необработанная ошибка в задаче '$($task.Name)': $($_.Exception.Message)" -Level ERROR -NoConsole -ErrorRecord $_ -Force
            }
            if (-not $Preview) {
                $taskResult = Complete-CleanupPlanTask -TaskName $task.Name -TaskResult $taskResult
            }
            $taskMs = [int]((Get-Date) - $taskStart).TotalMilliseconds
            if (-not $Preview -or $PersistPreview) {
                Write-CleanupTaskResult -Result $taskResult -DurationMs $taskMs
            }
            $results.Add($taskResult)
            Show-TaskResultLine -PercentComplete $percent -Activity $task.Name -Result $taskResult `
                -Preview:$Preview -Quiet:$Quiet
        }
        if (-not $Quiet) { Write-Host '' }
        return $results
    } finally {
        $global:WhatIfPreference = $previousWhatIf
        Set-CleanupLogContext -TaskName $null
        Set-CleanupPlanTaskContext -TaskName $null
    }
}

function Get-ResultTotals {
    [CmdletBinding()]
    param($Results)
    $f = ($Results | Measure-Object -Property FilesRemoved -Sum).Sum
    $d = ($Results | Measure-Object -Property FoldersRemoved -Sum).Sum
    $b = ($Results | Measure-Object -Property BytesFreed -Sum).Sum
    $e = ($Results | ForEach-Object { $_.Errors.Count } | Measure-Object -Sum).Sum
    $s = ($Results | ForEach-Object { $_.Skipped.Count } | Measure-Object -Sum).Sum
    [PSCustomObject]@{
        Files   = if ($f) { $f } else { 0 }
        Folders = if ($d) { $d } else { 0 }
        Bytes   = if ($b) { $b } else { 0L }
        Errors  = if ($e) { $e } else { 0 }
        Skipped = if ($s) { $s } else { 0 }
    }
}

# ---------------------------------------------------------------------------
# 7. ФОРМИРОВАНИЕ И ФИКСАЦИЯ ПЛАНА.
#    Даже -Force сначала создаёт план, но делает это без вывода и вопросов.
#    После Lock-CleanupPlan список разрешённых для удаления путей неизменяем.
# ---------------------------------------------------------------------------
$null = Initialize-CleanupPlan
Set-CleanupConsoleMode -Compact $true

if (-not $Force) {
    Write-Host ''
    Write-Host " Предпросмотр: формирую безопасный план ($($tasks.Count) задач)..." -ForegroundColor Magenta
    Write-Host ''
}
$previewResults = Invoke-CleanupTasks -Tasks $tasks -Preview -Quiet:$Force -PersistPreview:$UserRequestedPreviewOnly
$previewTotals = Get-ResultTotals -Results $previewResults
$planSummary = Lock-CleanupPlan
Write-CleanupLog -Message "План зафиксирован: id=$($planSummary.Id); hash=$($planSummary.Hash); задач=$($planSummary.TaskCount); файловых объектов=$($planSummary.ItemCount); системных действий=$($planSummary.ActionCount); оценка=$(Format-Bytes $planSummary.EstimatedBytes)." -Level INFO -NoConsole -Force

if (-not $Force) {
    Write-InfoTable -Title 'Предпросмотр — будет удалено' -Color Magenta -Data ([ordered]@{
        'Файлов (оценка)'      = $previewTotals.Files
        'Папок (оценка)'       = $previewTotals.Folders
        'Пропущено безопасно'  = $previewTotals.Skipped
        'Критических ошибок'   = $previewTotals.Errors
        'Освободится (оценка)' = Format-Bytes $previewTotals.Bytes
        'Идентификатор плана'  = $planSummary.Hash.Substring(0, 12)
    })
    Write-Host ' Примечание: объём DISM и SFC заранее не оценивается; оценка журналов событий может измениться к моменту очистки.' -ForegroundColor DarkGray
}

if ($UserRequestedPreviewOnly) {
    Write-Host ''
    Write-Host ' Режим -WhatIf: показан только предпросмотр, ничего не было удалено.' -ForegroundColor Yellow
    Write-Host " Полный текстовый журнал предпросмотра: $logPath" -ForegroundColor DarkGray
    Write-Host ''
    Close-CleanupLog -Preview -Summary ([PSCustomObject]@{
        FilesRemoved   = $previewTotals.Files
        FoldersRemoved = $previewTotals.Folders
        FreedFormatted = Format-Bytes $previewTotals.Bytes
        FreedBytes     = $previewTotals.Bytes
        ErrorCount     = $previewTotals.Errors
        SkippedCount   = $previewTotals.Skipped
        Duration       = 'только предпросмотр'
    })
    Stop-CleanupPlan
    if (-not $NoPause -and -not $NonInteractive) { Read-Host ' Нажмите Enter для выхода' }
    if ($previewTotals.Errors -gt 0) { exit 1 }
    exit 0
}

if (-not $Force) {
    Write-Host ''
    $answer = Read-Host ' Выполнить очистку по этим данным? (Y/N)'
    if ($answer -notin @('y', 'Y', 'yes', 'Yes', 'YES', 'д', 'Д', 'да', 'Да', 'ДА')) {
        Write-Host ''
        Write-Host ' Очистка отменена пользователем. Ничего не было удалено.' -ForegroundColor Yellow
        Write-CleanupLog -Message 'Пользователь отменил очистку после предпросмотра.' -Level INFO -NoConsole -Force
        Write-Host ''
        Stop-CleanupPlan
        if (-not $NoPause -and -not $NonInteractive) { Read-Host ' Нажмите Enter для выхода' }
        exit 2
    }
}

# ---------------------------------------------------------------------------
# 8. РЕАЛЬНАЯ ОЧИСТКА.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ' Начинаю очистку...' -ForegroundColor Cyan
Write-Host ''

$startTime = Get-Date
$allResults = Invoke-CleanupTasks -Tasks $tasks
Stop-CleanupPlan
$afterDisk = Get-DiskInfo -DriveLetter $systemDrive
$duration = (Get-Date) - $startTime
$totals = Get-ResultTotals -Results $allResults
$freedActual = [Math]::Max([long]0, $afterDisk.FreeBytes - $beforeDisk.FreeBytes)
$durationText = "{0} мин {1} сек" -f [int]$duration.TotalMinutes, $duration.Seconds

Write-InfoTable -Title "Диск $($afterDisk.Drive) — после очистки" -Color Yellow -Data ([ordered]@{
    'Свободно'     = Format-Bytes $afterDisk.FreeBytes
    'Используется' = Format-Bytes $afterDisk.UsedBytes
    'Всего'        = Format-Bytes $afterDisk.TotalBytes
})

$postRunErrors = [System.Collections.Generic.List[string]]::new()
if ($config.CreateHTMLReport) {
    try {
        $reportPath = New-HtmlReport -OutputDirectory $reportDir -SystemInfo $sysInfo `
            -BeforeDisk $beforeDisk -AfterDisk $afterDisk -TaskResults $allResults -Duration $duration
        Write-Host ''
        Write-Host " HTML-отчёт сохранён: $reportPath" -ForegroundColor Cyan
    } catch {
        $postRunErrors.Add("HTML-отчёт: $($_.Exception.Message)")
        Write-CleanupLog -Message "Не удалось создать HTML-отчёт: $($_.Exception.Message)" -Level ERROR -Force -ErrorRecord $_
    }
}

$errorsBeforeSupport = [int]$totals.Errors + $postRunErrors.Count
$completionLevel = if ($errorsBeforeSupport -gt 0) { 'ERROR' } elseif ($totals.Skipped -gt 0) { 'WARN' } else { 'OK' }
Write-CleanupLog -Message "Очистка завершена. Освобождено: $(Format-Bytes $freedActual). Пропущено: $($totals.Skipped). Критических ошибок: $errorsBeforeSupport." -Level $completionLevel -NoConsole -Force
Close-CleanupLog -Summary ([PSCustomObject]@{
    FilesRemoved   = $totals.Files
    FoldersRemoved = $totals.Folders
    FreedFormatted = Format-Bytes $freedActual
    FreedBytes     = $freedActual
    ErrorCount     = $errorsBeforeSupport
    SkippedCount   = $totals.Skipped
    Duration       = $durationText
})

# Пакет создаётся после закрытия журнала, поэтому внутрь попадает полная
# сводка запуска. Если само создание пакета не удалось, это отдельная
# критическая ошибка и ненулевой код возврата.
$supportBundlePath = $null
if ($CreateSupportBundle) {
    try {
        $supportBundlePath = New-CleanupSupportBundle -OutputDirectory (Join-Path $PSScriptRoot 'support') `
            -LogPath $logPath -JsonLogPath (Get-CleanupJsonLogPath) -ConfigPath $configPath -ProjectRoot $PSScriptRoot
        Write-Host " Диагностический пакет : $supportBundlePath" -ForegroundColor Cyan
    } catch {
        $postRunErrors.Add("Диагностический пакет: $($_.Exception.Message)")
        Write-CleanupLog -Message "Не удалось создать диагностический пакет: $($_.Exception.Message)" -Level ERROR -Force -ErrorRecord $_
    }
}

$effectiveErrorCount = [int]$totals.Errors + $postRunErrors.Count
$summaryColor = if ($effectiveErrorCount -gt 0) { 'Red' } elseif ($totals.Skipped -gt 0) { 'Yellow' } else { 'Green' }
Write-InfoTable -Title 'Итоги очистки' -Color $summaryColor -Data ([ordered]@{
    'До очистки (свободно)'    = Format-Bytes $beforeDisk.FreeBytes
    'После очистки (свободно)' = Format-Bytes $afterDisk.FreeBytes
    'Удалено файлов'           = $totals.Files
    'Удалено папок'            = $totals.Folders
    'Освобождено'              = Format-Bytes $freedActual
    'Пропущено безопасно'      = $totals.Skipped
    'Критических ошибок'       = $effectiveErrorCount
    'Время выполнения'         = $durationText
})

Write-Host " Текстовый журнал        : $logPath" -ForegroundColor DarkGray
Write-Host " Структурированный журнал : $(Get-CleanupJsonLogPath)" -ForegroundColor DarkGray
Write-Host ''
if ($effectiveErrorCount -gt 0) {
    Write-Host ' Завершено с критическими ошибками. Подробности сохранены в журнале.' -ForegroundColor Red
} elseif ($totals.Skipped -gt 0) {
    Write-Host ' Готово. Некоторые занятые или изменившиеся объекты безопасно пропущены.' -ForegroundColor Yellow
} else {
    Write-Host ' Готово. Все запланированные задачи выполнены.' -ForegroundColor Green
}
Write-Host ''
if (-not $NoPause -and -not $NonInteractive) {
    Read-Host ' Нажмите Enter, чтобы закрыть окно'
}
if ($effectiveErrorCount -gt 0) { exit 1 }
exit 0
