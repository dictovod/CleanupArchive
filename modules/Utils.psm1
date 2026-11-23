#Requires -Version 5.1
<#
.SYNOPSIS
    Общие вспомогательные функции CleanupArchive.
.DESCRIPTION
    Модуль сам по себе ничего не очищает. Он предоставляет "строительные
    блоки", которыми пользуются все остальные модули:
      - Test-ProtectedPath / Remove-ItemSafely — единая точка безопасного
        удаления, через которую обязаны проходить ВСЕ операции удаления
        в проекте;
      - New-CleanupResult / Merge-CleanupResult — единый формат результата
        задачи очистки (файлов удалено, папок удалено, освобождено байт,
        ошибки);
      - Get-SystemInfo / Get-DiskInfo — определение ОС и диска;
      - Format-Bytes, Show-ProgressBar, Show-Banner, Write-InfoTable —
        оформление консольного вывода;
      - Clear-RecycleBinContents — безопасная очистка корзины.
#>

function Get-CleanupKnownFolderPath {
    <#
    .SYNOPSIS
        Возвращает системный путь из API .NET, не доверяя одноимённым
        переменным окружения процесса.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Windows', 'ProgramFiles', 'ProgramFilesX86', 'CommonApplicationData', 'LocalApplicationData', 'ApplicationData', 'UserProfile')]
        [string]$Name
    )
    try {
        $specialFolderType = [System.Environment].Assembly.GetType('System.Environment+SpecialFolder')
        $enumValue = [System.Enum]::Parse($specialFolderType, $Name)
        $path = [System.Environment]::GetFolderPath($enumValue)
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            return [System.IO.Path]::GetFullPath($path).TrimEnd('\')
        }
    } catch { }

    # SpecialFolder.Windows отсутствует в отдельных старых реализациях .NET.
    if ($Name -eq 'Windows') {
        try {
            $systemDirectory = [System.Environment]::SystemDirectory
            if (-not [string]::IsNullOrWhiteSpace($systemDirectory)) {
                return [System.IO.Directory]::GetParent($systemDirectory).FullName.TrimEnd('\')
            }
        } catch { }
    }
    return $null
}

function Get-CleanupSystemDrive {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $windowsDirectory = Get-CleanupKnownFolderPath -Name Windows
    if (-not $windowsDirectory) { return $null }
    return [System.IO.Path]::GetPathRoot($windowsDirectory).TrimEnd('\')
}

# ---------------------------------------------------------------------------
# Защищённые пути формируются из известных каталогов Windows/.NET, а не из
# изменяемых переменных WinDir, SystemDrive, ProgramFiles и ProgramData.
# ---------------------------------------------------------------------------
$trustedWindows = Get-CleanupKnownFolderPath -Name Windows
$trustedSystemDrive = Get-CleanupSystemDrive
$trustedProgramFiles = Get-CleanupKnownFolderPath -Name ProgramFiles
$trustedProgramFilesX86 = Get-CleanupKnownFolderPath -Name ProgramFilesX86
$trustedProgramData = Get-CleanupKnownFolderPath -Name CommonApplicationData
$protectedPathSpecs = @(
    @{ Base = $trustedWindows; Children = @('WinSxS', 'System32', 'SysWOW64', 'assembly', 'servicing', 'Boot', 'Fonts', 'Installer', 'System', 'Microsoft.NET', 'security') }
    @{ Base = $trustedSystemDrive; Children = @('Recovery', 'System Volume Information', '$Recycle.Bin', 'Boot', 'EFI', 'PerfLogs') }
    @{ Base = $trustedProgramFiles; Children = @('WindowsApps', 'Windows Defender', 'Windows Defender Advanced Threat Protection', 'Microsoft\Edge', 'Microsoft\Edge WebView', 'WindowsPowerShell') }
    @{ Base = $trustedProgramFilesX86; Children = @('WindowsApps', 'Microsoft\Edge') }
    @{ Base = $trustedProgramData; Children = @('Microsoft\Windows Defender\Platform', 'Microsoft\Windows\Start Menu') }
)
$Script:ProtectedPaths = @(
    foreach ($spec in $protectedPathSpecs) {
        if ([string]::IsNullOrWhiteSpace($spec.Base)) { continue }
        foreach ($child in $spec.Children) { Join-Path $spec.Base $child }
    }
)

# Неизменяемый план текущего запуска. Во время предпросмотра в него попадают
# только пути, прошедшие все проверки безопасности. После Lock-CleanupPlan
# реальные операции могут работать исключительно с уже зарегистрированными
# путями. Новые файлы, появившиеся между фазами, автоматически пропускаются.
$Script:CleanupPlan = $null
$Script:CleanupPlanMode = 'Off'   # Off | Capture | Execute
$Script:CleanupPlanTaskName = $null

function Get-TrustedCleanupBases {
    [CmdletBinding()]
    param()
    $bases = [System.Collections.Generic.List[string]]::new()
    foreach ($folderName in @('Windows', 'ProgramFiles', 'ProgramFilesX86', 'CommonApplicationData', 'LocalApplicationData', 'ApplicationData', 'UserProfile')) {
        $full = Get-CleanupKnownFolderPath -Name $folderName
        if ($full -and -not $full.StartsWith('\\') -and -not $bases.Contains($full)) { $bases.Add($full) }
    }
    return $bases.ToArray()
}

$Script:TrustedCleanupBases = @(Get-TrustedCleanupBases)

function Get-NormalizedCleanupPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    } catch {
        return $null
    }
}

