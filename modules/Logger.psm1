#Requires -Version 5.1
<#
.SYNOPSIS
    Ведение журнала выполнения CleanupArchive.
.DESCRIPTION
    Пишет ДВА параллельных журнала каждого запуска в logs\:
      - cleanup_ГГГГ-ММ-ДД_ЧЧ-мм-сс.log   — человекочитаемый текстовый лог;
      - cleanup_ГГГГ-ММ-ДД_ЧЧ-мм-сс.jsonl — тот же лог в структурированном
        виде (JSON Lines, одна запись на строку), с версией программы,
        версией PowerShell, ОС, длительностью каждой задачи и полными
        деталями исключений там, где они переданы.

    Структурированный лог существует для отладки и диагностики: если что-то
    пошло не так, эти файлы легко разобрать программно или приложить к
    сообщению об ошибке. ВАЖНО: оба файла пишутся ТОЛЬКО на диск
    пользователя, в locale-папку logs\ рядом со скриптом. CleanupArchive
    не имеет сетевого кода и никуда их не отправляет — см. README,
    раздел "Логи и диагностика".

    Обычный предпросмотр перед подтверждением не дублирует каждое служебное
    сообщение в журнал. При отдельном запуске Cleanup.ps1 -WhatIf итог каждой
    задачи и общая сводка сохраняются, чтобы такой запуск можно было проверить
    или приложить к обращению в поддержку.
#>

$Script:LogFilePath = $null
$Script:JsonLogFilePath = $null
$Script:CurrentTaskName = $null
$Script:VerboseLogging = $true
$Script:CompactConsole = $false

function Initialize-CleanupLog {
    <#
    .SYNOPSIS
        Создаёт новые файлы журнала (.log и .jsonl) и пишет в них заголовок.
    .PARAMETER LogDirectory
        Папка, в которой будут созданы файлы журнала (создаётся при отсутствии).
    .PARAMETER VerboseLogging
        При $true в .jsonl попадают все сообщения уровня INFO; при $false —
        только сводки по задачам и предупреждения/ошибки (уровня OK/WARN/ERROR).
        Человекочитаемый .log и консоль всегда получают все сообщения.
    .OUTPUTS
        Полный путь к текстовому файлу журнала.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogDirectory,
        [bool]$VerboseLogging = $true
    )
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        # Журнал — намеренное диагностическое исключение из режима -WhatIf:
        # предпросмотр ничего не удаляет, но обязан оставить проверяемый след.
        New-Item -ItemType Directory -Path $LogDirectory -Force -ErrorAction Stop -WhatIf:$false | Out-Null
    }

    $Script:VerboseLogging = $VerboseLogging
    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $Script:LogFilePath = Join-Path $LogDirectory "cleanup_$timestamp.log"
    $Script:JsonLogFilePath = Join-Path $LogDirectory "cleanup_$timestamp.jsonl"

    $header = @(
        '==================================================================='
        ' CleanupArchive - журнал очистки'
        " Версия       : $(Get-CleanupArchiveVersion)"
        " Дата запуска : $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')"
        " Пользователь : $env:USERNAME"
        " Компьютер    : $env:COMPUTERNAME"
        '==================================================================='
        ''
    )
    Set-Content -LiteralPath $Script:LogFilePath -Value $header -Encoding UTF8 -ErrorAction Stop -WhatIf:$false

    try {
        $startEvent = [ordered]@{
            ts                    = (Get-Date).ToString('o')
            event                 = 'run_start'
            cleanupArchiveVersion = Get-CleanupArchiveVersion
            powerShellVersion     = $PSVersionTable.PSVersion.ToString()
            psEdition             = "$($PSVersionTable.PSEdition)"
            os                    = [System.Environment]::OSVersion.VersionString
            is64BitOS             = [System.Environment]::Is64BitOperatingSystem
            user                  = $env:USERNAME
            computer              = $env:COMPUTERNAME
            verboseLogging        = $VerboseLogging
        }
        Set-Content -LiteralPath $Script:JsonLogFilePath -Value ($startEvent | ConvertTo-Json -Compress -Depth 6) -Encoding UTF8 -ErrorAction Stop -WhatIf:$false
    } catch {
        throw "Не удалось создать структурированный журнал '$Script:JsonLogFilePath': $($_.Exception.Message)"
    }

    return $Script:LogFilePath
}

function Set-CleanupLogContext {
    <#
    .SYNOPSIS
        Задаёт имя текущей задачи — оно автоматически добавляется в каждую
        структурированную запись журнала (.jsonl), пока не будет изменено.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$TaskName
    )
    $Script:CurrentTaskName = $TaskName
}

