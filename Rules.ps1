function Update-History($Row, [string]$Path, $Old, [long]$Now) {
    $uploaded = [long]$Row[6]
    $status = [int]$Row[1]
    $complete = ([int]$Row[4] -eq 1000 -and [long]$Row[18] -eq 0)
    $running = (($status -band 1) -ne 0 -and ($status -band (2+16+32)) -eq 0)
    $knownPeers = ($null -ne $Row[12] -and $null -ne $Row[13] -and [long]$Row[12] -ge 0 -and [long]$Row[13] -ge 0)
    $demand = ([long]$Row[12] -gt 0 -or [long]$Row[13] -gt 0 -or [long]$Row[8] -gt 0)
    $reset = (!$Old -or $Old.path -ne $Path -or $Now -lt [long]$Old.lastSeen -or $uploaded -lt [long]$Old.uploaded)
    $first = $Now; $quiet = $Now; $total = 0L
    if (!$reset) {
        $first = [long]$Old.firstSeen
        $quiet = [long]$Old.quietSince
        $delta = $uploaded - [long]$Old.uploaded
        $total = [long]$Old.observedUpload + $delta
        if ($delta -gt 0) { $demand = $true }
        if (($Now - [long]$Old.lastSeen) -gt 3600) { $quiet = $Now }
    }
    if (!$complete) { $first = $Now }
    if ($demand -or !$running -or !$complete -or !$knownPeers) { $quiet = $Now }
    [pscustomobject]@{
        hash = [string]$Row[0]; path = $Path; firstSeen = $first; quietSince = $quiet
        lastSeen = $Now; uploaded = $uploaded; observedUpload = $total
        complete = $complete; running = $running; knownPeers = $knownPeers; demand = $demand
    }
}
function Get-Decision($State, [long]$Now) {
    if (!$State.complete) { return 'Загрузка не завершена' }
    if (!$State.running -or !$State.knownPeers) { return 'Недостаточно данных / остановлена' }
    if ($State.demand) { return 'Есть спрос' }
    if (($Now - $State.firstSeen) -ge 30*86400 -and ($Now - $State.quietSince) -ge 14*86400) { return 'Кандидат на удаление' }
    return 'Наблюдение'
}
