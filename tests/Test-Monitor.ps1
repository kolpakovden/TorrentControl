. "$PSScriptRoot\TestCommon.ps1"
$temp = New-TestDirectory
try {
    # The guard in Monitor.ps1 makes dot-sourcing define functions only; nothing runs against real files.
    . "$PSScriptRoot\..\Monitor.ps1"
    $root = $temp
    Set-Content -LiteralPath "$temp\config.json" -Value '{"url":"http://127.0.0.1:9090"}' -Encoding UTF8
    $h1 = New-TestHash 'a'; $h2 = New-TestHash 'b'; $h3 = New-TestHash 'c'; $h4 = New-TestHash 'd'
    $script:rows = @(); $script:paths = @{}; $script:autoCalls = 0; $script:feedEntries = @()
    function Import-Clixml { return [pscustomobject]@{} }
    function Fetch-List { return (ConvertTo-WebUIList $script:rows) }
    $script:feedFails = $false; $script:autoEntries = -1
    function Collect-Films {
        param($TorrentRows, $Directory)
        if ($script:feedFails) {
            $script:LatestFilmEntries = $null
            $script:FeedDiagnostics = [pscustomobject]@{ fetchedAt = [DateTimeOffset]::UtcNow.AddHours(-8); ageHours = 8 }
            throw 'MirrorStaleOver6Hours'
        }
        $script:LatestFilmEntries = $script:feedEntries; return 0
    }
    function Get-FeedMirrorStatus { return $null }
    function Read-LocalPaths { return $script:paths }
    function Invoke-AutoLoad { $script:autoCalls++; $script:autoEntries = @($args[0]).Count; return 'stub' }
    function Invoke-WebRequest { throw 'Network access is not allowed in tests' }
    $statePath = "$temp\state.json"
    function Read-State { return (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    function Get-Record($Hash) { return @((Read-State).items | Where-Object hash -eq $Hash)[0] }

    # --- First poll ---------------------------------------------------------------------------
    $script:rows = @(
        (New-TestRow $h1 'D:\Хранитель\One' -Uploaded 100 -PeersSwarm 40 -SeedsSwarm 9 -Name 'One'),
        (New-TestRow $h2 'F:\Two' -Uploaded 200 -PeersConnected 1 -Name 'Two'),
        (New-TestRow $h3 'E:\Archive' -Name 'Archive'),
        (New-TestRow $h4 '' -Name 'Unknown'))
    Collect
    $first = Read-State
    Assert (@($first.items).Count -eq 2) 'only D/F torrents are tracked'
    Assert ($script:autoCalls -eq 1) 'autoload runs on a normal poll'
    $csv = Get-FileText "$temp\report.csv"
    Assert ($csv -notmatch 'Скачивающих') 'swarm peers must not be labelled as downloaders'
    foreach ($column in @('Признак_спроса','Пиров_подключено','Пиров_в_рое','Сидов_в_рое','Отдача_КБ_с')) { Assert ($csv -match $column) "report column $column" }
    $report = @(Import-Csv -LiteralPath "$temp\report.csv" -Delimiter ';' -Encoding UTF8)
    $one = @($report | Where-Object Hash -eq $h1)[0]; $two = @($report | Where-Object Hash -eq $h2)[0]
    Assert ($one.Решение -ne 'Есть спрос' -and $one.Пиров_в_рое -eq '40' -and $one.Пиров_подключено -eq '0') 'swarm-only torrent has no demand'
    Assert ($two.Решение -eq 'Есть спрос' -and $two.Признак_спроса -eq 'подключены пиры') 'connected peer is demand'
    Assert ((Get-FileText "$temp\report.html") -match 'не о нашей раздаче') 'report explains swarm columns'
    Assert (!(Test-Path -LiteralPath "$statePath.tmp")) 'no temporary file left'
    $firstSeen = (Get-Record $h1).firstSeen

    # --- Second poll: atomic replace keeps the previous version as .bak -----------------------------
    Collect
    Assert (Test-Path -LiteralPath "$statePath.bak") 'previous state kept as .bak'
    Assert ((Get-Record $h1).firstSeen -eq $firstSeen) 'history continues'

    # --- Feed stale or unavailable: the autoload queue keeps running, no new topics are added ------
    $script:feedFails = $true
    $calls = $script:autoCalls
    Collect
    Assert ($script:autoCalls -eq $calls + 1 -and $script:autoEntries -eq 0) 'autoload queue stopped while the feed was stale'
    $html = Get-FileText "$temp\report.html"
    Assert ($html -match 'MirrorStaleOver6Hours' -and $html -match 'возраст 8' -and $html -match 'новые темы не добавляются') 'stale feed reason not reported'
    Assert ((Get-FileText "$temp\monitor.log") -match 'FEED ERROR: .*MirrorStaleOver6Hours.*snapshotAgeHours=8') 'stale feed not logged with its age'
    Assert ((Get-Record $h1).firstSeen -eq $firstSeen) 'stale feed changed history'
    $script:feedFails = $false
    $script:feedEntries = @([pscustomobject]@{ topic = '900000001' })
    Collect
    Assert ($script:autoEntries -eq 1 -and $script:autoCalls -eq $calls + 2) 'feed entries not passed after recovery'
    $script:feedEntries = @()
    $before = Get-FileText $statePath
    $calls = $script:autoCalls

    # --- Empty WebUI list: nothing written, autoload not started ----------------------------------
    $script:rows = @()
    Assert-Throws { Collect } 'EmptyTorrentList' 'empty list must stop the poll'
    Assert ((Get-FileText $statePath) -eq $before) 'empty list must not touch state.json'
    Assert ($script:autoCalls -eq $calls) 'autoload must not run on an empty list'

    # --- Unsupported row format: stop before autoload -----------------------------------------------
    $script:rows = @(,@($h1, 201, 'short'))
    Assert-Throws { Collect } 'UnsupportedRowFormat' 'short rows must stop the poll'
    Assert ((Get-FileText $statePath) -eq $before -and $script:autoCalls -eq $calls) 'short rows change nothing'

    # --- resume.dat unreadable on uTorrent 2.2.1: all paths unknown, history kept ----------------
    $script:rows = @((New-TestRow $h1 -Fields 19 -Uploaded 100), (New-TestRow $h2 -Fields 19 -Uploaded 200))
    $script:paths = @{}
    Collect
    Assert (@((Read-State).items).Count -eq 2) 'unknown paths must not drop history'
    Assert ((Get-Record $h1).firstSeen -eq $firstSeen) 'kept history is unchanged'
    Assert ((Get-FileText "$temp\report.html") -match 'История сохранена без обновления: 2') 'report shows kept history'

    # --- Same 19-field rows with resume.dat paths: history continues ---------------------------
    $script:paths = @{ $h1 = 'D:\Хранитель\One'; $h2 = 'F:\Two' }
    Collect
    Assert ((Get-Record $h1).firstSeen -eq $firstSeen) 'history continues after resume.dat recovers'

    # --- Partial list: absent torrent kept for the grace period, not reported ----------------------
    $script:rows = @(,(New-TestRow $h1 'D:\Хранитель\One' -Uploaded 100))
    $script:paths = @{}
    Collect
    $two = Get-Record $h2
    Assert ($two -and $two.missingPolls -eq 1) 'absent torrent kept with missing counter'
    # Still listed in resume.dat: absence is not confirmed, the counter does not grow.
    $script:paths = @{ $h2 = 'F:\Two' }
    Collect
    Assert ((Get-Record $h2).missingPolls -eq 1) 'torrent present in resume.dat counted as missing'
    $script:paths = @{}
    Assert (@(Import-Csv -LiteralPath "$temp\report.csv" -Delimiter ';' -Encoding UTF8 | Where-Object Hash -eq $h2).Count -eq 0) 'absent torrent not reported'

    # --- Corrupted numeric values: autoload skipped before any submission, history kept, report safe ---
    $calls = $script:autoCalls
    $bad = New-TestRow $h1 'D:\Хранитель\One' -Uploaded 100; $bad[8] = 'fast'; $bad[12] = $null
    $script:rows = @(,$bad)
    Collect
    Assert ($script:autoCalls -eq $calls) 'autoload ran on corrupted client data'
    Assert ((Get-FileText "$temp\monitor.log") -match 'AUTO SKIPPED: ClientDataInvalid:UploadSpeed') 'skipped autoload logged with a code'
    Assert ((Get-FileText "$temp\report.html") -match 'Автозагрузка не запускалась: .{1,12}Torrent вернул некорректные данные \(UploadSpeed\)') 'report explains skipped autoload'
    $one = @(Import-Csv -LiteralPath "$temp\report.csv" -Delimiter ';' -Encoding UTF8 | Where-Object Hash -eq $h1)[0]
    Assert ($one.Отдача_КБ_с -eq 'н/д' -and $one.Пиров_подключено -eq 'н/д') 'unknown values labelled, not shown as 0'
    Assert ($one.Решение -eq 'Недостаточно данных / остановлена') 'corrupted peers are not evidence of no demand'
    Assert ((Get-Record $h1).firstSeen -eq $firstSeen -and (Get-Record $h2).missingPolls -eq 1) 'damaged list changed history'
    # Progress that looks complete as a string: the row keeps its history, autoload stays off.
    $bad = New-TestRow $h1 'D:\Хранитель\One' -Uploaded 100 -Progress 500; $bad[4] = '1000'
    $script:rows = @(,$bad)
    Collect
    Assert ($script:autoCalls -eq $calls) 'autoload ran on corrupted progress'
    Assert ((Get-Record $h1).firstSeen -eq $firstSeen -and (Get-Record $h2).missingPolls -eq 1) 'corrupted progress changed history'

    # --- Corrupted state.json: stop, keep the file for inspection --------------------------------
    Set-Content -LiteralPath $statePath -Value '{"version":1,"items":[{"hash"' -Encoding UTF8
    $broken = Get-FileText $statePath
    Assert-Throws { Collect } 'StateUnreadable' 'corrupted history must stop the poll'
    Assert ((Get-FileText $statePath) -eq $broken) 'corrupted history must not be overwritten'

    # --- state.json missing but a backup exists: ambiguous, stop ----------------------------------
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $statePath
    Assert-Throws { Collect } 'StateMissingBackupPresent' 'missing history with a backup must stop'
    Assert (!(Test-Path -LiteralPath $statePath)) 'no new history created over a backup'
    Assert ((Get-MonitorErrorCode ([Exception]::new('StateUnreadable'))) -eq 'StateUnreadable') 'error code allowlist'
    Assert ((Get-MonitorErrorCode ([Exception]::new('http://secret@host/?token=1'))) -eq 'Other') 'unknown errors are not logged verbatim'

    # --- Whole script in a copy: guard, lock and error logging work outside the test session ------
    $copy = Join-Path $temp 'copy'
    $null = Microsoft.PowerShell.Management\New-Item -Path $copy -ItemType Directory
    foreach ($name in @('Monitor.ps1','Rules.ps1','LocalPaths.ps1','Feed.ps1','AutoLoad.ps1','RuTracker.ps1','RuTrackerRoute.cs','ResumePaths.cs','TorrentMetadata.cs')) {
        Copy-Item -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..') $name) -Destination $copy
    }
    $exe = (Get-Process -Id $PID).Path
    # 'Continue': Windows PowerShell 5.1 turns redirected stderr of a child process into a terminating error under 'Stop'.
    $ErrorActionPreference = 'Continue'
    $output = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $copy 'Monitor.ps1') -Once 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert ($exitCode -eq 1) "script without config.json must exit 1: $output"
    $log = Get-FileText (Join-Path $copy 'monitor.log')
    Assert ($log -match 'ERROR: .*History not advanced.*code: Other') 'error is logged with a code'
    Assert (!(Test-Path -LiteralPath (Join-Path $copy 'state.json'))) 'failed run creates no history'
    # .NET on Linux does not treat '\' as a separator; the production scripts target Windows only.
    if ($script:OnWindows) { Assert (Test-Path -LiteralPath (Join-Path $copy 'monitor.lock')) 'lock is taken inside the copy' }
} finally { Remove-TestDirectory $temp }
"PASS Test-Monitor: $script:AssertCount assertions"
