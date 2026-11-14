. "$PSScriptRoot\TestCommon.ps1"
. "$PSScriptRoot\..\Rules.ps1"
. "$PSScriptRoot\..\AutoLoad.ps1"
. "$PSScriptRoot\..\Cleanup.ps1"
# Evaluation time, deliberately not aligned to an hour ($Eval: PowerShell names are case-insensitive, so not $T next to $t).
$Eval = 1800000000L + 37 * 60 + 13
$H = [long][math]::Floor($Eval / 3600)
$GiB = 1073741824L
$hash = New-TestHash 'a'

function Get-Uploaded([long]$Time, [double[]]$Days) {
    # Cumulative UPLOADED: Days[0] GiB spread over (T-24h, T], Days[1] over (T-48h, T-24h], Days[2] over (T-72h, T-48h].
    $total = 0.0
    for ($k = 1; $k -le 3; $k++) {
        $a = $Eval - 86400 * $k; $b = $Eval - 86400 * ($k - 1)
        $overlap = [math]::Max(0, [math]::Min($Time, $b) - $a)
        $total += $Days[$k - 1] * $GiB * $overlap / 86400
    }
    return 5 * $GiB + [long][math]::Floor($total)
}
function Invoke-Seeding {
    # Polls every 15 minutes through the real Merge-History; the first record looks like a 1.8 record
    # observed for 40 days (no upload history yet), so this also covers the upgrade path.
    param([double[]]$Days = @(0, 0, 0), [string]$Path = 'D:\Seed\Film', [long]$From = ($Eval - 80 * 3600), [long]$Step = 900,
        [scriptblock]$Tweak = $null, [scriptblock]$Skip = $null, [scriptblock]$Repeat = $null)
    $seed = [pscustomobject]@{ hash = $hash; path = $Path; firstSeen = $Eval - 40 * 86400; quietSince = $Eval - 40 * 86400
        lastSeen = $From - $Step; uploaded = (Get-Uploaded ($From - $Step) $Days); observedUpload = 0L
        complete = $true; running = $true; knownPeers = $true; demand = $false }
    $items = @($seed); $m = $null
    for ($t = $From; $t -le $Eval; $t += $Step) {
        if ($Skip -and (& $Skip $t)) { continue }
        $times = @($t)
        if ($Repeat -and (& $Repeat $t)) { $times += $t + 60 }
        foreach ($at in $times) {
            if ($at -gt $Eval) { continue }
            $row = New-TestRow $hash $Path -Size (40 * $GiB) -Uploaded (Get-Uploaded $at $Days) -SeedsSwarm 3 -Name 'Seed film'
            if ($Tweak) { & $Tweak $row $at }
            $m = Merge-History @(,$row) @{} $items $at
            $items = @($m.items)
        }
    }
    return [pscustomobject]@{ items = $items; entry = @($m.observed)[0] }
}
function Decide($Run, [string]$Problem = '', $Owned = @{}) { return (Get-CleanupDecision $Run.entry $Eval $Problem $Owned) }

# --- Required scenarios ----------------------------------------------------------------------------------
$zero = Invoke-Seeding @(0, 0, 0)
$d = Decide $zero
Assert ($d.decision -eq 'Кандидат на очистку' -and $d.candidate) "0/0/0 GiB: $($d.decision) / $($d.reason)"
Assert ($d.day1 -eq 0 -and $d.day2 -eq 0 -and $d.day3 -eq 0 -and $d.total72 -eq 0) 'idle torrent has zero upload in every period'
Assert ($d.observedDays -ge 40 -and $d.sizeBytes -eq 40 * $GiB -and $d.hash -eq $hash -and $d.path -eq 'D:\Seed\Film') 'report fields'

$low = Invoke-Seeding @(0.8, 0.5, 0.9)
$d = Decide $low
Assert ($d.decision -eq 'Кандидат на очистку') "0.8/0.5/0.9 GiB: $($d.decision) / $($d.reason)"
# Upper bounds: never below the true amount, below 1 GiB here.
# (Test amounts are floored to whole bytes, hence the one-byte tolerance.)
Assert ($d.day1 -ge 0.8 * $GiB - 1 -and $d.day1 -lt $GiB -and $d.day2 -ge 0.5 * $GiB - 1 -and $d.day3 -ge 0.9 * $GiB - 1 -and $d.day3 -lt $GiB) "bounds $($d.day1) $($d.day2) $($d.day3)"
Assert ($d.total72 -ge 2.2 * $GiB - 1 -and $d.total72 -lt 2.4 * $GiB) "72 h total $($d.total72)"

