#Requires -Version 5.1
<#
.SYNOPSIS
    Очистка системных временных файлов и мелких служебных кэшей Windows.
.DESCRIPTION
    Модуль объединяет несколько тематически близких, но небольших по
    объёму кода задач очистки, для которых в структуре проекта не
    предусмотрено отдельных файлов: временные файлы Windows, Prefetch,
    кэш шрифтов, кэш Windows Defender, безопасные временные файлы
    установщика, старые лог-файлы Windows, временные файлы OneDrive
    и Office.
#>

function Clear-WindowsTempFiles {
    <#
    .SYNOPSIS
        Очищает C:\Windows\Temp.
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Временные файлы Windows'
    $windowsDirectory = Get-CleanupKnownFolderPath -Name Windows
    if (-not $windowsDirectory) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message 'Не удалось получить доверенный каталог Windows из системного API.'
        return $result
    }
    $target = Join-Path $windowsDirectory 'Temp'
    if (-not (Test-Path -LiteralPath $target)) { return $result }

    Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $isContainer = $_.PSIsContainer
        $itemResult = Remove-ItemSafely -Path $_.FullName -AllowedRoot $target -Recurse:$isContainer
        Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $isContainer
    }
    Write-CleanupLog -Message "Windows\Temp: удалено файлов $($result.FilesRemoved), папок $($result.FoldersRemoved), освобождено $(Format-Bytes $result.BytesFreed)." -Level OK
    return $result
}

function Clear-PrefetchFiles {
    <#
    .SYNOPSIS
        Очищает кэш Prefetch (*.pf). Только по явному включению в config.json
        (CleanPrefetch), т.к. Windows использует эти файлы для ускорения
        запуска программ — они безвредно пересоздаются заново, но сразу
        после очистки возможно небольшое замедление первого запуска.
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Кэш Prefetch'
    $windowsDirectory = Get-CleanupKnownFolderPath -Name Windows
    if (-not $windowsDirectory) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message 'Не удалось получить доверенный каталог Windows из системного API.'
        return $result
    }
    $target = Join-Path $windowsDirectory 'Prefetch'
    if (-not (Test-Path -LiteralPath $target)) { return $result }

    Get-ChildItem -LiteralPath $target -Filter '*.pf' -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $itemResult = Remove-ItemSafely -Path $_.FullName -AllowedRoot $target
        Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $false
    }
    Write-CleanupLog -Message "Prefetch: удалено файлов $($result.FilesRemoved), освобождено $(Format-Bytes $result.BytesFreed)." -Level OK
    return $result
}

