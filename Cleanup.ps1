# TorrentControl 1.9: cleanup of complete torrents by actual upload - DRY RUN ONLY.
# This module reads the monitor history (Rules.ps1) and writes cleanup.html / cleanup.csv. It never deletes
# files or folders, never removes or stops torrents, never calls WebUI and never changes client settings;
# tests\Test-Static.ps1 enforces that for every production file.
# Modes (cleanup.json): Disabled | DryRun (default). Enabled is reserved for a future version and refused.
$script:CleanupBanner = 'DRY RUN — файлы и раздачи не удаляются'
$script:CleanupLimitBytes = 1073741824L   # 1 GiB per 24-hour period; equal is NOT "less than"
$script:CleanupNotes = @{
    New = 'новая раздача'; Path = 'смена пути'; Clock = 'часы компьютера переведены назад'; Counter = 'сброс счётчика отдачи'
    Gap = 'пропуск опросов более 60 мин'; Missing = 'раздача пропадала из списка µTorrent'; Damaged = 'история отдачи повреждена'
    Invalid = 'недостоверное значение отдачи'; NotSeeding = 'раздача не раздавалась (остановлена, проверка, очередь или неизвестны пиры)'
    Start = 'начало учёта отдачи'
}
function Get-CleanupMode([string]$Directory) {
    $path = Join-Path $Directory 'cleanup.json'
    if (!(Test-Path -LiteralPath $path)) { return [pscustomobject]@{ mode = 'DryRun'; warning = '' } }
    $settings = $null
    try { $settings = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $settings = $null }
    $requested = ''
    if ($null -ne $settings) { $requested = [string]$settings.mode }
    if ($requested -eq 'Disabled') { return [pscustomobject]@{ mode = 'Disabled'; warning = '' } }
    if ($requested -eq 'DryRun') { return [pscustomobject]@{ mode = 'DryRun'; warning = '' } }
    if ($requested -eq 'Enabled') {
        return [pscustomobject]@{ mode = 'DryRun'; warning = 'Режим Enabled в версии 1.9 недоступен и не включается: выполняется только Dry Run.' }
    }
    return [pscustomobject]@{ mode = 'DryRun'; warning = 'cleanup.json не распознан: выполняется только Dry Run.' }
}
function Get-CleanupOwnership([string]$Directory) {
    # Torrents TorrentControl added itself: autoload journal records confirmed in their own rt-<topic> folder.
    $owned = @{}
    $path = Join-Path $Directory 'auto-state.json'
    if (!(Test-Path -LiteralPath $path)) { return $owned }
    $state = $null
    try { $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $owned }
    foreach ($item in @($state.items)) {
        if ($null -ne $item -and [string]$item.status -eq 'Confirmed' -and [string]$item.hash -match '^[0-9A-Fa-f]{40}$' -and
            [string]$item.path -match '^D:\\Фильмы\\rt-\d+$') {
            $owned[([string]$item.hash).ToUpperInvariant()] = [string]$item.path
        }
    }
    return $owned
}
function Get-CleanupDecision($Entry, [long]$Now, [string]$ListProblem = '', $Owned = @{}) {
    # Candidate only if: complete (PROGRESS 1000 and REMAINING 0), running, path on D: or F:, valid WebUI data,
    # no upload and no connected downloading peers right now, observed for 30 days, a continuous upload history
    # covering all three periods, and less than 1 GiB in EACH period (upper bounds, see Get-UploadWindows).
    $row = $Entry.row; $state = $Entry.state; $path = [string]$Entry.path
    $windows = Get-UploadWindows $state $Now
    $hash = ([string]$row[0]).ToUpperInvariant()
    $owner = 'Ручная'
    if ($Owned -and $Owned.ContainsKey($hash)) {
        $folder = [string]$Owned[$hash]
        if ($path -eq $folder -or $path.StartsWith($folder + '\', [StringComparison]::OrdinalIgnoreCase)) { $owner = 'TorrentControl' }
    }
    $rare = 'нет данных'
    if (Test-RowInteger $row[15]) {
        $rare = ''
        if ([long]$row[15] -le 1) { $rare = 'Да: других сидеров может не быть (в рое: ' + $row[15] + ')' }
    }
    $size = $null
    if (Test-RowInteger $row[3]) { $size = [long]$row[3] }
    $observedDays = [math]::Round(($Now - [long]$state.firstSeen) / 86400, 1)
    $note = ''
    if ($script:CleanupNotes.ContainsKey([string]$state.uploadNote)) { $note = ' (последний перезапуск: ' + $script:CleanupNotes[[string]$state.uploadNote] + ')' }
    $problem = Get-TorrentRowProblem $row
    $decision = 'Кандидат на очистку'
    $reason = 'Полностью скачана, наблюдается не менее 30 дней, отдача менее 1 ГиБ в каждые из трёх суток, сейчас нет отдачи и пиров'
    if ($path -notmatch '^[DF]:\\') { $decision = 'Оставить'; $reason = 'Защищённый диск: очищаются только D: и F:' }
    elseif ($ListProblem) { $decision = 'Недостаточно данных'; $reason = 'Некорректный ответ WebUI (' + $ListProblem + ')' }
    elseif ($problem) { $decision = 'Недостаточно данных'; $reason = 'Некорректные данные раздачи (' + $problem + ')' }
    elseif (!$state.complete) { $decision = 'Оставить'; $reason = 'Загрузка не завершена (нужно PROGRESS = 1000 и REMAINING = 0)' }
    elseif (!$state.running) { $decision = 'Недостаточно данных'; $reason = 'Раздача остановлена, на паузе, в очереди, проверяется или с ошибкой' }
    elseif ([long]$row[8] -gt 0) { $decision = 'Оставить'; $reason = 'Идёт отдача' }
    elseif ([long]$row[12] -gt 0) { $decision = 'Оставить'; $reason = 'Подключены скачивающие пиры' }
    elseif ($Now - [long]$state.firstSeen -lt 30 * 86400) { $decision = 'Недостаточно данных'; $reason = 'Наблюдается ' + $observedDays + ' дн. из 30' }
    elseif (!$windows.complete) { $decision = 'Недостаточно данных'; $reason = 'Непрерывная история отдачи ' + $windows.hours + ' ч из 73' + $note }
    else {
        $days = @($windows.day1, $windows.day2, $windows.day3)
        for ($k = 0; $k -lt 3; $k++) {
            if ($days[$k] -ge $script:CleanupLimitBytes) {
                $decision = 'Оставить'
                $reason = 'За сутки ' + ($k + 1) + ' отдано не менее 1 ГиБ (до ' + [math]::Round($days[$k] / 1GB, 2) + ' ГиБ)'
                break
            }
        }
    }
    [pscustomobject]@{
        decision = $decision; reason = $reason; candidate = ($decision -eq 'Кандидат на очистку')
        name = [string]$row[2]; path = $path; sizeBytes = $size; hash = $hash; observedDays = $observedDays
        day1 = $windows.day1; day2 = $windows.day2; day3 = $windows.day3; total72 = $windows.total72
        upSpeed = $row[8]; peers = $row[12]; seeds = $row[15]; rare = $rare; owner = $owner
    }
}
function Format-CleanupGib($Bytes) {
    # Unknown periods are "н/д", never 0.
    if ($null -eq $Bytes) { return 'н/д' }
    return [math]::Round([double]$Bytes / 1GB, 3)
}
function Write-CleanupReport($Decisions, [string]$Directory, [string]$Mode, [long]$Now, [int]$Excluded = 0, $Notes = @()) {
    $order = @{ 'Кандидат на очистку' = 0; 'Недостаточно данных' = 1; 'Оставить' = 2 }
    $list = @(@($Decisions) | Where-Object { $null -ne $_ } | Sort-Object @{ Expression = { $order[$_.decision] } }, @{ Expression = { [double]$_.sizeBytes }; Descending = $true })
    if ($Mode -eq 'Disabled') { $list = @() }
    $candidates = @($list | Where-Object { $_.candidate })
    $bytes = 0L; $ownedBytes = 0L
    foreach ($item in $candidates) {
        $bytes += [long]$item.sizeBytes
        if ($item.owner -eq 'TorrentControl') { $ownedBytes += [long]$item.sizeBytes }
    }
    $insufficient = @($list | Where-Object { $_.decision -eq 'Недостаточно данных' }).Count
    $keep = @($list | Where-Object { $_.decision -eq 'Оставить' }).Count
    $rows = @(foreach ($item in $list) {
        [pscustomobject]@{
            Решение = $item.decision; Причина = $item.reason; Название = $item.name; Путь = $item.path
            Размер_ГиБ = (Format-CleanupGib $item.sizeBytes); Hash = $item.hash; Наблюдение_дней = $item.observedDays
            Сутки_1_ГиБ = (Format-CleanupGib $item.day1); Сутки_2_ГиБ = (Format-CleanupGib $item.day2); Сутки_3_ГиБ = (Format-CleanupGib $item.day3)
            Всего_72ч_ГиБ = (Format-CleanupGib $item.total72); Отдача_КБ_с = (Format-RowNumber $item.upSpeed 1KB 1)
            Пиров_подключено = (Format-RowNumber $item.peers); Сидов_в_рое = (Format-RowNumber $item.seeds)
            Редкая_раздача = $item.rare; Принадлежность = $item.owner; Режим = $script:CleanupBanner
        }
    })
    $gib = [math]::Round($bytes / 1GB, 2); $ownedGib = [math]::Round($ownedBytes / 1GB, 2); $manualGib = [math]::Round(($bytes - $ownedBytes) / 1GB, 2)
    $stamp = [DateTimeOffset]::FromUnixTimeSeconds($Now).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
    $intro = '<h1>Очистка раздач</h1><p class="dry">' + $script:CleanupBanner + '</p><p>Обновлено: ' + $stamp + '. Режим: ' + $Mode + '. Автоматическое удаление в версии 1.9 не реализовано.</p>'
    foreach ($text in @($Notes)) { if ($text) { $intro += '<p class="warn">' + [Net.WebUtility]::HtmlEncode([string]$text) + '</p>' } }
    if ($Mode -eq 'Disabled') {
        $intro += '<p>Очистка выключена (Disabled в cleanup.json): кандидаты не рассчитываются. История отдачи продолжает накапливаться.</p>'
    } else {
        $intro += '<p><b>Кандидатов на очистку: ' + $candidates.Count + '. Потенциально освобождается: ' + $gib + ' ГиБ</b> (раздачи TorrentControl: ' + $ownedGib + ' ГиБ, ручные: ' + $manualGib + ' ГиБ). Недостаточно данных: ' + $insufficient + '. Оставить: ' + $keep + '. Раздач на других дисках: ' + $Excluded + ' (C:, E: и прочие не очищаются).</p>'
        $intro += '<p>Кандидат: полностью скачана (PROGRESS = 1000 и REMAINING = 0), путь на D: или F:, наблюдается не менее 30 дней, сейчас нет отдачи и подключённых скачивающих пиров, и в <b>каждые</b> из трёх последних суток отдано <b>менее 1 ГиБ</b> (ровно 1 ГиБ — уже не «менее»). Сиды на решение не влияют; «Редкая раздача» — предупреждение, если других сидеров в рое может не быть.</p>'
        $intro += '<p>Отдача считается по накопительному счётчику UPLOADED µTorrent между соседними опросами. Каждые «сутки» — это 25 целых часов UTC, которые содержат соответствующие 24 часа; интервалы опроса на границе засчитываются целиком. Поэтому значения в столбцах «Сутки» — верхняя оценка: реальная отдача не больше. Нужна непрерывная история не меньше 73 часов: пропуск опросов более 60 минут, сброс счётчика, смена пути, остановка раздачи или повреждение истории начинают её заново. Неизвестная активность никогда не считается нулём («н/д»).</p>'
    }
    $style = '<meta charset="utf-8"><style>body{font:15px Segoe UI;margin:24px;background:#f5f7fa}table{border-collapse:collapse;background:white;width:100%}td,th{padding:8px;border:1px solid #ddd;text-align:left}th{background:#dfeafa}.dry{font-size:20px;font-weight:bold;color:#8a1c1c;background:#fde8e8;border:2px solid #8a1c1c;padding:10px}.warn{color:#8a5a00}</style>'
    $html = $rows | ConvertTo-Html -Head $style -PreContent $intro -PostContent ('<p class="dry">' + $script:CleanupBanner + '</p>')
    $html | Set-Content (Join-Path $Directory 'cleanup.html') -Encoding UTF8
    $csvPath = Join-Path $Directory 'cleanup.csv'
    if ($rows.Count) { $rows | Export-Csv $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ';' }
    else { Set-Content -LiteralPath $csvPath -Value '"Решение";"Причина";"Название";"Путь";"Размер_ГиБ";"Hash";"Наблюдение_дней";"Сутки_1_ГиБ";"Сутки_2_ГиБ";"Сутки_3_ГиБ";"Всего_72ч_ГиБ";"Отдача_КБ_с";"Пиров_подключено";"Сидов_в_рое";"Редкая_раздача";"Принадлежность";"Режим"' -Encoding UTF8 }
    return [pscustomobject]@{ candidates = $candidates.Count; bytes = $bytes; ownedBytes = $ownedBytes; insufficient = $insufficient; keep = $keep }
}
