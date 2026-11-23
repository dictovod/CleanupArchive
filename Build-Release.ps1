#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$releaseName = 'CleanupArchive_v1.2.1'
$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $projectRoot "$releaseName.zip"
}
$archivePath = [IO.Path]::GetFullPath($OutputPath)
$stageBase = Join-Path ([IO.Path]::GetTempPath()) ('CleanupArchive-Release-' + [Guid]::NewGuid().ToString('N'))
$verifyBase = Join-Path ([IO.Path]::GetTempPath()) ('CleanupArchive-Verify-' + [Guid]::NewGuid().ToString('N'))

function Remove-VerifiedTempDirectory {
    param([string]$Path, [string]$RequiredPrefix)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return }
    $full = [IO.Path]::GetFullPath($Path)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $leaf = [IO.Path]::GetFileName($full)
    if (-not $full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $leaf.StartsWith($RequiredPrefix, [StringComparison]::Ordinal)) {
        throw "Refusing to remove unverified temporary path: $full"
    }
    Remove-Item -LiteralPath $full -Recurse -Force
}

try {
    $releaseRoot = Join-Path $stageBase $releaseName
    New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null

    $rootFiles = @(
        'Build-Release.ps1', 'Cleanup.ps1', 'config.json', 'LICENSE',
        'README.md', 'RELEASE_NOTES.md', 'Settings.bat', 'Settings.ps1',
        'Start.bat', 'SupportBundle.bat', 'SupportBundle.ps1', 'VERSION'
    )
    foreach ($name in $rootFiles) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $releaseRoot
    }
    Copy-Item -LiteralPath (Join-Path $projectRoot 'modules') -Destination $releaseRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $projectRoot 'web') -Destination $releaseRoot -Recurse

    foreach ($directoryName in @('logs', 'reports', 'support')) {
        $targetDirectory = Join-Path $releaseRoot $directoryName
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $projectRoot "$directoryName\README.txt") -Destination $targetDirectory
    }

    Compress-Archive -LiteralPath $releaseRoot -DestinationPath $archivePath -CompressionLevel Optimal -Force

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $entries = @($zip.Entries |
            Where-Object { -not [string]::IsNullOrEmpty($_.Name) } |
            ForEach-Object { $_.FullName -replace '\\', '/' })
        $forbidden = @($entries | Where-Object {
            $_ -match 'cleanup_\d' -or $_ -match 'report_\d' -or
            $_ -match 'terminal' -or $_ -match '\.zip$'
        })
        if ($forbidden.Count -gt 0) {
            throw "Release contains forbidden diagnostic files: $($forbidden -join ', ')"
        }
        $required = @(
            "$releaseName/Cleanup.ps1",
            "$releaseName/modules/ThumbnailCache.psm1",
            "$releaseName/config.json",
            "$releaseName/VERSION",
            "$releaseName/RELEASE_NOTES.md"
        )
        $missing = @($required | Where-Object { $_ -notin $entries })
        if ($missing.Count -gt 0) {
            throw "Release is missing required files: $($missing -join ', ')"
        }
    } finally {
        $zip.Dispose()
    }

    Expand-Archive -LiteralPath $archivePath -DestinationPath $verifyBase -Force
    $verifyRoot = Join-Path $verifyBase $releaseName
    $parseErrors = @()
    foreach ($file in Get-ChildItem -LiteralPath $verifyRoot -Recurse -File |
            Where-Object { $_.Extension -in @('.ps1', '.psm1') }) {
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile(
            $file.FullName, [ref]$tokens, [ref]$errors
        ) | Out-Null
        foreach ($parseError in @($errors)) {
            $parseErrors += "$($file.FullName):$($parseError.Extent.StartLineNumber): $($parseError.Message)"
        }
    }
    if ($parseErrors.Count -gt 0) {
        throw "Release contains parser errors: $($parseErrors -join ' | ')"
    }

    Get-ChildItem -LiteralPath (Join-Path $verifyRoot 'modules') -Filter '*.psm1' -File |
        Sort-Object Name |
        ForEach-Object {
            Import-Module $_.FullName -Force -DisableNameChecking -ErrorAction Stop
        }
    if ((Get-CleanupArchiveVersion) -ne '1.2.1') {
        throw 'Release version check failed.'
    }

    $releaseConfig = Get-Content -LiteralPath (Join-Path $verifyRoot 'config.json') `
        -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ($releaseConfig.CleanDefenderCache -ne $false -or $releaseConfig.CleanEventLogs -ne $false) {
        throw 'Release configuration does not contain the expected safe defaults.'
    }

    $archive = Get-Item -LiteralPath $archivePath
    $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    [PSCustomObject]@{
        Path       = $archive.FullName
        SizeBytes  = $archive.Length
        FileCount  = $entries.Count
        SHA256     = $hash
        Version    = Get-CleanupArchiveVersion
        Validation = 'Passed'
    }
} finally {
    Remove-VerifiedTempDirectory -Path $stageBase -RequiredPrefix 'CleanupArchive-Release-'
    Remove-VerifiedTempDirectory -Path $verifyBase -RequiredPrefix 'CleanupArchive-Verify-'
}
