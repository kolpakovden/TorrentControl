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
    Assert ($one.Решение -eq 'Недостаточно данных' -and $one.Признак_спроса -eq '' -and $one.Пиров_в_рое -eq '40' -and $one.Пиров_подключено -eq '0') 'swarm-only torrent has no demand'
    Assert ($two.Решение -eq 'Оставить' -and $two.Причина -match 'пиры' -and $two.Признак_спроса -eq 'подключены пиры') 'connected peer keeps the torrent'
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
    Assert ($one.Решение -eq 'Недостаточно данных') 'corrupted peers are not evidence of no demand'
    Assert ((Get-Record $h1).firstSeen -eq $firstSeen -and (Get-Record $h2).missingPolls -eq 1) 'damaged list changed history'
    # Progress that looks complete as a string: the row keeps its history, autoload stays off.
    $bad = New-TestRow $h1 'D:\Хранитель\One' -Uploaded 100 -Progress 500; $bad[4] = '1000'
    $script:rows = @(,$bad)
    Collect
    Assert ($script:autoCalls -eq $calls) 'autoload ran on corrupted progress'
    Assert ((Get-Record $h1).firstSeen -eq $firstSeen -and (Get-Record $h2).missingPolls -eq 1) 'corrupted progress changed history'

    # --- 1.9 cleanup Dry Run end to end: decisions, reports, history write failure, reruns -------------
    $script:clock = 1800000000L + 1513
    function Get-UnixNow { return $script:clock }
    $hIdle = New-TestHash 'e'; $hBusy = New-TestHash 'f'
    function New-Seed($Hash, $Path, $Uploaded) {
        [pscustomobject]@{ hash = $Hash; path = $Path; firstSeen = $script:clock - 40 * 86400; quietSince = $script:clock - 40 * 86400
            lastSeen = $script:clock - 900; uploaded = $Uploaded; observedUpload = 0; complete = $true; running = $true; knownPeers = $true
            demand = $false; demandReason = ''; missingPolls = 0; missingSince = 0; uploadSince = $script:clock - 80 * 3600; uploadHours = ''; uploadNote = 'Start' }
    }
    Save-AutoJson @{ version = 1; updated = $script:clock - 900; items = @((New-Seed $hIdle 'D:\Seed\Idle' 7GB), (New-Seed $hBusy 'F:\Seed\Busy' 9GB)) } $statePath
    $script:rows = @((New-TestRow $hIdle 'D:\Seed\Idle' -Size 30GB -Uploaded 7GB -SeedsSwarm 0 -Name 'Idle film'),
        (New-TestRow $hBusy 'F:\Seed\Busy' -Size 20GB -Uploaded 9GB -UpSpeed 4096 -Name 'Busy film'), (New-TestRow $h3 'E:\Archive' -Size 50GB -Name 'Archive film'))
    $script:paths = @{}
    Collect
    $cleanupHtml = Get-FileText "$temp\cleanup.html"
    Assert ($cleanupHtml -match 'DRY RUN — файлы и раздачи не удаляются' -and $cleanupHtml -match 'Idle film' -and $cleanupHtml -notmatch 'Archive film') 'cleanup.html content'
    $cleanupCsv = @(Import-Csv -LiteralPath "$temp\cleanup.csv" -Delimiter ';' -Encoding UTF8)
    $idle = @($cleanupCsv | Where-Object Hash -eq $hIdle)[0]; $busy = @($cleanupCsv | Where-Object Hash -eq $hBusy)[0]
    Assert ($idle.Решение -eq 'Кандидат на очистку' -and $idle.Редкая_раздача -match '^Да' -and $idle.Размер_ГиБ -eq '30') "idle torrent: $($idle.Решение) / $($idle.Причина)"
    Assert ($busy.Решение -eq 'Оставить' -and $busy.Причина -match 'отдача') "busy torrent: $($busy.Решение) / $($busy.Причина)"
    $main = @(Import-Csv -LiteralPath "$temp\report.csv" -Delimiter ';' -Encoding UTF8 | Where-Object Hash -eq $hIdle)[0]
    Assert ($main.Решение -eq 'Кандидат на очистку') 'main report and cleanup report disagree'
    Assert ((Get-FileText "$temp\report.html") -match 'DRY RUN' -and (Get-FileText "$temp\report.html") -match 'cleanup.html') 'main report links the Dry Run report'
    Assert ((Get-FileText "$temp\monitor.log") -match 'CLEANUP DRY RUN: candidates=1, GiB=30') 'cleanup summary not logged'
    # History is saved before any report: a failed save changes neither, and nothing is counted twice later.
    $reportBefore = Get-FileText "$temp\cleanup.html"; $stateBefore = Get-FileText $statePath
    $script:clock += 900
    $script:rows[0][6] = 7GB + 100MB
    $script:failSave = $true
    function Save-Json { if ($script:failSave) { throw 'Simulated disk error' }; Save-AutoJson @args }
    Assert-Throws { Collect } 'Simulated disk error' 'history write failure not reported'
    Assert ((Get-FileText "$temp\cleanup.html") -eq $reportBefore -and (Get-FileText $statePath) -eq $stateBefore) 'reports changed although history was not saved'
    $script:failSave = $false
    $script:clock += 900
    Collect
    function Get-UploadSumOf($Hash) { $sum = 0L; foreach ($part in @(([string](Get-Record $Hash).uploadHours) -split ';' | Where-Object { $_ })) { $f = $part -split ','; $sum += [long]$f[1] + [long]$f[2] }; return $sum }
    Assert ((Get-UploadSumOf $hIdle) -eq 100MB) "upload after a failed save counted $(Get-UploadSumOf $hIdle) bytes"
    Assert (@(Import-Csv -LiteralPath "$temp\cleanup.csv" -Delimiter ';' -Encoding UTF8 | Where-Object Hash -eq $hIdle)[0].Решение -eq 'Кандидат на очистку') '100 MB in a day keeps the candidate'
    Collect
    Assert ((Get-UploadSumOf $hIdle) -eq 100MB) 'rerun at the same time counted the upload twice'
    # More than an hour without a saved poll: the continuous history starts again.
    $script:clock += 2 * 3600
    Collect
    Assert (@(Import-Csv -LiteralPath "$temp\cleanup.csv" -Delimiter ';' -Encoding UTF8 | Where-Object Hash -eq $hIdle)[0].Решение -eq 'Недостаточно данных') 'candidate after a two-hour gap'

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
    foreach ($name in @('Monitor.ps1','Rules.ps1','LocalPaths.ps1','Feed.ps1','AutoLoad.ps1','Cleanup.ps1','ResumePaths.cs','TorrentMetadata.cs')) {
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