function Set-CleanupConsoleMode {
    <#
    .SYNOPSIS
        Включает компактный режим: модули пишут детали в журнал, а главный
        сценарий выводит ровно одну итоговую строку на задачу.
    #>
    [CmdletBinding()]
    param([bool]$Compact = $true)
    $Script:CompactConsole = $Compact
}

function Write-CleanupLog {
    <#
    .SYNOPSIS
        Добавляет строку в оба журнала (.log и .jsonl) и, опционально,
        выводит её в консоль.
    .PARAMETER Level
        INFO (обычное событие), OK (успех), WARN (предупреждение,
        не критично), ERROR (ошибка).
    .PARAMETER NoConsole
        Не дублировать сообщение в консоль (только в файл(ы)).
    .PARAMETER ErrorRecord
        Если передан объект ошибки PowerShell — в .jsonl попадёт полный тип
        исключения, сообщение и ScriptStackTrace. Сильно упрощает отладку
        по сравнению с одной строкой $_.Exception.Message.
    .PARAMETER DurationMs
        Длительность операции в миллисекундах, если применимо — попадает
        только в структурированный лог, используется для поиска "тормозящих"
        задач.
    .PARAMETER Force
        Записать в постоянные файлы журнала, даже если сейчас идёт
        предпросмотр (используется только для самой сводки предпросмотра
        и необработанных ошибок в цикле задач).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')]
        [string]$Level = 'INFO',
        [switch]$NoConsole,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Nullable[int]]$DurationMs,
        [switch]$Force
    )
    $isPreview = [bool]$global:WhatIfPreference
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $prefix = if ($isPreview) { '[ПРЕДПРОСМОТР] ' } else { '' }
    $line = "[$timestamp] [$Level] $prefix$Message"
    $shouldPersist = (-not $isPreview) -or $Force

    if ($Script:LogFilePath -and $shouldPersist) {
        Add-Content -LiteralPath $Script:LogFilePath -Value $line -Encoding UTF8 -WhatIf:$false
    }

    if ($Script:JsonLogFilePath -and $shouldPersist -and ($Script:VerboseLogging -or $Level -ne 'INFO')) {
        try {
            $entry = [ordered]@{
                ts      = (Get-Date).ToString('o')
                level   = $Level
                task    = $Script:CurrentTaskName
                message = $Message
                preview = $isPreview
            }
            if ($PSBoundParameters.ContainsKey('DurationMs') -and $null -ne $DurationMs) {
                $entry['durationMs'] = $DurationMs
            }
            if ($ErrorRecord) {
                $entry['exception'] = [ordered]@{
                    type             = $ErrorRecord.Exception.GetType().FullName
                    message          = $ErrorRecord.Exception.Message
                    category         = "$($ErrorRecord.CategoryInfo.Category)"
                    scriptStackTrace = "$($ErrorRecord.ScriptStackTrace)"
                }
            }
            Add-Content -LiteralPath $Script:JsonLogFilePath -Value ($entry | ConvertTo-Json -Compress -Depth 6) -Encoding UTF8 -WhatIf:$false
        } catch {
            # Не даём сбою сериализации структурированного лога сорвать очистку.
        }
    }

    $showInConsole = (-not $NoConsole)
    if ($Script:CompactConsole -and $Script:CurrentTaskName) {
        $showInConsole = $false
    }
    if ($showInConsole) {
        $color = switch ($Level) {
            'ERROR' { 'Red' }
            'WARN' { 'Yellow' }
            'OK' { 'Green' }
            default { 'Gray' }
        }
        if ($isPreview) { $color = 'Magenta' }
        Write-Host " $line" -ForegroundColor $color
    }
}

