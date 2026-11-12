. "$PSScriptRoot\TestCommon.ps1"
. "$PSScriptRoot\..\Rules.ps1"
$day = 86400L
$now = 1800000000L
$path = 'D:\Хранитель\Film'
$h1 = New-TestHash 'a'; $h2 = New-TestHash 'b'; $h3 = New-TestHash 'c'
function Old-Record([string]$Hash, [long]$Age, [long]$Quiet, [long]$Uploaded = 0, [string]$RecordPath = $path) {
    [pscustomobject]@{ hash = $Hash; path = $RecordPath; firstSeen = $now - $Age; quietSince = $now - $Quiet; lastSeen = $now - 900
        uploaded = $Uploaded; observedUpload = 0; complete = $true; running = $true; knownPeers = $true; demand = $false }
}

# --- Row indices follow the official WebUI spec ---------------------------------------------------
# Every field gets a distinct value; the history must read exactly 6 (uploaded), 8 (speed), 12 (connected).
$row = New-TestRow $h1 $path -Uploaded 777 -UpSpeed 0 -PeersConnected 0 -PeersSwarm 55 -SeedsConnected 3 -SeedsSwarm 99
$s = Update-History $row $path $null $now
Assert ($s.uploaded -eq 777) 'uploaded must come from index 6'
Assert (!$s.demand) 'peers in the swarm (13) or seeds (14/15) must not count as demand'

# --- Regression: swarm peers alone never block a candidate -------------------------------------
$old = Old-Record $h1 (40*$day) (20*$day)
$s = Update-History (New-TestRow $h1 $path -PeersSwarm 120 -SeedsSwarm 40) $path $old $now
Assert (!$s.demand) 'swarm-only peers counted as demand'
Assert ((Get-Decision $s $now) -eq 'Кандидат на удаление') 'swarm-only torrent must still become a candidate'
Assert ($s.quietSince -eq $old.quietSince) 'quiet period must continue without own demand'

# --- Real observed demand ------------------------------------------------------------------------
$s = Update-History (New-TestRow $h1 $path -PeersConnected 2) $path $old $now
Assert ($s.demand -and $s.demandReason -eq 'ConnectedPeers' -and $s.quietSince -eq $now) 'connected peers (12) are demand'
Assert ((Get-Decision $s $now) -eq 'Есть спрос') 'connected peers decision'
$s = Update-History (New-TestRow $h1 $path -UpSpeed 4096) $path $old $now
Assert ($s.demand -and $s.demandReason -eq 'UploadSpeed') 'upload speed (8) is demand'
$s = Update-History (New-TestRow $h1 $path -Uploaded 5MB) $path (Old-Record $h1 (40*$day) (20*$day) 1MB) $now
Assert ($s.demand -and $s.demandReason -eq 'Upload' -and $s.observedUpload -eq 4MB) 'upload delta is demand and is accumulated'
Assert ((Get-DemandLabel $s) -eq 'отдача с прошлой проверки') 'demand label'
$s = Update-History (New-TestRow $h1 $path -Uploaded 5MB -UpSpeed 1 -PeersConnected 1) $path (Old-Record $h1 (40*$day) (20*$day) 1MB) $now
Assert ($s.demandReason -eq 'Upload,UploadSpeed,ConnectedPeers') 'all demand reasons'

