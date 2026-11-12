. "$PSScriptRoot\TestCommon.ps1"
. "$PSScriptRoot\..\Feed.ps1"
. "$PSScriptRoot\..\AutoLoad.ps1"
$now = [DateTimeOffset]::UtcNow
function New-FeedEntry([string]$Topic, [DateTimeOffset]$Updated, [string]$Hash = ('A' * 40), [string]$Title = 'Film WEB-DLRip Dub') {
    [pscustomobject]@{ topic = $Topic; updated = $Updated; hash = $Hash; title = $Title }
}
function New-FeedXml([DateTimeOffset]$Updated, $Entries) {
    $xml = '<?xml version="1.0" encoding="utf-8"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Фильмы</title><id>tag:rto.feed,2000:/f/252</id><updated>' + $Updated.ToString('o') + '</updated>'
    foreach ($e in @($Entries)) {
        $xml += '<entry><title>' + [Security.SecurityElement]::Escape($e.title) + '</title><id>tag:rto.feed,2000:/t/' + $e.topic + '</id><updated>' + $e.updated.ToString('o') + '</updated><link rel="enclosure" href="magnet:?xt=urn:btih:' + $e.hash + '&amp;tr=x"/></entry>'
    }
    return $xml + '</feed>'
}
function New-TestSnapshot([DateTimeOffset]$FetchedAt, $Entries, [int]$LagSeconds = 60, [int]$Count = -1, [hashtable]$Extra = @{}) {
    if ($Count -lt 0) { $Count = @($Entries).Count }
    $o = [ordered]@{ schema = 1; forum = 252; source = 'https://feed.rutracker.cc/atom/f/252.atom'; fetched_at = $FetchedAt.ToString('o')
        entry_count = $Count; xml = (New-FeedXml $FetchedAt.AddSeconds(-$LagSeconds) $Entries) }
    foreach ($key in $Extra.Keys) { $o[$key] = $Extra[$key] }
    return ($o | ConvertTo-Json -Depth 5)
}
function Get-Window([DateTimeOffset]$Base, [int[]]$Topics, [double]$OldestHours = 300) {
    $i = 0
    foreach ($t in $Topics) { New-FeedEntry ([string]$t) $Base.AddHours(-1 - $i * ($OldestHours / [math]::Max(1, $Topics.Count - 1))) ('{0:X40}' -f $t); $i++ }
}

