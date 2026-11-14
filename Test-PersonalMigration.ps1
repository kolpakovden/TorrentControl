param([string]$Topic = '', [string]$Hash = '', [switch]$List, [string]$StateDirectory = '', [switch]$NoWebUI)
# Dry Run before re-binding ONE old TorrentControl torrent to the personal tracker (17-Check-personal-migration.cmd).
# Nothing is changed: uTorrent is only read through WebUI (token.html, list=1, getprops), the TorrentControl folder
# given as -StateDirectory (e.g. C:\TorrentMonitor) is only read (auto-state.json, config.json, credential.xml - the
# password is decrypted in memory, never copied). Reports are written next to this script only.
#   -List      old TorrentControl torrents with topic links (personal-migration-list.html); no WebUI needed
#   -Topic N / -Hash H   check one torrent; -NoWebUI   skip uTorrent (offline file and record check only)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Monitor.ps1"
. "$PSScriptRoot\TrackerMigration.ps1"
. "$PSScriptRoot\PersonalImport.ps1"
# Read-only guarantee for this process: the only changing operations of the migration are disabled.
function Set-WebUITrackers { throw 'ReadOnlyViolation' }
function Invoke-TrackerMigration { throw 'ReadOnlyViolation' }
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if (!$StateDirectory) {
            if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'auto-state.json')) { $StateDirectory = $PSScriptRoot }
            else { $StateDirectory = ([string](Read-Host 'Папка TorrentControl с auto-state.json (только чтение), например C:\TorrentMonitor')).Trim().Trim('"') }
        }
        $StateDirectory = Resolve-StateDirectory $StateDirectory
        if ($List -or (!$Topic -and !$Hash)) {
            $entries = @(Get-PersonalMigrationList $StateDirectory)
            $entries | Format-Table topic, imported, title, downloadUrl -AutoSize | Out-String -Width 220 | Write-Host
            Write-Host ('Раздач TorrentControl: ' + $entries.Count + '. Список со ссылками: ' + (Write-PersonalMigrationList $entries $PSScriptRoot))
            if ($List) { exit 0 }
            $Topic = ([string](Read-Host 'Номер темы для проверки (Enter — выход)')).Trim()
            if (!$Topic) { exit 0 }
        }
        $config = $null; $credential = $null
        if (!$NoWebUI) {
            $configPath = Join-Path $StateDirectory 'config.json'; $credentialPath = Join-Path $StateDirectory 'credential.xml'
            if ((Test-Path -LiteralPath $configPath) -and (Test-Path -LiteralPath $credentialPath)) {
                $config = (Read-SharedText $configPath) | ConvertFrom-Json
                $credential = Import-Clixml -LiteralPath $credentialPath
                $null = Assert-AutoLocalClient $config
            } else { Write-Host 'config.json или credential.xml не найдены: µTorrent не проверяется (как с -NoWebUI).' }
        }
        $result = Invoke-PersonalMigrationCheck $StateDirectory $Hash $Topic $config $credential -NoWebUI:$NoWebUI
        $lines = Format-PersonalCheck $result
        foreach ($line in $lines) { Write-Host $line }
        [IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'personal-migration-check.txt'), [string[]]$lines, (New-Object Text.UTF8Encoding($true)))
        if ($result.verdict -eq 'ReadyToRebind') { exit 0 }
        exit 2
    } catch {
        $code = Get-PersonalCode $_.Exception
        $text = $script:PersonalTexts[$code]
        if ($code -in @('WebUINotLocal', 'ExpectedOneLocalClient', 'TokenMissing')) { $text = 'Проверка µTorrent невозможна (' + $code + '); можно запустить с -NoWebUI.' }
        Write-Host ('Проверка остановлена: ' + $code + ' — ' + $text) -ForegroundColor Red
        exit 1
    }
}
