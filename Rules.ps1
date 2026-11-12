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
    $reset = (!$Old -or $Old.path -ne $Path -or $Now -lt [long]$Old.lastSeen -or $uploaded -lt [long]$Old.uploaded)
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
    [pscustomobject]@{
        hash = ([string]$Row[0]).ToUpperInvariant(); path = $Path; firstSeen = $first; quietSince = $quiet
        lastSeen = $Now; uploaded = $uploaded; observedUpload = $total
        complete = $complete; running = $running; knownPeers = $knownPeers; demand = $demand
        demandReason = ($reasons -join ','); missingPolls = 0; missingSince = 0L
    }
}
function Copy-HistoryRecord($Old, [int]$MissingPolls, [long]$MissingSince) {
    [pscustomobject]@{
        hash = ([string]$Old.hash).ToUpperInvariant(); path = [string]$Old.path; firstSeen = [long]$Old.firstSeen
        quietSince = [long]$Old.quietSince; lastSeen = [long]$Old.lastSeen; uploaded = [long]$Old.uploaded
        observedUpload = [long]$Old.observedUpload; complete = [bool]$Old.complete; running = [bool]$Old.running
        knownPeers = [bool]$Old.knownPeers; demand = [bool]$Old.demand; demandReason = [string]$Old.demandReason
        missingPolls = $MissingPolls; missingSince = $MissingSince
    }
}
function Merge-History($Rows, $LocalPaths, $PreviousItems, [long]$Now, [int]$DropPolls = 3, [long]$DropSeconds = 21600) {
    # Builds the next state.json. Temporary failures keep the previous record unchanged:
    # unknown path (resume.dat not readable), invalid values, unparseable rows.
    # A torrent absent from a complete list is kept for DropPolls consecutive polls spanning
    # DropSeconds before its history is discarded as a real removal.
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
        $path = ''
        if (Get-HistoryRowProblem $row) { $invalid++ } else {
            $path = Get-HistoryPath $row $LocalPaths
            if (!$path) { $unknown++ }
        }
        if (!$path) {
            if ($old) {
                $copy = Copy-HistoryRecord $old 0 0
                if ([int]$old.missingPolls -gt 0) { $copy.quietSince = $Now }
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
        if (!$complete) {
            # Some rows could not be identified: absence is not evidence of removal.
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
function Get-Decision($State, [long]$Now) {
    if (!$State.complete) { return 'Загрузка не завершена' }
    if (!$State.running -or !$State.knownPeers) { return 'Недостаточно данных / остановлена' }
    if ($State.demand) { return 'Есть спрос' }
    if (($Now - $State.firstSeen) -ge 30*86400 -and ($Now - $State.quietSince) -ge 14*86400) { return 'Кандидат на удаление' }
    return 'Наблюдение'
}
