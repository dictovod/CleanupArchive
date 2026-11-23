#Requires -Version 5.1
<#
.SYNOPSIS
    Очистка кэша шейдеров DirectX и видеодрайверов.
#>

function Clear-DirectXShaderCache {
    <#
    .SYNOPSIS
        Очищает D3DSCache и, если присутствуют, дополнительные кэши
        шейдеров NVIDIA/AMD. Все они автоматически пересоздаются
        драйвером/DirectX при следующем запуске приложений и игр.
    .DESCRIPTION
        У NVIDIA расположение DXCache менялось между версиями драйвера —
        в одних версиях он в AppData\Local\NVIDIA, в других (включая
        официально задокументированный Gaijin support) — в
        AppData\LocalLow\NVIDIA. Проверяются оба варианта.
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Кэш шейдеров DirectX'
    $localAppData = Get-CleanupKnownFolderPath -Name LocalApplicationData
    $userProfile = Get-CleanupKnownFolderPath -Name UserProfile
    if (-not $localAppData -or -not $userProfile) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message 'Не удалось получить доверенные пути профиля из системного API.'
        return $result
    }
    $localLow = Join-Path $userProfile 'AppData\LocalLow'
    $targets = @(
        (Join-Path $localAppData 'D3DSCache')
        (Join-Path $localAppData 'NVIDIA\DXCache')
        (Join-Path $localAppData 'NVIDIA\GLCache')
        (Join-Path $localLow 'NVIDIA\DXCache')
        (Join-Path $localLow 'NVIDIA\PerDriverCache')
        (Join-Path $localAppData 'AMD\DxCache')
        (Join-Path $localAppData 'AMD\DxcCache')
        (Join-Path $localAppData 'Ati\GLCache')
    )
    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target)) { continue }
        Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $isContainer = $_.PSIsContainer
            $itemResult = Remove-ItemSafely -Path $_.FullName -AllowedRoot $target -Recurse:$isContainer
            Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $isContainer
        }
    }
    Write-CleanupLog -Message "Кэш шейдеров DirectX: удалено объектов $($result.FilesRemoved + $result.FoldersRemoved), освобождено $(Format-Bytes $result.BytesFreed)." -Level OK
    return $result
}

Export-ModuleMember -Function Clear-DirectXShaderCache
