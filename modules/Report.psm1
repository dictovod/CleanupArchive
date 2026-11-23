#Requires -Version 5.1
<#
.SYNOPSIS
    Формирование HTML-отчёта об очистке.
#>

function New-HtmlReport {
    <#
    .SYNOPSIS
        Создаёт HTML-отчёт с общей сводкой и детализацией по каждой задаче.
    .PARAMETER OutputDirectory
        Папка reports\, куда сохраняется файл отчёта.
    .PARAMETER SystemInfo
        Объект из Get-SystemInfo.
    .PARAMETER BeforeDisk
        Объект из Get-DiskInfo, снятый до очистки.
    .PARAMETER AfterDisk
        Объект из Get-DiskInfo, снятый после очистки.
    .PARAMETER TaskResults
        Список объектов-результатов всех выполненных задач.
    .PARAMETER Duration
        Затраченное время в виде TimeSpan.
    .OUTPUTS
        Полный путь к созданному .html файлу.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)]$SystemInfo,
        [Parameter(Mandatory)]$BeforeDisk,
        [Parameter(Mandatory)]$AfterDisk,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$TaskResults,
        [Parameter(Mandatory)][TimeSpan]$Duration
    )

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $reportPath = Join-Path $OutputDirectory "report_$timestamp.html"

    $totalFiles = ($TaskResults | Measure-Object -Property FilesRemoved -Sum).Sum
    $totalFolders = ($TaskResults | Measure-Object -Property FoldersRemoved -Sum).Sum
    $totalSkipped = ($TaskResults | ForEach-Object { $_.Skipped.Count } | Measure-Object -Sum).Sum
    $totalErrors = ($TaskResults | ForEach-Object { $_.Errors.Count } | Measure-Object -Sum).Sum
    $freedActual = [Math]::Max([long]0, $AfterDisk.FreeBytes - $BeforeDisk.FreeBytes)

    $rowsHtml = ($TaskResults | ForEach-Object {
        $t = $_
        $status = Get-CleanupResultStatus -Result $t
        $statusText = switch ($status) {
            'Failed'  { 'Ошибка' }
            'Warning' { 'Частично' }
            default   { 'Готово' }
        }
        $statusClass = switch ($status) {
            'Failed'  { 'status-bad' }
            'Warning' { 'status-warn' }
            default   { 'status-ok' }
        }
        $details = [System.Collections.Generic.List[string]]::new()
        foreach ($issue in @($t.Issues)) {
            $pathText = if ($issue.Path) { "$($issue.Path): " } else { '' }
            $details.Add("[$($issue.Status)] $pathText$($issue.Reason)")
        }
        foreach ($skippedText in @($t.Skipped)) {
            $alreadyDetailed = $false
            foreach ($detailText in $details) {
                if (($detailText).IndexOf([string]$skippedText, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $alreadyDetailed = $true
                    break
                }
            }
            if (-not $alreadyDetailed) {
                $details.Add("[Пропущено] $skippedText")
            }
        }
        foreach ($errorText in @($t.Errors)) {
            $alreadyDetailed = $false
            foreach ($detailText in $details) {
                if (($detailText).IndexOf([string]$errorText, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $alreadyDetailed = $true
                    break
                }
            }
            if (-not $alreadyDetailed) { $details.Add("[Failed] $errorText") }
        }
        $detailsHtml = if ($details.Count -gt 0) {
            $items = ($details | ForEach-Object { '<li>' + [System.Net.WebUtility]::HtmlEncode($_) + '</li>' }) -join ''
            "<details><summary>Показать ($($details.Count))</summary><ul>$items</ul></details>"
        } else { '—' }
        @"
        <tr>
            <td>$([System.Net.WebUtility]::HtmlEncode($t.TaskName))</td>
            <td><span class="status $statusClass">$statusText</span></td>
            <td>$($t.FilesRemoved)</td>
            <td>$($t.FoldersRemoved)</td>
            <td>$(Format-Bytes $t.BytesFreed)</td>
            <td>$($t.Skipped.Count)</td>
            <td class="$(if ($t.Errors.Count -gt 0) { 'err' } else { '' })">$($t.Errors.Count)</td>
            <td class="details-cell">$detailsHtml</td>
        </tr>
"@
    }) -join "`n"

    $html = @"
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Отчёт об очистке — CleanupArchive</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    font-family: 'Segoe UI', Tahoma, Geneva, sans-serif;
    background: #0f172a;
    color: #e2e8f0;
    margin: 0;
    padding: 32px 16px;
  }
  .card {
    max-width: 960px;
    margin: 0 auto;
    background: #1e293b;
    border-radius: 14px;
    padding: 32px;
    box-shadow: 0 10px 30px rgba(0,0,0,.4);
  }
  h1 { color: #38bdf8; margin-top: 0; font-size: 26px; }
  h2 { color: #93c5fd; border-bottom: 1px solid #334155; padding-bottom: 8px; margin-top: 32px; font-size: 18px; }
  table { width: 100%; border-collapse: collapse; margin-top: 12px; }
  th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #334155; font-size: 14px; }
  th { color: #94a3b8; font-size: 12px; text-transform: uppercase; letter-spacing: .05em; }
  td.err { color: #fca5a5; font-weight: 600; }
  .status { display: inline-block; border-radius: 999px; padding: 3px 9px; font-size: 12px; font-weight: 700; }
  .status-ok { color: #86efac; background: #14532d; }
  .status-warn { color: #fde68a; background: #713f12; }
  .status-bad { color: #fecaca; background: #7f1d1d; }
  .details-cell { max-width: 360px; }
  details summary { color: #93c5fd; cursor: pointer; }
  details ul { margin: 8px 0 0; padding-left: 18px; overflow-wrap: anywhere; }
  .stat-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 16px; margin-top: 16px; }
  .stat { background: #0f172a; border: 1px solid #334155; border-radius: 10px; padding: 16px; }
  .stat .label { color: #94a3b8; font-size: 12px; text-transform: uppercase; letter-spacing: .05em; }
  .stat .value { color: #4ade80; font-size: 24px; font-weight: 700; margin-top: 6px; }
  .muted { color: #94a3b8; font-size: 13px; }
  .badge { display: inline-block; background: #164e63; color: #67e8f9; border-radius: 6px; padding: 2px 8px; font-size: 12px; margin-left: 8px; }
</style>
</head>
<body>
<div class="card">
  <h1>CleanupArchive — отчёт об очистке<span class="badge">MIT · open source</span></h1>
  <p class="muted">$([System.Net.WebUtility]::HtmlEncode($SystemInfo.Name)) · сборка $($SystemInfo.Build) · $([System.Net.WebUtility]::HtmlEncode([string]$SystemInfo.Architecture)) · $([System.Net.WebUtility]::HtmlEncode([string]$SystemInfo.ComputerName)) · $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')</p>

  <div class="stat-grid">
    <div class="stat"><div class="label">Освобождено места</div><div class="value">$(Format-Bytes $freedActual)</div></div>
    <div class="stat"><div class="label">Удалено файлов</div><div class="value">$totalFiles</div></div>
    <div class="stat"><div class="label">Удалено папок</div><div class="value">$totalFolders</div></div>
    <div class="stat"><div class="label">Безопасно пропущено</div><div class="value">$totalSkipped</div></div>
    <div class="stat"><div class="label">Критических ошибок</div><div class="value">$totalErrors</div></div>
    <div class="stat"><div class="label">Время выполнения</div><div class="value">$([int]$Duration.TotalMinutes) м $($Duration.Seconds) с</div></div>
  </div>

  <h2>Диск $($BeforeDisk.Drive)</h2>
  <table>
    <tr><th></th><th>До очистки</th><th>После очистки</th></tr>
    <tr><td>Свободно</td><td>$(Format-Bytes $BeforeDisk.FreeBytes)</td><td>$(Format-Bytes $AfterDisk.FreeBytes)</td></tr>
    <tr><td>Используется</td><td>$(Format-Bytes $BeforeDisk.UsedBytes)</td><td>$(Format-Bytes $AfterDisk.UsedBytes)</td></tr>
    <tr><td>Всего</td><td>$(Format-Bytes $BeforeDisk.TotalBytes)</td><td>$(Format-Bytes $AfterDisk.TotalBytes)</td></tr>
  </table>

  <h2>Подробности по задачам</h2>
  <table>
    <tr><th>Задача</th><th>Статус</th><th>Файлов</th><th>Папок</th><th>Освобождено</th><th>Пропущено</th><th>Ошибок</th><th>Подробности</th></tr>
    $rowsHtml
  </table>

  <p class="muted" style="margin-top:28px;">
    Отчёт сформирован автоматически утилитой CleanupArchive (лицензия MIT) и хранится только
    локально в папке reports\ — никуда не отправляется. Подробный построчный журнал
    этого запуска находится в папке logs\.
  </p>
</div>
</body>
</html>
"@

    Set-Content -LiteralPath $reportPath -Value $html -Encoding UTF8
    return $reportPath
}

Export-ModuleMember -Function New-HtmlReport
