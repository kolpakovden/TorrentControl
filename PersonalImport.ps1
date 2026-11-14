# Personal .torrent files that the person downloads in Firefox (logged in to RuTracker there) and imports here, and the
# offline check of one old TorrentControl torrent before its tracker is re-bound. Needs AutoLoad.ps1 and RuTracker.ps1;
# the check also needs Monitor.ps1 and TrackerMigration.ps1 (read-only WebUI functions).
# - No network access to RuTracker, no browser profile or cookie: the person chooses the file.
# - The file is identified by its own infohash (never by its name) and must belong to a record of auto-state.json;
#   it is verified with TorrentMetadata.Verify and Test-PersonalTorrent and stored unchanged in
#   %LOCALAPPDATA%\TorrentControl\personal (current user only). Get-PersonalTorrent then uses it without the network.
# - The TorrentControl folder given as -StateDirectory (e.g. C:\TorrentMonitor) is only read, with sharing that never
#   blocks the running monitor; nothing is written there. Reports go to the folder of these scripts.
$script:ImportableStatuses = @('Confirmed', 'WaitingAuth', 'WaitingMetadata', 'NoSpace')
$script:PersonalImportCodes = @('ImportFileMissing', 'ImportNotInAutoState', 'ImportTopicMismatch', 'ImportStatusNotAllowed', 'AutoStateNotFound',
    'AutoStateUnreadable', 'HashOrTopicRequired', 'InvalidHash', 'InvalidTopic', 'NotInAutoState', 'AmbiguousTopic', 'ReadOnlyViolation', 'StateDirectoryMissing')
$script:PersonalTexts = @{
    ImportFileMissing = 'Файл не найден. Укажите полный путь к .torrent, скачанному в Firefox.'
    ImportNotInAutoState = 'Hash этого .torrent не найден в auto-state.json: файл не относится ни к одной раздаче TorrentControl (другая тема или перезалитая раздача).'
    ImportTopicMismatch = 'Указанный номер темы не совпадает с темой этой раздачи в auto-state.json.'
    ImportStatusNotAllowed = 'Запись в auto-state.json не относится к раздачам TorrentControl, для которых нужен персональный .torrent (например, ручная или отклонённая).'
    AutoStateNotFound = 'В указанной папке нет auto-state.json. Укажите папку TorrentControl: -StateDirectory C:\TorrentMonitor.'
    AutoStateUnreadable = 'auto-state.json не читается.'
    StateDirectoryMissing = 'Папка TorrentControl не указана или не существует.'
    HashOrTopicRequired = 'Укажите раздачу: -Topic <номер темы> или -Hash <40 символов>.'
    InvalidHash = 'Hash должен состоять из 40 шестнадцатеричных символов.'
    InvalidTopic = 'Номер темы должен состоять из цифр.'
    NotInAutoState = 'Такой раздачи нет в auto-state.json: это не раздача TorrentControl (ручные раздачи не проверяются и не меняются).'
    AmbiguousTopic = 'У этой темы несколько записей с разными hash; укажите -Hash.'
    ReadOnlyViolation = 'Попытка изменения в режиме проверки остановлена.'
    PersonalTorrentInvalid = 'Файл повреждён или содержит недопустимые пути.'
    PersonalAnnounceMissing = 'В файле нет персонального адреса подтверждённого сервера RuTracker (скачан без входа или это не файл RuTracker).'
    PersonalTrackersUnexpected = 'В файле кроме персонального адреса есть публичный или посторонний трекер.'
    PersonalHashMismatch = 'Hash файла не совпал с записью.'
    PersonalTopicMismatch = 'В файле указана другая тема RuTracker.'
    PersonalImportInvalid = 'Сохранённый файл не прошёл повторную проверку (подменён или повреждён); импортируйте его заново.'
    LocalAppDataMissing = 'Не определена папка профиля Windows (LOCALAPPDATA).'
}
$script:CheckTexts = @{
    ReadyToRebind = 'ГОТОВО К ПЕРЕПРИВЯЗКЕ: публичный трекер этой раздачи можно заменить персональным без перекачки. Ничего не изменено.'
    OfflineOnly = 'Файл и запись в порядке, но µTorrent не проверялся (нет WebUI или -NoWebUI): готовность не подтверждена.'
    NotOwnedByTorrentControl = 'Запись не подтверждена как раздача TorrentControl в своей папке D:\Фильмы\rt-<тема>: не трогается.'
    NotImported = 'Персональный .torrent этой темы ещё не импортирован: скачайте его в Firefox и запустите 16-Import-personal-torrent.cmd.'
    PersonalImportInvalid = 'Сохранённый персональный .torrent не прошёл повторную проверку (подменён или повреждён): импортируйте его заново.'
    PersonalTopicMismatch = 'Сохранённый файл относится к другой теме.'
    NotInClient = 'Раздачи с этим hash нет в µTorrent.'
    PathUnknown = 'Путь раздачи в µTorrent не определён (ни WebUI, ни resume.dat): проверка остановлена.'
    PathMismatch = 'Раздача в µTorrent лежит не в своей папке TorrentControl: не трогается.'
    ClientChecking = 'µTorrent сейчас проверяет эту раздачу: повторите позже.'
    AlreadyPersonal = 'У раздачи уже персональный трекер RuTracker: перепривязка не нужна.'
    UnexpectedTrackers = 'У раздачи посторонние или смешанные трекеры: автоматическая замена не выполняется.'
    ClientDataInvalid = 'µTorrent вернул некорректный список раздач: проверка остановлена.'
    ClientUnavailable = 'WebUI µTorrent недоступен для чтения: проверка µTorrent не выполнена.'
}