function Write-CleanupTaskResult {
    <#
    .SYNOPSIS
        Сохраняет полный структурированный результат задачи, включая причины
        каждого пропуска. Эти сведения раньше оставались только в памяти.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][int]$DurationMs
    )
    $status = Get-CleanupResultStatus -Result $Result
    $summaryLine = "Задача '$($Result.TaskName)': статус $status; файлов $($Result.FilesRemoved); папок $($Result.FoldersRemoved); освобождено $(Format-Bytes $Result.BytesFreed); пропущено $($Result.Skipped.Count); ошибок $($Result.Errors.Count); ${DurationMs} мс."
    if ($Script:LogFilePath) {
        Add-Content -LiteralPath $Script:LogFilePath -Value "[$(Get-Date -Format 'HH:mm:ss')] [TASK] $summaryLine" -Encoding UTF8 -WhatIf:$false
        foreach ($issue in @($Result.Issues)) {
            $issuePath = if ($issue.Path) { " [$($issue.Path)]" } else { '' }
            Add-Content -LiteralPath $Script:LogFilePath `
                -Value "[$(Get-Date -Format 'HH:mm:ss')] [$($issue.Status)]$issuePath $($issue.Reason)" -Encoding UTF8 -WhatIf:$false
        }
        # Ошибки внешних системных команд могут не иметь ItemDetails.
        foreach ($errorText in @($Result.Errors)) {
            $alreadyDetailed = $false
            foreach ($issue in @($Result.Issues)) {
                $reasonText = [string]$issue.Reason
                if ($reasonText -and ([string]$errorText).IndexOf($reasonText, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $alreadyDetailed = $true
                    break
                }
            }
            if (-not $alreadyDetailed) {
                Add-Content -LiteralPath $Script:LogFilePath `
                    -Value "[$(Get-Date -Format 'HH:mm:ss')] [ERROR] $errorText" -Encoding UTF8 -WhatIf:$false
            }
        }
    }

    if ($Script:JsonLogFilePath) {
        try {
            $issues = @($Result.Issues | ForEach-Object {
                [ordered]@{
                    path          = $_.Path
                    status        = $_.Status
                    reason        = $_.Reason
                    exceptionType = $_.ExceptionType
                    isContainer   = $_.IsContainer
                    bytesFreed    = $_.BytesFreed
                }
            })
            $entry = [ordered]@{
                ts             = (Get-Date).ToString('o')
                event          = 'task_result'
                task           = $Result.TaskName
                status         = $status
                filesRemoved   = $Result.FilesRemoved
                foldersRemoved = $Result.FoldersRemoved
                bytesFreed     = $Result.BytesFreed
                skippedCount   = $Result.Skipped.Count
                errorCount     = $Result.Errors.Count
                skipped        = @($Result.Skipped)
                errors         = @($Result.Errors)
                issues         = $issues
                durationMs     = $DurationMs
            }
            Add-Content -LiteralPath $Script:JsonLogFilePath -Value ($entry | ConvertTo-Json -Compress -Depth 8) -Encoding UTF8 -WhatIf:$false
        } catch { }
    }
}

function Get-CleanupLogPath {
    <#
    .SYNOPSIS
        Возвращает путь к текущему текстовому файлу журнала (или $null).
    #>
    [CmdletBinding()]
    param()
    return $Script:LogFilePath
}

function Get-CleanupJsonLogPath {
    <#
    .SYNOPSIS
        Возвращает путь к текущему структурированному (.jsonl) журналу.
    #>
    [CmdletBinding()]
    param()
    return $Script:JsonLogFilePath
}

function Close-CleanupLog {
    <#
    .SYNOPSIS
        Дописывает итоговую сводку в конец обоих файлов журнала.
    .PARAMETER Summary
        Объект со свойствами FilesRemoved, FoldersRemoved, FreedFormatted,
        FreedBytes, ErrorCount, Duration, DurationMs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Summary,
        [switch]$Preview
    )
    if ($Script:LogFilePath) {
        $summaryTitle = if ($Preview) { ' Итог предпросмотра' } else { ' Итог очистки' }
        $footer = @(
            ''
            '==================================================================='
            $summaryTitle
            " Удалено файлов : $($Summary.FilesRemoved)"
            " Удалено папок  : $($Summary.FoldersRemoved)"
            " Освобождено    : $($Summary.FreedFormatted)"
            " Ошибок         : $($Summary.ErrorCount)"
            " Пропущено      : $($Summary.SkippedCount)"
            " Время работы   : $($Summary.Duration)"
            '==================================================================='
        )
        Add-Content -LiteralPath $Script:LogFilePath -Value $footer -Encoding UTF8 -WhatIf:$false
    }

    if ($Script:JsonLogFilePath) {
        try {
            $endEvent = [ordered]@{
                ts             = (Get-Date).ToString('o')
                event          = if ($Preview) { 'preview_end' } else { 'run_end' }
                filesRemoved   = $Summary.FilesRemoved
                foldersRemoved = $Summary.FoldersRemoved
                freedBytes     = $Summary.FreedBytes
                errorCount     = $Summary.ErrorCount
                skippedCount   = $Summary.SkippedCount
                durationText   = "$($Summary.Duration)"
            }
            Add-Content -LiteralPath $Script:JsonLogFilePath -Value ($endEvent | ConvertTo-Json -Compress -Depth 6) -Encoding UTF8 -WhatIf:$false
        } catch { }
    }
}

Export-ModuleMember -Function Initialize-CleanupLog, Write-CleanupLog, Write-CleanupTaskResult, `
    Get-CleanupLogPath, Get-CleanupJsonLogPath, Close-CleanupLog, Set-CleanupLogContext, `
    Set-CleanupConsoleMode
