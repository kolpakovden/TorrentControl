param([switch]$Disable, [switch]$Review)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Feed.ps1"
. "$PSScriptRoot\AutoLoad.ps1"
$lock=$null
try {
    $lock=[IO.File]::Open("$PSScriptRoot\monitor.lock",'OpenOrCreate','ReadWrite','None')
    $settingsPath=Join-Path $PSScriptRoot 'autoload.json'
    $statePath=Join-Path $PSScriptRoot 'auto-state.json'
    if ($Disable) {
        Save-AutoJson @{enabled=$false;destination='D:\Фильмы';reserveGiB=20} $settingsPath
        Write-Host 'Automatic adding disabled. Existing torrents continue normally.'
    } elseif ($Review) {
        # Clears "NeedsAttention" after the user checked uTorrent. Records stay, hashes are never resent.
        if (!(Test-Path -LiteralPath $statePath)) {throw 'AutoBaselineMissing'}
        $state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.version -ne 1 -or !$state.enabledAt) {throw 'InvalidAutoState'}
        $pending=@($state.items | Where-Object status -eq 'NeedsAttention')
        if (!$pending.Count) {Write-Host 'Nothing to review: no records need attention.'}
        else {
            foreach ($item in $pending) {Write-Host ('NEEDS ATTENTION: '+$item.hash+' '+$item.reason+' '+$item.path)}
            Write-Host 'Check these torrents in uTorrent first. TorrentControl will never resend them.'
            if ((Read-Host 'Type YES to mark them as reviewed and resume automatic adding') -ne 'YES') {throw 'ReviewCancelled'}
            $count=Set-AutoReviewed $state
            Save-AutoJson $state $statePath
            Write-Host "Marked as reviewed: $count. Automatic adding continues on the next monitor run."
        }
    } else {
        $config=Get-Content "$PSScriptRoot\config.json" -Raw -Encoding UTF8 | ConvertFrom-Json
        $null=Assert-AutoLocalClient $config
        Assert-AutoDirectory 'D:\Фильмы'
        if (!(Test-Path -LiteralPath $statePath)) {
            # A leftover copy means the journal was interrupted: never rebuild it silently.
            if ((Test-Path -LiteralPath "$statePath.bak") -or (Test-Path -LiteralPath "$statePath.tmp")) {throw 'AutoStateBackupPresent'}
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
    Write-Host ('Configuration failed: '+$_.Exception.GetType().Name+'; code: '+(Get-AutoErrorCode $_.Exception)) -ForegroundColor Red
    Write-Host 'If the monitor is currently running, wait for it to finish and try again.'
    exit 1
} finally {if($lock){$lock.Dispose()}}