# --- Snapshot checks: freshness, source, content, rollback -----------------------------------------------
$entries = @(Get-Window $now 101, 102, 103)
$s = Convert-FilmSnapshot (New-TestSnapshot $now.AddMinutes(-20) $entries -Extra @{ sequence = 12; trigger = 'refresh-feed:schedule' })
Assert (@($s.entries).Count -eq 3 -and $s.sequence -eq 12 -and $s.trigger -eq 'refresh-feed:schedule') 'fresh snapshot with diagnostics'
Assert ([math]::Abs(($now - $s.fetchedAtValue).TotalMinutes - 20) -lt 1) 'snapshot time kept'
Assert ($script:FeedDiagnostics.ageHours -ge 0.3 -and $script:FeedDiagnostics.ageHours -le 0.4) 'age reported'
Assert-Throws { Convert-FilmSnapshot (New-TestSnapshot $now.AddHours(-7) $entries) } 'MirrorStaleOver6Hours' 'stale snapshot accepted'
Assert ($script:FeedDiagnostics.ageHours -ge 6.9 -and $script:FeedDiagnostics.fetchedAt -lt $now) 'age known for a stale snapshot'
Assert-Throws { Convert-FilmSnapshot (New-TestSnapshot $now.AddMinutes(30) $entries) } 'MirrorFutureDate' 'future snapshot accepted'
Assert-Throws { Convert-FilmSnapshot (New-TestSnapshot $now.AddMinutes(-5) $entries -Count 4) } 'MirrorInvalid' 'entry count mismatch accepted'
Assert-Throws { Convert-FilmSnapshot ((New-TestSnapshot $now $entries) -replace 'f/252\.atom', 'f/1.atom') } 'MirrorInvalid' 'foreign source accepted'
Assert-Throws { Convert-FilmSnapshot ((New-TestSnapshot $now $entries) -replace '"fetched_at":\s*"[^"]+"', '"fetched_at": "soon"') } 'MirrorInvalid' 'unparseable time accepted'
# A fresh fetched_at on an old Atom document is an old snapshot presented as fresh.
Assert-Throws { Convert-FilmSnapshot (New-TestSnapshot $now.AddMinutes(-5) $entries -LagSeconds (3 * 3600)) } 'MirrorSourceStale' 'old Atom document accepted as fresh'
Assert (@((Convert-FilmSnapshot (New-TestSnapshot $now.AddMinutes(-5) $entries -LagSeconds 600)).entries).Count -eq 3) 'normal 10-minute source lag'
# Never go back to an older snapshot (CDN edge, reverted commit); the same one is fine.
$last = $now.AddMinutes(-10)
Assert-Throws { Convert-FilmSnapshot (New-TestSnapshot $now.AddMinutes(-40) $entries) $last } 'MirrorRollback' 'older snapshot replaced a newer one'
Assert (@((Convert-FilmSnapshot (New-TestSnapshot $last $entries) $last).entries).Count -eq 3) 'same snapshot again'
Assert (@((Convert-FilmSnapshot (New-TestSnapshot $now.AddMinutes(-1) $entries) $last).entries).Count -eq 3) 'newer snapshot'
Assert ((ConvertTo-FeedTime ([datetime]::SpecifyKind([datetime]'2026-11-12T01:02:07', 'Utc'))).ToUnixTimeSeconds() -eq 1794445327) 'DateTime from ConvertFrom-Json (PowerShell 7)'
Assert ((ConvertTo-FeedTime '2026-11-12T01:02:07.025423+00:00').ToUnixTimeSeconds() -eq 1794445327) 'ISO time string'

# --- Coverage: the source keeps only the newest 50 entries ------------------------------------------------
Assert ((Get-FeedCoverage $entries $null).status -eq 'First') 'first snapshot'
Assert ((Get-FeedCoverage $entries $now.AddHours(-11)).status -eq 'Contiguous') 'eleven-hour gap is inside the feed window'
$gap = Get-FeedCoverage @(Get-Window $now 201, 202 -OldestHours 24) $now.AddDays(-20)
Assert ($gap.status -eq 'PossibleGap' -and $gap.from -lt $gap.to) 'gap beyond the feed window detected'

# --- Mirror status (diagnostics only, strictly validated) ---------------------------------------------
$status = ConvertFrom-FeedStatus ('{"schema":1,"last_attempt_at":"' + $now.AddMinutes(-30).ToString('o') + '","last_error":"UpstreamHTTP=503","consecutive_failures":4}')
Assert ($status.lastError -eq 'UpstreamHTTP=503' -and $status.failures -eq 4) 'status parsed'
Assert ($null -eq (ConvertFrom-FeedStatus '{"schema":1,"last_attempt_at":"x","last_error":"","consecutive_failures":0}')) 'bad status time accepted'
Assert ($null -eq (ConvertFrom-FeedStatus ('{"schema":1,"last_attempt_at":"' + $now.ToString('o') + '","last_error":"<script>","consecutive_failures":1}'))) 'unsafe error text accepted'
Assert ($null -eq (ConvertFrom-FeedStatus 'not json')) 'broken status accepted'

