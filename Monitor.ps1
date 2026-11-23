param([switch]$Setup, [switch]$Once)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. "$root\Rules.ps1"
. "$root\LocalPaths.ps1"
. "$root\Feed.ps1"
. "$root\AutoLoad.ps1"
. "$root\Cleanup.ps1"
# Compact JSON: state.json holds the hourly upload history of every torrent on D:/F:.
function Save-Json($Value, $Path) { Save-AutoJson $Value $Path -Compress }
function Get-MonitorErrorCode($Exception) {
    # Fixed codes only; never log response bodies, tokens or URLs.
    $allowed = @('EmptyTorrentList','UnsupportedRowFormat','StateUnreadable','StateMissingBackupPresent','TokenMissing','TorrentListMissing')
    if ($Exception.Message -in $allowed) { return $Exception.Message }
    return 'Other'
}
function Fetch-List($Config, $Credential) {
    $base = ([string]$Config.url).TrimEnd('/')
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $session.Credentials = $Credential.GetNetworkCredential()
    $tokenPage = Invoke-WebRequest "$base/gui/token.html" -WebSession $session -UseBasicParsing -TimeoutSec 30
    $match = [regex]::Match($tokenPage.Content, '<div[^>]*id=["'']token["''][^>]*>([^<]+)</div>')
    if (!$match.Success) { throw 'TokenMissing' }
    $token = [uri]::EscapeDataString($match.Groups[1].Value)
    $response = Invoke-WebRequest "$base/gui/?token=$token&list=1" -WebSession $session -UseBasicParsing -TimeoutSec 30
    # Legacy WebUI can omit charset; Windows PowerShell then misdecodes UTF-8.
    $response.RawContentStream.Position = 0
    $reader = New-Object IO.StreamReader($response.RawContentStream, (New-Object Text.UTF8Encoding($false, $true)))
    try { $json = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $data = $json | ConvertFrom-Json
    if ($null -eq $data.torrents) { throw 'TorrentListMissing' }
    return $data
}
function Read-HistoryState([string]$Path) {
    if (!(Test-Path -LiteralPath $Path)) {
        # Missing file next to a leftover copy is ambiguous (interrupted save): stop instead of starting over.
        if ((Test-Path -LiteralPath "$Path.tmp") -or (Test-Path -LiteralPath "$Path.bak")) { throw 'StateMissingBackupPresent' }
        return @()
    }
    $saved = $null
    try { $saved = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw 'StateUnreadable' }
    if ($null -eq $saved -or $saved.version -ne 1 -or $null -eq $saved.items) { throw 'StateUnreadable' }
    return @($saved.items)
}
function Collect {
    $config = Get-Content "$root\config.json" -Raw | ConvertFrom-Json
    $credential = Import-Clixml "$root\credential.xml"
    $statePath = "$root\state.json"
    # Read history first: an unreadable history stops the whole poll before anything is written.
    $previousItems = @(Read-HistoryState $statePath)
    $data = Fetch-List $config $credential
    $torrents = @($data.torrents)
    # An empty list after a non-empty history is treated as a client/WebUI glitch, never as mass removal.
    if ($torrents.Count -eq 0 -and $previousItems.Count -gt 0) { throw 'EmptyTorrentList' }
    Assert-TorrentRows $torrents
    $feedMessage = 'Подборка фильмов не обновлена; подробности в monitor.log.'
    try {
        $feedCount = Collect-Films $torrents $root
        $feedMessage = "Подборка фильмов обновлена: $feedCount записей. " + (Get-FeedSuccessSummary)
    } catch {
        $detail = Get-FeedErrorDetail $_.Exception
        $feedMessage = "Подборка фильмов не обновлена: $detail. " + (Get-FeedFailureSummary)
        Write-Host "Feed failed: $detail" -ForegroundColor Yellow
        $age = ''
        if ($null -ne $script:FeedDiagnostics) { $age = "; snapshotAgeHours=$($script:FeedDiagnostics.ageHours)" }
        Add-Content "$root\monitor.log" "$(Get-Date -Format s) FEED ERROR: $detail$age. Torrent monitoring continues." -Encoding UTF8
    }
    $localPaths = Read-LocalPaths
    $autoMessage=''
    # The whole WebUI response is checked strictly before autoload may submit anything.
    $listProblem = Get-TorrentListProblem $torrents
    if ($listProblem) {
        $autoMessage = "Автозагрузка не запускалась: µTorrent вернул некорректные данные ($listProblem). Новые раздачи не отправляются, пока список не станет корректным."
        Add-Content "$root\monitor.log" "$(Get-Date -Format s) AUTO SKIPPED: ClientDataInvalid:$listProblem" -Encoding UTF8
    } else {
        # The queue (path confirmation, metadata retries, waiting for space) does not depend on the feed.
        # Without a valid snapshot no new topics are added, so a stale feed only delays discovery.
        $entries = @()
        if ($null -ne $script:LatestFilmEntries) { $entries = $script:LatestFilmEntries }
        try {
            $autoMessage=Invoke-AutoLoad $entries $torrents $localPaths $config $credential $root
            if ($null -eq $script:LatestFilmEntries) { $autoMessage = 'Лента не обновлена: новые темы не добавляются. ' + $autoMessage }
        }
        catch {
            $autoMessage='Автозагрузка приостановлена из-за ошибки; см. monitor.log.'
            Add-Content "$root\monitor.log" "$(Get-Date -Format s) AUTO ERROR: $($_.Exception.GetType().Name); $(Get-AutoErrorCode $_.Exception)" -Encoding UTF8
        }
    }
    $now = Get-UnixNow
    $merge = Merge-History $torrents $localPaths $previousItems $now
    # Cleanup is Dry Run only: decisions are reported, nothing is deleted, stopped or changed.
    $cleanupMode = Get-CleanupMode $root
    $owned = Get-CleanupOwnership $root
    $observed = @($merge.observed)
    $decisions = @(foreach ($entry in $observed) { Get-CleanupDecision $entry $now $listProblem $owned })
    # History first: if it cannot be saved, no report shows decisions the next run could not reproduce.
    Save-Json @{ version = 1; updated = $now; items = @($merge.items) } $statePath
    $report = @()
    for ($i = 0; $i -lt $observed.Count; $i++) {
        $entry = $observed[$i]; $row = $entry.row; $state = $entry.state
        $report += [pscustomobject]@{
            Решение = $decisions[$i].decision; Причина = $decisions[$i].reason; Признак_спроса = (Get-DemandLabel $state)
            Название = [string]$row[2]; Путь = $entry.path
            ГБ = (Format-RowNumber $row[3] 1GB 2)
            Готово = (Format-RowNumber $row[4] 10 1)
            Дней_хранения = [math]::Round(($now - $state.firstSeen) / 86400, 1)
            Дней_без_спроса = [math]::Round(($now - $state.quietSince) / 86400, 1)
            Отдано_за_наблюдение_МБ = [math]::Round($state.observedUpload / 1MB, 2)
            Отдача_КБ_с = (Format-RowNumber $row[8] 1KB 1)
            Пиров_подключено = (Format-RowNumber $row[12]); Сидов_подключено = (Format-RowNumber $row[14])
            Пиров_в_рое = (Format-RowNumber $row[13]); Сидов_в_рое = (Format-RowNumber $row[15]); Hash = $state.hash
        }
    }
    $report = @($report | Sort-Object Решение, Название)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $observedCount = $observed.Count
    $notes = @()
    if ($cleanupMode.warning) { $notes += $cleanupMode.warning }
    if ($merge.unknown -gt 0) { $notes += "Путь не определён у $($merge.unknown) раздач: они не оцениваются." }
    $cleanup = Write-CleanupReport $decisions $root $cleanupMode.mode $now $merge.excluded $notes
    $cleanupGib = [math]::Round($cleanup.bytes / 1GB, 2)
    $intro = "<h1>Монитор временных раздач</h1><p style='font-weight:bold;color:#8a1c1c'>$($script:CleanupBanner)</p><p>Обновлено: $stamp. Раздач D/F: $observedCount. Другие диски: $($merge.excluded). Путь не определён: $($merge.unknown). Некорректные данные клиента: $($merge.invalid).</p>"
    $intro += "<p>Очистка ($($cleanupMode.mode)): кандидатов $($cleanup.candidates), потенциально освобождается $cleanupGib ГиБ — <a href='cleanup.html'>отчёт об очистке</a>. Кандидат: полностью скачана, наблюдается не менее 30 дней, в каждые из трёх последних суток отдано менее 1 ГиБ, сейчас нет отдачи и подключённых скачивающих пиров. «Признак_спроса» и «Дней_без_спроса» показаны справочно.</p>"
    $intro += '<p>Столбцы «Пиров_в_рое» и «Сидов_в_рое» — сведения о рое в целом (по данным трекера), а не о нашей раздаче; на решение они не влияют. «н/д» — клиент не сообщил корректное значение.</p>'
    if ($merge.kept -gt 0 -or $merge.missing -gt 0) {
        $intro += "<p>История сохранена без обновления: $($merge.kept) (путь временно не определён, данные некорректны или отсутствие раздачи не подтверждено). Нет в списке клиента: $($merge.missing) — история удаляется только после трёх подряд проверок без раздачи и не ранее чем через 6 часов.</p>"
    }
    $style = '<meta charset="utf-8"><style>body{font:15px Segoe UI;margin:28px;background:#f5f7fa}table{border-collapse:collapse;background:white;width:100%}td,th{padding:9px;border:1px solid #ddd;text-align:left}th{background:#dfeafa}h1{color:#17365d}</style>'
    if ($merge.unknown -gt 0) {
        $intro += '<p>Для части раздач путь неизвестен. Монитор читает resume.dat из профиля Windows и папки запущенного µTorrent. Если файл находится в другом месте, укажите его полный путь в resume-path.txt рядом с Monitor.ps1. Неизвестные пути исключены из отбора.</p>'
    }
    $intro += '<p>Отслеживаются все раздачи на D: и F:. Весь E: — постоянное хранение; C: — системный. Оба диска исключены.</p>'
    $intro += "<p>$feedMessage <a href='films.html'>Открыть публикации раздела 252</a></p>"
    $intro += '<p>'+[Net.WebUtility]::HtmlEncode($autoMessage)+'</p>'
    if (Test-Path "$root\auto-downloads.html") {$intro += '<p><a href="auto-downloads.html">Журнал автозагрузки</a></p>'}
    $html = $report | ConvertTo-Html -Head $style -PreContent $intro
    $html | Set-Content "$root\report.html" -Encoding UTF8
    $report | Export-Csv "$root\report.csv" -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    Add-Content "$root\monitor.log" "$stamp OK: D/F=$observedCount, unknown=$($merge.unknown), excluded=$($merge.excluded), invalid=$($merge.invalid), kept=$($merge.kept), missing=$($merge.missing), removed=$($merge.removed)" -Encoding UTF8
    if ($cleanupMode.mode -eq 'Disabled') { Add-Content "$root\monitor.log" "$stamp CLEANUP DISABLED" -Encoding UTF8 }
    else { Add-Content "$root\monitor.log" "$stamp CLEANUP DRY RUN: candidates=$($cleanup.candidates), GiB=$cleanupGib, insufficient=$($cleanup.insufficient), keep=$($cleanup.keep)" -Encoding UTF8 }
    Write-Host "OK: $observedCount torrents on D/F. Report: $root\report.html"
}
# Dot-sourcing (tests) only defines the functions above.
if ($MyInvocation.InvocationName -ne '.') {
try {
    if ($Setup) {
        Write-Host 'Setup on the torrent computer. Autoload follows your local autoload.json settings.'
        $url = Read-Host 'WebUI URL [http://127.0.0.1:9090]'
        if (!$url) { $url = 'http://127.0.0.1:9090' }
        $parsed = [uri]$url
        if (!$parsed.IsAbsoluteUri -or $parsed.Scheme -notin @('http','https') -or $parsed.UserInfo -or $parsed.Query -or $parsed.AbsolutePath -ne '/') { throw 'Enter only http://HOST:PORT without login, password or /gui/.' }
        $credential = Get-Credential -UserName 'admin' -Message 'Enter uTorrent WebUI password (stored encrypted for this Windows user)'
        if (!$credential) { throw 'Setup cancelled.' }
        $null = Fetch-List ([pscustomobject]@{url=$url}) $credential
        $credential | Export-Clixml "$root\credential.xml"
        Save-Json @{url=$url} "$root\config.json"
        $setupLock=[IO.File]::Open("$root\monitor.lock",'OpenOrCreate','ReadWrite','None')
        try {Collect} finally {$setupLock.Dispose()}
        $taskName = 'TorrentMonitor-DF'
        $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $action = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\Monitor.ps1`" -Once" -WorkingDirectory $root
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15)
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host 'Scheduled every 15 minutes while this Windows user is signed in (locked/disconnected session is OK).'
        Start-Process "$root\report.html"
    } else {
        $lock = $null
        try {
            $lock = [IO.File]::Open("$root\monitor.lock", 'OpenOrCreate', 'ReadWrite', 'None')
            Collect
        } finally { if ($lock) { $lock.Dispose() } }
    }
} catch {
    # Avoid logging URLs containing a token or authentication details.
    $message = 'Connection/processing failed. Check uTorrent, URL, password and local file access. History not advanced. Error type: ' + $_.Exception.GetType().Name + '; code: ' + (Get-MonitorErrorCode $_.Exception)
    Add-Content "$root\monitor.log" "$(Get-Date -Format s) ERROR: $message" -Encoding UTF8
    Write-Host $message -ForegroundColor Red
    if ($Setup) { Write-Host 'If the report opened/was created but scheduling failed, run 2-Run-once.cmd manually or retry setup.' }
    exit 1
}
}