function Test-CleanupRoot {
    <#
    .SYNOPSIS
        Проверяет, что каталог очистки находится внутри ожидаемой области.
    .DESCRIPTION
        Используется прежде всего для переменных окружения вроде TEMP: даже
        если переменная была случайно или намеренно направлена в другую папку,
        CleanupArchive не будет считать её доверенной автоматически.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$TrustedBase
    )
    $full = Get-NormalizedCleanupPath -Path $Path
    if (-not $full -or $full.StartsWith('\\')) { return $false }
    $driveRoot = [System.IO.Path]::GetPathRoot($full)
    if ($driveRoot -and $full.Equals($driveRoot.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    foreach ($base in $TrustedBase) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $baseFull = Get-NormalizedCleanupPath -Path $base
        if (-not $baseFull -or $baseFull.StartsWith('\\')) { continue }
        if ($full.StartsWith($baseFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Test-ReparsePointInCleanupPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$AllowedRoots
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $rootSet = @($AllowedRoots | ForEach-Object { Get-NormalizedCleanupPath -Path $_ })
    $current = Get-NormalizedCleanupPath -Path $Path
    while ($current) {
        try {
            $entry = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $true
            }
        } catch {
            return $true
        }
        if ($rootSet -contains $current) { break }
        try {
            $parent = [System.IO.Directory]::GetParent($current)
            if (-not $parent) { break }
            $next = $parent.FullName.TrimEnd('\')
            if ($next -eq $current) { break }
            $current = $next
        } catch {
            return $true
        }
    }
    return $false
}

function Test-CleanupPathSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$AllowedRoot,
        [string]$AllowedProtectedExactPath
    )
    $full = Get-NormalizedCleanupPath -Path $Path
    if (-not $full) {
        return [PSCustomObject]@{ Safe = $false; Path = $Path; Roots = @(); Reason = 'Некорректный или пустой путь.' }
    }
    if ($full.StartsWith('\\')) {
        return [PSCustomObject]@{ Safe = $false; Path = $full; Roots = @(); Reason = 'Сетевые UNC-пути запрещены.' }
    }

    $roots = [System.Collections.Generic.List[string]]::new()
    $insideRoot = $false
    foreach ($root in $AllowedRoot) {
        $rootFull = Get-NormalizedCleanupPath -Path $root
        if (-not $rootFull -or $rootFull.StartsWith('\\')) { continue }
        $driveRoot = [System.IO.Path]::GetPathRoot($rootFull)
        if ($driveRoot -and $rootFull.Equals($driveRoot.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $rootTrusted = $false
        foreach ($trustedBase in $Script:TrustedCleanupBases) {
            if ($rootFull.Equals($trustedBase, [System.StringComparison]::OrdinalIgnoreCase) -or `
                $rootFull.StartsWith($trustedBase + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                $rootTrusted = $true
                break
            }
        }
        if (-not $rootTrusted) { continue }
        $roots.Add($rootFull)
        # Удалять сам разрешённый корень нельзя: только явно выбранный объект
        # внутри него. Это защищает от ошибочно слишком широкого параметра.
        if ($full.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $insideRoot = $true
        }
    }
    if (-not $insideRoot) {
        return [PSCustomObject]@{ Safe = $false; Path = $full; Roots = $roots.ToArray(); Reason = 'Путь находится вне разрешённого корня задачи.' }
    }

    if (Test-ProtectedPath -Path $full) {
        $override = if ([string]::IsNullOrWhiteSpace($AllowedProtectedExactPath)) { $null } `
            else { Get-NormalizedCleanupPath -Path $AllowedProtectedExactPath }
        if (-not $override -or -not $full.Equals($override, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [PSCustomObject]@{ Safe = $false; Path = $full; Roots = $roots.ToArray(); Reason = 'Путь защищён правилами CleanupArchive.' }
        }
    }

    if ((Test-Path -LiteralPath $full) -and (Test-ReparsePointInCleanupPath -Path $full -AllowedRoots $roots.ToArray())) {
        return [PSCustomObject]@{ Safe = $false; Path = $full; Roots = $roots.ToArray(); Reason = 'Путь содержит junction, символическую ссылку или другую reparse point.' }
    }
    return [PSCustomObject]@{ Safe = $true; Path = $full; Roots = $roots.ToArray(); Reason = $null }
}

function Initialize-CleanupPlan {
    [CmdletBinding()]
    param()
    $Script:CleanupPlan = [PSCustomObject]@{
        Id         = [Guid]::NewGuid().ToString('N')
        CreatedUtc = [DateTime]::UtcNow
        Hash       = $null
        Items      = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Actions    = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Tasks      = [System.Collections.Generic.Dictionary[string,bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    $Script:CleanupPlanMode = 'Capture'
    $Script:CleanupPlanTaskName = $null
    return $Script:CleanupPlan.Id
}

function Set-CleanupPlanTaskContext {
    [CmdletBinding()]
    param([AllowNull()][string]$TaskName)
    $Script:CleanupPlanTaskName = $TaskName
}

function Register-CleanupPlanTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskName)
    if ($Script:CleanupPlanMode -eq 'Capture' -and $Script:CleanupPlan) {
        $Script:CleanupPlan.Tasks[$TaskName] = $true
        return $true
    }
    if ($Script:CleanupPlanMode -eq 'Execute' -and $Script:CleanupPlan) {
        return $Script:CleanupPlan.Tasks.ContainsKey($TaskName)
    }
    return $false
}

function Add-CleanupPlanItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$AllowedRoots,
        [Parameter(Mandatory)][bool]$IsContainer,
        [long]$Bytes = [long]0,
        [Nullable[DateTime]]$LastWriteUtc,
        [string]$Fingerprint
    )
    if ($Script:CleanupPlanMode -ne 'Capture' -or -not $Script:CleanupPlan) {
        return [PSCustomObject]@{ Registered = $false; Reason = 'План не находится в режиме формирования.'; Item = $null }
    }
    $key = (Get-NormalizedCleanupPath -Path $Path)
    if ($Script:CleanupPlan.Items.ContainsKey($key)) {
        return [PSCustomObject]@{ Registered = $false; Reason = "Объект уже включён задачей '$($Script:CleanupPlan.Items[$key].TaskName)'."; Item = $Script:CleanupPlan.Items[$key] }
    }
    $item = [PSCustomObject]@{
        Path         = $key
        TaskName     = $Script:CleanupPlanTaskName
        AllowedRoots = @($AllowedRoots)
        IsContainer  = $IsContainer
        Bytes        = [long]$Bytes
        LastWriteUtc = $LastWriteUtc
        Fingerprint  = $Fingerprint
        Attempted    = $false
    }
    $Script:CleanupPlan.Items.Add($key, $item)
    return [PSCustomObject]@{ Registered = $true; Reason = $null; Item = $item }
}

function Use-CleanupPlanAction {
    <#
    .SYNOPSIS
        Регистрирует внешнее действие в предпросмотре и разрешает только его
        точное повторение после фиксации плана.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ActionId,
        [Parameter(Mandatory)][string]$Description
    )
    if (-not $Script:CleanupPlan -or -not $Script:CleanupPlanTaskName) { return $false }
    $key = "$($Script:CleanupPlanTaskName)|$ActionId"
    if ($Script:CleanupPlanMode -eq 'Capture') {
        if (-not $Script:CleanupPlan.Actions.ContainsKey($key)) {
            $Script:CleanupPlan.Actions.Add($key, [PSCustomObject]@{
                TaskName    = $Script:CleanupPlanTaskName
                ActionId    = $ActionId
                Description = $Description
                Attempted   = $false
            })
        }
        return $true
    }
    if ($Script:CleanupPlanMode -eq 'Execute' -and $Script:CleanupPlan.Actions.ContainsKey($key)) {
        $Script:CleanupPlan.Actions[$key].Attempted = $true
        return $true
    }
    return $false
}

function Complete-CleanupPlanActionGroup {
    <#
    .SYNOPSIS
        Помечает исходное действие обработанным, когда его состояние изменилось
        и точный идентификатор больше не совпадает с планом.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ActionIdPrefix)
    if ($Script:CleanupPlanMode -ne 'Execute' -or -not $Script:CleanupPlan) { return }
    foreach ($action in @($Script:CleanupPlan.Actions.Values | Where-Object {
        $_.TaskName -eq $Script:CleanupPlanTaskName -and $_.ActionId.StartsWith($ActionIdPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    })) {
        $action.Attempted = $true
    }
}

function Lock-CleanupPlan {
    [CmdletBinding()]
    param()
    if ($Script:CleanupPlanMode -ne 'Capture' -or -not $Script:CleanupPlan) {
        throw 'План очистки не был сформирован.'
    }
    $manifestLines = [System.Collections.Generic.List[string]]::new()
    foreach ($taskName in @($Script:CleanupPlan.Tasks.Keys | Sort-Object)) {
        $manifestLines.Add("TASK|$taskName")
    }
    foreach ($item in @($Script:CleanupPlan.Items.Values | Sort-Object -Property Path)) {
        $manifestLines.Add("ITEM|$($item.TaskName)|$($item.Path)|$($item.IsContainer)|$($item.Bytes)|$($item.LastWriteUtc)|$($item.Fingerprint)")
    }
    foreach ($action in @($Script:CleanupPlan.Actions.Values | Sort-Object { "$($_.TaskName)|$($_.ActionId)" })) {
        $manifestLines.Add("ACTION|$($action.TaskName)|$($action.ActionId)|$($action.Description)")
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($manifestLines -join "`n"))
        $Script:CleanupPlan.Hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    $Script:CleanupPlanMode = 'Execute'
    $estimated = ($Script:CleanupPlan.Items.Values | Measure-Object -Property Bytes -Sum).Sum
    return [PSCustomObject]@{
        Id             = $Script:CleanupPlan.Id
        Hash           = $Script:CleanupPlan.Hash
        TaskCount      = $Script:CleanupPlan.Tasks.Count
        ItemCount      = $Script:CleanupPlan.Items.Count
        ActionCount    = $Script:CleanupPlan.Actions.Count
        EstimatedBytes = if ($estimated) { [long]$estimated } else { 0L }
    }
}

function Get-CleanupPlanMode {
    [CmdletBinding()]
    param()
    return $Script:CleanupPlanMode
}

function Get-CleanupPlanItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not $Script:CleanupPlan) { return $null }
    $key = Get-NormalizedCleanupPath -Path $Path
    if ($key -and $Script:CleanupPlan.Items.ContainsKey($key)) {
        return $Script:CleanupPlan.Items[$key]
    }
    return $null
}

function Set-CleanupPlanItemAttempted {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ($Script:CleanupPlanMode -ne 'Execute') { return }
    $item = Get-CleanupPlanItem -Path $Path
    if ($item -and $item.TaskName -eq $Script:CleanupPlanTaskName) {
        $item.Attempted = $true
    }
}

function Complete-CleanupPlanTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)]$TaskResult
    )
    if ($Script:CleanupPlanMode -ne 'Execute' -or -not $Script:CleanupPlan) { return $TaskResult }
    foreach ($planned in @($Script:CleanupPlan.Items.Values | Where-Object { $_.TaskName -eq $TaskName -and -not $_.Attempted })) {
        $planned.Attempted = $true
        $missingResult = [PSCustomObject]@{
            Path          = $planned.Path
            Success       = $false
            BytesFreed    = 0L
            Skipped       = $true
            Error         = 'Объект исчез или изменился после предпросмотра.'
            Reason        = 'Объект исчез или изменился после предпросмотра.'
            Status        = 'SkippedChanged'
            ExceptionType = $null
            Preview       = $false
        }
        Merge-CleanupResult -TaskResult $TaskResult -ItemResult $missingResult -IsContainer ([bool]$planned.IsContainer)
    }
    foreach ($action in @($Script:CleanupPlan.Actions.Values | Where-Object { $_.TaskName -eq $TaskName -and -not $_.Attempted })) {
        $action.Attempted = $true
        Add-CleanupResultIssue -TaskResult $TaskResult -Status SkippedChanged `
            -Message "Запланированное действие не было выполнено: $($action.Description)." -Path $action.ActionId
    }
    return $TaskResult
}

function Stop-CleanupPlan {
    [CmdletBinding()]
    param()
    $Script:CleanupPlanMode = 'Off'
    $Script:CleanupPlanTaskName = $null
}

function Test-ProtectedPath {
    <#
    .SYNOPSIS
        Проверяет, находится ли путь внутри защищённой системной области.
    .DESCRIPTION
        Возвращает $true, если путь совпадает с одним из защищённых
        каталогов или является его потомком, если путь некорректен, пуст,
        либо указывает прямо на корень диска. Это последний рубеж защиты
        перед вызовом Remove-Item внутри Remove-ItemSafely.
    .PARAMETER Path
        Проверяемый путь. Не обязан существовать.
    .EXAMPLE
        Test-ProtectedPath -Path 'C:\Windows\System32\drivers'
        # $true
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }

    try {
        $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    } catch {
        return $true
    }

    # Запрещаем работу прямо с корнем диска ("C:" или "C:\").
    if ($full -match '^[A-Za-z]:$') { return $true }

    foreach ($protected in $Script:ProtectedPaths) {
        if ([string]::IsNullOrWhiteSpace($protected)) { continue }
        $protectedFull = $protected.TrimEnd('\')
        if ($full.Equals($protectedFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        if ($full.StartsWith($protectedFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-FolderSize {
    <#
    .SYNOPSIS
        Считает суммарный размер файлов внутри папки в байтах.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    return [long](Get-CleanupTreeSnapshot -Path $Path).Bytes
}

function Get-CleanupTreeSnapshot {
    <#
    .SYNOPSIS
        Возвращает размер и отпечаток дерева без перехода по reparse points.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $root = Get-NormalizedCleanupPath -Path $Path
    $result = [PSCustomObject]@{
        Bytes        = 0L
        Fingerprint  = $null
        HasReparse   = $false
        EntryCount   = 0
    }
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { return $result }

    $queue = [System.Collections.Generic.Queue[string]]::new()
    $entries = [System.Collections.Generic.List[string]]::new()
    $queue.Enqueue($root)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        foreach ($entry in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue)) {
            $relative = $entry.FullName.Substring($root.Length).TrimStart('\')
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $result.HasReparse = $true
                $entries.Add("R|$relative")
                continue
            }
            if ($entry.PSIsContainer) {
                $entries.Add("D|$relative|$($entry.LastWriteTimeUtc.Ticks)")
                $queue.Enqueue($entry.FullName)
            } else {
                $length = [long]$entry.Length
                $result.Bytes += $length
                $entries.Add("F|$relative|$length|$($entry.LastWriteTimeUtc.Ticks)")
            }
        }
    }
    $result.EntryCount = $entries.Count
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $manifest = @($entries | Sort-Object) -join "`n"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($manifest)
        $result.Fingerprint = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    return $result
}

