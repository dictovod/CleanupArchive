#Requires -Version 5.1
<#
.SYNOPSIS
    Очистка временной папки пользователя (%TEMP%).
#>

function Clear-UserTempFiles {
    <#
    .SYNOPSIS
        Удаляет содержимое %TEMP% текущего пользователя.
    .DESCRIPTION
        Удаляются все файлы и папки внутри %TEMP%. Объекты, занятые другим
        процессом (например, лог активно работающей программы), безопасно
        пропускаются — см. Remove-ItemSafely.
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName '%TEMP% пользователя'
    $localAppData = Get-CleanupKnownFolderPath -Name LocalApplicationData
    $userProfile = Get-CleanupKnownFolderPath -Name UserProfile
    $expectedTarget = if ($localAppData) { Join-Path $localAppData 'Temp' } else { $null }
    $target = $env:TEMP

    if ([string]::IsNullOrWhiteSpace($target) -or -not (Test-Path -LiteralPath $target)) {
        Write-CleanupLog -Message '%TEMP% не найден, пропущено.' -Level WARN -NoConsole
        return $result
    }
    try {
        $targetFull = [System.IO.Path]::GetFullPath($target).TrimEnd('\')
        $expectedFull = [System.IO.Path]::GetFullPath($expectedTarget).TrimEnd('\')
    } catch {
        $targetFull = $null
        $expectedFull = $null
    }
    if (-not $targetFull -or -not $expectedFull -or `
        -not $targetFull.Equals($expectedFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message '%TEMP% отличается от стандартного доверенного каталога LocalAppData\Temp; задача безопасно пропущена.' -Path $target
        Write-CleanupLog -Message '%TEMP% не совпадает с доверенным каталогом LocalAppData\Temp, пропущено.' -Level WARN -NoConsole
        return $result
    }
    $target = $targetFull
    if (-not (Test-CleanupRoot -Path $target -TrustedBase @($localAppData, $userProfile))) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message '%TEMP% находится вне профиля текущего пользователя; задача безопасно пропущена.' -Path $target
        Write-CleanupLog -Message '%TEMP% находится вне доверенной области профиля, пропущено.' -Level WARN -NoConsole
        return $result
    }

    Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $isContainer = $_.PSIsContainer
        $itemResult = Remove-ItemSafely -Path $_.FullName -AllowedRoot $target -Recurse:$isContainer
        Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $isContainer
    }

    Write-CleanupLog -Message "%TEMP%: удалено файлов $($result.FilesRemoved), папок $($result.FoldersRemoved), освобождено $(Format-Bytes $result.BytesFreed)." -Level OK
    return $result
}

Export-ModuleMember -Function Clear-UserTempFiles