$busy = Decide (Invoke-Seeding @(0.8, 1.2, 0.4))
Assert ($busy.decision -eq 'Оставить' -and $busy.reason -match 'сутки 2' -and $busy.day2 -ge 1.2 * $GiB) "0.8/1.2/0.4 GiB: $($busy.decision) / $($busy.reason)"

$short = Decide (Invoke-Seeding @(0, 0, 0) -From ($Eval - 40 * 3600))
Assert ($short.decision -eq 'Недостаточно данных' -and $null -eq $short.day3 -and $null -eq $short.total72) "40 h of history: $($short.decision) / $($short.reason)"
Assert ($null -ne $short.day1) 'a fully covered first period is still shown'

# Missed polls: a 2-hour gap restarts the continuous history.
$gap = Decide (Invoke-Seeding @(0, 0, 0) -Skip { param($t) $t -gt $Eval - 30 * 3600 -and $t -lt $Eval - 28 * 3600 })
Assert ($gap.decision -eq 'Недостаточно данных' -and $gap.reason -match 'пропуск') "missed polls: $($gap.decision) / $($gap.reason)"
# Up to an hour without a poll loses nothing (cumulative counter) and is attributed conservatively.
$small = Invoke-Seeding @(0.8, 0.5, 0.9) -Skip { param($t) $t -gt $Eval - 30 * 3600 -and $t -lt $Eval - 29.4 * 3600 }
$s = Decide $small
Assert ($s.decision -eq 'Кандидат на очистку' -and $s.total72 -ge (Decide $low).total72) 'short gap must not lose upload'

# UPLOADED counter reset (torrent re-added or client lost its counters).
$reset = Decide (Invoke-Seeding @(0, 0, 0) -Tweak { param($row, $t) if ($t -ge $Eval - 20 * 3600) { $row[6] = [long]$row[6] - 4 * $GiB } })
Assert ($reset.decision -eq 'Недостаточно данных') "counter reset: $($reset.decision) / $($reset.reason)"

# Monitor started again between scheduled polls: nothing is counted twice.
$again = Decide (Invoke-Seeding @(0.8, 0.5, 0.9) -Repeat { param($t) (($Eval - $t) / 900) % 4 -eq 1 })
$ref = Decide $low
Assert ($again.day1 -eq $ref.day1 -and $again.day2 -eq $ref.day2 -and $again.day3 -eq $ref.day3 -and $again.total72 -eq $ref.total72) 'extra runs counted twice'
$same = Invoke-Seeding @(0.8, 0.5, 0.9)
$entry = $same.entry
$m = Merge-History @(,$entry.row) @{} $same.items $Eval
Assert ((Get-CleanupDecision @($m.observed)[0] $Eval).total72 -eq $ref.total72) 'the same poll processed twice changed the totals'

# Still downloading, active upload, connected downloading peers.
$dl = Decide (Invoke-Seeding @(0, 0, 0) -Tweak { param($row, $t) if ($t -eq $Eval) { $row[4] = 990; $row[18] = 400MB } })
Assert ($dl.decision -eq 'Оставить' -and $dl.reason -match 'не завершена') "downloading: $($dl.decision) / $($dl.reason)"
$odd = Decide (Invoke-Seeding @(0, 0, 0) -Tweak { param($row, $t) if ($t -eq $Eval) { $row[18] = 1MB } })
Assert ($odd.decision -eq 'Оставить') 'PROGRESS=1000 with REMAINING>0 counted as complete'
$up = Decide (Invoke-Seeding @(0, 0, 0) -Tweak { param($row, $t) if ($t -eq $Eval) { $row[8] = 2048 } })
Assert ($up.decision -eq 'Оставить' -and $up.reason -match 'отдача') "active upload: $($up.decision) / $($up.reason)"
$peer = Decide (Invoke-Seeding @(0, 0, 0) -Tweak { param($row, $t) if ($t -eq $Eval) { $row[12] = 1 } })
Assert ($peer.decision -eq 'Оставить' -and $peer.reason -match 'пиры') "connected peers: $($peer.decision) / $($peer.reason)"
# Paused for an hour inside the window: low upload then says nothing about demand.
$pause = Decide (Invoke-Seeding @(0, 0, 0) -Tweak { param($row, $t) if ($t -ge $Eval - 30 * 3600 -and $t -lt $Eval - 29 * 3600) { $row[1] = 233 } })
Assert ($pause.decision -eq 'Недостаточно данных') "paused inside the window: $($pause.decision)"
$stopped = Decide (Invoke-Seeding @(0, 0, 0) -Tweak { param($row, $t) if ($t -eq $Eval) { $row[1] = 200 } })
Assert ($stopped.decision -eq 'Недостаточно данных') 'queued/stopped torrent became a candidate'

