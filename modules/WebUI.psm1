#Requires -Version 5.1
<#
.SYNOPSIS
    Локальный веб-интерфейс настроек CleanupArchive.
.DESCRIPTION
    Поднимает простой HTTP-сервер на 127.0.0.1 (System.Net.HttpListener —
    входит в состав .NET, никаких дополнительных пакетов не требуется) и
    отдаёт через него страницу настроек (web\index.html) и небольшой JSON
    API поверх config.json. Сервер слушает ТОЛЬКО адрес обратной петли
    (127.0.0.1) — то есть недоступен с других устройств в сети.

    Сама очистка отсюда НЕ запускается напрямую и не встраивается в
    HTTP-обработчик: кнопки "Запустить" и "Предпросмотр" на странице лишь
    открывают Cleanup.ps1 в обычном, уже проверенном консольном режиме
    (том же самом, что и Start.bat) — со всеми его проверками прав,
    предпросмотром и запросом подтверждения. Так весь код, который реально
    что-то удаляет, остаётся в одном месте.
#>

function Invoke-WebUIRequest {
    <#
    .SYNOPSIS
        Обрабатывает один HTTP-запрос: простая маршрутизация по пути.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$IndexHtml,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$ReportsDir,
        [Parameter(Mandatory)][string]$CleanupScript
    )
    $req = $Context.Request
    $res = $Context.Response

    function Send-RawText {
        param([string]$Text, [string]$ContentType = 'text/plain; charset=utf-8', [int]$Status = 200)
        $res.StatusCode = $Status
        $res.ContentType = $ContentType
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
    }
    function Send-JsonObject {
        param($Object, [int]$Status = 200)
        Send-RawText -Text ($Object | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json; charset=utf-8' -Status $Status
    }

    $path = $req.Url.AbsolutePath

    try {
        switch -Regex ($path) {
            '^/$' {
                Send-RawText -Text $IndexHtml -ContentType 'text/html; charset=utf-8'
                break
            }
            '^/api/config$' {
                if ($req.HttpMethod -eq 'GET') {
                    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                    Send-JsonObject -Object $cfg
                } elseif ($req.HttpMethod -eq 'POST') {
                    $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                    $body = $reader.ReadToEnd()
                    $reader.Close()
                    try {
                        $incoming = $body | ConvertFrom-Json -ErrorAction Stop
                        $boolKeys = @('RunSFC', 'RunRestoreHealth', 'RunComponentCleanup', 'CleanPrefetch', `
                                'FlushDNS', 'CreateHTMLReport', 'VerboseLog', 'CleanDefenderCache', `
                                'CleanEventLogs', 'CleanRestorePoints')
                        $clean = [ordered]@{}
                        foreach ($k in $boolKeys) {
                            $clean[$k] = [bool]($incoming.$k)
                        }
                        $keep = 3
                        if ($incoming.PSObject.Properties.Name -contains 'KeepRestorePoints') {
                            [void][int]::TryParse("$($incoming.KeepRestorePoints)", [ref]$keep)
                        }
                        $clean['KeepRestorePoints'] = [Math]::Max(1, [Math]::Min(50, $keep))
                        ($clean | ConvertTo-Json) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
                        Send-JsonObject -Object @{ ok = $true; config = $clean }
                    } catch {
                        Send-JsonObject -Status 400 -Object @{ ok = $false; error = $_.Exception.Message }
                    }
                } else {
                    Send-RawText -Status 405 -Text 'Method not allowed'
                }
                break
            }
            '^/api/reports$' {
                $items = @()
                if (Test-Path -LiteralPath $ReportsDir) {
                    $items = @(Get-ChildItem -LiteralPath $ReportsDir -Filter 'report_*.html' -File -ErrorAction SilentlyContinue |
                            Sort-Object LastWriteTime -Descending | Select-Object -First 15 |
                            ForEach-Object {
                                @{
                                    name     = $_.Name
                                    modified = $_.LastWriteTime.ToString('dd.MM.yyyy HH:mm')
                                    sizeKb   = [Math]::Round($_.Length / 1KB, 1)
                                }
                            })
                }
                Send-JsonObject -Object @($items)
                break
            }
            '^/reports/([A-Za-z0-9_\-\.]+\.html)$' {
                $fileName = $Matches[1]
                # Разрешаем отдавать ТОЛЬКО файлы вида report_*.html из папки
                # reports\ — без этого регулярного выражения запрос вида
                # /reports/..%2f..%2fconfig.json мог бы прочитать чужой файл.
                if ($fileName -notmatch '^report_[0-9_\-]+\.html$') {
                    Send-RawText -Status 404 -Text 'Not found'
                    break
                }
                $full = Join-Path $ReportsDir $fileName
                if (-not (Test-Path -LiteralPath $full)) {
                    Send-RawText -Status 404 -Text 'Not found'
                } else {
                    $html = Get-Content -LiteralPath $full -Raw -Encoding UTF8
                    Send-RawText -Text $html -ContentType 'text/html; charset=utf-8'
                }
                break
            }
            '^/api/run$' {
                if ($req.HttpMethod -ne 'POST') { Send-RawText -Status 405 -Text 'Method not allowed'; break }
                try {
                    $powerShellPath = (Get-Process -Id $PID -ErrorAction Stop).Path
                    if (-not $powerShellPath -or -not (Test-Path -LiteralPath $powerShellPath)) {
                        throw 'Не удалось определить путь текущего процесса PowerShell.'
                    }
                    Start-Process -FilePath $powerShellPath `
                        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$CleanupScript`"") `
                        -ErrorAction Stop | Out-Null
                    Send-JsonObject -Object @{ ok = $true; message = 'CleanupArchive запущен в новом окне.' }
                } catch {
                    Send-JsonObject -Status 500 -Object @{ ok = $false; error = $_.Exception.Message }
                }
                break
            }
            '^/api/preview$' {
                if ($req.HttpMethod -ne 'POST') { Send-RawText -Status 405 -Text 'Method not allowed'; break }
                try {
                    $powerShellPath = (Get-Process -Id $PID -ErrorAction Stop).Path
                    if (-not $powerShellPath -or -not (Test-Path -LiteralPath $powerShellPath)) {
                        throw 'Не удалось определить путь текущего процесса PowerShell.'
                    }
                    Start-Process -FilePath $powerShellPath `
                        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$CleanupScript`"", '-WhatIf') `
                        -ErrorAction Stop | Out-Null
                    Send-JsonObject -Object @{ ok = $true; message = 'Предпросмотр запущен в новом окне.' }
                } catch {
                    Send-JsonObject -Status 500 -Object @{ ok = $false; error = $_.Exception.Message }
                }
                break
            }
            default {
                Send-RawText -Status 404 -Text 'Not found'
            }
        }
    } catch {
        try {
            Send-JsonObject -Status 500 -Object @{ ok = $false; error = $_.Exception.Message }
        } catch { }
    }
}

