. "$PSScriptRoot\TestCommon.ps1"
. "$PSScriptRoot\..\Rules.ps1"
. "$PSScriptRoot\..\AutoLoad.ps1"
. "$PSScriptRoot\..\RuTracker.ps1"

# --- Pure helpers -------------------------------------------------------------------------------------
Assert (Test-AutoTitle 'Film WEB-DLRip Dub') 'good title'
Assert (!(Test-AutoTitle 'Film TS Dub')) 'TS accepted'
Assert (!(Test-AutoTitle 'Film WEB-DL Original Eng + Sub Rus')) 'subtitles accepted as voice'
$hA = New-TestHash 'a'; $hB = New-TestHash 'b'
$rows = @((New-TestRow $hA 'D:\old' -Size 100GB -Progress 400 -Downloaded 40GB), (New-TestRow $hB 'F:\old' -Size 100GB -Progress 0))
Assert ((Get-AutoBudget $rows @{} 340GB 20GB) -eq 260GB) 'unfinished D reservation'
Assert-Throws { Get-AutoBudget @(,(New-TestRow $hA '' -Size 1GB -Progress 0)) @{} 10GB 20GB } 'UnknownIncompletePath' 'unknown path did not block'
Assert ((Get-AutoBudget @(,(New-TestRow $hA -Fields 19 -Size 10GB -Progress 0)) @{ $hA = 'D:\x' } 100GB 20GB) -eq 70GB) '2.2.1 rows use resume.dat path'
Assert-Throws { Get-AutoBudget @(,@($hA, 1)) @{} 1GB 20GB } 'UnsupportedRow' 'short row accepted'

# --- Budget for drive D: (1.8: consistent completeness, exact arithmetic, fail-closed) -------------
function Budget($Rows, $Paths = @{}, $Free = 200GB, $Reserve = 20GB) { return (Get-AutoBudget @($Rows) $Paths $Free $Reserve) }
# PROGRESS=1000 but REMAINING>0 and DOWNLOADED<SIZE: data is still missing and must be reserved.
Assert ((Budget @(,(New-TestRow $hA 'D:\Фильмы\rt-1\Film' -Size 100GB -Progress 1000 -Downloaded 60GB -Remaining 40GB))) -eq 140GB) 'PROGRESS=1000 with REMAINING>0 not reserved'
Assert ((Budget @(,(New-TestRow $hA 'F:\Film' -Size 100GB -Progress 1000 -Downloaded 60GB -Remaining 40GB))) -eq 180GB) 'F: download used the D: reserve'
# Normal uTorrent 2.2.1 seeds: added from existing data (DOWNLOADED=0) or long seeded; never reserved, path not needed.
Assert ((Budget @(,(New-TestRow $hA 'D:\Keeper\Film' -Size 100GB -Progress 1000 -Downloaded 0 -Remaining 0))) -eq 180GB) 'complete torrent with DOWNLOADED=0 reserved'
Assert ((Budget @(,(New-TestRow $hA -Fields 19 -Size 100GB -Progress 1000 -Downloaded 0 -Remaining 0))) -eq 180GB) 'complete torrent without a known path blocked'
Assert ((Budget @(,(New-TestRow $hA 'D:\Keeper\Film' -Size 10GB -Progress 1000 -Downloaded 5TB -Remaining 0))) -eq 180GB) 'long-seeded complete torrent reserved'
# REMAINING=0 while PROGRESS shows half missing and DOWNLOADED>=SIZE: the progress share is reserved.
Assert ((Budget @(,(New-TestRow $hA 'D:\x' -Size 100GB -Progress 500 -Downloaded 200GB -Remaining 0))) -eq 130GB) 'contradictory REMAINING=0 not reserved'
# REMAINING slightly above SIZE (piece boundaries): the larger value is reserved, not rejected.
Assert ((Budget @(,(New-TestRow $hA 'D:\x' -Size 10GB -Progress 0 -Downloaded 0 -Remaining (10GB + 4MB)))) -eq (170GB - 4MB)) 'REMAINING above SIZE'
# Several downloads on D: add up; F:, E: and complete torrents do not.
$many = @(
    (New-TestRow (New-TestHash '1') 'D:\a' -Size 20GB -Progress 500 -Downloaded 10GB),
    (New-TestRow (New-TestHash '2') 'D:\b' -Size 30GB -Progress 500 -Downloaded 15GB),
    (New-TestRow (New-TestHash '3') 'd:\c' -Size 10GB -Progress 500 -Downloaded 5GB),
    (New-TestRow (New-TestHash '4') 'F:\d' -Size 500GB -Progress 0),
    (New-TestRow (New-TestHash '5') 'E:\e' -Size 500GB -Progress 0),
    (New-TestRow (New-TestHash '6') 'D:\f' -Size 900GB -Progress 1000))