function Remove-ItemSafely {
    <#
    .SYNOPSIS
        Безопасно удаляет файл или папку, никогда не трогая защищённые пути.
    .DESCRIPTION
        Единая точка удаления для всего проекта. Перед удалением:
          1. проверяет Test-ProtectedPath (жёсткий отказ на защищённых путях);
          2. проверяет существование объекта;
          3. вычисляет его размер ДО удаления (для честного подсчёта
             освобождённого места);
          4. пытается удалить; если файл занят другим процессом, доступ
             запрещён, либо возникла любая иная ошибка — объект молча
             пропускается, а не роняет весь скрипт (см. try/catch).
    .PARAMETER Path
        Путь к файлу или папке.
    .PARAMETER Recurse
        Удалить папку рекурсивно (используется для папок).
    .OUTPUTS
        PSCustomObject: Path, Success, BytesFreed, Skipped, Error
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string[]]$AllowedRoot,
        [switch]$Recurse,
        [string]$AllowedProtectedExactPath
    )

    $result = [PSCustomObject]@{
        Path          = $Path
        Success       = $false
        BytesFreed    = 0L
        Skipped       = $false
        Error         = $null
        Reason        = $null
        Status        = 'Pending'
        ExceptionType = $null
        Preview       = ([bool]$global:WhatIfPreference -or $Script:CleanupPlanMode -eq 'Capture')
    }

    $safety = Test-CleanupPathSafety -Path $Path -AllowedRoot $AllowedRoot -AllowedProtectedExactPath $AllowedProtectedExactPath
    $result.Path = $safety.Path
    if (-not $safety.Safe) {
        Set-CleanupPlanItemAttempted -Path $Path
        $result.Skipped = $true
        $result.Status = if ($safety.Reason -match 'reparse|junction|ссылк') { 'SkippedReparsePoint' } `
            elseif ($safety.Reason -match 'защищён') { 'SkippedProtected' } else { 'SkippedSafety' }
        $result.Reason = $safety.Reason
        $result.Error = $safety.Reason
        return $result
    }

    if (-not (Test-Path -LiteralPath $safety.Path)) {
        Set-CleanupPlanItemAttempted -Path $safety.Path
        $result.Skipped = $true
        $result.Status = 'SkippedChanged'
        $result.Reason = 'Объект отсутствует или был изменён после формирования списка.'
        return $result
    }

    $item = $null
    $sizeBefore = 0L
    $treeFingerprint = $null
    try {
        $item = Get-Item -LiteralPath $safety.Path -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            $snapshot = Get-CleanupTreeSnapshot -Path $safety.Path
            if ($snapshot.HasReparse) {
                Set-CleanupPlanItemAttempted -Path $safety.Path
                $result.Skipped = $true
                $result.Status = 'SkippedReparsePoint'
                $result.Reason = 'Внутри папки обнаружена junction, символическая ссылка или другая reparse point.'
                return $result
            }
            $sizeBefore = [long]$snapshot.Bytes
            $treeFingerprint = $snapshot.Fingerprint
        } else {
            $sizeBefore = [long]$item.Length
        }
        $result.BytesFreed = $sizeBefore
    } catch {
        Set-CleanupPlanItemAttempted -Path $safety.Path
        $result.Skipped = $true
        $result.Status = 'SkippedChanged'
        $result.Reason = $_.Exception.Message
        $result.Error = $_.Exception.Message
        $result.ExceptionType = $_.Exception.GetType().FullName
        return $result
    }

    if ($Script:CleanupPlanMode -eq 'Capture') {
        $registered = Add-CleanupPlanItem -Path $safety.Path -AllowedRoots $safety.Roots `
            -IsContainer ([bool]$item.PSIsContainer) -Bytes $sizeBefore -LastWriteUtc $item.LastWriteTimeUtc `
            -Fingerprint $treeFingerprint
        if (-not $registered.Registered) {
            $result.BytesFreed = 0L
            $result.Skipped = $true
            $result.Status = 'SkippedDuplicate'
            $result.Reason = $registered.Reason
            return $result
        }
        $result.Success = $true
        $result.Status = 'Planned'
        return $result
    }

    if ($Script:CleanupPlanMode -ne 'Execute') {
        $result.BytesFreed = 0L
        $result.Skipped = $true
        $result.Status = 'SkippedNotPlanned'
        $result.Reason = 'Удаление запрещено: отсутствует зафиксированный план очистки.'
        return $result
    }

    $planned = Get-CleanupPlanItem -Path $safety.Path
    if (-not $planned -or $planned.TaskName -ne $Script:CleanupPlanTaskName) {
        $result.BytesFreed = 0L
        $result.Skipped = $true
        $result.Status = 'SkippedNotPlanned'
        $result.Reason = 'Объект не входил в подтверждённый план этой задачи.'
        return $result
    }
    $planned.Attempted = $true

    if ([bool]$planned.IsContainer -ne [bool]$item.PSIsContainer) {
        $result.BytesFreed = 0L
        $result.Skipped = $true
        $result.Status = 'SkippedChanged'
        $result.Reason = 'Тип объекта изменился после предпросмотра.'
        return $result
    }
    if ($item.PSIsContainer -and $treeFingerprint -ne $planned.Fingerprint) {
        $result.BytesFreed = 0L
        $result.Skipped = $true
        $result.Status = 'SkippedChanged'
        $result.Reason = 'Содержимое папки изменилось после предпросмотра и было безопасно пропущено.'
        return $result
    }
    if (-not $item.PSIsContainer -and ($item.Length -ne $planned.Bytes -or $item.LastWriteTimeUtc -ne $planned.LastWriteUtc)) {
        $result.BytesFreed = 0L
        $result.Skipped = $true
        $result.Status = 'SkippedChanged'
        $result.Reason = 'Файл изменился после предпросмотра и был безопасно пропущен.'
        return $result
    }

    try {
        if ($Recurse) {
            Remove-Item -LiteralPath $safety.Path -Recurse -Force -ErrorAction Stop
        } else {
            Remove-Item -LiteralPath $safety.Path -Force -ErrorAction Stop
        }
        $result.Success = $true
        $result.Status = 'Deleted'
    } catch {
        $result.Success = $false
        $result.Skipped = $true
        $result.Error = $_.Exception.Message
        $result.Reason = $_.Exception.Message
        $result.ExceptionType = $_.Exception.GetType().FullName
        if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::PermissionDenied -or `
            $_.Exception -is [System.UnauthorizedAccessException] -or `
            $_.Exception -is [System.Security.SecurityException]) {
            $result.Status = 'SkippedAccessDenied'
        } elseif ($_.Exception -is [System.IO.FileNotFoundException] -or `
                  $_.Exception -is [System.IO.DirectoryNotFoundException] -or `
                  $_.Exception -is [System.Management.Automation.ItemNotFoundException]) {
            $result.Status = 'SkippedChanged'
        } elseif ($_.Exception -is [System.IO.IOException]) {
            $result.Status = 'SkippedLocked'
        } else {
            $result.Status = 'Failed'
            $result.Skipped = $false
        }

        # Remove-Item -Recurse может частично удалить содержимое до встречи с
        # занятым файлом. Не теряем реально освобождённые байты из отчёта.
        $remaining = [long]0
        if (Test-Path -LiteralPath $safety.Path) {
            try {
                $current = Get-Item -LiteralPath $safety.Path -Force -ErrorAction Stop
                $remaining = if ($current.PSIsContainer) { (Get-CleanupTreeSnapshot -Path $safety.Path).Bytes } else { [long]$current.Length }
            } catch { $remaining = $sizeBefore }
        }
        $result.BytesFreed = [Math]::Max([long]0, $sizeBefore - $remaining)
    }

    return $result
}

function Clear-RecycleBinContents {
    <#
    .SYNOPSIS
        Очищает корзину на системном диске.
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Корзина'
    try {
        $before = 0L
        $items = @()
        try {
            $shell = New-Object -ComObject Shell.Application
            $bin = $shell.Namespace(0xA)
            if ($bin) {
                $items = @($bin.Items())
                if ($items.Count -gt 0) {
                    $before = ($items | ForEach-Object { $_.Size } | Measure-Object -Sum).Sum
                }
            }
        } catch { }

        $binManifest = @($items | ForEach-Object { "$($_.Path)|$($_.Size)|$($_.ModifyDate)" } | Sort-Object) -join "`n"
        $binSha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $binBytes = [System.Text.Encoding]::UTF8.GetBytes($binManifest)
            $binFingerprint = ([BitConverter]::ToString($binSha.ComputeHash($binBytes))).Replace('-', '').ToLowerInvariant()
        } finally {
            $binSha.Dispose()
        }

        if (-not (Use-CleanupPlanAction -ActionId ("recycle-bin.clear-current-user." + $binFingerprint) `
                -Description 'Очистка корзины текущего пользователя')) {
            Complete-CleanupPlanActionGroup -ActionIdPrefix 'recycle-bin.clear-current-user.'
            Add-CleanupResultIssue -TaskResult $result -Status SkippedChanged `
                -Message 'Содержимое корзины изменилось после предпросмотра; очистка безопасно пропущена.'
            return $result
        }

        if ($global:WhatIfPreference) {
            $result.BytesFreed = [long]$before
            if ($before -gt 0) { $result.FoldersRemoved = 1 }
            Write-CleanupLog -Message "Будет очищена корзина, освободится $(Format-Bytes $before)." -Level INFO -NoConsole
            return $result
        }

        if (Get-Command -Name Clear-RecycleBin -ErrorAction SilentlyContinue) {
            Clear-RecycleBin -Force -ErrorAction Stop
        } else {
            throw 'Штатный командлет Clear-RecycleBin недоступен; небезопасный прямой обход корзины отключён.'
        }

        $result.BytesFreed = [long]$before
        if ($before -gt 0) { $result.FoldersRemoved = 1 }
        Write-CleanupLog -Message "Корзина очищена, освобождено $(Format-Bytes $before)." -Level OK
    } catch {
        Add-CleanupResultIssue -TaskResult $result -Status Failed -Message $_.Exception.Message `
            -ExceptionType $($_.Exception.GetType().FullName)
        Write-CleanupLog -Message "Ошибка при очистке корзины: $($_.Exception.Message)" -Level ERROR -ErrorRecord $_
    }
    return $result
}

function New-CleanupResult {
    <#
    .SYNOPSIS
        Создаёт пустой объект результата для одной задачи очистки.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TaskName
    )
    [PSCustomObject]@{
        TaskName       = $TaskName
        FilesRemoved   = 0
        FoldersRemoved = 0
        BytesFreed     = 0L
        Errors         = [System.Collections.Generic.List[string]]::new()
        Skipped        = [System.Collections.Generic.List[string]]::new()
        Issues         = [System.Collections.Generic.List[object]]::new()
    }
}

function Merge-CleanupResult {
    <#
    .SYNOPSIS
        Добавляет результат одного Remove-ItemSafely в общий результат задачи.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$TaskResult,
        [Parameter(Mandatory)]$ItemResult,
        [bool]$IsContainer = $false
    )
    if ($ItemResult.Success) {
        if ($IsContainer) { $TaskResult.FoldersRemoved++ } else { $TaskResult.FilesRemoved++ }
        $TaskResult.BytesFreed += $ItemResult.BytesFreed
        return
    }

    if ($ItemResult.BytesFreed -gt 0) {
        $TaskResult.BytesFreed += [long]$ItemResult.BytesFreed
    }
    $reason = if ($ItemResult.Reason) { $ItemResult.Reason } elseif ($ItemResult.Error) { $ItemResult.Error } else { 'Объект пропущен.' }
    $issue = [PSCustomObject]@{
        Path          = $ItemResult.Path
        Status        = $ItemResult.Status
        Reason        = $reason
        ExceptionType = $ItemResult.ExceptionType
        IsContainer   = [bool]$IsContainer
        BytesFreed    = [long]$ItemResult.BytesFreed
    }
    $TaskResult.Issues.Add($issue)
    $message = if ([string]::IsNullOrWhiteSpace($ItemResult.Path)) { $reason } else { "$($ItemResult.Path): $reason" }
    if ($ItemResult.Status -eq 'Failed') {
        $TaskResult.Errors.Add($message)
    } else {
        $TaskResult.Skipped.Add($message)
    }
}

function Add-CleanupResultIssue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$TaskResult,
        [Parameter(Mandatory)][ValidateSet('SkippedLocked', 'SkippedAccessDenied', 'SkippedChanged', 'SkippedProtected', 'SkippedSafety', 'SkippedNotPlanned', 'SkippedExternalFailure', 'Failed')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        [string]$Path,
        [string]$ExceptionType
    )
    $issue = [PSCustomObject]@{
        Path          = $Path
        Status        = $Status
        Reason        = $Message
        ExceptionType = $ExceptionType
        IsContainer   = $false
        BytesFreed    = 0L
    }
    $TaskResult.Issues.Add($issue)
    $line = if ($Path) { "${Path}: $Message" } else { $Message }
    if ($Status -eq 'Failed') { $TaskResult.Errors.Add($line) } else { $TaskResult.Skipped.Add($line) }
}

function Get-CleanupResultStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Result)
    if ($Result.Errors.Count -gt 0) { return 'Failed' }
    if ($Result.Skipped.Count -gt 0) { return 'Warning' }
    if ($global:WhatIfPreference -or $Script:CleanupPlanMode -eq 'Capture') { return 'Planned' }
    return 'Success'
}

function Format-Bytes {
    <#
    .SYNOPSIS
        Форматирует число байт в удобочитаемый вид (КБ/МБ/ГБ/ТБ).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [double]$Bytes
    )
    $units = 'Б', 'КБ', 'МБ', 'ГБ', 'ТБ'
    $sign = if ($Bytes -lt 0) { '-' } else { '' }
    $value = [math]::Abs($Bytes)
    $index = 0
    while ($value -ge 1024 -and $index -lt ($units.Length - 1)) {
        $value = $value / 1024
        $index++
    }
    return "{0}{1:N2} {2}" -f $sign, $value, $units[$index]
}

function Get-CleanupArchiveVersion {
    <#
    .SYNOPSIS
        Возвращает текущую версию CleanupArchive (единый источник правды
        для баннера, таблицы информации о системе и структурированного лога).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        $versionPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'VERSION'
        if (Test-Path -LiteralPath $versionPath) {
            $version = (Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim()
            if ($version) { return $version }
        }
    } catch { }
    return '1.2.1'
}

function Get-SystemInfo {
    <#
    .SYNOPSIS
        Определяет версию/сборку/редакцию Windows и архитектуру.
    #>
    [CmdletBinding()]
    param()
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $buildNumber = 0
        [void][int]::TryParse($os.BuildNumber, [ref]$buildNumber)

        # Win32_OperatingSystem у Windows 11 часто всё ещё сообщает Caption
        # "Microsoft Windows 10 ...", различать нужно по номеру сборки.
        $friendlyName = ($os.Caption -replace '^Microsoft\s+', '').Trim()
        if ($buildNumber -ge 22000 -and $friendlyName -match 'Windows 10') {
            $friendlyName = $friendlyName -replace 'Windows 10', 'Windows 11'
        }

        [PSCustomObject]@{
            Name         = $friendlyName
            Edition      = $os.Caption
            Version      = $os.Version
            Build        = $buildNumber
            Architecture = $os.OSArchitecture
            ComputerName = $cs.Name
        }
    } catch {
        [PSCustomObject]@{
            Name         = 'Неизвестная система'
            Edition      = 'Неизвестно'
            Version      = 'Неизвестно'
            Build        = 0
            Architecture = 'Неизвестно'
            ComputerName = $env:COMPUTERNAME
        }
    }
}

function Get-DiskInfo {
    <#
    .SYNOPSIS
        Возвращает сведения о диске: тип носителя (SSD/HDD), общий размер,
        занято и свободно места.
    #>
    [CmdletBinding()]
    param(
        [string]$DriveLetter
    )
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) {
        $DriveLetter = Get-CleanupSystemDrive
    }
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) {
        throw 'Не удалось определить системный диск через API Windows.'
    }
    $letter = $DriveLetter.TrimEnd('\').TrimEnd(':')
    $result = [PSCustomObject]@{
        Drive      = "$letter`:"
        TotalBytes = 0L
        FreeBytes  = 0L
        UsedBytes  = 0L
        MediaType  = 'Неизвестно'
    }

    try {
        $vol = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$letter`:'" -ErrorAction Stop
        if ($vol) {
            $result.TotalBytes = [long]$vol.Size
            $result.FreeBytes = [long]$vol.FreeSpace
            $result.UsedBytes = $result.TotalBytes - $result.FreeBytes
        }
    } catch { }

    try {
        $partition = Get-Partition -DriveLetter $letter -ErrorAction Stop
        $disk = $partition | Get-Disk -ErrorAction Stop | Select-Object -First 1
        $physicalDisk = $disk | Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1
        if ($physicalDisk -and $physicalDisk.MediaType -and $physicalDisk.MediaType -ne 'Unspecified') {
            $result.MediaType = [string]$physicalDisk.MediaType
        }
    } catch {
        $result.MediaType = 'Неизвестно'
    }

    return $result
}

function Show-ProgressBar {
    <#
    .SYNOPSIS
        Рисует текстовый индикатор прогресса вида [█████░░░░░]  NN%  Задача
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$PercentComplete,
        [Parameter(Mandatory)][string]$Activity,
        [int]$Width = 30
    )
    $pct = [Math]::Max(0, [Math]::Min(100, $PercentComplete))
    $filled = [Math]::Round(($Width * $pct) / 100)
    $empty = $Width - $filled
    $bar = ('█' * $filled) + ('░' * $empty)
    $activityPadded = if ($Activity.Length -gt 42) { $Activity.Substring(0, 39) + '...' } else { $Activity.PadRight(42) }
    $line = "  [{0}] {1,3}%  {2}" -f $bar, $pct, $activityPadded
    Write-Host "`r$line" -NoNewline -ForegroundColor Cyan
    if ($pct -ge 100) { Write-Host '' }
}

