#Requires -Version 5.1
<#
.SYNOPSIS
    Очистка дискового кэша браузеров.
.DESCRIPTION
    Затрагивается ИСКЛЮЧИТЕЛЬНО папка дискового кэша каждого браузера
    (Cache / Code Cache / GPUCache / cache2 и т.п.). История посещений,
    сохранённые пароли, куки, автозаполнение, закладки и открытые вкладки
    НЕ читаются и НЕ изменяются этим модулем ни при каких обстоятельствах.
#>

function Clear-BrowserCache {
    <#
    .SYNOPSIS
        Очищает кэш Chrome, Edge, Brave, Vivaldi, Opera и Firefox для
        всех найденных профилей текущего пользователя.
    #>
    [CmdletBinding()]
    param()
    $result = New-CleanupResult -TaskName 'Кэш браузеров'
    $localAppData = Get-CleanupKnownFolderPath -Name LocalApplicationData
    if (-not $localAppData) {
        Add-CleanupResultIssue -TaskResult $result -Status SkippedSafety `
            -Message 'Не удалось получить доверенный путь LocalAppData из системного API.'
        return $result
    }

    # --- Chromium-подобные браузеры -------------------------------------
    # У Chrome/Edge/Brave/Vivaldi кэш лежит в подпапках профиля внутри
    # "User Data". У Opera (тоже Chromium, но своя раскладка) кэш — прямо
    # в корне "Opera Stable", без подпапок Default/Profile N.
    $chromiumBrowsers = @(
        @{ Name = 'Google Chrome'; Root = (Join-Path $localAppData 'Google\Chrome\User Data'); FlatProfile = $false }
        @{ Name = 'Microsoft Edge'; Root = (Join-Path $localAppData 'Microsoft\Edge\User Data'); FlatProfile = $false }
        @{ Name = 'Brave'; Root = (Join-Path $localAppData 'BraveSoftware\Brave-Browser\User Data'); FlatProfile = $false }
        @{ Name = 'Vivaldi'; Root = (Join-Path $localAppData 'Vivaldi\User Data'); FlatProfile = $false }
        @{ Name = 'Opera'; Root = (Join-Path $localAppData 'Opera Software\Opera Stable'); FlatProfile = $true }
        @{ Name = 'Opera GX'; Root = (Join-Path $localAppData 'Opera Software\Opera GX Stable'); FlatProfile = $true }
    )
    $cacheSubfolders = @('Cache', 'Cache2', 'Code Cache', 'GPUCache', 'Media Cache', 'DawnCache', 'DawnGraphiteCache', 'GrShaderCache', 'ShaderCache')

    foreach ($browser in $chromiumBrowsers) {
        if (-not (Test-Path -LiteralPath $browser.Root)) { continue }

        $profileDirs = if ($browser.FlatProfile) {
            , (Get-Item -LiteralPath $browser.Root -Force)
        } else {
            Get-ChildItem -LiteralPath $browser.Root -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' }
        }

        $before = $result.BytesFreed
        foreach ($profileDir in $profileDirs) {
            foreach ($sub in $cacheSubfolders) {
                $cachePath = Join-Path $profileDir.FullName $sub
                if (-not (Test-Path -LiteralPath $cachePath)) { continue }
                $itemResult = Remove-ItemSafely -Path $cachePath -AllowedRoot $profileDir.FullName -Recurse
                Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $true
            }
        }
        Write-CleanupLog -Message "Кэш браузера '$($browser.Name)': освобождено $(Format-Bytes ($result.BytesFreed - $before))." -Level INFO -NoConsole
    }

    # --- Firefox ----------------------------------------------------------
    # Профили Firefox называются случайно: xxxxxxxx.default-release и т.п.
    $firefoxRoot = Join-Path $localAppData 'Mozilla\Firefox\Profiles'
    if (Test-Path -LiteralPath $firefoxRoot) {
        $before = $result.BytesFreed
        Get-ChildItem -LiteralPath $firefoxRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($sub in @('cache2', 'startupCache', 'shader-cache', 'OfflineCache')) {
                $cachePath = Join-Path $_.FullName $sub
                if (-not (Test-Path -LiteralPath $cachePath)) { continue }
                $itemResult = Remove-ItemSafely -Path $cachePath -AllowedRoot $_.FullName -Recurse
                Merge-CleanupResult -TaskResult $result -ItemResult $itemResult -IsContainer $true
            }
        }
        Write-CleanupLog -Message "Кэш браузера 'Firefox': освобождено $(Format-Bytes ($result.BytesFreed - $before))." -Level INFO -NoConsole
    }

    Write-CleanupLog -Message "Кэш браузеров: удалено папок $($result.FoldersRemoved), освобождено $(Format-Bytes $result.BytesFreed)." -Level OK
    return $result
}

Export-ModuleMember -Function Clear-BrowserCache