# --- Unknown or conservative cases -----------------------------------------------------------------
$r = New-TestRow $h1 $path; $r[12] = $null
$s = Update-History $r $path $old $now
Assert (!$s.knownPeers -and $s.quietSince -eq $now) 'unknown connected peers must not look like no demand'
Assert ((Get-Decision $s $now) -eq 'Недостаточно данных / остановлена') 'unknown peers decision'
$r = New-TestRow $h1 $path; $r[13] = $null; $r[15] = -1
$s = Update-History $r $path $old $now
Assert ($s.knownPeers -and (Get-Decision $s $now) -eq 'Кандидат на удаление') 'swarm counts are irrelevant even when missing'
foreach ($status in @(200, 233, 152, 130)) {
    # 200 queued seed (not started), 233 paused, 152 error, 130 checking
    $s = Update-History (New-TestRow $h1 $path -Status $status) $path $old $now
    Assert (!$s.running -and $s.quietSince -eq $now) "status $status must not count as running"
}
$s = Update-History (New-TestRow $h1 $path -Status 137) $path $old $now
Assert ($s.running) 'forced seeding (137) is running'
$s = Update-History (New-TestRow $h1 $path -Progress 990) $path $old $now
Assert (!$s.complete -and $s.firstSeen -eq $now) 'incomplete torrent restarts storage period'
$s = Update-History (New-TestRow $h1 'D:\Other') 'D:\Other' $old $now
Assert ($s.firstSeen -eq $now) 'path change restarts history'
$s = Update-History (New-TestRow $h1 $path -Uploaded 10) $path (Old-Record $h1 (40*$day) (20*$day) 100) $now
Assert ($s.firstSeen -eq $now -and $s.observedUpload -eq 0) 'counter reset restarts history'
$gap = Old-Record $h1 (40*$day) (20*$day); $gap.lastSeen = $now - 7200
$s = Update-History (New-TestRow $h1 $path) $path $gap $now
Assert ($s.quietSince -eq $now -and $s.firstSeen -eq $gap.firstSeen) 'gap over an hour restarts only the quiet period'
$miss = Old-Record $h1 (40*$day) (20*$day); $miss | Add-Member -NotePropertyName missingPolls -NotePropertyValue 1
$s = Update-History (New-TestRow $h1 $path) $path $miss $now
Assert ($s.quietSince -eq $now -and $s.firstSeen -eq $miss.firstSeen -and $s.missingPolls -eq 0) 'reappearing torrent restarts quiet period only'

# --- Row validation --------------------------------------------------------------------------------
Assert ((Get-HistoryRowProblem (New-TestRow $h1 $path)) -eq '') 'valid row'
$r = New-TestRow $h1 $path; $r[6] = $null; Assert ((Get-HistoryRowProblem $r) -eq 'Uploaded') 'null uploaded detected'
$r = New-TestRow $h1 $path; $r[6] = '12'; Assert ((Get-HistoryRowProblem $r) -eq 'Uploaded') 'string uploaded detected'
$r = New-TestRow $h1 $path; $r[4] = 1001; Assert ((Get-HistoryRowProblem $r) -eq 'Progress') 'progress over 1000 detected'
$r = New-TestRow 'xyz' $path; Assert ((Get-HistoryRowProblem $r) -eq 'Hash') 'bad hash detected'
Assert (Test-RowInteger ([int]5)) 'int accepted'; Assert (Test-RowInteger ([long]5)) 'long accepted'
Assert (!(Test-RowInteger 1.5)) 'fraction rejected'; Assert (!(Test-RowInteger $true)) 'bool rejected'; Assert (!(Test-RowInteger -1)) 'negative rejected'

# --- Paths: 2.2.1 (19 fields, resume.dat) and 3.x (index 26) ------------------------------------------
$legacy = New-TestRow $h1 -Fields 19
Assert ((Get-HistoryPath $legacy @{ $h1 = 'D:\Old' }) -eq 'D:\Old') 'resume.dat path for 19-field rows'
Assert ((Get-HistoryPath $legacy @{}) -eq '') 'unknown path'
Assert ((Get-HistoryPath (New-TestRow $h1 'F:\New') @{ $h1 = 'D:\Old' }) -eq 'F:\New') 'index 26 wins when absolute'
Assert ((Get-HistoryPath (New-TestRow $h1 'relative') @{}) -eq '') 'non-absolute path ignored'

# --- Merge-History: temporary failures never destroy history -----------------------------------------
$previous = @((Old-Record $h1 (40*$day) (20*$day) 100), (Old-Record $h2 (50*$day) (30*$day) 200 'F:\Second'))
Assert-Throws { Merge-History @() @{} $previous $now } 'EmptyTorrentList' 'empty list with history must stop'
$m = Merge-History @() @{} @() $now
Assert (@($m.items).Count -eq 0) 'empty list without history is fine'
Assert-Throws { Merge-History @(,@($h1, 1, 2)) @{} $previous $now } 'UnsupportedRowFormat' 'short rows must stop'

# resume.dat unreadable on 2.2.1: every path unknown -> records kept exactly.
$rows = @((New-TestRow $h1 -Fields 19 -Uploaded 100), (New-TestRow $h2 -Fields 19 -Uploaded 200))
$m = Merge-History $rows @{} $previous $now
Assert (@($m.items).Count -eq 2 -and $m.unknown -eq 2 -and $m.kept -eq 2 -and @($m.observed).Count -eq 0) 'unknown paths keep history'
$k = @($m.items | Where-Object hash -eq $h1)[0]
Assert ($k.firstSeen -eq $previous[0].firstSeen -and $k.quietSince -eq $previous[0].quietSince -and $k.lastSeen -eq $previous[0].lastSeen) 'kept record unchanged'