function Start-CleanupWebUI {
    <#
    .SYNOPSIS
        Запускает локальный веб-сервер настроек и открывает браузер.
    .DESCRIPTION
        Пробует несколько портов подряд (на случай, если первый занят),
        слушает строго 127.0.0.1 (не доступен из сети), обслуживает
        запросы в цикле, пока окно не будет закрыто (Ctrl+C).
    .PARAMETER ProjectRoot
        Корневая папка проекта (там, где лежат config.json, Cleanup.ps1, web\).
    .PARAMETER Port
        Предпочитаемый порт. При занятости пробуются Port+1 .. Port+4.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [int]$Port = 8791
    )

    $indexPath = Join-Path $ProjectRoot 'web\index.html'
    if (-not (Test-Path -LiteralPath $indexPath)) {
        Write-Host " Не найден файл интерфейса: $indexPath" -ForegroundColor Red
        return
    }
    $indexHtml = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8
    $configPath = Join-Path $ProjectRoot 'config.json'
    $reportsDir = Join-Path $ProjectRoot 'reports'
    $cleanupScript = Join-Path $ProjectRoot 'Cleanup.ps1'

    $listener = $null
    $chosenPort = $null
    foreach ($candidate in @($Port, $Port + 1, $Port + 2, $Port + 3, $Port + 4)) {
        try {
            $l = New-Object System.Net.HttpListener
            $l.Prefixes.Add("http://127.0.0.1:$candidate/")
            $l.Start()
            $listener = $l
            $chosenPort = $candidate
            break
        } catch {
            continue
        }
    }

    if (-not $listener) {
        Write-Host ' Не удалось занять ни один порт (8791-8795).' -ForegroundColor Red
        Write-Host ' Закройте программы, которые могут их использовать, или запустите Settings.bat от имени администратора.' -ForegroundColor Red
        return
    }

    $url = "http://127.0.0.1:$chosenPort/"
    Write-Host ''
    Write-Host " Веб-интерфейс настроек CleanupArchive запущен:" -ForegroundColor Cyan
    Write-Host " $url" -ForegroundColor White
    Write-Host ''
    Write-Host ' Сейчас откроется браузер. Сервер слушает только этот компьютер' -ForegroundColor DarkGray
    Write-Host ' (127.0.0.1) — по сети он недоступен.' -ForegroundColor DarkGray
    Write-Host ' Чтобы остановить сервер — закройте это окно или нажмите Ctrl+C.' -ForegroundColor DarkGray
    Write-Host ''

    try { Start-Process $url } catch {
        Write-Host " Не удалось открыть браузер автоматически — откройте ссылку выше вручную." -ForegroundColor Yellow
    }

    try {
        while ($listener.IsListening) {
            $context = $listener.GetContext()
            Invoke-WebUIRequest -Context $context -IndexHtml $indexHtml -ConfigPath $configPath `
                -ReportsDir $reportsDir -CleanupScript $cleanupScript
        }
    } catch [System.Net.HttpListenerException] {
        # Возникает при остановке listener'а (например, закрытием окна) — не ошибка.
    } finally {
        $listener.Stop()
        $listener.Close()
    }
}

Export-ModuleMember -Function Start-CleanupWebUI, Invoke-WebUIRequest