function Show-TaskResultLine {
    <#
    .SYNOPSIS
        Печатает одну завершённую строку результата задачи без перезаписи.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$PercentComplete,
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)]$Result,
        [switch]$Preview,
        [switch]$Quiet,
        [int]$Width = 30
    )
    if ($Quiet) { return }
    $pct = [Math]::Max(0, [Math]::Min(100, $PercentComplete))
    $filled = [Math]::Round(($Width * $pct) / 100)
    $bar = ('█' * $filled) + ('░' * ($Width - $filled))
    $objects = [int]$Result.FilesRemoved + [int]$Result.FoldersRemoved
    $skippedCount = [int]$Result.Skipped.Count
    $errorCount = [int]$Result.Errors.Count

    if ($Preview -and $errorCount -gt 0) {
        $tag = '[ОШИБКА ПЛАНА]'
        $detail = "ошибок $errorCount, пропущено $skippedCount"
        $color = 'Red'
    } elseif ($Preview) {
        $tag = '[ПЛАН]'
        $detail = "объектов $objects, оценка $(Format-Bytes $Result.BytesFreed)"
        if ($skippedCount -gt 0) { $detail += ", пропущено $skippedCount" }
        $color = 'Magenta'
    } elseif ($errorCount -gt 0) {
        $tag = '[ОШИБКА]'
        $detail = "ошибок $errorCount, пропущено $skippedCount, освобождено $(Format-Bytes $Result.BytesFreed)"
        $color = 'Red'
    } elseif ($skippedCount -gt 0) {
        $tag = '[ЧАСТИЧНО]'
        $detail = "объектов $objects, пропущено $skippedCount, освобождено $(Format-Bytes $Result.BytesFreed)"
        $color = 'Yellow'
    } else {
        $tag = '[OK]'
        $detail = if ($objects -gt 0 -or $Result.BytesFreed -gt 0) `
            { "объектов $objects, освобождено $(Format-Bytes $Result.BytesFreed)" } else { 'выполнено' }
        $color = 'Green'
    }
    $activityText = if ($Activity.Length -gt 36) { $Activity.Substring(0, 33) + '...' } else { $Activity.PadRight(36) }
    Write-Host ("  [{0}] {1,3}%  {2} {3} {4}" -f $bar, $pct, $activityText, $tag, $detail) -ForegroundColor $color
}

function Show-Banner {
    <#
    .SYNOPSIS
        Печатает ASCII-логотип и шапку утилиты.
    #>
    [CmdletBinding()]
    param()
    $banner = @'
   _____ _                            _____           _     _
  / ____| |                     /\   / ____|         | |   (_)
 | |    | | ___  __ _ _ __     /  \ | |     _ __   ___| |__  ___   _____
 | |    | |/ _ \/ _` | '_ \   / /\ \| |    | '__| / __| '_ \| \ \ / / _ \
 | |____| |  __/ (_| | | | | / ____ \ |____| |    | (__| | | | |\ V /  __/
  \_____|_|\___|\__,_|_| |_|/_/    \_\_____|_|     \___|_| |_|_| \_/ \___|
'@
    Write-Host $banner -ForegroundColor Cyan
    Write-Host "        Утилита обслуживания и очистки Windows 10/11" -ForegroundColor White
    Write-Host "        Открытый исходный код · без рекламы · без телеметрии · MIT" -ForegroundColor DarkGray
    Write-Host ('=' * 90) -ForegroundColor DarkCyan
}

