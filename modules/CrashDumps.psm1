#Requires -Version 5.1
<#
.SYNOPSIS
    Очистка отчётов об ошибках Windows (WER) и дампов памяти.
#>

function Clear-ErrorReportingFiles {
    <#
    .SYNOPSIS
        Очищает очередь и архив отчётов Windows Error Reporting (WER).
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Отчёты об ошибках (WER)'
    $programData = Get-CleanupKnownFolderPath -Name CommonApplicationData
    $localAppData = Get-CleanupKnownFolderPath -Name LocalApplicationData
    if (-not $programData -or -not $localAppData) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message 'Не удалось получить доверенные пути ProgramData/LocalAppData из системного API.'
        return $result
    }
    $targets = @(
        (Join-Path $programData 'Microsoft\Windows\WER\ReportQueue')
        (Join-Path $programData 'Microsoft\Windows\WER\ReportArchive')
        (Join-Path $programData 'Microsoft\Windows\WER\Temp')
        (Join-Path $localAppData 'Microsoft\Windows\WER\ReportQueue')
        (Join-Path $localAppData 'Microsoft\Windows\WER\ReportArchive')
    )
    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target)) { continue }
        Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $isContainer = $_.PSIsContainer
            $itemResult = Remove-ItemSafely -Path $_.FullName -AllowedRoot $target -Recurse:$isContainer
            Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $isContainer
        }
    }
    Write-CleanupLog -Message "Отчёты об ошибках: удалено объектов $($result.FilesRemoved + $result.FoldersRemoved), освобождено $(Format-Bytes $result.BytesFreed)." -Level OK
    return $result
}

function Clear-CrashDumps {
    <#
    .SYNOPSIS
        Очищает пользовательские мини-дампы приложений, системные
        Minidump, полный дамп памяти (MEMORY.DMP) и LiveKernelReports.
    .DESCRIPTION
        Эти файлы нужны только для диагностики уже произошедших сбоев;
        их удаление не влияет на работу системы и ничего не "чинит" и не
        "ломает" — это чистое освобождение места.
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Дампы памяти и Minidump'
    $localAppData = Get-CleanupKnownFolderPath -Name LocalApplicationData
    $windowsDirectory = Get-CleanupKnownFolderPath -Name Windows
    if (-not $localAppData -or -not $windowsDirectory) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message 'Не удалось получить доверенные системные пути из API Windows.'
        return $result
    }

    $userDumps = Join-Path $localAppData 'CrashDumps'
    if (Test-Path -LiteralPath $userDumps) {
        Get-ChildItem -LiteralPath $userDumps -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $isContainer = $_.PSIsContainer
            $itemResult = Remove-ItemSafely -Path $_.FullName -AllowedRoot $userDumps -Recurse:$isContainer
            Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $isContainer
        }
    }

    $miniDumpDir = Join-Path $windowsDirectory 'Minidump'
    if (Test-Path -LiteralPath $miniDumpDir) {
        Get-ChildItem -LiteralPath $miniDumpDir -Filter '*.dmp' -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $itemResult = Remove-ItemSafely -Path $_.FullName -AllowedRoot $miniDumpDir
            Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $false
        }
    }

    $memoryDump = Join-Path $windowsDirectory 'MEMORY.DMP'
    if (Test-Path -LiteralPath $memoryDump) {
        $itemResult = Remove-ItemSafely -Path $memoryDump -AllowedRoot $windowsDirectory
        Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $false
    }

    $liveKernel = Join-Path $windowsDirectory 'LiveKernelReports'
    if (Test-Path -LiteralPath $liveKernel) {
        Get-ChildItem -LiteralPath $liveKernel -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $isContainer = $_.PSIsContainer
            $itemResult = Remove-ItemSafely -Path $_.FullName -AllowedRoot $liveKernel -Recurse:$isContainer
            Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $isContainer
        }
    }

    Write-CleanupLog -Message "Дампы памяти: удалено объектов $($result.FilesRemoved + $result.FoldersRemoved), освобождено $(Format-Bytes $result.BytesFreed)." -Level OK
    return $result
}

Export-ModuleMember -Function Clear-ErrorReportingFiles, Clear-CrashDumps
