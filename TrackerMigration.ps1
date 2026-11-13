# Re-binds torrents added by TorrentControl (public magnet announce) to the personal RuTracker announce,
# without re-downloading. Requires Rules.ps1, AutoLoad.ps1 and RuTracker.ps1 (Monitor.ps1 loads them).
# Scope: only autoload journal records with status Confirmed, found in uTorrent inside their own
# D:\Фильмы\rt-<topic> folder and currently using ONLY the public magnet tracker. Manual torrents are never touched.
# The only change ever made is the tracker list of one torrent via WebUI setprops s=trackers - the same request the
# official uTorrent WebUI sends from its Properties dialog. Files, paths, data, labels and history stay as they are.
# Order: Dry Run -> one torrent with explicit confirmation -> the user confirms statistics in the RuTracker
# profile (Verify) -> only then a batch.
$script:MigrationLabels = @{
    Planned = 'Готово к перепривязке (Dry Run)'; AlreadyPersonal = 'Уже персональный трекер'; Skipped = 'Пропущено'
    WaitingAuth = 'Ожидает авторизацию RuTracker'; Cancelled = 'Отменено пользователем'; Applying = 'Выполняется'
    Applied = 'Перепривязано — проверьте статистику'; Verified = 'Статистика подтверждена пользователем'; Failed = 'Ошибка — проверьте вручную'
}