# Invalid uploaded value: kept, not reset to zero.
$bad = New-TestRow $h1 $path; $bad[6] = $null
$m = Merge-History @($bad, (New-TestRow $h2 'F:\Second' -Uploaded 200)) @{} $previous $now
$k = @($m.items | Where-Object hash -eq $h1)[0]
Assert ($m.invalid -eq 1 -and $k.firstSeen -eq $previous[0].firstSeen -and $k.uploaded -eq 100) 'invalid row keeps history'

# Unparseable hash: list incomplete -> absent records kept without counting as missing.
$m = Merge-History @((New-TestRow 'broken' $path), (New-TestRow $h2 'F:\Second' -Uploaded 200)) @{} $previous $now
$k = @($m.items | Where-Object hash -eq $h1)[0]
Assert ($k -and [int]$k.missingPolls -eq 0 -and $m.missing -eq 0) 'incomplete list is not evidence of removal'

# Duplicate hash rows also make the list incomplete.
$m = Merge-History @((New-TestRow $h2 'F:\Second' -Uploaded 200), (New-TestRow $h2 'F:\Second' -Uploaded 200)) @{} $previous $now
Assert (@($m.items | Where-Object hash -eq $h1).Count -eq 1 -and $m.missing -eq 0 -and $m.invalid -eq 1) 'duplicate rows keep absent history'

# Real removal: kept for 3 polls spanning 6 hours, then dropped.
$state = @($previous)
$t = $now
foreach ($step in 1..3) {
    $m = Merge-History @(,(New-TestRow $h2 'F:\Second' -Uploaded 200)) @{} $state $t
    $state = @($m.items)
    $k = @($state | Where-Object hash -eq $h1)
    Assert ($k.Count -eq 1 -and $k[0].missingPolls -eq $step) "removed torrent kept on poll $step"
    Assert (@($m.observed | Where-Object { $_.state.hash -eq $h1 }).Count -eq 0) 'removed torrent not reported'
    $t += 900
}
$m = Merge-History @(,(New-TestRow $h2 'F:\Second' -Uploaded 200)) @{} $state ($now + 6*3600)
Assert (@($m.items | Where-Object hash -eq $h1).Count -eq 0 -and $m.removed -eq 1) 'history dropped after the grace period'

# Glitch: absent for one poll, back on the next -> history continues, quiet period restarts.
$m = Merge-History @(,(New-TestRow $h2 'F:\Second' -Uploaded 200)) @{} $previous $now
$m = Merge-History @((New-TestRow $h1 $path -Uploaded 100), (New-TestRow $h2 'F:\Second' -Uploaded 200)) @{} @($m.items) ($now + 900)
$k = @($m.items | Where-Object hash -eq $h1)[0]
Assert ($k.firstSeen -eq $previous[0].firstSeen -and $k.quietSince -eq ($now + 900) -and $k.missingPolls -eq 0) 'short absence keeps storage history'

# Moving to an excluded drive is a definite state: record removed, not kept.
$m = Merge-History @((New-TestRow $h1 'E:\Archive' -Uploaded 100), (New-TestRow $h2 'F:\Second' -Uploaded 200)) @{} $previous $now
Assert (@($m.items | Where-Object hash -eq $h1).Count -eq 0 -and $m.excluded -eq 1) 'excluded drive'

# Records from 1.7 (without missing fields) and new torrents.
$m = Merge-History @((New-TestRow $h1 $path -Uploaded 100), (New-TestRow $h3 'D:\New')) @{} @($previous[0]) $now
Assert (@($m.items).Count -eq 2 -and @($m.observed).Count -eq 2) 'legacy record and new torrent'
Assert ((@($m.items | Where-Object hash -eq $h3)[0]).firstSeen -eq $now) 'new torrent starts now'

# Lower-case hashes from older state files still match.
$lower = Old-Record ($h1.ToLowerInvariant()) (40*$day) (20*$day) 100
$m = Merge-History @(,(New-TestRow $h1 $path -Uploaded 100)) @{} @($lower) $now
Assert ((@($m.items)[0]).firstSeen -eq $lower.firstSeen) 'hash comparison is case-insensitive'