Assert ((Budget $many) -eq 150GB) 'several incomplete torrents on D:'
# No free space, exact bytes and rounding.
Assert ((Budget @(,(New-TestRow $hA 'D:\x' -Size 10GB -Progress 0)) -Free 15GB) -eq 0) 'free space below the reserve'
Assert ((Budget @() -Free 0) -eq 0) 'empty drive'
Assert ((Budget @() -Free (20GB + 58)) -eq 58) 'exact bytes above the reserve'
Assert ((Budget @(,(New-TestRow $hA 'D:\x' -Size 1001 -Progress 999 -Downloaded 1001 -Remaining 0))) -eq (180GB - 2)) 'progress share must round up'
$big = 9007199254740993L
Assert ([decimal](Budget @() -Free $big) -eq ([decimal]$big - [decimal]20GB)) 'free space beyond 2^53 lost precision'
# Fail-closed: the D: budget cannot be confirmed.
$broken = @(
    @{ i = 18; v = $null }, @{ i = 18; v = 'x' }, @{ i = 18; v = -1 }, @{ i = 18; v = [double]::NaN }, @{ i = 18; v = 1.5 },
    @{ i = 18; v = [long][math]::Pow(2, 60) }, @{ i = 3; v = 0 }, @{ i = 3; v = [double]::PositiveInfinity }, @{ i = 5; v = $null },
    @{ i = 4; v = 1001 }, @{ i = 4; v = $null }, @{ i = 4; v = '1000' })
foreach ($c in $broken) {
    $row = New-TestRow $hA 'D:\x' -Size 10GB -Progress 500 -Downloaded 5GB; $row[$c.i] = $c.v
    Assert-Throws { Budget @(,$row) } 'UnknownRemainingSize' "field $($c.i)='$($c.v)' did not stop the budget"
}
$row = New-TestRow $hA 'F:\x' -Size 10GB -Progress 500 -Downloaded 5GB; $row[18] = $null
Assert ((Budget @(,$row)) -eq 180GB) 'damaged F: torrent blocked the D: budget'
foreach ($p in @('\\?\D:\Фильмы\x', '\\server\share\x', 'D:', 'Фильмы\x')) {
    Assert-Throws { Budget @(,(New-TestRow $hA -Fields 19 -Size 10GB -Progress 0)) @{ $hA = $p } } 'UnknownIncompletePath' "path '$p' accepted"
}
Assert-Throws { Budget @() -Free ([double]::NaN) } 'FreeSpaceUnknown' 'NaN free space'
Assert-Throws { Budget @() -Free -1 } 'FreeSpaceUnknown' 'negative free space'
Assert-Throws { Budget @() -Free $null } 'FreeSpaceUnknown' 'missing free space'
Assert-Throws { Budget @() -Reserve 10GB } 'InvalidAutoSettings' 'reserve below 20 GiB'
Assert-Throws { Budget @() -Reserve ([double]::NaN) } 'InvalidAutoSettings' 'NaN reserve'
foreach ($bad in @('E:\Archive', 'D:\Фильмы\..\Windows', 'D:\Фильмы\rt-1\sub', 'D:\Фильмы\rt-1x', 'D:\Other')) {
    Assert-Throws { Assert-AutoDirectory $bad } 'DestinationNotAllowed' "destination $bad allowed"
}
$single = @(,(New-TestRow $hA 'D:\x'))
Assert ((Find-AutoRow $single $hA).Count -eq 27) 'Find-AutoRow must return the whole row, not unroll it'
Assert ($null -eq (Find-AutoRow $single $hB)) 'Find-AutoRow miss'
Assert ((Get-AutoPresence $single @{} $hA) -eq 'Client') 'presence in WebUI list'
Assert ((Get-AutoPresence @() @{ $hB = 'E:\x' } $hB) -eq 'ResumeDat') 'presence in resume.dat'
Assert ((Get-AutoPresence $single @{} $hB) -eq '') 'absence'
Assert (Test-AutoListShrank $rows $single) 'lost row detected'
Assert (!(Test-AutoListShrank $single $rows)) 'added row is not shrinkage'
Assert ((ConvertTo-AutoTime '2026-10-24T00:00:00.0000000+00:00').ToUnixTimeSeconds() -eq 1792800000) 'ISO time parsed'
Assert ($null -eq (ConvertTo-AutoTime '')) 'empty time'
Assert ((Get-AutoErrorCode ([Exception]::new('AutoStateBackupPresent'))) -eq 'AutoStateBackupPresent') 'error allowlist'
Assert ((Get-AutoErrorCode ([Exception]::new('C:\secret\path'))) -eq 'SeeClientAndConfiguration') 'unknown errors hidden'
Assert ((Get-AutoErrorCode ([Exception]::new('ClientDataInvalid:Progress'))) -eq 'ClientDataInvalid:Progress') 'data error code kept'
Assert ((Get-AutoErrorCode ([Exception]::new('ClientDataInvalid:C:\x'))) -eq 'SeeClientAndConfiguration') 'only known data codes logged'

