param([switch]$Disable)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Feed.ps1"
. "$PSScriptRoot\AutoLoad.ps1"
$lock=$null
try {
    $lock=[IO.File]::Open("$PSScriptRoot\monitor.lock",'OpenOrCreate','ReadWrite','None')
    $settingsPath=Join-Path $PSScriptRoot 'autoload.json'
    if ($Disable) {
        Save-AutoJson @{enabled=$false;destination='D:\Фильмы';reserveGiB=20} $settingsPath
        Write-Host 'Automatic adding disabled. Existing torrents continue normally.'
    } else {
        $config=Get-Content "$PSScriptRoot\config.json" -Raw -Encoding UTF8 | ConvertFrom-Json
        $null=Assert-AutoLocalClient $config
        Assert-AutoDirectory 'D:\Фильмы'
        $statePath=Join-Path $PSScriptRoot 'auto-state.json'
        if (!(Test-Path $statePath)) {
            $snapshot=Get-AutoRemoteJson 'https://raw.githubusercontent.com/kolpakovden/TorrentControl/main/data/forum-252.json'
            $parsed=Convert-FilmSnapshot ($snapshot | ConvertTo-Json -Depth 5)
            $topics=@($parsed.entries | ForEach-Object {[string]$_.topic})
            if (Test-Path "$PSScriptRoot\feed-state.json") {
                $feedState=Get-Content "$PSScriptRoot\feed-state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
                $topics+=@($feedState.items | ForEach-Object {[string]$_.topic})
            }
            Save-AutoJson @{version=1;enabledAt=[DateTimeOffset]::UtcNow.ToString('o');knownTopics=@($topics | Select-Object -Unique);items=@()} $statePath
        }
        Save-AutoJson @{enabled=$true;destination='D:\Фильмы';reserveGiB=20} $settingsPath
        Write-Host 'Automatic adding ENABLED for new topics after activation.'
        Write-Host 'Destination: D:\Фильмы\rt-<topic>; reserve: 20 GiB; at most one addition per monitor run.'
        Write-Host 'No per-torrent size limit. Current feed is excluded on first activation.'
        Write-Host 'Run 2-Run-once.cmd or wait for the existing scheduled task.'
    }
} catch {
    Write-Host ('Configuration failed: '+$_.Exception.GetType().Name) -ForegroundColor Red
    Write-Host 'If the monitor is currently running, wait for it to finish and try again.'
    exit 1
} finally {if($lock){$lock.Dispose()}}
