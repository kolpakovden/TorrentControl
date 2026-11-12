. "$PSScriptRoot\TestCommon.ps1"
. "$PSScriptRoot\..\Rules.ps1"
. "$PSScriptRoot\..\AutoLoad.ps1"

# --- Pure helpers -------------------------------------------------------------------------------------
Assert (Test-AutoTitle 'Film WEB-DLRip Dub') 'good title'
Assert (!(Test-AutoTitle 'Film TS Dub')) 'TS accepted'
Assert (!(Test-AutoTitle 'Film WEB-DL Original Eng + Sub Rus')) 'subtitles accepted as voice'
$hA = New-TestHash 'a'; $hB = New-TestHash 'b'
$rows = @((New-TestRow $hA 'D:\old' -Size 100GB -Progress 400 -Downloaded 40GB), (New-TestRow $hB 'F:\old' -Size 100GB -Progress 0))
Assert ((Get-AutoBudget $rows @{} 340GB 20GB) -eq 260GB) 'unfinished D reservation'
Assert-Throws { Get-AutoBudget @(,(New-TestRow $hA '' -Size 1GB -Progress 0)) @{} 10GB 0 } 'UnknownIncompletePath' 'unknown path did not block'
Assert ((Get-AutoBudget @(,(New-TestRow $hA -Fields 19 -Size 10GB -Progress 0)) @{ $hA = 'D:\x' } 100GB 20GB) -eq 70GB) '2.2.1 rows use resume.dat path'
Assert-Throws { Get-AutoBudget @(,@($hA, 1)) @{} 1GB 0 } 'UnsupportedRow' 'short row accepted'
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
        $script:launches += $ArgumentList
        if ($script:afterLaunch) { & $script:afterLaunch }
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

    Assert ($script:webCalls.Count -eq 0) "WebUI was called directly: $($script:webCalls -join '; ')"
    Assert ($script:launches.Count -eq 2) "exactly two launches expected in the whole run, got $($script:launches.Count)"
} finally { Remove-TestDirectory $temp }
"PASS Test-AutoLoad: $script:AssertCount assertions"