# Damaged WebUI response.
Assert ((Decide $zero 'UploadSpeed').decision -eq 'Недостаточно данных') 'candidate despite a damaged WebUI response'
$bad = Invoke-Seeding @(0, 0, 0) -Tweak { param($row, $t) if ($t -eq $Eval) { $row[12] = 'many' } }
Assert ((Decide $bad).decision -ne 'Кандидат на очистку') 'damaged row became a candidate'

# Drives: C: and E: are never candidates; D: and F: are allowed in Dry Run.
foreach ($p in @('C:\Seed\Film', 'E:\Archive\Film')) {
    $copy = [pscustomobject]@{ row = $zero.entry.row; path = $p; state = $zero.entry.state }
    $x = Get-CleanupDecision $copy $Eval
    Assert ($x.decision -eq 'Оставить' -and $x.reason -match 'Защищённый диск') "path $p is a candidate"
}
$f = Decide (Invoke-Seeding @(0, 0, 0) -Path 'F:\Seed\Film')
Assert ($f.decision -eq 'Кандидат на очистку') 'F: torrent not allowed in Dry Run'

# Absent from the list, back with an unknown path, then measurable again: the history starts again.
$other = New-TestRow (New-TestHash 'c') 'D:\Other\Film'
$m1 = Merge-History @(,$other) @{} $zero.items ($Eval + 900)
$m2 = Merge-History @($other, (New-TestRow $hash -Fields 19 -Size (40 * $GiB) -Uploaded (Get-Uploaded $Eval @(0, 0, 0)))) @{} @($m1.items) ($Eval + 1800)
$m3 = Merge-History @($other, (New-TestRow $hash 'D:\Seed\Film' -Size (40 * $GiB) -Uploaded (Get-Uploaded $Eval @(0, 0, 0)))) @{} @($m2.items) ($Eval + 2700)
$back = @($m3.observed | Where-Object { $_.state.hash -eq $hash })[0]
Assert ($back.state.uploadNote -eq 'Missing' -and (Get-CleanupDecision $back ($Eval + 2700)).decision -eq 'Недостаточно данных') 'torrent that left the list kept its upload history'

# Observation shorter than 30 days.
$young = Invoke-Seeding @(0, 0, 0)
$young.entry.state.firstSeen = $Eval - 29 * 86400
Assert ((Decide $young).decision -eq 'Недостаточно данных') 'observed for 29 days'

