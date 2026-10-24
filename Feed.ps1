function Convert-FilmFeed([string]$XmlText) {
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
    foreach ($entry in $doc.SelectNodes('/a:feed/a:entry',$ns)) {
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
function Update-FilmReport($Entries, $TorrentRows, [string]$Directory) {
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
    $intro = '<h1>Фильмы — раздел 252</h1><p>Только подборка, скачивание отключено.</p><p>Обновлено: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '</p><p>При первом запуске записи образуют исходный список. Новая для наблюдателя — тема впервые появилась после него. Дата в ленте — поле updated, не подтверждённая дата создания темы. Лента ограничена: пропущенные при долгом простое записи могут не попасть в отчёт.</p><p>Совпадения с µTorrent проверены по хешу среди всех дисков. Разные версии одного фильма могут иметь разные хеши.</p>'
    $html = '<!doctype html><html lang="ru"><meta charset="utf-8"><title>Новые публикации</title><style>body{font:15px Segoe UI;margin:24px;background:#f5f7fa}table{border-collapse:collapse;width:100%;background:white}td,th{padding:9px;border:1px solid #ddd;text-align:left}th{background:#dfeafa}td{overflow-wrap:anywhere}</style><body>' + $intro + $table + '</body></html>'
    $html | Set-Content (Join-Path $Directory 'films.html') -Encoding UTF8
    $visible | Export-Csv (Join-Path $Directory 'films.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    $state = @{version=1;updated=$now;items=@($known.Values)}
    $state | ConvertTo-Json -Depth 6 | Set-Content "$statePath.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$statePath.tmp" -Destination $statePath -Force
}
function Collect-Films($TorrentRows, [string]$Directory) {
    $params = @{Uri='https://feed.rutracker.cc/atom/f/252.atom';UseBasicParsing=$true;TimeoutSec=30}
    $proxyFile = Join-Path $Directory 'feed-proxy.txt'
    if (Test-Path $proxyFile) { $params.Proxy = (Get-Content $proxyFile -Raw).Trim() }
    $response = Invoke-WebRequest @params
    $response.RawContentStream.Position = 0
    $reader = New-Object IO.StreamReader($response.RawContentStream, (New-Object Text.UTF8Encoding($false,$true)))
    try { $xmlText = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $entries = @(Convert-FilmFeed $xmlText)
    Update-FilmReport $entries $TorrentRows $Directory
    return $entries.Count
}
