$script:FeedMirrorBase = 'https://raw.githubusercontent.com/kolpakovden/TorrentControl/main/data/'
function Read-FilmFeedXml([string]$XmlText) {
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 10MB
    $reader = [Xml.XmlReader]::Create((New-Object IO.StringReader($XmlText)), $settings)
    $doc = New-Object Xml.XmlDocument
    $doc.XmlResolver = $null
    try { $doc.Load($reader) } finally { $reader.Dispose() }
    $ns = New-Object Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('a','http://www.w3.org/2005/Atom')
    if ($doc.SelectSingleNode('/a:feed/a:id',$ns).InnerText -ne 'tag:rto.feed,2000:/f/252') { throw 'Unexpected feed: expected forum 252' }
    # Wrapped: an XmlDocument returned directly would be enumerated by the pipeline.
    return [pscustomobject]@{ doc = $doc; ns = $ns }
}
function Convert-FilmFeed([string]$XmlText) {
    $feed = Read-FilmFeedXml $XmlText
    $ns = $feed.ns
    foreach ($entry in $feed.doc.SelectNodes('/a:feed/a:entry',$ns)) {
        $id = $entry.SelectSingleNode('a:id',$ns).InnerText
        if ($id -notmatch '/t/(\d+)$') { throw 'Missing topic ID' }
        $topic = $Matches[1]
        $hash = ''
        foreach ($link in $entry.SelectNodes('a:link',$ns)) {
            if ($link.GetAttribute('rel') -eq 'enclosure' -and $link.GetAttribute('href') -match '(?i)urn:btih:([0-9a-f]{40})(?:&|$)') { $hash = $Matches[1].ToUpperInvariant() }
        }
        $updated = $entry.SelectSingleNode('a:updated',$ns).InnerText
        $date = [DateTimeOffset]::Parse($updated, [Globalization.CultureInfo]::InvariantCulture)
        [pscustomobject]@{ topic=$topic; title=$entry.SelectSingleNode('a:title',$ns).InnerText; hash=$hash; updated=$date.ToString('o'); url="https://rutracker.org/forum/viewtopic.php?t=$topic" }
    }
}
function ConvertTo-FeedTime($Value) {
    # Windows PowerShell 5.1 keeps ISO strings from ConvertFrom-Json; PowerShell 7 turns them into DateTime.
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { $Value = [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        return [DateTimeOffset]$Value.ToUniversalTime()
    }
    $parsed = [DateTimeOffset]::MinValue
    if ($Value -is [string] -and [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed }
    throw 'MirrorInvalid'
}
function Get-FilmFeedUpdated([string]$XmlText) {
    $feed = Read-FilmFeedXml $XmlText
    $node = $feed.doc.SelectSingleNode('/a:feed/a:updated', $feed.ns)
    if ($null -eq $node) { throw 'MirrorInvalid' }
    return (ConvertTo-FeedTime ([string]$node.InnerText))
}
function Format-FeedAge($Hours) {
    if ([double]$Hours -lt 1) { return ('{0} мин' -f [math]::Round([double]$Hours * 60)) }
    return ('{0} ч' -f [math]::Round([double]$Hours, 1))
}
function Update-FilmReport($Entries, $TorrentRows, [string]$Directory, [string]$SnapshotTime, $Snapshot = $null, $Coverage = $null) {
    $statePath = Join-Path $Directory 'feed-state.json'
    $firstRun = !(Test-Path $statePath)
    $known = @{}
    if (!$firstRun) {
        $saved = Get-Content $statePath -Raw | ConvertFrom-Json
        foreach ($record in $saved.items) { $known[[string]$record.topic] = $record }
    }
    $hashes = @{}
    foreach ($torrent in $TorrentRows) { $hashes[[string]$torrent[0]] = $true }
    $now = [DateTimeOffset]::UtcNow.ToString('o')
    $visible = @()
    foreach ($item in $Entries) {
        if (!$known.ContainsKey($item.topic)) {
            $known[$item.topic] = [pscustomobject]@{topic=$item.topic; firstSeen=$now; baseline=$firstRun; hash=$item.hash}
        }
        $record = $known[$item.topic]
        $status = 'Новая для наблюдателя'
        if ($record.baseline) { $status = 'Исходный список' }
        if ($record.hash -and $item.hash -and $record.hash -ne $item.hash) { $status = 'Изменился хеш раздачи' }
        if (!$item.hash) { $status = 'Хеш отсутствует — проверить вручную' }
        elseif ($hashes.ContainsKey($item.hash)) { $status = 'Уже есть в µTorrent' }
        $visible += [pscustomobject]@{Статус=$status; Название=$item.title; Дата_в_ленте=$item.updated; Впервые_замечена=$record.firstSeen; Тема=$item.url; Hash=$item.hash}
    }
    $table = ($visible | Sort-Object Дата_в_ленте -Descending | ConvertTo-Html -Fragment) -join "`n"
    # Only generated numeric-topic URLs are converted to links; feed text stays HTML-escaped.
    $table = [regex]::Replace($table, '<td>(https://rutracker\.org/forum/viewtopic\.php\?t=\d+)</td>', '<td><a href="$1" target="_blank" rel="noopener noreferrer">Открыть тему</a></td>')
    $intro = '<h1>Фильмы — раздел 252</h1><p>Подборка публикаций. Состояние автозагрузки показано в основном отчёте.</p><p>Обновлено: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '</p><p>При первом запуске записи образуют исходный список. Новая для наблюдателя — тема впервые появилась после него. Дата в ленте — поле updated, не подтверждённая дата создания темы. Лента ограничена: пропущенные при долгом простое записи могут не попасть в отчёт.</p><p>Совпадения с µTorrent проверены по хешу среди всех дисков. Разные версии одного фильма могут иметь разные хеши.</p>'
    if ($Snapshot) {
        $details = ''
        if ($null -ne $Snapshot.sequence) { $details += ' Снимок №' + $Snapshot.sequence + '.' }
        if ($Snapshot.trigger) { $details += ' Запуск: ' + $Snapshot.trigger + '.' }
        $intro += '<p>Копия ленты получена GitHub (UTC): ' + [Net.WebUtility]::HtmlEncode($SnapshotTime) + '; возраст: ' + (Format-FeedAge $Snapshot.ageHours) + '.' + [Net.WebUtility]::HtmlEncode($details) + ' Лента RuTracker содержит 50 последних обновлённых тем (сейчас это около двух недель): при перерывах в обновлении темы не теряются, пока остаются в этом окне. Запуск обновления по расписанию GitHub не гарантирован.</p>'
    } elseif ($SnapshotTime) { $intro += '<p>Копия ленты получена GitHub (UTC): ' + [Net.WebUtility]::HtmlEncode($SnapshotTime) + '.</p>' }
    if ($Coverage -and $Coverage.status -eq 'PossibleGap') {
        $intro += '<p><b>Внимание:</b> темы, обновлённые между ' + $Coverage.from.UtcDateTime.ToString('yyyy-MM-dd HH:mm') + ' и ' + $Coverage.to.UtcDateTime.ToString('yyyy-MM-dd HH:mm') + ' UTC, могли выпасть из ленты до получения этой копии. Источник не позволяет их восстановить — проверьте раздел вручную.</p>'
    }
    $html = '<!doctype html><html lang="ru"><meta charset="utf-8"><title>Новые публикации</title><style>body{font:15px Segoe UI;margin:24px;background:#f5f7fa}table{border-collapse:collapse;width:100%;background:white}td,th{padding:9px;border:1px solid #ddd;text-align:left}th{background:#dfeafa}td{overflow-wrap:anywhere}</style><body>' + $intro + $table + '</body></html>'
    $html | Set-Content (Join-Path $Directory 'films.html') -Encoding UTF8
    $visible | Export-Csv (Join-Path $Directory 'films.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    $state = [ordered]@{version=1;updated=$now;items=@($known.Values)}
    if ($Snapshot) {
        # Newest snapshot already used: an older one is never accepted again (rollback protection).
        $state.snapshotFetchedAt = $Snapshot.fetchedAtValue.ToString('o')
        $state.snapshotSequence = $Snapshot.sequence
    }
    # Atomic write from AutoLoad.ps1 (loaded by Monitor.ps1 and Configure-AutoLoad.ps1).
    Save-AutoJson $state $statePath
}
function Convert-FilmSnapshot([string]$JsonText, $LastFetchedAt = $null) {
    $script:FeedDiagnostics = $null
    try { $snapshot = $JsonText | ConvertFrom-Json } catch { throw 'MirrorInvalid' }
    if ($null -eq $snapshot -or $snapshot.schema -ne 1 -or $snapshot.forum -ne 252 -or $snapshot.source -ne 'https://feed.rutracker.cc/atom/f/252.atom') { throw 'MirrorInvalid' }
    $stamp = ConvertTo-FeedTime $snapshot.fetched_at
    $age = [DateTimeOffset]::UtcNow - $stamp
    $script:FeedDiagnostics = [pscustomobject]@{ fetchedAt = $stamp; ageHours = [math]::Round($age.TotalHours, 1) }
    if ($age.TotalMinutes -lt -5) { throw 'MirrorFutureDate' }
    if ($age.TotalHours -gt 6) { throw 'MirrorStaleOver6Hours' }
    # Never go back: a CDN edge or a reverted commit must not replace a newer snapshot already used.
    if ($null -ne $LastFetchedAt -and $stamp -lt $LastFetchedAt) { throw 'MirrorRollback' }
    # The Atom document carries its own generation time (observed lag up to 10 minutes):
    # a fresh fetched_at on an old document is an old snapshot presented as fresh.
    $source = Get-FilmFeedUpdated ([string]$snapshot.xml)
    if ($source -gt $stamp.AddMinutes(5) -or $source -lt $stamp.AddHours(-2)) { throw 'MirrorSourceStale' }
    $entries = @(Convert-FilmFeed $snapshot.xml)
    if (!$entries.Count -or $entries.Count -ne $snapshot.entry_count) { throw 'MirrorInvalid' }
    # Diagnostics only (1.8 mirror); never used for decisions.
    $sequence = $null
    if (($snapshot.sequence -is [int] -or $snapshot.sequence -is [long]) -and $snapshot.sequence -ge 0) { $sequence = [long]$snapshot.sequence }
    $trigger = ''
    if ([string]$snapshot.trigger -match '^[a-z-]{1,40}:[a-z_]{1,40}$') { $trigger = [string]$snapshot.trigger }
    return [pscustomobject]@{entries=$entries; fetchedAt=$stamp.UtcDateTime.ToString('u'); fetchedAtValue=$stamp; sourceUpdated=$source
        ageHours=[math]::Round($age.TotalHours, 2); sequence=$sequence; trigger=$trigger}
}
function Get-FeedCoverage($Entries, $LastFetchedAt) {
    # The feed lists only the 50 most recently updated topics. If even its oldest entry is newer than
    # the snapshot used before, topics updated in between may have dropped out and cannot be recovered.
    if ($null -eq $LastFetchedAt) { return [pscustomobject]@{ status = 'First'; from = $null; to = $null } }
    $oldest = $null
    foreach ($entry in @($Entries)) {
        $time = ConvertTo-FeedTime $entry.updated
        if ($null -eq $oldest -or $time -lt $oldest) { $oldest = $time }
    }
    if ($null -eq $oldest -or $oldest -le $LastFetchedAt) { return [pscustomobject]@{ status = 'Contiguous'; from = $null; to = $null } }
    return [pscustomobject]@{ status = 'PossibleGap'; from = $LastFetchedAt; to = $oldest }
}
function Get-FeedLastFetchedAt([string]$Directory) {
    $path = Join-Path $Directory 'feed-state.json'
    if (!(Test-Path -LiteralPath $path)) { return $null }
    $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $saved.snapshotFetchedAt -or [string]$saved.snapshotFetchedAt -eq '') { return $null }
    return (ConvertTo-FeedTime $saved.snapshotFetchedAt)
}
function Read-MirrorText([string]$Uri, [int]$TimeoutSec) {
    $previousTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
        $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec
    } finally { [Net.ServicePointManager]::SecurityProtocol = $previousTls }
    $response.RawContentStream.Position = 0
    $reader = New-Object IO.StreamReader($response.RawContentStream, (New-Object Text.UTF8Encoding($false,$true)))
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
function ConvertFrom-FeedStatus([string]$JsonText) {
    # Diagnostics only, strictly validated, never used for decisions.
    try {
        $status = $JsonText | ConvertFrom-Json
        if ($null -eq $status -or $status.schema -ne 1) { return $null }
        $attempt = ConvertTo-FeedTime $status.last_attempt_at
        $errorCode = [string]$status.last_error
        if ($errorCode -notmatch '^[A-Za-z0-9=:;,._ -]{0,120}$') { return $null }
        $failures = $status.consecutive_failures
        if (!($failures -is [int] -or $failures -is [long]) -or $failures -lt 0) { return $null }
        return [pscustomobject]@{ lastAttemptAt = $attempt; lastError = $errorCode; failures = [long]$failures }
    } catch { return $null }
}
function Get-FeedMirrorStatus {
    try { return (ConvertFrom-FeedStatus (Read-MirrorText ($script:FeedMirrorBase + 'feed-status.json') 15)) } catch { return $null }
}
function Get-FeedFailureSummary {
    # Why the feed is not current: snapshot age, and whether GitHub tried and failed or did not run at all.
    $parts = @()
    $info = $script:FeedDiagnostics
    if ($null -ne $info) { $parts += ('Копия GitHub от {0} UTC, возраст {1}.' -f $info.fetchedAt.UtcDateTime.ToString('yyyy-MM-dd HH:mm'), (Format-FeedAge $info.ageHours)) }
    $status = Get-FeedMirrorStatus
    if ($null -ne $status -and $status.lastError -and ($null -eq $info -or $status.lastAttemptAt -gt $info.fetchedAt)) {
        $parts += ('GitHub пытался обновить ленту {0} UTC: ошибка {1} (подряд: {2}).' -f $status.lastAttemptAt.UtcDateTime.ToString('yyyy-MM-dd HH:mm'), $status.lastError, $status.failures)
    } elseif ($null -ne $info) {
        $parts += 'Ошибок обновления после этого не записано: вероятно, GitHub Actions не запускал обновление (запуск по расписанию не гарантирован).'
    }
    $parts += 'Новые темы не добавляются; очередь автозагрузки обрабатывается.'
    return ($parts -join ' ')
}
function Get-FeedSuccessSummary {
    $snapshot = $script:LatestFeedSnapshot
    if ($null -eq $snapshot) { return '' }
    $text = 'Копия GitHub от {0} UTC, возраст {1}.' -f $snapshot.fetchedAtValue.UtcDateTime.ToString('yyyy-MM-dd HH:mm'), (Format-FeedAge $snapshot.ageHours)
    if ($script:FeedCoverage -and $script:FeedCoverage.status -eq 'PossibleGap') { $text += ' Возможен пропуск тем между копиями: см. films.html.' }
    return $text
}
function Collect-Films($TorrentRows, [string]$Directory) {
    $script:LatestFilmEntries = $null; $script:LatestFeedSnapshot = $null; $script:FeedCoverage = $null; $script:FeedDiagnostics = $null
    Write-Host 'Fetching film snapshot from GitHub (timeout: 30 seconds)...'
    # The old feed-proxy.txt applies to the unreachable upstream, not this mirror.
    $last = Get-FeedLastFetchedAt $Directory
    $jsonText = Read-MirrorText ($script:FeedMirrorBase + 'forum-252.json') 30
    $snapshot = Convert-FilmSnapshot $jsonText $last
    $coverage = Get-FeedCoverage $snapshot.entries $last
    $script:FeedCoverage = $coverage
    if ($coverage.status -eq 'PossibleGap') {
        Add-Content (Join-Path $Directory 'monitor.log') ('{0} FEED GAP: topics updated between {1} and {2} UTC may have left the 50-entry feed.' -f (Get-Date -Format s), $coverage.from.UtcDateTime.ToString('s'), $coverage.to.UtcDateTime.ToString('s')) -Encoding UTF8
    }
    Update-FilmReport $snapshot.entries $TorrentRows $Directory $snapshot.fetchedAt $snapshot $coverage
    $script:LatestFeedSnapshot = $snapshot
    $script:LatestFilmEntries = $snapshot.entries
    return $snapshot.entries.Count
}
function Get-FeedErrorDetail($Exception) {
    # Only fixed type/status codes; never log response bodies, credentials or URLs.
    $parts = @()
    $current = $Exception
    for ($depth=0; $current -and $depth -lt 6; $depth++) {
        $parts += $current.GetType().Name
        if ($current.Message -in @('MirrorInvalid','MirrorFutureDate','MirrorStaleOver6Hours','MirrorRollback','MirrorSourceStale')) { $parts += $current.Message }
        if ($current -is [Net.WebException]) {
            $parts += ('NetworkStatus=' + $current.Status.ToString())
            if ($current.Response -is [Net.HttpWebResponse]) { $parts += ('HTTP=' + [int]$current.Response.StatusCode) }
        }
        if ($current -is [Net.Sockets.SocketException]) { $parts += ('Socket=' + $current.SocketErrorCode.ToString()) }
        $current = $current.InnerException
    }
    return ($parts -join '; ')
}