function Clear-FontCache {
    <#
    .SYNOPSIS
        Очищает кэш службы Windows Font Cache и FNTCACHE.DAT.
    .DESCRIPTION
        Служба на время очистки останавливается и запускается заново,
        чтобы файлы не были заняты.

        FNTCACHE.DAT лежит прямо в System32, который в остальном полностью
        защищён (см. Test-ProtectedPath) — но это единственный, явно и
        жёстко прописанный (без масок и рекурсии) файл-исключение: это
        именно кэш (это буквально его имя), который Windows пересоздаёт
        сама, и его удаление для устранения проблем с кэшем шрифтов
        задокументировано Microsoft. Поэтому он удаляется отдельным, явным
        шагом через общий Remove-ItemSafely с точечным разрешением только
        для этого полного пути.
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Кэш шрифтов'
    $windowsDirectory = Get-CleanupKnownFolderPath -Name Windows
    if (-not $windowsDirectory) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message 'Не удалось получить доверенный каталог Windows из системного API.'
        return $result
    }
    $wasRunning = Stop-ServiceSafely -Name 'FontCache' -TaskResult $result

    $target = Join-Path $windowsDirectory 'ServiceProfiles\LocalService\AppData\Local\FontCache'
    if (Test-Path -LiteralPath $target) {
        Get-ChildItem -LiteralPath $target -Filter '*.dat' -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $itemResult = Remove-ItemSafely -Path $_.FullName -AllowedRoot $target
            Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $false
        }
    }

    $fntCacheDat = Join-Path $windowsDirectory 'System32\FNTCACHE.DAT'
    if (Test-Path -LiteralPath $fntCacheDat) {
        # Единственное точечное исключение внутри защищённого System32. Оно
        # всё равно проходит общий план, проверку точного пути и reparse point.
        $itemResult = Remove-ItemSafely -Path $fntCacheDat -AllowedRoot $windowsDirectory `
            -AllowedProtectedExactPath $fntCacheDat
        Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $false
    }

    if ($wasRunning) { Start-ServiceSafely -Name 'FontCache' -TaskResult $result }
    Write-CleanupLog -Message "Кэш шрифтов: освобождено $(Format-Bytes $result.BytesFreed)." -Level OK
    return $result
}

function Clear-WindowsDefenderCache {
    <#
    .SYNOPSIS
        Очищает кэш сканирований Windows Defender (CacheManager).
    .DESCRIPTION
        Затрагивается ТОЛЬКО кэш истории сканирований. Файлы платформы
        Defender (ProgramData\Microsoft\Windows Defender\Platform) защищены
        и никогда не удаляются — см. Test-ProtectedPath.
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Кэш Windows Defender'
    $programData = Get-CleanupKnownFolderPath -Name CommonApplicationData
    if (-not $programData) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message 'Не удалось получить доверенный каталог ProgramData из системного API.'
        return $result
    }
    $target = Join-Path $programData 'Microsoft\Windows Defender\Scans\History\CacheManager'
    if (-not (Test-Path -LiteralPath $target)) { return $result }

    Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $isContainer = $_.PSIsContainer
        $itemResult = Remove-ItemSafely -Path $_.FullName -AllowedRoot $target -Recurse:$isContainer
        Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $isContainer
    }
    Write-CleanupLog -Message "Кэш Windows Defender: освобождено $(Format-Bytes $result.BytesFreed)." -Level OK
    return $result
}

function Clear-InstallerTempFiles {
    <#
    .SYNOPSIS
        Удаляет только заведомо безопасные временные файлы установщика.
    .DESCRIPTION
        ВАЖНО: папка Windows\Installer (кэш MSI/MSP) сюда НЕ входит и
        никогда не трогается — она нужна Windows для последующего ремонта
        и удаления уже установленных программ; её удаление сторонними
        "чистильщиками" — частая причина поломки деинсталляции ПО.
        Очищаются только временные *.msi/*.msp/MSI*.tmp в %TEMP% и
        Windows\Temp, которые Windows создаёт и удаляет сама во время
        установки и в норме не должны накапливаться.
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Временные файлы установщика'
    $windowsDirectory = Get-CleanupKnownFolderPath -Name Windows
    $localAppData = Get-CleanupKnownFolderPath -Name LocalApplicationData
    if (-not $windowsDirectory -or -not $localAppData) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message 'Не удалось получить доверенные системные пути из API Windows.'
        return $result
    }
    $userTemp = Join-Path $localAppData 'Temp'
    $windowsTemp = Join-Path $windowsDirectory 'Temp'
    $patterns = @(
        @{ Dir = $userTemp; Filter = '*.msi' }
        @{ Dir = $userTemp; Filter = '*.msp' }
        @{ Dir = $userTemp; Filter = 'MSI*.tmp' }
        @{ Dir = $windowsTemp; Filter = '*.msi' }
        @{ Dir = $windowsTemp; Filter = '*.msp' }
        @{ Dir = $windowsTemp; Filter = 'MSI*.tmp' }
    )
    foreach ($p in $patterns) {
        if (-not (Test-Path -LiteralPath $p.Dir)) { continue }
        Get-ChildItem -LiteralPath $p.Dir -Filter $p.Filter -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $itemResult = Remove-ItemSafely -Path $_.FullName -AllowedRoot $p.Dir
            Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $false
        }
    }
    Write-CleanupLog -Message "Временные файлы установщика: освобождено $(Format-Bytes $result.BytesFreed)." -Level OK
    return $result
}

function Clear-OldWindowsLogFiles {
    <#
    .SYNOPSIS
        Очищает известные крупные текстовые лог-файлы Windows (не журналы
        событий — те обрабатывает модуль EventLogs).
    .DESCRIPTION
        CBS.log, DISM.log и setupapi-логи могут вырастать до сотен
        мегабайт на системах с долгой историей обновлений. Здесь
        перечислены только конкретные, точно известные файлы — никаких
        рекурсивных удалений целых папок C:\Windows\INF или C:\Windows\Logs.
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Старые лог-файлы Windows'
    $windowsDirectory = Get-CleanupKnownFolderPath -Name Windows
    if (-not $windowsDirectory) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message 'Не удалось получить доверенный каталог Windows из системного API.'
        return $result
    }
    $targets = @(
        (Join-Path $windowsDirectory 'Logs\CBS\CBS.log')
        (Join-Path $windowsDirectory 'Logs\DISM\dism.log')
        (Join-Path $windowsDirectory 'INF\setupapi.dev.log')
        (Join-Path $windowsDirectory 'INF\setupapi.app.log')
        (Join-Path $windowsDirectory 'INF\setupapi.offline.log')
        (Join-Path $windowsDirectory 'Panther\setupact.log')
        (Join-Path $windowsDirectory 'Panther\setuperr.log')
    )
    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target)) { continue }
        $itemResult = Remove-ItemSafely -Path $target -AllowedRoot (Split-Path $target -Parent)
        Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $false
    }
    Write-CleanupLog -Message "Старые логи Windows: удалено файлов $($result.FilesRemoved), освобождено $(Format-Bytes $result.BytesFreed)." -Level OK
    return $result
}

function Clear-OneDriveTempFiles {
    <#
    .SYNOPSIS
        Очищает служебные логи и временные файлы клиента OneDrive.
    .DESCRIPTION
        Затрагиваются только логи и служебные данные самого приложения
        OneDrive. Синхронизируемые пользовательские файлы в папке OneDrive
        этот модуль не открывает и не трогает.
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Временные файлы OneDrive'
    $localAppData = Get-CleanupKnownFolderPath -Name LocalApplicationData
    if (-not $localAppData) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message 'Не удалось получить доверенный путь LocalAppData из системного API.'
        return $result
    }
    $targets = @(
        (Join-Path $localAppData 'Microsoft\OneDrive\logs')
        (Join-Path $localAppData 'Microsoft\OneDrive\setup\logs')
    )
    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target)) { continue }
        Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $isContainer = $_.PSIsContainer
            $itemResult = Remove-ItemSafely -Path $_.FullName -AllowedRoot $target -Recurse:$isContainer
            Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $isContainer
        }
    }
    Write-CleanupLog -Message "Временные файлы OneDrive: освобождено $(Format-Bytes $result.BytesFreed)." -Level OK
    return $result
}

function Clear-OfficeTempFiles {
    <#
    .SYNOPSIS
        Очищает временные lock-файлы и кэш файлов Microsoft Office.
    .DESCRIPTION
        ВАЖНО: папка UnsavedFiles никогда не трогается — там Office хранит
        несохранённые документы пользователя (функция автовосстановления).
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Временные файлы Office'
    $localAppData = Get-CleanupKnownFolderPath -Name LocalApplicationData
    if (-not $localAppData) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message 'Не удалось получить доверенный путь LocalAppData из системного API.'
        return $result
    }
    $userTemp = Join-Path $localAppData 'Temp'

    # Файлы блокировки открытых документов: ~$document.docx и т.п.
    if (Test-Path -LiteralPath $userTemp) {
        Get-ChildItem -LiteralPath $userTemp -Filter '~$*' -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $itemResult = Remove-ItemSafely -Path $_.FullName -AllowedRoot $userTemp
            Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $false
        }
    }

    # Кэш файлов Office (OfficeFileCache) для каждой установленной версии.
    $officeRoot = Join-Path $localAppData 'Microsoft\Office'
    if (Test-Path -LiteralPath $officeRoot) {
        Get-ChildItem -LiteralPath $officeRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $cachePath = Join-Path $_.FullName 'OfficeFileCache'
            if (Test-Path -LiteralPath $cachePath) {
                $itemResult = Remove-ItemSafely -Path $cachePath -AllowedRoot $_.FullName -Recurse
                Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $true
            }
        }
    }
    Write-CleanupLog -Message "Временные файлы Office: освобождено $(Format-Bytes $result.BytesFreed)." -Level OK
    return $result
}

Export-ModuleMember -Function Clear-WindowsTempFiles, Clear-PrefetchFiles, Clear-FontCache, `
    Clear-WindowsDefenderCache, Clear-InstallerTempFiles, Clear-OldWindowsLogFiles, `
    Clear-OneDriveTempFiles, Clear-OfficeTempFiles
