# uTorrent WebUI list=1 torrent row, official spec: https://github.com/bittorrent/webui/wiki/Web-UI-API
#  0 HASH  1 STATUS (bitfield)  2 NAME  3 SIZE  4 PERCENT PROGRESS (per mil)  5 DOWNLOADED  6 UPLOADED
#  7 RATIO  8 UPLOAD SPEED  9 DOWNLOAD SPEED  10 ETA  11 LABEL  12 PEERS CONNECTED  13 PEERS IN SWARM
# 14 SEEDS CONNECTED  15 SEEDS IN SWARM  16 AVAILABILITY  17 QUEUE ORDER  18 REMAINING
# uTorrent 2.2.1 returns exactly these 19 fields. Index 26 (save path) is a later 3.x extension outside the
# published spec; it is used only when present and absolute, otherwise the path comes from resume.dat.
# Demand means what our own client observes for this copy: bytes uploaded since the previous poll,
# current upload speed (8) or non-seed peers connected to us (12). Swarm totals (13, 15) describe the
# whole swarm and are never treated as demand for our copy.
function Test-TorrentHash($Value) {
    return ($Value -is [string] -and $Value -match '^[0-9A-Fa-f]{40}$')
}
function Test-RowInteger($Value, [double]$Minimum = 0, [double]$Maximum = 9.0e18) {
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) { return $false }
    if (!($Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double])) { return $false }
    $number = [double]$Value
    return ($number -eq [math]::Floor($number) -and $number -ge $Minimum -and $number -le $Maximum)
}
function Get-HistoryRowProblem($Row) {
    # Fields that drive history resets; a bad value here must not wipe accumulated history.
    if (!(Test-TorrentHash $Row[0])) { return 'Hash' }
    if (!(Test-RowInteger $Row[1])) { return 'Status' }
    if (!(Test-RowInteger $Row[3])) { return 'Size' }
    if (!(Test-RowInteger $Row[4] 0 1000)) { return 'Progress' }
    if (!(Test-RowInteger $Row[6])) { return 'Uploaded' }
    if (!(Test-RowInteger $Row[18])) { return 'Remaining' }
    return ''
}
function Get-TorrentRowProblem($Row) {
    # Strict check of every numeric field the monitor or autoload reads.
    $problem = Get-HistoryRowProblem $Row
    if ($problem) { return $problem }
    if (!(Test-RowInteger $Row[5])) { return 'Downloaded' }
    if (!(Test-RowInteger $Row[8])) { return 'UploadSpeed' }
    if (!(Test-RowInteger $Row[12])) { return 'PeersConnected' }
    return ''
}
function Get-TorrentListProblem($Rows) {
    # Whole-response check before autoload may act: one damaged row makes the response untrusted.
    $seen = @{}
    foreach ($row in @($Rows)) {
        if ($null -eq $row -or $row -is [string] -or $row -isnot [Collections.IList] -or $row.Count -lt 19) { return 'Format' }
        $problem = Get-TorrentRowProblem $row
        if ($problem) { return $problem }
        $hash = ([string]$row[0]).ToUpperInvariant()
        if ($seen.ContainsKey($hash)) { return 'DuplicateHash' }
        $seen[$hash] = $true
    }
    return ''
}
function Format-RowNumber($Value, [double]$Divisor = 1, [int]$Digits = 0) {
    # Report helper: an invalid or missing client value is shown as "н/д", never as 0 and never as an error.
    if (!(Test-RowInteger $Value)) { return 'н/д' }
    return [math]::Round([double]$Value / $Divisor, $Digits)
}
function Assert-TorrentRows($Rows) {
    foreach ($row in @($Rows)) {
        if ($null -eq $row -or $row -is [string] -or $row -isnot [Collections.IList] -or $row.Count -lt 19) { throw 'UnsupportedRowFormat' }
    }
}
function Get-HistoryPath($Row, $LocalPaths) {
    $path = ''
    if ($Row.Count -gt 26) { $path = [string]$Row[26] }
    if ($path -notmatch '^[A-Za-z]:\\' -and $LocalPaths -and $LocalPaths.ContainsKey([string]$Row[0])) {
        $path = [string]$LocalPaths[[string]$Row[0]]
    }
    if ($path -notmatch '^[A-Za-z]:\\') { return '' }
    return $path
}
function Get-UnixNow { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
# --- Upload history for cleanup (1.9) --------------------------------------------------------------
# UPLOADED (index 6) is cumulative, so the delta between two consecutive polls is exact. Each delta is
# stored per UTC hour: "in" when both polls fall into the same hour, "cross" (kept on the earlier hour)
# when the interval crosses an hour boundary. A series is continuous only while every poll sees the
# torrent complete, running, with known peers, at the same path, with a counter that never goes back,
# and polls are at most MaxGap apart. Anything else starts a new series (uploadSince) - it is never
# counted as zero upload. Only hours inside the last ~75 are kept, as a compact "hour,in,cross;..." string.
function ConvertFrom-UploadHours([string]$Text) {
    $map = @{}
    if (!$Text) { return $map }
    if ($Text.Length -gt 12000 -or $Text -notmatch '^\d{1,8},\d{1,16},\d{1,16}(;\d{1,8},\d{1,16},\d{1,16})*$') { return $null }
    foreach ($part in $Text.Split(';')) {
        $fields = $part.Split(',')
        $hour = [long]$fields[0]
        if ($map.ContainsKey($hour)) { return $null }
        $map[$hour] = [long[]]@([long]$fields[1], [long]$fields[2])
    }
    return $map
}
function ConvertTo-UploadHours($Map, [long]$MinHour) {
    $parts = foreach ($hour in @($Map.Keys | Where-Object { $_ -ge $MinHour } | Sort-Object)) {
        $value = $Map[$hour]
        if ($value[0] -gt 0 -or $value[1] -gt 0) { '{0},{1},{2}' -f $hour, $value[0], $value[1] }
    }
    return (@($parts) -join ';')
}
function Step-UploadHistory($Old, [string]$Restart, [bool]$Seeding, [long]$Uploaded, [long]$Now, [long]$MaxGap = 3600) {
    if (!$Seeding) { return [pscustomobject]@{ since = 0L; hours = ''; note = 'NotSeeding' } }
    $note = $Restart
    if (!$note) {
        $map = ConvertFrom-UploadHours ([string]$Old.uploadHours)
        $since = [long]$Old.uploadSince
        $then = [long]$Old.lastSeen
        $hourNow = [long][math]::Floor($Now / 3600)
        $hourThen = [long][math]::Floor($then / 3600)
        $delta = $Uploaded - [long]$Old.uploaded
        if ($null -eq $map) { $note = 'Damaged' }
        elseif ($since -le 0 -or $since -gt $then) { $note = 'Start'; if ([string]$Old.uploadNote) { $note = [string]$Old.uploadNote } }
        elseif ([int]$Old.missingPolls -gt 0) { $note = 'Missing' }
        elseif ($Now - $then -gt $MaxGap -or $hourNow - $hourThen -gt 1) { $note = 'Gap' }
        elseif ($delta -gt 1125899906842624) { $note = 'Invalid' }
        else {
            if (!$map.ContainsKey($hourThen)) { $map[$hourThen] = [long[]]@(0, 0) }
            if ($hourNow -eq $hourThen) { $map[$hourThen][0] += $delta } else { $map[$hourThen][1] += $delta }
            return [pscustomobject]@{ since = $since; hours = (ConvertTo-UploadHours $map ($hourNow - 75)); note = [string]$Old.uploadNote }
        }
    }
    # This poll is the first sample of a new continuous series.
    return [pscustomobject]@{ since = $Now; hours = ''; note = $note }
}
function Get-UploadSum($Map, [long]$First, [long]$Last) {
    # Upper bound for whole UTC hours First..Last: deltas inside them plus every interval touching them.
    $sum = 0L
    for ($hour = $First - 1; $hour -le $Last; $hour++) {
        if ($Map.ContainsKey($hour)) {
            if ($hour -ge $First) { $sum += $Map[$hour][0] }
            $sum += $Map[$hour][1]
        }
    }
    return $sum
}
function Get-UploadWindows($Record, [long]$Now) {
    # Three periods of 25 whole UTC hours each: hours H-24..H, H-48..H-24 and H-72..H-48 (H = current hour).
    # Each contains the corresponding true 24-hour period ending now (and the two before it), and its sum
    # is an upper bound, so "upper bound < 1 GiB" proves "less than 1 GiB" for that 24-hour period.
    $hour = [long][math]::Floor($Now / 3600)
    $since = [long]$Record.uploadSince
    $map = ConvertFrom-UploadHours ([string]$Record.uploadHours)
    $valid = ($null -ne $map -and $since -gt 0 -and [long]$Record.lastSeen -ge $hour * 3600 -and [long]$Record.lastSeen -le $Now)
    $days = @($null, $null, $null)
    for ($k = 1; $k -le 3; $k++) {
        $first = $hour - 24 * $k
        if ($valid -and $since -le $first * 3600) { $days[$k - 1] = Get-UploadSum $map $first ($hour - 24 * ($k - 1)) }
    }
    $total = $null
    if ($valid -and $since -le ($hour - 72) * 3600) { $total = Get-UploadSum $map ($hour - 72) $hour }
    $covered = 0.0
    if ($valid) { $covered = [math]::Round(($Now - $since) / 3600, 1) }
    [pscustomobject]@{ day1 = $days[0]; day2 = $days[1]; day3 = $days[2]; total72 = $total; complete = ($null -ne $total); hours = $covered }
}
function Update-History($Row, [string]$Path, $Old, [long]$Now) {
    $uploaded = [long]$Row[6]
    $status = [long]$Row[1]
    $complete = ([long]$Row[4] -eq 1000 -and [long]$Row[18] -eq 0)
    $running = (($status -band 1) -ne 0 -and ($status -band (2+16+32)) -eq 0)
    # Only our own observations count. Unknown values mean "not enough data", never "no demand".
    $knownPeers = ((Test-RowInteger $Row[8]) -and (Test-RowInteger $Row[12]))
    $reasons = @()
    if ($knownPeers -and [long]$Row[8] -gt 0) { $reasons += 'UploadSpeed' }
    if ($knownPeers -and [long]$Row[12] -gt 0) { $reasons += 'ConnectedPeers' }
    $restart = ''
    if (!$Old) { $restart = 'New' }
    elseif ($Old.path -ne $Path) { $restart = 'Path' }
    elseif ($Now -lt [long]$Old.lastSeen) { $restart = 'Clock' }
    elseif ($uploaded -lt [long]$Old.uploaded) { $restart = 'Counter' }
    $reset = [bool]$restart
    $first = $Now; $quiet = $Now; $total = 0L
    if (!$reset) {
        $first = [long]$Old.firstSeen
        $quiet = [long]$Old.quietSince
        $delta = $uploaded - [long]$Old.uploaded
        $total = [long]$Old.observedUpload + $delta
        if ($delta -gt 0) { $reasons = @('Upload') + $reasons }
        # A gap in observation (missed polls, torrent absent from the list) restarts the quiet period.
        if (($Now - [long]$Old.lastSeen) -gt 3600 -or [int]$Old.missingPolls -gt 0) { $quiet = $Now }
    }
    $demand = ($reasons.Count -gt 0)
    if (!$complete) { $first = $Now }
    if ($demand -or !$running -or !$complete -or !$knownPeers) { $quiet = $Now }
    $upload = Step-UploadHistory $Old $restart ($complete -and $running -and $knownPeers) $uploaded $Now
    [pscustomobject]@{
        hash = ([string]$Row[0]).ToUpperInvariant(); path = $Path; firstSeen = $first; quietSince = $quiet
        lastSeen = $Now; uploaded = $uploaded; observedUpload = $total
        complete = $complete; running = $running; knownPeers = $knownPeers; demand = $demand
        demandReason = ($reasons -join ','); missingPolls = 0; missingSince = 0L
        uploadSince = $upload.since; uploadHours = $upload.hours; uploadNote = $upload.note
    }
}
function Copy-HistoryRecord($Old, [int]$MissingPolls, [long]$MissingSince) {
    [pscustomobject]@{
        hash = ([string]$Old.hash).ToUpperInvariant(); path = [string]$Old.path; firstSeen = [long]$Old.firstSeen
        quietSince = [long]$Old.quietSince; lastSeen = [long]$Old.lastSeen; uploaded = [long]$Old.uploaded
        observedUpload = [long]$Old.observedUpload; complete = [bool]$Old.complete; running = [bool]$Old.running
        knownPeers = [bool]$Old.knownPeers; demand = [bool]$Old.demand; demandReason = [string]$Old.demandReason
        missingPolls = $MissingPolls; missingSince = $MissingSince
        uploadSince = [long]$Old.uploadSince; uploadHours = [string]$Old.uploadHours; uploadNote = [string]$Old.uploadNote
    }
}
function Merge-History($Rows, $LocalPaths, $PreviousItems, [long]$Now, [int]$DropPolls = 3, [long]$DropSeconds = 21600) {
    # Builds the next state.json. Temporary failures keep the previous record unchanged:
    # unknown path (resume.dat not readable), invalid values, unparseable rows.
    # A torrent counts as absent only when every row of the list is intact and resume.dat does not
    # list it either; it is then kept for DropPolls consecutive polls spanning DropSeconds before its
    # history is discarded as a real removal.
    $previous = @{}
    foreach ($item in @($PreviousItems)) {
        if ($null -ne $item -and (Test-TorrentHash ([string]$item.hash))) { $previous[([string]$item.hash).ToUpperInvariant()] = $item }
    }
    $rowList = @($Rows)
    if ($rowList.Count -eq 0 -and $previous.Count -gt 0) { throw 'EmptyTorrentList' }
    Assert-TorrentRows $rowList
    $items = New-Object Collections.ArrayList
    $observed = New-Object Collections.ArrayList
    $seen = @{}; $complete = $true
    $unknown = 0; $excluded = 0; $invalid = 0; $kept = 0; $missing = 0; $removed = 0
    foreach ($row in $rowList) {
        if (!(Test-TorrentHash $row[0])) { $invalid++; $complete = $false; continue }
        $hash = ([string]$row[0]).ToUpperInvariant()
        if ($seen.ContainsKey($hash)) { $invalid++; $complete = $false; continue }
        $seen[$hash] = $true
        $old = $null
        if ($previous.ContainsKey($hash)) { $old = $previous[$hash] }
        # Any corrupted value makes the response suspect: absence of other torrents proves nothing.
        if (Get-TorrentRowProblem $row) { $invalid++; $complete = $false }
        $path = ''
        if (!(Get-HistoryRowProblem $row)) {
            $path = Get-HistoryPath $row $LocalPaths
            if (!$path) { $unknown++ }
        }
        if (!$path) {
            if ($old) {
                $copy = Copy-HistoryRecord $old 0 0
                if ([int]$old.missingPolls -gt 0) {
                    # It was absent from the list: back, but not measurable yet - its upload history starts again.
                    $copy.quietSince = $Now; $copy.uploadSince = 0L; $copy.uploadHours = ''; $copy.uploadNote = 'Missing'
                }
                [void]$items.Add($copy); $kept++
            }
            continue
        }
        if ($path -notmatch '^[DF]:\\') { $excluded++; continue }
        $state = Update-History $row $path $old $Now
        [void]$items.Add($state)
        [void]$observed.Add([pscustomobject]@{ row = $row; path = $path; state = $state })
    }
    foreach ($hash in @($previous.Keys)) {
        if ($seen.ContainsKey($hash)) { continue }
        $old = $previous[$hash]
        if (!$complete -or ($LocalPaths -and $LocalPaths.ContainsKey($hash))) {
            # Damaged list, or uTorrent still lists the torrent in resume.dat: absence is not evidence of removal.
            [void]$items.Add((Copy-HistoryRecord $old ([int]$old.missingPolls) ([long]$old.missingSince))); $kept++
            continue
        }
        $polls = [int]$old.missingPolls + 1
        $since = [long]$old.missingSince
        if ($since -le 0) { $since = $Now }
        if ($polls -ge $DropPolls -and ($Now - $since) -ge $DropSeconds) { $removed++; continue }
        [void]$items.Add((Copy-HistoryRecord $old $polls $since)); $missing++
    }
    [pscustomobject]@{
        items = $items.ToArray(); observed = $observed.ToArray()
        unknown = $unknown; excluded = $excluded; invalid = $invalid; kept = $kept; missing = $missing; removed = $removed
    }
}
function Get-DemandLabel($State) {
    $names = @{ Upload = 'отдача с прошлой проверки'; UploadSpeed = 'идёт отдача'; ConnectedPeers = 'подключены пиры' }
    $labels = @()
    foreach ($code in ([string]$State.demandReason -split ',')) { if ($names.ContainsKey($code)) { $labels += $names[$code] } }
    return ($labels -join '; ')
}
