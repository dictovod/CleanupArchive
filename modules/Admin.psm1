#Requires -Version 5.1
<#
.SYNOPSIS
    Проверка и запрос повышенных прав (UAC) для CleanupArchive.
.DESCRIPTION
    Большинству операций очистки (SoftwareDistribution, DISM, Defender,
    журналы событий, системные логи) требуются права администратора.
    Этот модуль определяет, запущен ли скрипт от администратора, и если
    нет — перезапускает его через UAC, завершая неповышенный процесс.
#>

function Test-IsAdministrator {
    <#
    .SYNOPSIS
        Проверяет, выполняется ли текущий процесс с правами администратора.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Request-AdminElevation {
    <#
    .SYNOPSIS
        Перезапускает указанный скрипт с правами администратора через UAC.
    .DESCRIPTION
        Если права администратора уже есть — ничего не делает и возвращает
        $true. Иначе запускает новый процесс powershell.exe с параметром
        -Verb RunAs (это и вызывает системный запрос UAC) и возвращает
        $false, сигнализируя вызывающему коду, что текущий (неповышенный)
        процесс должен завершиться.
    .PARAMETER ScriptPath
        Полный путь к .ps1, который нужно перезапустить.
    .PARAMETER ScriptArguments
        Дополнительные аргументы командной строки для перезапуска.
    .OUTPUTS
        [bool] $true, если права уже были администраторскими и перезапуск
        не потребовался; $false, если повышенный процесс успешно запущен.
        При отказе UAC или ошибке запуска выбрасывается исключение.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,
        [string[]]$ScriptArguments = @()
    )

    if (Test-IsAdministrator) {
        return $true
    }

    Write-Host ''
    Write-Host ' Для очистки системных папок нужны права администратора.' -ForegroundColor Yellow
    Write-Host ' Сейчас появится системный запрос UAC — подтвердите его.' -ForegroundColor Yellow

    try {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"") + $ScriptArguments
        $powerShellPath = (Get-Process -Id $PID -ErrorAction Stop).Path
        if (-not $powerShellPath -or -not (Test-Path -LiteralPath $powerShellPath)) {
            throw 'Не удалось определить путь текущего процесса PowerShell.'
        }
        Start-Process -FilePath $powerShellPath -ArgumentList $argList -Verb RunAs -ErrorAction Stop | Out-Null
    } catch {
        Write-Host ''
        Write-Host " Не удалось запросить права администратора: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ' Запустите Start.bat через "Запуск от имени администратора" вручную.' -ForegroundColor Red
        throw
    }

    return $false
}

Export-ModuleMember -Function Test-IsAdministrator, Request-AdminElevation