$temp = New-TestDirectory
try {
    # --- Atomic journal writes ---------------------------------------------------------------------
    $journal = Join-Path $temp 'journal.json'
    Save-AutoJson @{ n = 1 } $journal
    Save-AutoJson @{ n = 2 } $journal
    Assert ((Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json).n -eq 2) 'new journal saved'
    Assert ((Get-Content -LiteralPath "$journal.bak" -Raw | ConvertFrom-Json).n -eq 1) 'previous journal kept as .bak'
    Assert (!(Microsoft.PowerShell.Management\Test-Path -LiteralPath "$journal.tmp")) 'no temporary journal left'

    # --- Stubs: no uTorrent, WebUI, GitHub or drive D: is touched --------------------------------------
    $fixture = Join-Path $temp 'fixture.torrent'
    [IO.File]::WriteAllBytes($fixture, [Convert]::FromBase64String('ZDQ6aW5mb2Q2Omxlbmd0aGk1OGU0Om5hbWUyODpUb3JyZW50Q29udHJvbC1wYXRoLXRlc3QudHh0MTI6cGllY2UgbGVuZ3RoaTE2Mzg0ZTY6cGllY2VzMjA6fif7fCP8oPWUPlhooe+04CEImto3OnByaXZhdGVpMWVlZQ=='))
    $script:stateFile = Join-Path $temp 'auto-state.json'
    Save-AutoJson @{ enabled = $true; destination = 'D:\Фильмы'; reserveGiB = 20 } (Join-Path $temp 'autoload.json')
    $hash = '51CE70C03EC2FBF311F03C4B6570951C3CF28F3A'
    $script:meta = [pscustomobject]@{ schema = 1; hash = $hash; status = 'success'; total_bytes = 58; torrent_base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture)) }
    $other = New-TestRow (New-TestHash 'e') 'E:\Keeper\Other' -Name 'Pre-existing keeper torrent'
    $script:free = 100GB; $script:launches = @(); $script:clientRows = @(,$other); $script:freshRows = $null
    $script:resume = @{}; $script:fakeD = @{}; $script:webCalls = @(); $script:metaRequests = 0
    $script:failLaunch = $false; $script:afterLaunch = $null; $script:expectTopic = '900000002'
    function Assert-AutoLocalClient { return 'fake-utorrent.exe' }
    function Assert-AutoDirectory { param([string]$Path) if ($Path -notlike 'D:\Фильмы*') { throw 'DestinationNotAllowed' } }
    function Get-AutoFreeBytes { return $script:free }
    function Get-AutoRemoteJson { param($Uri) $script:metaRequests++; return $script:meta }
    function Read-LocalPaths { return $script:resume }
    function Fetch-List { $list = $script:clientRows; if ($null -ne $script:freshRows) { $list = $script:freshRows }; return (ConvertTo-WebUIList $list) }
    # Any WebUI action (stop, remove, setprops...) would go through Invoke-WebRequest.
    function Invoke-WebRequest { $script:webCalls += ($args -join ' '); throw 'No network in tests' }
    function Test-Path {
        param([Parameter(Position = 0)][string]$Path, [string]$LiteralPath, [object]$PathType)
        $target = $LiteralPath; if (!$target) { $target = $Path }
        # Only the autoload destination is faked; CI checkouts may themselves live on D:.
        if ($target -like 'D:\Фильмы*') { return $script:fakeD.ContainsKey($target) }
        return (Microsoft.PowerShell.Management\Test-Path -LiteralPath $target)
    }
    function New-Item {
        param([Parameter(Position = 0)][string]$Path, [string]$ItemType, [switch]$Force)
        if ($Path -like 'D:\Фильмы*') { $script:fakeD[$Path] = $true; return }
        Microsoft.PowerShell.Management\New-Item -Path $Path -ItemType $ItemType -Force:$Force
    }
    function Start-Process {
        param($FilePath, $ArgumentList, $WindowStyle, $ErrorAction)
        $saved = Get-Content -LiteralPath $script:stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert (@($saved.items | Where-Object status -eq 'Submitted').Count -eq 1) 'not saved before launch'
        Assert ($ArgumentList -like ('/DIRECTORY "D:\Фильмы\rt-' + $script:expectTopic + '" *')) "wrong CLI path: $ArgumentList"
        if ($script:failLaunch) { throw 'Simulated launch failure' }
        # Only a personal .torrent may ever reach uTorrent.
        $file = [regex]::Match([string]$ArgumentList, '"([^"]+\.torrent)"$').Groups[1].Value
        $sent = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($file)))
        Assert ($sent -match 'ann\?kk=' -and $sent -notmatch 'ann\?magnet') "public or non-personal torrent submitted: $file"
        $script:submittedFiles += $file
        $script:launches += $ArgumentList
        if ($script:afterLaunch) { & $script:afterLaunch }
    }
    # Personal .torrent stub: the fixture's info (same infohash) with a personal announce and a FAKE key.
    $script:personalKey = 'FAKE-PERSONAL-KEY-7f3a9c'
    $personalAnnounce = 'http://bt2.rutracker.cx/ann?kk=' + $script:personalKey
    $fixtureBytes = [IO.File]::ReadAllBytes($fixture)
    $script:personalBytes = [byte[]](@([byte]100) + [Text.Encoding]::ASCII.GetBytes('8:announce' + $personalAnnounce.Length + ':' + $personalAnnounce) + $fixtureBytes[1..($fixtureBytes.Length - 1)])
    $script:personalMode = 'ok'; $script:personalCalls = 0; $script:submittedFiles = @()
    function Get-PersonalTorrent {
        param($Directory, $Topic, $Hash)
        $script:personalCalls++
        if ($script:personalMode -ne 'ok') { throw $script:personalMode }
        $path = Join-Path $temp ('personal-' + $Hash + '.torrent')
        [IO.File]::WriteAllBytes($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path), $script:personalBytes)
        $checked = Test-PersonalTorrent $path $Hash
        return [pscustomobject]@{ path = $path; host = $checked.host; tiers = $checked.tiers; size = $checked.size }
    }
    function Reset-AutoState($Items = @()) {
        Save-AutoJson @{ version = 1; enabledAt = '2026-10-24T00:00:00Z'; knownTopics = @('900000001'); items = @($Items) } $script:stateFile
        $script:fakeD = @{}; $script:freshRows = $null; $script:clientRows = @(,$other); $script:resume = @{}
    }
    function Read-AutoState { return (Get-Content -LiteralPath $script:stateFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
    function Get-AutoItem($Hash = $hash) { return @((Read-AutoState).items | Where-Object hash -eq $Hash)[0] }
    function Run-Auto($Entries) { return (Invoke-AutoLoad @($Entries) $script:clientRows $script:resume @{ url = 'http://127.0.0.1:9090' } $null $temp) }
    function New-Submitted([string]$HoursAgo) {
        [pscustomobject]@{ topic = '900000002'; hash = $hash; title = 'New WEB-DLRip Dub'; status = 'Submitted'; bytes = 58; path = 'D:\Фильмы\rt-900000002'
            reason = ''; submittedAt = [DateTimeOffset]::UtcNow.AddHours(-[double]$HoursAgo).ToString('o'); lastAttempt = '' }
    }
    $baseline = [pscustomobject]@{ topic = '900000001'; hash = $hash; title = 'Old WEB-DLRip Dub' }
    $new = [pscustomobject]@{ topic = '900000002'; hash = $hash; title = 'New WEB-DLRip Dub' }
    $ours = 'D:\Фильмы\rt-900000002\TorrentControl-path-test.txt'

    # --- Baseline, space, single submission, confirmation -----------------------------------------------
    Reset-AutoState
    $null = Run-Auto $baseline
    Assert ($script:launches.Count -eq 0) 'baseline downloaded'
    $script:free = 20GB
    $null = Run-Auto $new
    Assert ((Get-AutoItem).status -eq 'NoSpace') 'low space not deferred'
    $script:free = 100GB
    $null = Run-Auto $new
    Assert ($script:launches.Count -eq 1 -and $script:fakeD.ContainsKey('D:\Фильмы\rt-900000002')) 'missing first submission'
    $null = Run-Auto $new
    Assert ($script:launches.Count -eq 1 -and (Get-AutoItem).status -eq 'Submitted') 'repeated pending submission'
    $script:clientRows = @($other, (New-TestRow $hash $ours -Size 58))
    $null = Run-Auto $new
    Assert ((Get-AutoItem).status -eq 'Confirmed') 'path not confirmed'
    $script:clientRows = @(,$other)
    $null = Run-Auto $new
    Assert ($script:launches.Count -eq 1) 'removed confirmed torrent readded'

    # 2.2.1: path arrives via resume.dat for a 19-field row.
    Reset-AutoState @(New-Submitted 0)
    $script:clientRows = @($other, (New-TestRow $hash -Fields 19 -Size 58))
    $script:resume = @{ $hash = $ours }
    $null = Run-Auto $new
    Assert ((Get-AutoItem).status -eq 'Confirmed') 'resume.dat path not confirmed'

    # --- Unexpected path: never stop a torrent we cannot prove is ours -------------------------------
    Reset-AutoState @(New-Submitted 0)
    $script:clientRows = @($other, (New-TestRow $hash 'E:\wrong' -Size 58 -Progress 0))
    $null = Run-Auto $new
    $item = Get-AutoItem
    Assert ($item.status -eq 'NeedsAttention' -and $item.reason -eq 'UnexpectedClientPath') 'wrong destination not flagged'
    Assert ($script:webCalls.Count -eq 0) 'a torrent with unproven ownership was touched through WebUI'
    $next = [pscustomobject]@{ topic = '900000003'; hash = 'C0FFEE0000000000000000000000000000000003'; title = 'Next WEB-DL Dub' }
    $before = $script:launches.Count
    $null = Run-Auto @($new, $next)
    Assert ($script:launches.Count -eq $before -and (Get-AutoItem 'C0FFEE0000000000000000000000000000000003').status -eq 'WaitingMetadata') 'attention must block further additions'

    # Race: the user adds the same hash manually while our launch is in flight; uTorrent keeps the manual copy.
    Reset-AutoState
    $script:afterLaunch = { $script:clientRows = @($other, (New-TestRow $hash 'E:\Manual\Film' -Size 58 -Progress 100)) }
    $null = Run-Auto $new
    $script:afterLaunch = $null
    $null = Run-Auto $new
    Assert ((Get-AutoItem).status -eq 'NeedsAttention' -and $script:webCalls.Count -eq 0) 'manual torrent must not be stopped'

    # --- Existing torrents are never submitted ----------------------------------------------------
    Reset-AutoState
    $script:clientRows = @($other, (New-TestRow $hash 'E:\Archive\Film' -Size 58))
    $before = $script:launches.Count
    $null = Run-Auto $new
    Assert ($script:launches.Count -eq $before -and (Get-AutoItem).status -eq 'Existing') 'existing hash on E launched'
    # WebUI list missed a pre-existing torrent, resume.dat still knows it.
    Reset-AutoState
    $script:resume = @{ $hash = 'D:\Хранитель\Film' }
    $requests = $script:metaRequests
    $null = Run-Auto $new
    $item = Get-AutoItem
    Assert ($item.status -eq 'Existing' -and $item.reason -eq 'FoundInResumeDat' -and $script:metaRequests -eq $requests) 'resume.dat torrent submitted'
    # Manual addition between the first list and the refresh before launch.
    Reset-AutoState
    $script:freshRows = @($other, (New-TestRow $hash 'E:\Manual\Film' -Size 58))
    $null = Run-Auto $new
    Assert ($script:launches.Count -eq $before -and (Get-AutoItem).status -eq 'Existing') 'race before launch not detected'
    # Refresh returns an empty or shrunken list: absence cannot be trusted.
    foreach ($glitch in @(@(), @(,(New-TestRow (New-TestHash 'f') 'D:\Other')))) {
        Reset-AutoState
        $script:freshRows = $glitch
        $null = Run-Auto $new
        $item = Get-AutoItem
        Assert ($script:launches.Count -eq $before -and $item.status -eq 'WaitingMetadata' -and $item.reason -eq 'ClientListUnstable') 'unstable list used for submission'
    }
    # Initial list empty: nothing is examined.
    Reset-AutoState
    $script:clientRows = @()
    $requests = $script:metaRequests
    $message = Run-Auto $new
    Assert ($script:launches.Count -eq $before -and $script:metaRequests -eq $requests -and $message -match 'пустой список') 'empty client list used'

    # --- Corrupted numeric values from WebUI: nothing is examined or submitted -------------------------
    # Reference: a valid incomplete D: torrent reserves 85 GiB of 100 GiB free (minus 20 GiB reserve).
    $busy = New-TestRow (New-TestHash 'd') 'D:\Хранитель\Busy' -Size 100GB -Progress 150 -Downloaded 15GB
    Reset-AutoState
    $script:clientRows = @($other, $busy)
    $null = Run-Auto $new
    Assert ((Get-AutoItem).status -eq 'NoSpace' -and $script:launches.Count -eq $before) 'reserve for incomplete torrents'
    $corruptions = @(
        @{ i = 4; v = '1000'; code = 'Progress' }, @{ i = 18; v = $null; code = 'Remaining' }, @{ i = 5; v = 'x'; code = 'Downloaded' },
        @{ i = 3; v = -1; code = 'Size' }, @{ i = 0; v = 'not-a-hash'; code = 'Hash' }, @{ i = 12; v = 1.5; code = 'PeersConnected' },
        @{ i = 8; v = $null; code = 'UploadSpeed' }, @{ i = 1; v = '201'; code = 'Status' })
    foreach ($c in $corruptions) {
        $bad = [object[]]$busy.Clone(); $bad[$c.i] = $c.v
        $requests = $script:metaRequests
        # In the first list: autoload stops before confirmation, metadata or submission.
        Reset-AutoState
        $script:clientRows = (ConvertTo-WebUIList @($other, $bad)).torrents
        Assert-Throws { Run-Auto $new } ('ClientDataInvalid:' + $c.code) "field $($c.i) in the first list not rejected"
        Assert ($script:launches.Count -eq $before -and $script:metaRequests -eq $requests -and (Get-AutoItem).status -eq 'WaitingMetadata') "field $($c.i) in the first list led to a submission attempt"
        # In the list refreshed right before launch.
        Reset-AutoState
        $script:freshRows = (ConvertTo-WebUIList @($other, $bad)).torrents
        Assert-Throws { Run-Auto $new } ('ClientDataInvalid:' + $c.code) "field $($c.i) in the refreshed list not rejected"
        $item = Get-AutoItem
        Assert ($script:launches.Count -eq $before -and $item.status -eq 'WaitingMetadata' -and $item.reason -eq 'ClientDataInvalid') "field $($c.i) in the refreshed list led to a submission"
    }
    Reset-AutoState
    $script:clientRows = @($other, $other)
    Assert-Throws { Run-Auto $new } 'ClientDataInvalid:DuplicateHash' 'duplicate rows accepted'
    Assert ($script:launches.Count -eq $before) 'duplicate rows led to a submission'

    # --- Space check on the list refreshed right before launch -------------------------------------------
    $script:free = 100GB
    Reset-AutoState
    $script:freshRows = @($other, (New-TestRow (New-TestHash 'd') 'D:\Хранитель\Busy' -Size 100GB -Progress 1000 -Downloaded 15GB -Remaining 85GB))
    $null = Run-Auto $new
    Assert ((Get-AutoItem).status -eq 'NoSpace' -and $script:launches.Count -eq $before) 'PROGRESS=1000 with REMAINING>0 ignored before launch'
    Reset-AutoState
    $script:freshRows = @($other, (New-TestRow (New-TestHash 'd') 'D:\Manual\Big' -Size 90GB -Progress 0))
    $null = Run-Auto $new
    Assert ((Get-AutoItem).status -eq 'NoSpace' -and $script:launches.Count -eq $before) 'download started before launch ignored'
    Reset-AutoState
    $script:free = 19GB
    $null = Run-Auto $new
    Assert ((Get-AutoItem).status -eq 'NoSpace' -and $script:launches.Count -eq $before) 'free space below the reserve ignored'
    $script:free = 100GB

    # --- Recovery after failures and restarts ----------------------------------------------------
    # Crash after "Submitted" was saved but before uTorrent got the command: never resent.
    Reset-AutoState @(New-Submitted 0.5)
    $script:fakeD['D:\Фильмы\rt-900000002'] = $true
    foreach ($poll in 1..3) { $null = Run-Auto $new }
    Assert ($script:launches.Count -eq $before -and (Get-AutoItem).status -eq 'Submitted') 'interrupted submission resent'
    # After 2 hours without the hash the record asks for attention, still without resending.
    Reset-AutoState @(New-Submitted 3)
    $null = Run-Auto $new
    $item = Get-AutoItem
    Assert ($item.status -eq 'NeedsAttention' -and $item.reason -eq 'NotSeenInClient' -and $script:launches.Count -eq $before) 'stale submission'
    # ...but not when the client list itself is empty.
    Reset-AutoState @(New-Submitted 3)
    $script:clientRows = @()
    $null = Run-Auto $new
    Assert ((Get-AutoItem).status -eq 'Submitted') 'empty list treated as missing torrent'
    # Present, path never confirmed for 24 hours.
    Reset-AutoState @(New-Submitted 25)
    $script:clientRows = @($other, (New-TestRow $hash -Fields 19 -Size 58))
    $null = Run-Auto $new
    Assert ((Get-AutoItem).reason -eq 'PathNotConfirmed') 'unconfirmed path never flagged'
    # Crash after the folder was created but before the journal was saved.
    Reset-AutoState
    $script:fakeD['D:\Фильмы\rt-900000002'] = $true
    $null = Run-Auto $new
    $item = Get-AutoItem
    Assert ($item.status -eq 'Rejected' -and $item.reason -eq 'DestinationAlreadyExists' -and $script:launches.Count -eq $before) 'existing folder reused'
    # Launch errors retain an attention record and cannot silently retry.
    Reset-AutoState
    $script:failLaunch = $true
    try { $null = Run-Auto $new } catch {}
    $script:failLaunch = $false
    Assert ((Get-AutoItem).status -eq 'NeedsAttention' -and (Get-AutoItem).reason -eq 'LaunchFailed') 'launch failure not retained'
    $null = Run-Auto $new
    Assert ($script:launches.Count -eq $before) 'failed launch retried'

    # --- Review unblocks the queue; reviewed hashes are never resent ----------------------------
    $state = Read-AutoState
    Assert ((Set-AutoReviewed $state) -eq 1) 'review count'
    Save-AutoJson $state $script:stateFile
    $retopic = [pscustomobject]@{ topic = '900000004'; hash = $hash; title = 'Same release, new topic WEB-DL Dub' }
    $script:expectTopic = '900000003'
    $script:meta = [pscustomobject]@{ schema = 1; hash = 'C0FFEE0000000000000000000000000000000003'; status = 'success'; total_bytes = 58; torrent_base64 = '' }
    $null = Run-Auto @($retopic, $next)
    Assert ((Get-AutoItem).status -eq 'Reviewed' -and @((Read-AutoState).items | Where-Object hash -eq $hash).Count -eq 1) 'reviewed hash queued again'
    Assert ((Get-AutoItem 'C0FFEE0000000000000000000000000000000003').status -eq 'Rejected' -and $script:launches.Count -eq $before) 'review must resume the queue (next item examined and its invalid metadata rejected)'

    # --- Journal missing ------------------------------------------------------------------------
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $script:stateFile
    Assert-Throws { Run-Auto $new } 'AutoStateBackupPresent' 'missing journal with backup accepted'
    Assert (!(Microsoft.PowerShell.Management\Test-Path -LiteralPath $script:stateFile)) 'journal recreated over a backup'
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath "$($script:stateFile).bak"
    Assert-Throws { Run-Auto $new } 'AutoBaselineMissing' 'missing baseline accepted'

    # --- Settings ---------------------------------------------------------------------------------
    Save-AutoJson @{ enabled = $false; destination = 'D:\Фильмы'; reserveGiB = 20 } (Join-Path $temp 'autoload.json')
    Assert ((Run-Auto $new) -eq 'Автозагрузка выключена.') 'disabled autoload ran'
    Save-AutoJson @{ enabled = $true; destination = 'C:\Фильмы'; reserveGiB = 20 } (Join-Path $temp 'autoload.json')
    Assert-Throws { Run-Auto $new } 'InvalidAutoSettings' 'foreign destination accepted'
    Save-AutoJson @{ enabled = $true; destination = 'D:\Фильмы'; reserveGiB = 5 } (Join-Path $temp 'autoload.json')
    Assert-Throws { Run-Auto $new } 'InvalidAutoSettings' 'reserve under 20 GiB accepted'

    # --- Feed recovery after missed updates: each topic queued once, nothing duplicated --------------
    Save-AutoJson @{ enabled = $true; destination = 'D:\Фильмы'; reserveGiB = 20 } (Join-Path $temp 'autoload.json')
    $script:meta = [pscustomobject]@{ schema = 1; hash = ''; status = 'unavailable' }
    Reset-AutoState
    function New-FeedItem($Topic, $Hash, $Title = 'Film WEB-DL Dub') { [pscustomobject]@{ topic = [string]$Topic; hash = $Hash; title = $Title } }
    $window1 = @((New-FeedItem 900000101 ('1' * 40)), (New-FeedItem 900000102 ('2' * 40)), (New-FeedItem 900000103 ('3' * 40)))
    $null = Run-Auto $window1
    Assert (@((Read-AutoState).items).Count -eq 3) 'first window not queued'
    # Several polls while the feed is stale (queue only), then the snapshot after an 11-hour gap.
    foreach ($poll in 1..3) { $null = Run-Auto @() }
    Assert (@((Read-AutoState).items).Count -eq 3) 'queue-only polls changed the queue'
    $window2 = @((New-FeedItem 900000104 ('4' * 40)), (New-FeedItem 900000105 ('5' * 40)), (New-FeedItem 900000101 ('9' * 40)),
        (New-FeedItem 900000102 ('2' * 40)), (New-FeedItem 900000103 ('3' * 40)), (New-FeedItem 900000106 ('2' * 40) 'Repost WEB-DL Dub'))
    $null = Run-Auto $window2
    $queued = @((Read-AutoState).items)
    Assert ($queued.Count -eq 5) "recovered window: expected 5 queued topics, got $($queued.Count)"
    Assert (@($queued | Where-Object topic -eq '900000101')[0].hash -eq ('1' * 40)) 'hash change of a processed topic queued a new download'
    Assert (@($queued | Where-Object hash -eq ('2' * 40)).Count -eq 1) 'same release under a new topic queued twice'
    $null = Run-Auto $window2
    $null = Run-Auto $window1
    Assert (@((Read-AutoState).items).Count -eq 5 -and $script:launches.Count -eq 2) 'repeated or older window duplicated topics or tasks'

    # --- Space frees up: exactly one launch, no duplicate task afterwards -----------------------
    $script:expectTopic = '900000002'
    $script:meta = [pscustomobject]@{ schema = 1; hash = $hash; status = 'success'; total_bytes = 58; torrent_base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture)) }
    Reset-AutoState
    $busyRow = New-TestRow (New-TestHash 'd') 'D:\Хранитель\Busy' -Size 100GB -Progress 100 -Downloaded 10GB
    $script:clientRows = @($other, $busyRow)
    $null = Run-Auto $new
    Assert ((Get-AutoItem).status -eq 'NoSpace' -and $script:launches.Count -eq 2) 'busy drive accepted'
    $script:clientRows = @($other, (New-TestRow (New-TestHash 'd') 'D:\Хранитель\Busy' -Size 100GB -Progress 1000 -Downloaded 100GB -Remaining 0))
    $null = Run-Auto $new
    Assert ($script:launches.Count -eq 3 -and (Get-AutoItem).status -eq 'Submitted') 'freed space did not resume the queue'
    foreach ($poll in 1..2) { $null = Run-Auto $new }
    Assert ($script:launches.Count -eq 3) 'duplicate torrent task after launch'
    $script:clientRows = @($other, (New-TestRow $hash $ours -Size 58 -Progress 0))
    $null = Run-Auto $new
    $null = Run-Auto $new
    Assert ($script:launches.Count -eq 3 -and (Get-AutoItem).status -eq 'Confirmed') 'confirmed torrent submitted again'

    Assert ($script:webCalls.Count -eq 0) "WebUI was called directly: $($script:webCalls -join '; ')"
    Assert ($script:launches.Count -eq 3) "exactly three launches expected in the whole run, got $($script:launches.Count)"

    # --- P0: only the personal RuTracker .torrent is added ------------------------------------------------
    Assert ($script:submittedFiles.Count -eq 3) 'every launch went through the personal .torrent'
    Assert ((Get-AutoItem).tracker -eq 'bt2.rutracker.cx' -and (Get-AutoItem).trackerKind -eq 'Personal') 'tracker server not recorded'
    foreach ($name in @('auto-state.json', 'auto-downloads.html')) {
        Assert ((Get-FileText (Join-Path $temp $name)) -notmatch [regex]::Escape($script:personalKey)) "$name leaks the personal key"
    }
    Assert ((Get-FileText (Join-Path $temp 'auto-downloads.html')) -match 'bt2\.rutracker\.cx') 'tracker server not shown in the journal'
    # Without a working personal .torrent nothing is added: the public version is never used instead.
    $before = $script:launches.Count
    foreach ($code in @('RuTrackerNotConfigured', 'RuTrackerCredentialUnreadable', 'RuTrackerProxyInvalid', 'RuTrackerProxyUnavailable', 'RuTrackerTlsFailed', 'RuTrackerBlocked', 'RuTrackerRedirectRefused', 'RuTrackerCaptchaRequired', 'RuTrackerLoginFailed', 'RuTrackerAuthExpired', 'RuTrackerUnavailable', 'PersonalAnnounceMissing', 'PersonalTrackersUnexpected', 'PersonalTorrentInvalid', 'LocalAppDataMissing')) {
        Reset-AutoState
        $script:personalMode = $code
        $message = Run-Auto $new
        $item = Get-AutoItem
        Assert ($item.status -eq 'WaitingAuth' -and $item.reason -eq $code -and $script:launches.Count -eq $before) "$code added something: $($item.status)"
        Assert (!$script:fakeD.ContainsKey('D:\Фильмы\rt-900000002') -and $message -match 'публичная версия не добавляется') "$code created the folder or hid the reason"
    }
    Assert ((Get-FileText (Join-Path $temp 'auto-downloads.html')) -match 'Ожидает авторизацию RuTracker') 'waiting state not shown'
    # Login fixed: the waiting record is added once, never twice.
    $script:personalMode = 'ok'
    $null = Run-Auto $new
    Assert ($script:launches.Count -eq $before + 1 -and (Get-AutoItem).status -eq 'Submitted') 'waiting record not added after login'
    $null = Run-Auto $new
    Assert ($script:launches.Count -eq $before + 1) 'personal torrent added twice'
    # The topic was re-released with another hash: the old version is not added.
    Reset-AutoState
    $script:personalMode = 'PersonalHashMismatch'
    $null = Run-Auto $new
    Assert ((Get-AutoItem).status -eq 'Rejected' -and (Get-AutoItem).reason -eq 'TopicHashChanged' -and $script:launches.Count -eq $before + 1) 'mismatching hash added'
    # A torrent already in uTorrent is neither fetched from RuTracker nor added.
    Reset-AutoState
    $script:personalMode = 'ok'; $calls = $script:personalCalls
    $script:clientRows = @($other, (New-TestRow $hash 'E:\Archive\Film' -Size 58))
    $null = Run-Auto $new
    Assert ((Get-AutoItem).status -eq 'Existing' -and $script:personalCalls -eq $calls -and $script:launches.Count -eq $before + 1) 'existing hash fetched or added'
    Assert ($script:webCalls.Count -eq 0) 'WebUI called directly'
} finally { Remove-TestDirectory $temp }
"PASS Test-AutoLoad: $script:AssertCount assertions"
