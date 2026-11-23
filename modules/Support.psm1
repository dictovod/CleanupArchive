#Requires -Version 5.1
<#
.SYNOPSIS
    Создание обезличенного диагностического пакета CleanupArchive.
#>

function ConvertTo-CleanupSanitizedText {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [string]$ProjectRoot
    )
    if ($null -eq $Text) { return '' }
    $knownLocalAppData = Get-CleanupKnownFolderPath -Name LocalApplicationData
    $knownAppData = Get-CleanupKnownFolderPath -Name ApplicationData
    $knownUserProfile = Get-CleanupKnownFolderPath -Name UserProfile
    $knownTemp = if ($knownLocalAppData) { Join-Path $knownLocalAppData 'Temp' } else { $null }
    $pairs = [System.Collections.Generic.List[object]]::new()
    $candidates = @(
        @{ Value = $ProjectRoot;       Token = '%CLEANUPARCHIVE_ROOT%' }
        @{ Value = $knownLocalAppData; Token = '%LOCALAPPDATA%' }
        @{ Value = $knownAppData;      Token = '%APPDATA%' }
        @{ Value = $knownUserProfile;  Token = '%USERPROFILE%' }
        @{ Value = $knownTemp;         Token = '%TEMP%' }
        @{ Value = $env:LOCALAPPDATA;  Token = '%LOCALAPPDATA%' }
        @{ Value = $env:APPDATA;       Token = '%APPDATA%' }
        @{ Value = $env:USERPROFILE;   Token = '%USERPROFILE%' }
        @{ Value = $env:TEMP;          Token = '%TEMP%' }
        @{ Value = $env:USERNAME;      Token = '<USER>' }
        @{ Value = $env:COMPUTERNAME;  Token = '<COMPUTER>' }
    )
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate.Value)) {
            $pairs.Add([PSCustomObject]@{ Value = [string]$candidate.Value; Token = [string]$candidate.Token })
            if ([string]$candidate.Value -match '\\') {
                $pairs.Add([PSCustomObject]@{ Value = ([string]$candidate.Value).Replace('\', '\\'); Token = [string]$candidate.Token })
            }
        }
    }

    $sanitized = $Text
    foreach ($pair in @($pairs | Sort-Object { $_.Value.Length } -Descending)) {
        $sanitized = [regex]::Replace(
            $sanitized,
            [regex]::Escape($pair.Value),
            $pair.Token,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    # Дополнительная страховка для путей чужих профилей, которые могли
    # встретиться в системном сообщении, но отсутствуют в переменных среды.
    $sanitized = [regex]::Replace(
        $sanitized,
        '(?i)([A-Z]:\\(?:\\)?Users\\(?:\\)?)[^\\\r\n"]+',
        '$1<USER>'
    )
    return $sanitized
}

function New-CleanupSupportBundle {
    <#
    .SYNOPSIS
        Создаёт ZIP с обезличенными журналами и конфигурацией.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$JsonLogPath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$ProjectRoot
    )
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $bundlePath = Join-Path $OutputDirectory "support_$timestamp.zip"
    $suffix = 1
    while (Test-Path -LiteralPath $bundlePath) {
        $bundlePath = Join-Path $OutputDirectory "support_${timestamp}_$suffix.zip"
        $suffix++
    }

    # ZIP формируется прямо в памяти/потоке, без временной папки и её
    # рекурсивного удаления. Это исключает отдельный класс ошибок путей.
    $entries = [ordered]@{}
    if (Test-Path -LiteralPath $LogPath) {
        $text = Get-Content -LiteralPath $LogPath -Raw -Encoding UTF8
        $entries['cleanup.log'] = ConvertTo-CleanupSanitizedText -Text $text -ProjectRoot $ProjectRoot
    }
    if ($JsonLogPath -and (Test-Path -LiteralPath $JsonLogPath)) {
        $jsonText = Get-Content -LiteralPath $JsonLogPath -Raw -Encoding UTF8
        $entries['cleanup.jsonl'] = ConvertTo-CleanupSanitizedText -Text $jsonText -ProjectRoot $ProjectRoot
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        $configText = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        $entries['config.json'] = ConvertTo-CleanupSanitizedText -Text $configText -ProjectRoot $ProjectRoot
    }

    $entries['support-info.txt'] = @(
        'CleanupArchive — обезличенный диагностический пакет'
        "Версия CleanupArchive : $(Get-CleanupArchiveVersion)"
        "Создан               : $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')"
        "PowerShell           : $($PSVersionTable.PSVersion)"
        "ОС                   : $([System.Environment]::OSVersion.VersionString)"
        "64-разрядная ОС      : $([System.Environment]::Is64BitOperatingSystem)"
        ''
        'Имена пользователя и компьютера, а также пользовательские пути заменены маркерами.'
    ) -join "`r`n"

    $entries['README.txt'] = @(
        'Этот ZIP предназначен для безопасной передачи разработчику CleanupArchive.'
        'Он содержит обезличенные журналы последнего запуска и копию config.json.'
        'Содержимое пакета можно дополнительно проверить обычным архиватором перед отправкой.'
    ) -join "`r`n"

    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    $fileStream = $null
    $archive = $null
    try {
        $fileStream = [System.IO.File]::Open($bundlePath, [System.IO.FileMode]::CreateNew, `
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $archive = [System.IO.Compression.ZipArchive]::new(
            $fileStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false,
            [System.Text.Encoding]::UTF8
        )
        foreach ($entryName in $entries.Keys) {
            $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $writer = [System.IO.StreamWriter]::new($entry.Open(), [System.Text.UTF8Encoding]::new($true))
            try { $writer.Write([string]$entries[$entryName]) } finally { $writer.Dispose() }
        }
        $archive.Dispose()
        $archive = $null
        $fileStream.Dispose()
        $fileStream = $null
        return (Get-Item -LiteralPath $bundlePath -Force).FullName
    } catch {
        if ($archive) { $archive.Dispose() }
        if ($fileStream) { $fileStream.Dispose() }
        if (Test-Path -LiteralPath $bundlePath) { [System.IO.File]::Delete($bundlePath) }
        throw
    }
}

Export-ModuleMember -Function ConvertTo-CleanupSanitizedText, New-CleanupSupportBundle