# --- Window arithmetic, thresholds and damaged history ------------------------------------------------
function New-Record([string]$Hours, [long]$Since = ($Eval - 80 * 3600)) {
    [pscustomobject]@{ hash = $hash; path = 'D:\x'; firstSeen = $Eval - 40 * 86400; lastSeen = $Eval; uploadSince = $Since; uploadHours = $Hours }
}
# in[H-30] = 100 bytes; an interval crossing from H-25 into H-24 = 7 bytes (touches periods 1 and 2).
$w = Get-UploadWindows (New-Record ("{0},100,0;{1},0,7" -f ($H - 30), ($H - 25))) $Eval
Assert ($w.complete -and $w.day1 -eq 7 -and $w.day2 -eq 107 -and $w.day3 -eq 0 -and $w.total72 -eq 107) "window sums $($w.day1) $($w.day2) $($w.day3) $($w.total72)"
$w = Get-UploadWindows (New-Record ("{0},0,5" -f ($H - 73))) $Eval
Assert ($w.day3 -eq 5 -and $w.day2 -eq 0 -and $w.total72 -eq 5) 'interval crossing into the oldest period counted in full'
Assert (!(Get-UploadWindows (New-Record '' ($Eval - 71 * 3600))).complete) 'history starting after the oldest period counted as complete'
Assert (!(Get-UploadWindows (New-Record '' 0)).complete) 'no history counted as complete'
$exact = Invoke-Seeding @(0, 0, 0)
$exact.entry.state.uploadHours = '{0},{1},0' -f ($H - 30), $GiB
Assert ((Decide $exact).decision -eq 'Оставить') 'exactly 1 GiB is not "less than 1 GiB"'
$exact.entry.state.uploadHours = '{0},{1},0' -f ($H - 30), ($GiB - 1)
Assert ((Decide $exact).decision -eq 'Кандидат на очистку') '1 GiB minus one byte is low activity'
foreach ($damaged in @('x', '1,2', '1,2,3;1,2,3', '-1,2,3', ('1,2,3;' * 5000 + '1,2,3'))) {
    Assert ($null -eq (ConvertFrom-UploadHours $damaged)) "damaged history '$($damaged.Substring(0, [math]::Min(12, $damaged.Length)))' accepted"
}
$broken = Invoke-Seeding @(0, 0, 0)
$broken.items[0].uploadHours = 'garbage'
$m = Merge-History @(,$broken.entry.row) @{} $broken.items ($Eval + 900)
Assert ((Get-CleanupDecision @($m.observed)[0] ($Eval + 900)).decision -eq 'Недостаточно данных') 'damaged history used for a decision'
Assert (@($m.items)[0].uploadNote -eq 'Damaged') 'damaged history not marked'
# Records stay small: hours older than the windows are pruned.
Assert (@((ConvertFrom-UploadHours $low.items[0].uploadHours).Keys | Where-Object { $_ -lt $H - 75 }).Count -eq 0) 'old hours kept'

# --- Rare torrent warning (reference only) ----------------------------------------------------------
foreach ($c in @(@{ seeds = 0; rare = $true }, @{ seeds = 1; rare = $true }, @{ seeds = 4; rare = $false })) {
    $r = Invoke-Seeding @(0, 0, 0) -Tweak { param($row, $t) $row[15] = $c.seeds }
    $x = Decide $r
    Assert (($x.rare -match '^Да') -eq $c.rare -and $x.decision -eq 'Кандидат на очистку') "seeds $($c.seeds): rare=$($x.rare)"
}