function New-WebUIContext($Config, $Credential) {
    $base = ([string]$Config.url).TrimEnd('/')
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $session.Credentials = $Credential.GetNetworkCredential()
    $page = Invoke-WebRequest "$base/gui/token.html" -WebSession $session -UseBasicParsing -TimeoutSec 30
    $match = [regex]::Match($page.Content, '<div[^>]*id=["'']token["''][^>]*>([^<]+)</div>')
    if (!$match.Success) { throw 'TokenMissing' }
    [pscustomobject]@{ base = $base; session = $session; token = [uri]::EscapeDataString($match.Groups[1].Value) }
}
function Get-WebUITrackers($Context, [string]$Hash) {
    if ($Hash -notmatch '^[0-9A-F]{40}$') { throw 'InvalidHash' }
    $response = Invoke-WebRequest ($Context.base + '/gui/?token=' + $Context.token + '&action=getprops&hash=' + $Hash) -WebSession $Context.session -UseBasicParsing -TimeoutSec 30
    $response.RawContentStream.Position = 0
    $reader = New-Object IO.StreamReader($response.RawContentStream, (New-Object Text.UTF8Encoding($false, $true)))
    try { $json = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    $props = @($json.props)[0]
    if ($null -eq $props -or ([string]$props.hash).ToUpperInvariant() -ne $Hash -or $null -eq $props.trackers) { throw 'PropsMissing' }
    return [string]$props.trackers
}
function Set-WebUITrackers($Context, [string]$Hash, [string]$Trackers) {
    # The only state change of the migration: the tracker list of one torrent (no recheck, no move).
    if ($Hash -notmatch '^[0-9A-F]{40}$') { throw 'InvalidHash' }
    $null = Invoke-WebRequest ($Context.base + '/gui/?token=' + $Context.token + '&action=setprops&hash=' + $Hash + '&s=trackers&v=' + [uri]::EscapeDataString($Trackers)) -WebSession $Context.session -UseBasicParsing -TimeoutSec 30
}
function Get-TrackerLines([string]$Text) { return @(([string]$Text) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
function ConvertTo-TrackerText($Tiers) {
    # uTorrent tracker box: one URL per line, a blank line between tiers.
    return (@(foreach ($tier in @($Tiers)) { (@($tier) -join "`r`n") }) -join "`r`n`r`n")
}
function Get-TrackerClass([string]$Text) {
    $lines = @(Get-TrackerLines $Text)
    if (!$lines.Count) { return [pscustomobject]@{ kind = 'Unexpected'; host = '' } }
    $public = 0; $hostName = ''
    foreach ($line in $lines) {
        $info = Get-AnnounceInfo $line
        if ($info.public) { $public++ } elseif ($info.personal -and !$hostName) { $hostName = $info.host }
    }
    if ($public -eq $lines.Count) { return [pscustomobject]@{ kind = 'Public'; host = '' } }
    if ($hostName -and $public -eq 0) { return [pscustomobject]@{ kind = 'Personal'; host = $hostName } }
    return [pscustomobject]@{ kind = 'Unexpected'; host = '' }
}
function Test-PathInside([string]$Path, [string]$Folder) {
    $p = $Path.TrimEnd('\'); $f = $Folder.TrimEnd('\')
    return ($p -eq $f -or $p.StartsWith($f + '\', [StringComparison]::OrdinalIgnoreCase))
}
function Read-MigrationJournal([string]$Directory) {
    $path = Join-Path $Directory 'tracker-migration.json'
    if (!(Test-Path -LiteralPath $path)) { return [pscustomobject]@{ version = 1; entries = @() } }
    $journal = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($journal.version -ne 1) { throw 'MigrationJournalInvalid' }
    return [pscustomobject]@{ version = 1; entries = @($journal.entries | Where-Object { $_ }) }
}
function Save-MigrationJournal($Journal, [string]$Directory) {
    Save-AutoJson ([ordered]@{ version = 1; entries = @($Journal.entries) }) (Join-Path $Directory 'tracker-migration.json')
}
function Get-MigrationEntry($Journal, $Item) {
    $entry = @($Journal.entries | Where-Object { $_.hash -eq $Item.hash })[0]
    if ($null -eq $entry) {
        $entry = [pscustomobject]@{ hash = [string]$Item.hash; topic = [string]$Item.topic; title = [string]$Item.title; path = [string]$Item.path
            status = ''; reason = ''; tracker = ''; checkedAt = ''; appliedAt = ''; verifiedAt = '' }
        $Journal.entries = @($Journal.entries) + $entry
    }
    $entry.checkedAt = [DateTimeOffset]::UtcNow.ToString('o')
    return $entry
}
function Write-MigrationReport($Journal, [string]$Directory, [string]$Mode) {
    $rows = @(foreach ($e in @($Journal.entries)) {
        [pscustomobject]@{ Статус = $script:MigrationLabels[[string]$e.status]; Причина = [string]$e.reason; Название = [string]$e.title; Путь = [string]$e.path
            Тема = [string]$e.topic; Сервер_статистики = [string]$e.tracker; Проверено = [string]$e.checkedAt; Перепривязано = [string]$e.appliedAt
            Подтверждено = [string]$e.verifiedAt; Hash = [string]$e.hash }
    })
    $banner = 'Режим: ' + $Mode + '. Изменяется только список трекеров раздач TorrentControl; файлы, пути и данные не меняются. Ключ трекера не показывается.'
    if ($Mode -eq 'DryRun') { $banner = 'DRY RUN — трекеры не изменяются. ' + $banner }
    $intro = '<h1>Перепривязка к персональному трекеру RuTracker</h1><p style="font-weight:bold;color:#8a1c1c">' + [Net.WebUtility]::HtmlEncode($banner) + '</p><p>Порядок: Dry Run → одна раздача с подтверждением (12-Tracker-migration-one.cmd) → проверка в профиле RuTracker → отметка «подтверждено» → только затем пакет.</p>'
    $rows | ConvertTo-Html -Head '<meta charset="utf-8"><style>body{font:15px Segoe UI;margin:24px}td,th{border:1px solid #ddd;padding:6px}table{border-collapse:collapse}</style>' -PreContent $intro | Set-Content (Join-Path $Directory 'tracker-migration.html') -Encoding UTF8
    if ($rows.Count) { $rows | Export-Csv (Join-Path $Directory 'tracker-migration.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';' }
}
function Invoke-TrackerMigration {
    param([string]$Directory, [string]$Mode = 'DryRun', [string]$Hash = '', $Config, $Credential, [scriptblock]$Confirm, [int]$PauseSeconds = 2)
    if ($Mode -notin @('DryRun', 'Apply', 'Verify', 'Batch')) { throw 'InvalidMode' }
    $Hash = $Hash.ToUpperInvariant()
    $autoPath = Join-Path $Directory 'auto-state.json'
    if (!(Test-Path -LiteralPath $autoPath)) { throw 'AutoBaselineMissing' }
    $auto = Get-Content -LiteralPath $autoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $journal = Read-MigrationJournal $Directory
    if ($Mode -in @('Apply', 'Verify') -and $Hash -notmatch '^[0-9A-F]{40}$') { throw 'HashRequired' }
    if ($Mode -eq 'Verify') {
        $entry = @($journal.entries | Where-Object { $_.hash -eq $Hash -and $_.status -eq 'Applied' })[0]
        if ($null -eq $entry) { throw 'NothingToVerify' }
        $answer = [string](& $Confirm ('Введите VERIFIED ' + $Hash.Substring(0, 8) + ' только если uTorrent показывает трекер как работающий И раздача видна в профиле RuTracker с засчитанной отдачей'))
        if ($answer.Trim() -ne ('VERIFIED ' + $Hash.Substring(0, 8))) { throw 'VerifyCancelled' }
        $entry.status = 'Verified'; $entry.verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
        Save-MigrationJournal $journal $Directory; Write-MigrationReport $journal $Directory $Mode
        return [pscustomobject]@{ mode = $Mode; verified = 1 }
    }
    if ($Mode -eq 'Batch' -and !@($journal.entries | Where-Object { $_.status -eq 'Verified' }).Count) { throw 'BatchNeedsVerifiedMigration' }
    $data = Fetch-List $Config $Credential
    $rows = @($data.torrents)
    $problem = Get-TorrentListProblem $rows
    if ($problem) { throw "ClientDataInvalid:$problem" }
    $paths = Read-LocalPaths
    $owned = @($auto.items | Where-Object { $_.status -eq 'Confirmed' -and [string]$_.hash -match '^[0-9A-Fa-f]{40}$' -and [string]$_.path -match '^D:\\Фильмы\\rt-\d+$' })
    if ($Mode -eq 'Apply') {
        $owned = @($owned | Where-Object { ([string]$_.hash).ToUpperInvariant() -eq $Hash })
        if (!$owned.Count) { throw 'NotOwnedByTorrentControl' }
    }
    if ($Mode -eq 'Batch') {
        $answer = [string](& $Confirm ('Введите YES BATCH, чтобы перепривязать до ' + $owned.Count + ' раздач TorrentControl по одной, с остановкой на первой проблеме'))
        if ($answer.Trim() -ne 'YES BATCH') { throw 'BatchCancelled' }
    }
    $context = New-WebUIContext $Config $Credential
    $summary = [ordered]@{ mode = $Mode; planned = 0; applied = 0; already = 0; skipped = 0; waiting = 0; failed = 0; cancelled = 0 }
    foreach ($item in $owned) {
        $hash = ([string]$item.hash).ToUpperInvariant()
        $entry = Get-MigrationEntry $journal $item
        # An interrupted or failed change needs a look by the person: only an explicit -Apply for this hash retries it.
        if ($entry.status -eq 'Applying') { $entry.status = 'Failed'; $entry.reason = 'Interrupted' }
        if ($entry.status -eq 'Failed' -and $Mode -ne 'Apply') { $summary.failed++; continue }
        $row = Find-AutoRow $rows $hash
        $actual = ''
        if ($null -ne $row) { $actual = Get-AutoPath $row $paths }
        if ($null -eq $row) { $entry.status = 'Skipped'; $entry.reason = 'NotInClient'; $summary.skipped++; continue }
        if (!$actual -or !(Test-PathInside $actual ([string]$item.path))) { $entry.status = 'Skipped'; $entry.reason = 'PathMismatch'; $summary.skipped++; continue }
        $class = Get-TrackerClass (Get-WebUITrackers $context $hash)
        if ($class.kind -eq 'Personal') {
            if ($entry.status -notin @('Applied', 'Verified')) { $entry.status = 'AlreadyPersonal'; $entry.reason = '' }
            $entry.tracker = $class.host; $summary.already++; continue
        }
        if ($class.kind -ne 'Public') { $entry.status = 'Skipped'; $entry.reason = 'UnexpectedTrackers'; $summary.skipped++; continue }
        $personal = $null
        try { $personal = Get-PersonalTorrent $Directory ([string]$item.topic) $hash }
        catch {
            $code = Get-RuTrackerCode $_.Exception
            if ($code -eq 'PersonalHashMismatch') { $entry.status = 'Skipped'; $entry.reason = 'TopicHashChanged'; $summary.skipped++; continue }
            # The same problem would repeat for every torrent: stop here.
            $entry.status = 'WaitingAuth'; $entry.reason = $code; $summary.waiting++
            break
        }
        $text = ConvertTo-TrackerText $personal.tiers
        $entry.tracker = $personal.host
        if ($Mode -eq 'DryRun') {
            $entry.status = 'Planned'; $entry.reason = ''; $summary.planned++
            if ($PauseSeconds -gt 0) { Start-Sleep -Seconds $PauseSeconds }
            continue
        }
        if ($Mode -eq 'Apply') {
            $answer = [string](& $Confirm ('Введите YES ' + $hash.Substring(0, 8) + ', чтобы заменить публичный трекер раздачи «' + $item.title + '» на ваш персональный трекер RuTracker (' + $personal.host + ')'))
            if ($answer.Trim() -ne ('YES ' + $hash.Substring(0, 8))) { $entry.status = 'Cancelled'; $entry.reason = ''; $summary.cancelled++; continue }
        }
        $before = @($row[3], $row[4], $row[18], $actual)
        $entry.status = 'Applying'; $entry.reason = ''
        Save-MigrationJournal $journal $Directory   # recorded before the change
        Set-WebUITrackers $context $hash $text
        $readBack = @(Get-TrackerLines (Get-WebUITrackers $context $hash))
        $wanted = @(Get-TrackerLines $text)
        if (($readBack -join "`n") -ne ($wanted -join "`n")) { $entry.status = 'Failed'; $entry.reason = 'ReadBackMismatch'; $summary.failed++; break }
        $after = Find-AutoRow @((Fetch-List $Config $Credential).torrents) $hash
        $afterPath = ''
        if ($null -ne $after) { $afterPath = Get-AutoPath $after (Read-LocalPaths) }
        if ($null -eq $after -or $afterPath -ne $before[3] -or $after[3] -ne $before[0] -or $after[4] -ne $before[1] -or $after[18] -ne $before[2] -or (([long]$after[1]) -band 2)) {
            $entry.status = 'Failed'; $entry.reason = 'StateChanged'; $summary.failed++; break
        }
        $entry.status = 'Applied'; $entry.appliedAt = [DateTimeOffset]::UtcNow.ToString('o'); $summary.applied++
        if ($Mode -eq 'Batch' -and $PauseSeconds -gt 0) { Start-Sleep -Seconds $PauseSeconds }
    }
    Save-MigrationJournal $journal $Directory
    Write-MigrationReport $journal $Directory $Mode
    return [pscustomobject]$summary
}