$temp = New-TestDirectory
try {
    # --- Collect-Films end to end: no network, snapshots served by a stub ------------------------------
    $script:snapshotJson = $null; $script:statusJson = $null; $script:requests = @()
    function Invoke-WebRequest {
        param($Uri, [switch]$UseBasicParsing, $TimeoutSec)
        $script:requests += [string]$Uri
        $text = $script:snapshotJson
        if ([string]$Uri -like '*feed-status.json') { $text = $script:statusJson }
        if ($null -eq $text) { throw (New-Object Net.WebException 'not found') }
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        return [pscustomobject]@{ RawContentStream = (New-Object IO.MemoryStream (, $bytes)) }
    }
    function Read-FeedState { return (Get-Content -LiteralPath (Join-Path $temp 'feed-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json) }
    $t1 = $now.AddMinutes(-50)
    $script:snapshotJson = New-TestSnapshot $t1 @(Get-Window $t1 101, 102, 103) -Extra @{ sequence = 1 }
    Assert ((Collect-Films @() $temp) -eq 3) 'first snapshot processed'
    Assert ((ConvertTo-FeedTime (Read-FeedState).snapshotFetchedAt) -eq (ConvertTo-FeedTime $t1.ToString('o'))) 'accepted snapshot time stored'
    $t2 = $now.AddMinutes(-5)
    $script:snapshotJson = New-TestSnapshot $t2 @(Get-Window $t2 104, 101, 102, 103) -Extra @{ sequence = 2 }
    Assert ((Collect-Films @() $temp) -eq 4 -and @($script:LatestFilmEntries).Count -eq 4) 'newer snapshot processed'
    $html = Get-FileText (Join-Path $temp 'films.html')
    Assert ($html -match 'возраст' -and $html -match '50 последних') 'films.html shows snapshot age and the window limit'
    # The previous snapshot comes back (CDN edge): rejected, state untouched.
    $before = Get-FileText (Join-Path $temp 'feed-state.json')
    $script:snapshotJson = New-TestSnapshot $t1 @(Get-Window $t1 101, 102, 103)
    Assert-Throws { Collect-Films @() $temp } 'MirrorRollback' 'rolled back snapshot accepted'
    Assert ($null -eq $script:LatestFilmEntries -and (Get-FileText (Join-Path $temp 'feed-state.json')) -eq $before) 'rollback changed the feed state'
    # Stale mirror: the reason is explained (GitHub did not run vs the source failed).
    $script:snapshotJson = New-TestSnapshot $now.AddHours(-9) @(Get-Window $now 101)
    Assert-Throws { Collect-Films @() $temp } 'MirrorStaleOver6Hours' 'stale snapshot accepted'
    $script:statusJson = $null
    $text = Get-FeedFailureSummary
    Assert ($text -match 'возраст 9' -and $text -match 'GitHub Actions не запускал' -and $text -match 'очередь') "no-run reason: $text"
    $script:statusJson = '{"schema":1,"last_attempt_at":"' + $now.AddHours(-1).ToString('o') + '","last_error":"UpstreamHTTP=503","consecutive_failures":3}'
    $text = Get-FeedFailureSummary
    Assert ($text -match 'UpstreamHTTP=503' -and $text -match 'подряд: 3') "source failure reason: $text"
    # Recovery after a long outage: everything still in the feed window is picked up; a hole is reported.
    $t3 = $now.AddMinutes(-2)
    $script:snapshotJson = New-TestSnapshot $t3 @(Get-Window $t3 105, 106, 104 -OldestHours 2)
    $state = Read-FeedState; $state.snapshotFetchedAt = $now.AddDays(-20).ToString('o')
    Save-AutoJson $state (Join-Path $temp 'feed-state.json')
    Assert ((Collect-Films @() $temp) -eq 3) 'snapshot after a long outage processed'
    Assert ($script:FeedCoverage.status -eq 'PossibleGap') 'coverage hole not detected'
    Assert ((Get-FileText (Join-Path $temp 'films.html')) -match 'могли выпасть') 'coverage hole not shown'
    Assert ((Get-FileText (Join-Path $temp 'monitor.log')) -match 'FEED GAP') 'coverage hole not logged'
    Assert (@($script:requests | Where-Object { $_ -notlike 'https://raw.githubusercontent.com/kolpakovden/TorrentControl/main/data/*' }).Count -eq 0) 'unexpected URL requested'
} finally { Remove-TestDirectory $temp }
"PASS Test-Feed: $script:AssertCount assertions"