$temp = New-TestDirectory
try {
    # --- Mode: Disabled / DryRun; Enabled is refused in 1.9 --------------------------------------
    Assert ((Get-CleanupMode $temp).mode -eq 'DryRun') 'default mode'
    foreach ($c in @(@{ text = '{"mode":"Disabled"}'; mode = 'Disabled'; warn = $false }, @{ text = '{"mode":"DryRun"}'; mode = 'DryRun'; warn = $false },
        @{ text = '{"mode":"Enabled"}'; mode = 'DryRun'; warn = $true }, @{ text = 'garbage'; mode = 'DryRun'; warn = $true })) {
        Set-Content -LiteralPath (Join-Path $temp 'cleanup.json') -Value $c.text -Encoding UTF8
        $mode = Get-CleanupMode $temp
        Assert ($mode.mode -eq $c.mode -and ([bool]$mode.warning) -eq $c.warn) "mode from '$($c.text)': $($mode.mode) / $($mode.warning)"
    }
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath (Join-Path $temp 'cleanup.json')

    # --- Ownership: only torrents confirmed by autoload belong to TorrentControl ---------------------
    $ownedHash = New-TestHash 'b'
    Save-AutoJson @{ version = 1; enabledAt = '2026-10-24T00:00:00Z'; knownTopics = @('1'); items = @(
        [pscustomobject]@{ topic = '900000001'; hash = $ownedHash; title = 't'; status = 'Confirmed'; bytes = 1; path = 'D:\Фильмы\rt-900000001'; reason = ''; submittedAt = ''; lastAttempt = '' },
        [pscustomobject]@{ topic = '900000002'; hash = $hash; title = 't'; status = 'Reviewed'; bytes = 1; path = 'D:\Seed'; reason = ''; submittedAt = ''; lastAttempt = '' }) } (Join-Path $temp 'auto-state.json')
    $owned = Get-CleanupOwnership $temp
    Assert ($owned.ContainsKey($ownedHash) -and !$owned.ContainsKey($hash)) 'only Confirmed autoload items are owned'
    $mine = Invoke-Seeding @(0, 0, 0) -Path 'D:\Фильмы\rt-900000001\Film.mkv'
    $mine.entry.state.hash = $ownedHash
    $mine.entry.row[0] = $ownedHash
    Assert ((Get-CleanupDecision $mine.entry $Eval '' $owned).owner -eq 'TorrentControl') 'autoload torrent not recognised'
    Assert ((Decide $zero '' $owned).owner -eq 'Ручная') 'manual torrent treated as owned'
    $elsewhere = [pscustomobject]@{ row = $mine.entry.row; path = 'D:\Other\Film.mkv'; state = $mine.entry.state }
    Assert ((Get-CleanupDecision $elsewhere $Eval '' $owned).owner -eq 'Ручная') 'owned hash outside its folder treated as owned'

    # --- Dry Run report -------------------------------------------------------------------------------
    $decisions = @((Decide $zero), (Get-CleanupDecision $mine.entry $Eval '' $owned), $busy, $short)
    $summary = Write-CleanupReport $decisions $temp 'DryRun' $Eval 3
    Assert ($summary.candidates -eq 2 -and $summary.bytes -eq 80 * $GiB -and $summary.ownedBytes -eq 40 * $GiB) "summary $($summary.candidates) $($summary.bytes)"
    $html = Get-FileText (Join-Path $temp 'cleanup.html')
    Assert ($html -match 'DRY RUN — файлы и раздачи не удаляются' -and $html -match '80 ГиБ' -and $html -match 'Кандидат на очистку') 'cleanup.html content'
    Assert ($html -match 'Недостаточно данных' -and $html -match 'Оставить' -and $html -match 'других дисках: 3') 'all decisions and excluded drives shown'
    $csv = @(Import-Csv -LiteralPath (Join-Path $temp 'cleanup.csv') -Delimiter ';' -Encoding UTF8)
    Assert ($csv.Count -eq 4 -and @($csv | Where-Object { $_.Режим -ne 'DRY RUN — файлы и раздачи не удаляются' }).Count -eq 0) 'every CSV row marked DRY RUN'
    foreach ($column in @('Решение','Причина','Название','Путь','Размер_ГиБ','Hash','Наблюдение_дней','Сутки_1_ГиБ','Сутки_2_ГиБ','Сутки_3_ГиБ','Всего_72ч_ГиБ','Отдача_КБ_с','Пиров_подключено','Сидов_в_рое','Редкая_раздача','Принадлежность')) {
        Assert ($csv[0].PSObject.Properties.Name -contains $column) "CSV column $column"
    }
    Assert ($csv[0].Решение -eq 'Кандидат на очистку') 'candidates listed first'
    Assert (@($csv | Where-Object Hash -eq $hash)[0].Сутки_3_ГиБ -ne 'н/д' -and @($csv | Where-Object Решение -eq 'Недостаточно данных')[0].Сутки_3_ГиБ -eq 'н/д') 'unknown periods shown as н/д, not 0'
    $null = Write-CleanupReport @() $temp 'Disabled' $Eval 0
    Assert ((Get-FileText (Join-Path $temp 'cleanup.html')) -match 'Disabled' -and (Get-FileText (Join-Path $temp 'cleanup.html')) -match 'DRY RUN') 'disabled notice'

    # --- state.json stays small with hundreds of busy torrents (Windows PowerShell 5.1 parses it) --------
    $records = foreach ($i in 1..600) {
        $parts = foreach ($h in ($H - 74)..$H) { '{0},{1},{2}' -f $h, (123456789012 + $i), (98765432109 + $i) }
        $r = New-Record ($parts -join ';'); $r.hash = '{0:X40}' -f $i; $r
    }
    $file = Join-Path $temp 'state.json'
    Save-AutoJson @{ version = 1; updated = $Eval; items = @($records) } $file -Compress
    $length = (Get-Item -LiteralPath $file).Length
    Assert ($length -lt 2000000) "state.json with 600 busy torrents is $length bytes"
    $back = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert (@($back.items).Count -eq 600 -and (Get-UploadWindows @($back.items)[0] $Eval).complete) 'large state.json round trip'
} finally { Remove-TestDirectory $temp }
"PASS Test-Cleanup: $script:AssertCount assertions"