function Read-SharedText([string]$Path) {
    # Read without blocking the monitor (it replaces its JSON files atomically while this may be reading).
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]'ReadWrite, Delete'))
    try { $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false)), $true); return $reader.ReadToEnd() }
    finally { $stream.Dispose() }
}
function Resolve-StateDirectory([string]$Directory) {
    if (!$Directory -or !(Test-Path -LiteralPath $Directory -PathType Container)) { throw 'StateDirectoryMissing' }
    return (Resolve-Path -LiteralPath $Directory).ProviderPath
}
function Read-AutoStateRecords([string]$StateDirectory) {
    $path = Join-Path (Resolve-StateDirectory $StateDirectory) 'auto-state.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw 'AutoStateNotFound' }
    $state = $null
    try { $state = (Read-SharedText $path) | ConvertFrom-Json } catch { throw 'AutoStateUnreadable' }
    if ($null -eq $state -or $state.version -ne 1) { throw 'AutoStateUnreadable' }
    return @($state.items | Where-Object { $null -ne $_ -and [string]$_.hash -match '^[0-9A-Fa-f]{40}$' -and [string]$_.topic -match '^\d{1,12}$' })
}
function Test-TorrentControlOwned($Item) {
    # Added by TorrentControl and confirmed in its own folder D:\Фильмы\rt-<topic> of the same topic.
    if ([string]$Item.status -ne 'Confirmed') { return $false }
    $match = [regex]::Match([string]$Item.path, '^D:\\Фильмы\\rt-(\d{1,12})$')
    return ($match.Success -and $match.Groups[1].Value -eq [string]$Item.topic)
}
function Get-PersonalCode($Exception) {
    $message = [string]$Exception.Message
    if ($message -in $script:PersonalImportCodes -or $message -in $script:RuTrackerCodes) { return $message }
    return $Exception.GetType().Name
}
function Get-TopicLinks([string]$Topic) {
    [pscustomobject]@{ topic = 'https://rutracker.org/forum/viewtopic.php?t=' + $Topic; download = 'https://rutracker.org/forum/dl.php?t=' + $Topic }
}
function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)) } finally { $sha.Dispose() }
}