function Write-InfoTable {
    <#
    .SYNOPSIS
        Печатает заголовок и выровненную таблицу "ключ : значение".
    .PARAMETER Data
        Упорядоченный словарь (используйте [ordered]@{ ... }), чтобы
        порядок строк совпадал с порядком добавления.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Data,
        [string]$Color = 'Yellow'
    )
    Write-Host ""
    Write-Host " $Title" -ForegroundColor $Color
    Write-Host (" " + ('-' * $Title.Length)) -ForegroundColor DarkGray
    $maxKeyLength = ($Data.Keys | Measure-Object -Property Length -Maximum).Maximum
    foreach ($key in $Data.Keys) {
        $paddedKey = $key.PadRight($maxKeyLength)
        Write-Host ("   {0} : " -f $paddedKey) -ForegroundColor Gray -NoNewline
        Write-Host $Data[$key] -ForegroundColor White
    }
}

Export-ModuleMember -Function Get-CleanupKnownFolderPath, Get-CleanupSystemDrive, `
    Test-ProtectedPath, Test-CleanupRoot, Test-CleanupPathSafety, `
    Get-FolderSize, Remove-ItemSafely, Clear-RecycleBinContents, New-CleanupResult, `
    Merge-CleanupResult, Add-CleanupResultIssue, Get-CleanupResultStatus, Format-Bytes, `
    Get-SystemInfo, Get-DiskInfo, Show-ProgressBar, Show-TaskResultLine, Show-Banner, `
    Write-InfoTable, Get-CleanupArchiveVersion, Initialize-CleanupPlan, `
    Set-CleanupPlanTaskContext, Register-CleanupPlanTask, Lock-CleanupPlan, `
    Get-CleanupPlanMode, Use-CleanupPlanAction, Complete-CleanupPlanActionGroup, `
    Complete-CleanupPlanTask, Stop-CleanupPlan
