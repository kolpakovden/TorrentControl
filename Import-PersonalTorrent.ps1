param([Parameter(Position = 0)][string]$Path = '', [string]$Topic = '', [string]$StateDirectory = '')
# Import of a personal .torrent that the person downloaded in Firefox (16-Import-personal-torrent.cmd; a file can be
# dropped onto it). No network and no browser data are used. The file is found in auto-state.json by its own infohash
# (never by its name), verified and stored unchanged in %LOCALAPPDATA%\TorrentControl\personal\<HASH>.torrent;
# nothing else is written.
#   -StateDirectory  TorrentControl folder whose auto-state.json is read (only read), e.g. C:\TorrentMonitor
#   -Topic           optional topic number; must match the record found by the infohash
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\AutoLoad.ps1"
. "$PSScriptRoot\RuTracker.ps1"
. "$PSScriptRoot\PersonalImport.ps1"
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if (!$Path) { $Path = ([string](Read-Host 'Путь к .torrent, скачанному в Firefox')).Trim().Trim('"') }
        if (!$StateDirectory) {
            if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'auto-state.json')) { $StateDirectory = $PSScriptRoot }
            else { $StateDirectory = ([string](Read-Host 'Папка TorrentControl с auto-state.json (только чтение), например C:\TorrentMonitor')).Trim().Trim('"') }
        }
        $result = Import-PersonalTorrentFile $Path $StateDirectory $Topic
        foreach ($line in (Format-ImportResult $result)) { Write-Host $line }
        Write-Host ('Дальше, без изменений в µTorrent: 17-Check-personal-migration.cmd -Topic ' + $result.topic + ' -StateDirectory "' + $StateDirectory + '"')
        exit 0
    } catch {
        $code = Get-PersonalCode $_.Exception
        Write-Host ('Импорт отклонён: ' + $code + ' — ' + $script:PersonalTexts[$code]) -ForegroundColor Red
        exit 1
    }
}
