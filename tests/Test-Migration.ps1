. "$PSScriptRoot\TestCommon.ps1"
. "$PSScriptRoot\..\Monitor.ps1"
. "$PSScriptRoot\..\TrackerMigration.ps1"
# Offline: a fake uTorrent WebUI (Invoke-WebRequest stub) and a fake personal .torrent source. Fake keys only.
$temp = New-TestDirectory
try {
    $public = 'http://bt.t-ru.org/ann?magnet'
    $config = [pscustomobject]@{ url = 'http://127.0.0.1:8080' }
    $credential = New-Object Management.Automation.PSCredential('admin', (ConvertTo-SecureString 'fake-webui' -AsPlainText -Force))
    function Personal-Tiers([string]$Topic) { return @(@('http://bt3.t-ru.org/ann?pk=FAKE-MIG-KEY-' + $Topic), @('http://retracker.local/announce')) }

    # --- Fake client: rows, tracker lists and the behaviour of setprops per hash ---------------------------
    $script:client = [ordered]@{}
    $script:requests = New-Object Collections.ArrayList
    $script:setBehaviour = @{}
    $script:resumePaths = @{}
    function Add-Client([string]$Hash, [string]$Path, [string]$Trackers, [int]$Fields = 27) {
        $script:client[$Hash] = @{ row = (New-TestRow $Hash $Path -Size 4GB -Uploaded 1GB -Fields $Fields -Name ('Film ' + $Hash.Substring(0, 1))); trackers = $Trackers }
    }
    function Invoke-WebRequest {
        param([Parameter(Position = 0)][string]$Uri, $WebSession, [switch]$UseBasicParsing, $TimeoutSec)
        [void]$script:requests.Add($Uri)
        $stream = { param($text) $s = New-Object IO.MemoryStream(, [Text.Encoding]::UTF8.GetBytes($text)); [pscustomobject]@{ Content = $text; RawContentStream = $s } }
        if ($Uri -like '*/gui/token.html') { return [pscustomobject]@{ Content = '<html><div id="token" style="display:none;">FAKE-TOKEN</div></html>' } }
        $query = @{}
        foreach ($pair in ($Uri -replace '^[^?]*\?', '').Split('&')) { $kv = $pair.Split('=', 2); $query[$kv[0]] = [uri]::UnescapeDataString($kv[1]) }
        if ($query.list -eq '1') {
            $plain = New-Object Collections.ArrayList
            foreach ($t in $script:client.Values) { $copy = New-Object object[] $t.row.Count; for ($i = 0; $i -lt $t.row.Count; $i++) { $copy[$i] = $t.row[$i] }; [void]$plain.Add($copy) }
            return (& $stream (@{ build = 25534; label = @(); torrents = $plain.ToArray(); torrentc = '1' } | ConvertTo-Json -Depth 6))
        }
        if ($query.action -eq 'getprops') {
            $t = $script:client[$query.hash]
            return (& $stream (@{ build = 25534; props = @(@{ hash = $query.hash; trackers = $t.trackers; ulrate = 0; dlrate = 0; superseed = 0; dht = 1; pex = 1 }) } | ConvertTo-Json -Depth 4))
        }
        if ($query.action -eq 'setprops') {
            Assert ($query.s -eq 'trackers') 'setprops for something other than trackers'
            $t = $script:client[$query.hash]
            switch ([string]$script:setBehaviour[$query.hash]) {
                'ignore' { }
                'checking' { $t.trackers = $query.v; $t.row[1] = 130 }
                default { $t.trackers = $query.v }
            }
            return (& $stream '{"build":25534}')
        }
        throw "unexpected WebUI request: $Uri"
    }
    function Read-LocalPaths { return $script:resumePaths }
    $script:personalMode = @{}; $script:personalCalls = New-Object Collections.ArrayList
    function Get-PersonalTorrent([string]$Directory, [string]$Topic, [string]$Hash) {
        [void]$script:personalCalls.Add($Topic)
        $mode = $script:personalMode[$Topic]; if (!$mode) { $mode = $script:personalMode['*'] }
        if ($mode) { throw $mode }
        return [pscustomobject]@{ path = 'unused'; host = 'bt3.t-ru.org'; tiers = (Personal-Tiers $Topic); size = 4GB }
    }
    $script:answer = ''; $script:prompts = New-Object Collections.ArrayList
    $confirm = { param($text) [void]$script:prompts.Add($text); return $script:answer }
    function Migrate([string]$Mode, [string]$Hash = '') { return (Invoke-TrackerMigration -Directory $temp -Mode $Mode -Hash $Hash -Config $config -Credential $credential -Confirm $confirm -PauseSeconds 0) }
    function Entry([string]$Hash) { return @((Get-Content -LiteralPath (Join-Path $temp 'tracker-migration.json') -Raw -Encoding UTF8 | ConvertFrom-Json).entries | Where-Object { $_.hash -eq $Hash })[0] }
    function Sets { return @($script:requests | Where-Object { $_ -match 'action=setprops' }) }

    # TorrentControl records (auto-state.json) and the client.
    $h = @{}; foreach ($k in @('a', 'b', 'c', 'd', 'e', 'f', '1', '2', '3', '4', '5', '6', '7')) { $h[$k] = New-TestHash $k }
    $items = New-Object Collections.ArrayList
    $topics = @{ a = 1001; b = 1002; c = 1003; d = 1004; e = 1005; f = 1006; '1' = 1007; '2' = 1008; '3' = 1009; '4' = 1010; '5' = 1011; '7' = 1013 }
    foreach ($k in @('a', 'b', 'c', 'd', 'e', 'f', '1', '2', '3', '4', '5', '7')) {
        $status = 'Confirmed'; if ($k -eq '5') { $status = 'Submitted' }
        $path = 'D:\Фильмы\rt-' + $topics[$k]; if ($k -eq '7') { $path = 'D:\Other\rt-1013' }
        [void]$items.Add([pscustomobject]@{ topic = [string]$topics[$k]; hash = $h[$k]; title = 'Film ' + $k; status = $status; bytes = 4GB; path = $path; reason = ''; submittedAt = ''; lastAttempt = '' })
    }
    Assert-Throws { Migrate 'DryRun' } 'AutoBaselineMissing' 'migration without the autoload journal'
    Save-AutoJson ([ordered]@{ version = 1; enabledAt = '2026-01-01T00:00:00Z'; items = $items.ToArray() }) (Join-Path $temp 'auto-state.json')
    foreach ($k in @('a', 'b', 'd', 'e', '1')) { Add-Client $h[$k] ('D:\Фильмы\rt-' + $topics[$k] + '\Film ' + $k) ($public + "`r`n") }
    Add-Client $h['c'] 'D:\Фильмы\rt-1003' ((Personal-Tiers '1003' | ForEach-Object { $_ -join "`r`n" }) -join "`r`n`r`n")
    Add-Client $h['f'] '' ($public + "`r`n") -Fields 19              # uTorrent 2.2.1 row: path from resume.dat
    $script:resumePaths[$h['f']] = 'D:\Фильмы\rt-1006'
    Add-Client $h['2'] 'F:\Films\Film 2' ($public + "`r`n")           # moved by the person
    Add-Client $h['4'] 'D:\Фильмы\rt-1010' ($public + "`r`n`r`nhttp://retracker.local/announce`r`n")
    Add-Client $h['5'] 'D:\Фильмы\rt-1011' ($public + "`r`n")         # not yet confirmed by autoload
    Add-Client $h['6'] 'D:\Фильмы\rt-1012' ($public + "`r`n")         # manual torrent, not in auto-state.json
    Add-Client $h['7'] 'D:\Other\rt-1013' ($public + "`r`n")
    $script:personalMode['1007'] = 'PersonalHashMismatch'
    $untouched = @{}; foreach ($k in @('5', '6', '7', '2', '4')) { $untouched[$k] = $script:client[$h[$k]].trackers }
    $paths = @{}; foreach ($key in @($script:client.Keys)) { $paths[$key] = [string]$script:client[$key].row[26] }

    # --- Dry Run: nothing changes, every record classified -----------------------------------------------
    $summary = Migrate 'DryRun'
    Assert (@(Sets).Count -eq 0) 'Dry Run changed trackers'
    Assert ($summary.planned -eq 5 -and $summary.already -eq 1 -and $summary.skipped -eq 4) "dry run summary: $($summary | Out-String)"
    foreach ($k in @('a', 'b', 'd', 'e', 'f')) { Assert ((Entry $h[$k]).status -eq 'Planned' -and (Entry $h[$k]).tracker -eq 'bt3.t-ru.org') "$k not planned" }
    Assert ((Entry $h['c']).status -eq 'AlreadyPersonal') 'personal torrent planned again'
    $expect = @{ '1' = 'TopicHashChanged'; '2' = 'PathMismatch'; '3' = 'NotInClient'; '4' = 'UnexpectedTrackers' }
    foreach ($k in $expect.Keys) { Assert ((Entry $h[$k]).status -eq 'Skipped' -and (Entry $h[$k]).reason -eq $expect[$k]) "$k not skipped as $($expect[$k])" }
    foreach ($k in @('5', '6', '7')) { Assert ($null -eq (Entry $h[$k])) "$k is not a confirmed TorrentControl torrent but was examined" }
    Assert (($script:personalCalls -join ',') -eq '1001,1002,1004,1005,1006,1007') "personal torrents requested for: $($script:personalCalls -join ',')"
    $html = Get-FileText (Join-Path $temp 'tracker-migration.html')
    Assert ($html -match 'DRY RUN' -and $html -match 'bt3\.t-ru\.org' -and $html -match 'Готово к перепривязке') 'dry run report'
    # Without RuTracker access nothing is planned and the run stops at the first record.
    $script:personalMode['*'] = 'RuTrackerNotConfigured'; $script:personalCalls.Clear()
    $summary = Migrate 'DryRun'
    Assert ($summary.waiting -eq 1 -and $script:personalCalls.Count -eq 1 -and (Entry $h['a']).status -eq 'WaitingAuth' -and (Entry $h['a']).reason -eq 'RuTrackerNotConfigured') 'missing authorization did not stop'
    Assert (@(Sets).Count -eq 0) 'changed without authorization'
    $script:personalMode.Remove('*')

    # --- One torrent, explicit confirmation --------------------------------------------------------------
    Assert-Throws { Migrate 'Apply' } 'HashRequired' 'apply without a hash'
    foreach ($k in @('5', '6', '7')) { Assert-Throws { Migrate 'Apply' $h[$k] } 'NotOwnedByTorrentControl' "$k changed although not a confirmed TorrentControl torrent" }
    $script:answer = 'yes'
    $summary = Migrate 'Apply' $h['a']
    Assert ($summary.cancelled -eq 1 -and @(Sets).Count -eq 0 -and (Entry $h['a']).status -eq 'Cancelled') 'not cancelled without the exact answer'
    $script:answer = 'YES ' + $h['a'].Substring(0, 8)
    $summary = Migrate 'Apply' $h['a'].ToLowerInvariant()
    Assert ($summary.applied -eq 1 -and @(Sets).Count -eq 1 -and (Entry $h['a']).status -eq 'Applied' -and (Entry $h['a']).appliedAt) 'single migration not applied'
    $set = @(Sets)[0]
    $expected = 'http://bt3.t-ru.org/ann?pk=FAKE-MIG-KEY-1001' + "`r`n`r`n" + 'http://retracker.local/announce'
    Assert ($set -match ('action=setprops&hash=' + $h['a'] + '&s=trackers&v=') -and $set.EndsWith('&v=' + [uri]::EscapeDataString($expected))) "setprops request: $(Protect-SecretText $set)"
    Assert ($script:client[$h['a']].trackers -eq $expected) 'tracker list not replaced by the personal one'
    Assert ((Get-TrackerClass $script:client[$h['a']].trackers).kind -eq 'Personal') 'read back not personal'
    Assert (@($script:prompts | Where-Object { $_ -match 'FAKE-MIG-KEY' }).Count -eq 0 -and $script:prompts[-1] -match 'bt3\.t-ru\.org') 'confirmation shows the key or hides the server'
    # 2.2.1 that ignores the change: detected by reading back, stops.
    $script:setBehaviour[$h['b']] = 'ignore'
    $script:answer = 'YES ' + $h['b'].Substring(0, 8)
    $summary = Migrate 'Apply' $h['b']
    Assert ($summary.failed -eq 1 -and (Entry $h['b']).status -eq 'Failed' -and (Entry $h['b']).reason -eq 'ReadBackMismatch') 'ignored setprops not detected'
    # A change that starts a recheck (or moves data) is reported, not accepted.
    $script:setBehaviour[$h['d']] = 'checking'
    $script:answer = 'YES ' + $h['d'].Substring(0, 8)
    $summary = Migrate 'Apply' $h['d']
    Assert ($summary.failed -eq 1 -and (Entry $h['d']).reason -eq 'StateChanged') 'state change after setprops not detected'
    # Failed records stay visible and are not retried by Dry Run or batch.
    $count = @(Sets).Count; $script:personalCalls.Clear()
    $summary = Migrate 'DryRun'
    Assert ($summary.failed -eq 2 -and (Entry $h['b']).status -eq 'Failed' -and (Entry $h['d']).status -eq 'Failed' -and $script:personalCalls -notcontains '1002') 'failed records re-planned'
    Assert ((Entry $h['a']).status -eq 'Applied') 'applied record downgraded'

    # --- Statistics confirmed by the person, then batch --------------------------------------------------
    Assert-Throws { Migrate 'Batch' } 'BatchNeedsVerifiedMigration' 'batch before a verified migration'
    Assert-Throws { Migrate 'Verify' $h['e'] } 'NothingToVerify' 'verify of a record that was not applied'
    $script:answer = 'VERIFIED'
    Assert-Throws { Migrate 'Verify' $h['a'] } 'VerifyCancelled' 'verify without the exact answer'
    $script:answer = 'VERIFIED ' + $h['a'].Substring(0, 8)
    $null = Migrate 'Verify' $h['a']
    Assert ((Entry $h['a']).status -eq 'Verified' -and (Entry $h['a']).verifiedAt) 'verification not recorded'
    $script:answer = 'yes'
    Assert-Throws { Migrate 'Batch' } 'BatchCancelled' 'batch without the exact answer'
    Assert (@(Sets).Count -eq $count) 'cancelled batch changed something'
    $script:answer = 'YES BATCH'
    $summary = Migrate 'Batch'
    Assert ($summary.applied -eq 2 -and (Entry $h['e']).status -eq 'Applied' -and (Entry $h['f']).status -eq 'Applied') "batch: $($summary | Out-String)"
    Assert (@(Sets).Count -eq $count + 2) 'batch changed more than the planned torrents'
    Assert ((Entry $h['a']).status -eq 'Verified' -and (Entry $h['c']).status -eq 'AlreadyPersonal' -and (Entry $h['b']).status -eq 'Failed') 'batch rewrote other records'
    $count = @(Sets).Count
    $script:answer = 'YES ' + $h['e'].Substring(0, 8)
    $summary = Migrate 'Apply' $h['e']
    Assert ($summary.already -eq 1 -and @(Sets).Count -eq $count) 'already personal torrent changed again'
    # Batch stops at the first authorization problem.
    $journalPath = Join-Path $temp 'tracker-migration.json'
    $script:client[$h['e']].trackers = $public; $script:client[$h['f']].trackers = $public
    $script:personalMode['*'] = 'RuTrackerCaptchaRequired'; $script:personalCalls.Clear(); $script:answer = 'YES BATCH'
    $summary = Migrate 'Batch'
    Assert ($summary.waiting -eq 1 -and $script:personalCalls.Count -eq 1 -and @(Sets).Count -eq $count) 'batch continued without authorization'
    $script:personalMode.Remove('*')
    # Interrupted change (journal says Applying): reported as failed, never touched automatically.
    $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json
    @($journal.entries | Where-Object { $_.hash -eq $h['f'] })[0].status = 'Applying'
    Save-AutoJson $journal $journalPath
    $summary = Migrate 'DryRun'
    Assert ((Entry $h['f']).status -eq 'Failed' -and (Entry $h['f']).reason -eq 'Interrupted') 'interrupted change not reported'

    # --- Safety of the whole run -------------------------------------------------------------------------
    foreach ($k in $untouched.Keys) { Assert ($script:client[$h[$k]].trackers -eq $untouched[$k]) "trackers of $k changed" }
    foreach ($key in @($script:client.Keys)) { Assert ([string]$script:client[$key].row[26] -eq $paths[$key]) "path of $key changed" }
    $bad = @($script:requests | Where-Object { $_ -notmatch '/gui/token\.html$' -and $_ -notmatch '[?&]list=1$' -and $_ -notmatch '&action=getprops&hash=[0-9A-F]{40}$' -and $_ -notmatch '&action=setprops&hash=[0-9A-F]{40}&s=trackers&v=[^&]+$' })
    Assert ($bad.Count -eq 0) "unexpected WebUI request: $($bad -join ' | ')"
    foreach ($name in @('tracker-migration.json', 'tracker-migration.html', 'tracker-migration.csv')) {
        Assert ((Get-FileText (Join-Path $temp $name)) -notmatch 'FAKE-MIG-KEY') "$name leaks the personal key"
    }
} finally { Remove-TestDirectory $temp }
"PASS Test-Migration: $script:AssertCount assertions"