# --- Strict validation of the whole list (gate before any autoload submission) -------------------
Assert ((Get-TorrentListProblem @((New-TestRow $h1 $path), (New-TestRow $h2 'F:\x'))) -eq '') 'valid list'
Assert ((Get-TorrentListProblem @()) -eq '') 'empty list has no corrupted values'
Assert ((Get-TorrentListProblem @(,(New-TestRow 'zz' $path))) -eq 'Hash') 'bad hash'
Assert ((Get-TorrentListProblem @((New-TestRow $h1 $path), (New-TestRow $h1 $path))) -eq 'DuplicateHash') 'duplicate hash'
Assert ((Get-TorrentListProblem @(,@($h1, 1))) -eq 'Format') 'short row'
$corruptions = @(
    @{ i = 1; v = 'x'; code = 'Status' }, @{ i = 3; v = -1; code = 'Size' }, @{ i = 4; v = '1000'; code = 'Progress' },
    @{ i = 5; v = $null; code = 'Downloaded' }, @{ i = 6; v = 1.5; code = 'Uploaded' }, @{ i = 8; v = 'fast'; code = 'UploadSpeed' },
    @{ i = 12; v = -3; code = 'PeersConnected' }, @{ i = 18; v = $null; code = 'Remaining' })
foreach ($c in $corruptions) {
    $bad = New-TestRow $h1 $path -Uploaded 100; $bad[$c.i] = $c.v
    Assert ((Get-TorrentListProblem @((New-TestRow $h2 'F:\Second' -Uploaded 200), $bad)) -eq $c.code) "field $($c.i) corruption not detected"
    # A damaged list is not evidence that absent torrents were removed.
    $m = Merge-History @(,$bad) @{} $previous $now
    $absent = @($m.items | Where-Object hash -eq $h2)[0]
    Assert ($absent -and [int]$absent.missingPolls -eq 0 -and $m.missing -eq 0 -and $m.invalid -eq 1) "field $($c.i) corruption increased missingPolls"
    $self = @($m.items | Where-Object hash -eq $h1)[0]
    Assert ($self.firstSeen -eq $previous[0].firstSeen -and $self.uploaded -eq 100) "field $($c.i) corruption reset the history of the damaged row"
    # Fields 5, 8, 12 do not drive history resets: the row is still observed (8/12 as "not enough data").
    if ($c.i -in @(8, 12)) { Assert (@($m.observed).Count -eq 1 -and !$self.knownPeers) "field $($c.i): row observed as 'not enough data'" }
    elseif ($c.i -eq 5) { Assert (@($m.observed).Count -eq 1 -and $self.knownPeers) 'field 5: row observed normally' }
    else { Assert (@($m.observed).Count -eq 0 -and $m.kept -ge 1) "field $($c.i): history kept unchanged" }
}
# The same damaged list for many polls and hours never drops absent history.
$bad = New-TestRow $h1 $path -Uploaded 100; $bad[8] = 'fast'
$state = @($previous)
foreach ($step in 0..5) { $state = @((Merge-History @(,$bad) @{} $state ($now + $step * 3 * 3600)).items) }
$absent = @($state | Where-Object hash -eq $h2)
Assert ($absent.Count -eq 1 -and [int]$absent[0].missingPolls -eq 0) 'repeated damaged lists dropped history'
# A torrent still listed in resume.dat is not counted as removed; absence from both sources is.
$m = Merge-History @(,(New-TestRow $h2 'F:\Second' -Uploaded 200)) @{ $h1 = $path } $previous $now
Assert ([int](@($m.items | Where-Object hash -eq $h1)[0]).missingPolls -eq 0 -and $m.missing -eq 0) 'torrent present in resume.dat counted as missing'
$m = Merge-History @(,(New-TestRow $h2 'F:\Second' -Uploaded 200)) @{ $h2 = 'F:\Second' } $previous $now
Assert ([int](@($m.items | Where-Object hash -eq $h1)[0]).missingPolls -eq 1 -and $m.missing -eq 1) 'absence confirmed by both sources must count'

# --- Report values: invalid client data is labelled, never cast or shown as zero -----------------
Assert ((Format-RowNumber 2048 1KB 1) -eq 2) 'number formatting'
Assert ((Format-RowNumber 0 1KB 1) -eq 0) 'zero is a real value'
foreach ($badValue in @($null, 'fast', '12', -1, 1.5, $true)) { Assert ((Format-RowNumber $badValue 1KB 1) -eq 'н/д') "value '$badValue' must be shown as unknown" }

"PASS Test-Rules: $script:AssertCount assertions"