function Import-PersonalTorrentFile([string]$Path, [string]$StateDirectory, [string]$Topic = '') {
    # Returns { status = Imported | Replaced | AlreadyImported; hash; topic; title; record; host; path; size }.
    if ($Topic -and $Topic -notmatch '^\d{1,12}$') { throw 'InvalidTopic' }
    if (!$Path -or !(Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'ImportFileMissing' }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    if (!('TorrentMetadata' -as [type])) { Add-Type -Path "$PSScriptRoot\TorrentMetadata.cs" }
    $hash = ''
    try { $hash = [TorrentMetadata]::InfoHash($full) } catch { throw 'PersonalTorrentInvalid' }
    $item = @(Read-AutoStateRecords $StateDirectory | Where-Object { ([string]$_.hash).ToUpperInvariant() -eq $hash })[0]
    if ($null -eq $item) { throw 'ImportNotInAutoState' }
    if ($Topic -and $Topic -ne [string]$item.topic) { throw 'ImportTopicMismatch' }
    if ([string]$item.status -notin $script:ImportableStatuses -or ([string]$item.status -eq 'Confirmed' -and !(Test-TorrentControlOwned $item))) { throw 'ImportStatusNotAllowed' }
    $bytes = [IO.File]::ReadAllBytes($full)
    $target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Get-PersonalTorrentPath $hash))
    $status = 'Imported'
    if ([IO.File]::Exists($target)) {
        if ((Get-BytesSha256 ([IO.File]::ReadAllBytes($target))) -eq (Get-BytesSha256 $bytes)) {
            $stored = Get-ImportedPersonalTorrent $hash ([string]$item.topic)
            return [pscustomobject]@{ status = 'AlreadyImported'; hash = $hash; topic = [string]$item.topic; title = [string]$item.title; record = [string]$item.status
                host = $stored.host; path = $stored.path; size = $stored.size }
        }
        $status = 'Replaced'
    }
    $saved = Save-PersonalTorrentBytes $bytes $hash ([string]$item.topic)
    [pscustomobject]@{ status = $status; hash = $hash; topic = [string]$item.topic; title = [string]$item.title; record = [string]$item.status
        host = $saved.host; path = $saved.path; size = $saved.size }
}
function Format-ImportResult($Result) {
    $texts = @{ Imported = 'ИМПОРТИРОВАН'; Replaced = 'ИМПОРТИРОВАН (заменил прежний файл этой раздачи)'; AlreadyImported = 'УЖЕ ИМПОРТИРОВАН (тот же файл)' }
    @(
        ($texts[$Result.status] + ': тема ' + $Result.topic + ' — ' + $Result.title)
        ('hash: ' + $Result.hash + '; запись auto-state.json: ' + $Result.record + '; сервер статистики: ' + $Result.host + ' (ключ не показывается)')
        ('Файл сохранён без изменений: ' + $Result.path)
        'Проверено: bencode и пути, infohash = запись TorrentControl, персональный адрес RuTracker, нет публичных и посторонних трекеров. Сеть не использовалась.'
    )
}

function Find-AutoStateRecord([string]$StateDirectory, [string]$Hash = '', [string]$Topic = '') {
    $items = @(Read-AutoStateRecords $StateDirectory)
    $found = @()
    if ($Hash) {
        if ($Hash -notmatch '^[0-9A-Fa-f]{40}$') { throw 'InvalidHash' }
        $found = @($items | Where-Object { ([string]$_.hash).ToUpperInvariant() -eq $Hash.ToUpperInvariant() })
    } elseif ($Topic) {
        if ($Topic -notmatch '^\d{1,12}$') { throw 'InvalidTopic' }
        $found = @($items | Where-Object { [string]$_.topic -eq $Topic })
    } else { throw 'HashOrTopicRequired' }
    if (!$found.Count) { throw 'NotInAutoState' }
    if ($found.Count -gt 1) { throw 'AmbiguousTopic' }
    if ($Hash -and $Topic -and [string]$found[0].topic -ne $Topic) { throw 'ImportTopicMismatch' }
    return $found[0]
}
function Get-PersonalMigrationList([string]$StateDirectory) {
    # Old TorrentControl torrents with their topic, the link to open in Firefox and the import state. Offline.
    foreach ($item in @(Read-AutoStateRecords $StateDirectory | Where-Object { Test-TorrentControlOwned $_ })) {
        $hash = ([string]$item.hash).ToUpperInvariant()
        $imported = 'нет'
        try { $local = Get-ImportedPersonalTorrent $hash ([string]$item.topic); if ($null -ne $local) { $imported = 'да (' + $local.host + ')' } }
        catch { $imported = 'ошибка проверки — импортируйте заново' }
        $links = Get-TopicLinks ([string]$item.topic)
        [pscustomobject]@{ topic = [string]$item.topic; title = [string]$item.title; hash = $hash; imported = $imported; topicUrl = $links.topic; downloadUrl = $links.download }
    }
}
function Write-PersonalMigrationList($List, [string]$ReportDirectory) {
    $encode = { param($text) [Net.WebUtility]::HtmlEncode([string]$text) }
    $rows = foreach ($entry in @($List)) {
        '<tr><td>' + (& $encode $entry.topic) + '</td><td>' + (& $encode $entry.title) + '</td><td><a href="' + $entry.topicUrl + '">тема</a></td><td><a href="' +
            $entry.downloadUrl + '">скачать .torrent</a></td><td>' + (& $encode $entry.imported) + '</td><td>' + (& $encode $entry.hash) + '</td></tr>'
    }
    $html = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>TorrentControl: персональные .torrent</title><style>body{font:15px Segoe UI;margin:24px}td,th{border:1px solid #ddd;padding:6px}table{border-collapse:collapse}</style></head><body>' +
        '<h1>Раздачи TorrentControl и персональные .torrent</h1><p>Откройте ссылку «скачать .torrent» в Firefox (вход в RuTracker), затем импортируйте файл: 16-Import-personal-torrent.cmd. ' +
        'Ничего не изменяется; ключ трекера здесь не показывается.</p><table><tr><th>Тема</th><th>Название</th><th>Ссылка</th><th>Файл</th><th>Импортирован</th><th>Hash</th></tr>' + (@($rows) -join '') + '</table></body></html>'
    [IO.File]::WriteAllText((Join-Path $ReportDirectory 'personal-migration-list.html'), $html, (New-Object Text.UTF8Encoding($true)))
    return (Join-Path $ReportDirectory 'personal-migration-list.html')
}

function Invoke-PersonalMigrationCheck {
    # Dry Run for ONE torrent: ownership, imported file, presence, path, hash and current trackers in uTorrent.
    # uTorrent is only read (token.html, list=1, getprops); nothing is changed anywhere.
    param([string]$StateDirectory, [string]$Hash = '', [string]$Topic = '', $Config = $null, $Credential = $null, [switch]$NoWebUI)
    $item = Find-AutoStateRecord $StateDirectory $Hash $Topic
    $hash = ([string]$item.hash).ToUpperInvariant(); $topic = [string]$item.topic
    $checks = New-Object Collections.Generic.List[object]
    $reason = ''
    $owned = Test-TorrentControlOwned $item
    $checks.Add([pscustomobject]@{ name = 'Раздача TorrentControl'; ok = $owned; text = ('статус ' + $item.status + ', папка ' + $item.path) })
    if (!$owned) { $reason = 'NotOwnedByTorrentControl' }
    $local = $null; $localCode = ''
    try { $local = Get-ImportedPersonalTorrent $hash $topic } catch { $localCode = Get-PersonalCode $_.Exception }
    if ($localCode) { $checks.Add([pscustomobject]@{ name = 'Персональный .torrent'; ok = $false; text = $localCode }); if (!$reason) { $reason = $localCode } }
    elseif ($null -eq $local) { $checks.Add([pscustomobject]@{ name = 'Персональный .torrent'; ok = $false; text = 'не импортирован' }); if (!$reason) { $reason = 'NotImported' } }
    else { $checks.Add([pscustomobject]@{ name = 'Персональный .torrent'; ok = $true; text = ('infohash совпадает, сервер ' + $local.host + ', посторонних трекеров нет') }) }
    $current = ''; $clientPath = ''; $clientCode = ''
    if ($NoWebUI -or $null -eq $Config) { $clientCode = 'ClientNotChecked' }
    elseif (!$owned) { $clientCode = 'ClientNotChecked' }   # a torrent that is not TorrentControl's is not even read
    else {
        try {
            $rows = @((Fetch-List $Config $Credential).torrents)
            if (Get-TorrentListProblem $rows) { $clientCode = 'ClientDataInvalid' }
            else {
                $row = Find-AutoRow $rows $hash
                if ($null -eq $row) { $clientCode = 'NotInClient' }
                else {
                    $clientPath = Get-AutoPath $row (Read-LocalPaths)
                    if (!$clientPath) { $clientCode = 'PathUnknown' }
                    elseif (!(Test-PathInside $clientPath ([string]$item.path))) { $clientCode = 'PathMismatch' }
                    elseif (([long]$row[1]) -band 2) { $clientCode = 'ClientChecking' }
                    else {
                        $context = New-WebUIContext $Config $Credential
                        $current = (Get-TrackerClass (Get-WebUITrackers $context $hash)).kind
                        if ($current -eq 'Personal') { $clientCode = 'AlreadyPersonal' } elseif ($current -ne 'Public') { $clientCode = 'UnexpectedTrackers' }
                    }
                }
            }
        } catch { $clientCode = 'ClientUnavailable' }
        $text = 'в µTorrent, папка ' + $clientPath + ', hash совпадает, трекеры: ' + $current
        if ($clientCode) { $text = $clientCode }
        $checks.Add([pscustomobject]@{ name = 'µTorrent (только чтение)'; ok = !$clientCode; text = $text })
    }
    $verdict = 'ReadyToRebind'
    if ($reason) { $verdict = 'NotReady' }
    elseif ($clientCode -eq 'ClientNotChecked') { $verdict = 'OfflineOnly'; $reason = 'OfflineOnly' }
    elseif ($clientCode) { $verdict = 'NotReady'; $reason = $clientCode }
    $planned = ''
    if ($null -ne $local) { $planned = $local.host }
    $links = Get-TopicLinks $topic
    [pscustomobject]@{ verdict = $verdict; reason = $reason; hash = $hash; topic = $topic; title = [string]$item.title; record = [string]$item.status
        path = [string]$item.path; clientPath = $clientPath; current = $current; planned = $planned; topicUrl = $links.topic; downloadUrl = $links.download; checks = $checks.ToArray() }
}
function Format-PersonalCheck($Result) {
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('Проверка перепривязки (Dry Run, только чтение) — ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $lines.Add('Тема ' + $Result.topic + ': ' + $Result.title)
    $lines.Add('hash: ' + $Result.hash + '; ссылка: ' + $Result.topicUrl + '; персональный .torrent: ' + $Result.downloadUrl)
    foreach ($check in $Result.checks) {
        $mark = '[нет]'; if ($check.ok) { $mark = '[да] ' }
        $lines.Add($mark + ' ' + $check.name + ': ' + $check.text)
    }
    if ($Result.verdict -eq 'ReadyToRebind') { $lines.Add('ИТОГ: ' + $script:CheckTexts.ReadyToRebind + ' Будет: ' + $Result.planned + ' вместо публичного адреса.') }
    else {
        $text = $script:CheckTexts[[string]$Result.reason]
        if (!$text) { $text = $script:PersonalTexts[[string]$Result.reason] }
        $lines.Add('ИТОГ: НЕ ГОТОВО (' + $Result.reason + '). ' + $text)
    }
    $lines.Add('В µTorrent ничего не изменялось. Начисление статистики подтверждается только после реальной перепривязки и проверки профиля.')
    return $lines.ToArray()
}
