. "$PSScriptRoot\TestCommon.ps1"
. "$PSScriptRoot\..\Rules.ps1"
. "$PSScriptRoot\..\AutoLoad.ps1"
. "$PSScriptRoot\..\RuTracker.ps1"
# The whole chain for a new film with the REAL Invoke-AutoLoad and Get-PersonalTorrent:
# feed entry -> public metadata (simulated GitHub cache) -> size and infohash -> personal .torrent from RuTracker
# (simulated at the HTTP layer) -> infohash and announce again -> exactly that file to uTorrent (fake) -> confirmation.
# Failures (network, damaged file, re-released topic, CAPTCHA, crash) must defer, never add a public version and
# never add anything twice. Fake keys only; no real network, uTorrent or drive D:.
$temp = New-TestDirectory
$savedLocal = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = Join-Path $temp 'LocalAppData'
    function Resolve-Local([string]$Path) { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    Save-AutoJson @{ enabled = $true; destination = 'D:\Фильмы'; reserveGiB = 20 } (Join-Path $temp 'autoload.json')
    $script:stateFile = Join-Path $temp 'auto-state.json'

    # --- Films: public metadata (as cached on GitHub) and the personal files RuTracker would serve -------------
    $films = @{}
    foreach ($n in 2..6) {
        $topic = '90000000' + $n
        $info = New-TestInfo ('Film ' + $n + '.mkv') (1000 + $n) ('chain' + $n)
        $public = Join-Path $temp ('public-' + $n + '.torrent')
        $hash = New-TestTorrentFile $public $info 'http://bt.t-ru.org/ann?magnet' @(,@('http://bt.t-ru.org/ann?magnet')) $topic
        $key = 'FAKE-CHAIN-KEY-' + $n
        $personal = Join-Path $temp ('personal-' + $n + '.torrent')
        $null = New-TestTorrentFile $personal $info ('http://bt2.rutracker.cx/ann?kk=' + $key) @(@('http://bt2.rutracker.cx/ann?kk=' + $key), @('http://retracker.local/announce')) $topic
        $films[$topic] = [pscustomobject]@{ topic = $topic; hash = $hash; title = 'Film ' + $n + ' WEB-DLRip Dub'; size = 1000 + $n; key = $key
            meta = [pscustomobject]@{ schema = 1; hash = $hash; status = 'success'; total_bytes = 1000 + $n; torrent_base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Local $public))) }
            personal = [IO.File]::ReadAllBytes((Resolve-Local $personal)) }
    }
    $rereleased = Join-Path $temp 'rereleased.torrent'
    $null = New-TestTorrentFile $rereleased (New-TestInfo 'Film 3 v2.mkv' 1003 'v2') 'http://bt2.rutracker.cx/ann?kk=FAKE-CHAIN-KEY-V2' $null '900000003'
    $rereleasedBytes = [IO.File]::ReadAllBytes((Resolve-Local $rereleased))

    # --- uTorrent, WebUI, GitHub and drive D: (fakes, as in Test-AutoLoad) ------------------------------------
    $other = New-TestRow (New-TestHash 'e') 'E:\Keeper\Other' -Name 'Pre-existing keeper torrent'
    $script:clientRows = @(,$other); $script:resume = @{}; $script:fakeD = @{}; $script:launches = New-Object Collections.ArrayList
    function Assert-AutoLocalClient { return 'fake-utorrent.exe' }
    function Assert-AutoDirectory { param([string]$Path) if ($Path -notlike 'D:\Фильмы*') { throw 'DestinationNotAllowed' } }
    function Get-AutoFreeBytes { return 100GB }
    function Get-AutoRemoteJson { param($Uri) $h = [regex]::Match([string]$Uri, '([0-9A-F]{40})\.json$').Groups[1].Value; return @($films.Values | Where-Object { $_.hash -eq $h })[0].meta }
    function Read-LocalPaths { return $script:resume }
    function Fetch-List { return (ConvertTo-WebUIList $script:clientRows) }
    function Invoke-WebRequest { throw 'No WebUI or GitHub request in this test' }
    function Test-Path {
        param([Parameter(Position = 0)][string]$Path, [string]$LiteralPath, [object]$PathType)
        $target = $LiteralPath; if (!$target) { $target = $Path }
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
        $match = [regex]::Match([string]$ArgumentList, '^/DIRECTORY "D:\\Фильмы\\rt-(\d+)" "([^"]+)"$')
        Assert $match.Success "unexpected uTorrent command line: $ArgumentList"
        $saved = Get-Content -LiteralPath $script:stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert (@($saved.items | Where-Object { $_.status -eq 'Submitted' -and $_.topic -eq $match.Groups[1].Value }).Count -eq 1) 'record not saved as Submitted before the launch'
        [void]$script:launches.Add([pscustomobject]@{ topic = $match.Groups[1].Value; file = $match.Groups[2].Value; bytes = [IO.File]::ReadAllBytes((Resolve-Local $match.Groups[2].Value)) })
    }

    # --- RuTracker, simulated at the HTTP layer (the real login, session and download logic runs) ---------------
    $script:routeOk = $true; $script:http = New-Object Collections.ArrayList; $script:answers = @{}
    $script:storedSession = ''; $script:credential = New-Object Management.Automation.PSCredential('fake-user', (ConvertTo-SecureString 'FAKE-CHAIN-PASSWORD' -AsPlainText -Force))
    function Invoke-RuTrackerRouteCheck([string]$Proxy, [string]$HostName = 'rutracker.org', [int]$TimeoutMs = 0) {
        if ($script:routeOk) { return [pscustomobject]@{ Ok = $true; Code = 'Ok'; Stage = 'Http'; ProxyStatus = 200; HttpStatus = 200; TlsErrors = ''; Addresses = 0; ElapsedMs = 1 } }
        return [pscustomobject]@{ Ok = $false; Code = 'DnsFailed'; Stage = 'Dns'; ProxyStatus = 0; HttpStatus = 0; TlsErrors = ''; Addresses = 0; ElapsedMs = 1 }
    }
    function Get-SystemRuTrackerProxy { return '' }
    function Read-RuTrackerCredential([string]$Directory) { return $script:credential }
    function Read-RuTrackerSessionText([string]$Directory) { return $script:storedSession }
    function Save-RuTrackerSessionText([string]$Directory, [string]$CookieText) { $script:storedSession = $CookieText }
    function Html([string]$Text) { return [pscustomobject]@{ status = 200; contentType = 'text/html; charset=windows-1251'; bytes = (Get-RuTrackerEncoding).GetBytes($Text); location = ''; error = '' } }
    function Invoke-RuTrackerHttp([string]$Method, [string]$Url, $Session, [string]$Form = '') {
        [void]$script:http.Add([pscustomobject]@{ method = $Method; url = $Url; form = $Form })
        $kind = 'dl'; if ($Url -like '*login.php') { $kind = 'login' }
        $queue = @($script:answers[$kind])
        $answer = 'offline'
        if ($queue.Count) { $answer = $queue[0]; $script:answers[$kind] = @($queue | Select-Object -Skip 1) }
        if ($answer -is [byte[]]) { return [pscustomobject]@{ status = 200; contentType = 'application/x-bittorrent'; bytes = $answer; location = ''; error = '' } }
        switch ([string]$answer) {
            'login-ok' { $Session.Cookies.Add([Uri]'https://rutracker.org/forum/', (New-Object Net.Cookie('bb_session', '0-FAKE-CHAIN-SESSION'))); return [pscustomobject]@{ status = 302; contentType = 'text/html'; bytes = [byte[]]@(); location = 'https://rutracker.org/forum/index.php'; error = '' } }
            'captcha' { return (Html '<form><img src="https://static.rutracker.cc/captcha/1/2/x.jpg"><input type="hidden" name="cap_sid" value="FAKEsid"><input name="cap_code_ab12"></form>') }
            'login-page' { return (Html '<html><form action="login.php">Вход</form></html>') }
            default { return [pscustomobject]@{ status = 0; contentType = ''; bytes = [byte[]]@(); location = ''; error = 'DnsFailed' } }
        }
    }
    function Calls([string]$Kind) { return @($script:http | Where-Object { ($Kind -eq 'login') -eq ($_.url -like '*login.php') }) }

    function Reset-Chain {
        Save-AutoJson @{ version = 1; enabledAt = '2026-10-24T00:00:00Z'; knownTopics = @('900000001'); items = @() } $script:stateFile
        Save-AutoJson ([ordered]@{ version = 1; blocked = ''; checkedAt = ''; loginAt = 0; host = '' }) (Join-Path $temp 'rutracker-state.json')
        $script:fakeD = @{}; $script:clientRows = @(,$other); $script:launches.Clear(); $script:http.Clear(); $script:answers = @{}
        $script:storedSession = ''; $script:routeOk = $true; Reset-RuTrackerRoute
        $folder = Join-Path $env:LOCALAPPDATA 'TorrentControl\personal'
        if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $folder) { Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $folder -File | Microsoft.PowerShell.Management\Remove-Item -Force }
    }
    function Poll($Film) { return (Invoke-AutoLoad @([pscustomobject]@{ topic = $Film.topic; hash = $Film.hash; title = $Film.title }) $script:clientRows $script:resume @{ url = 'http://127.0.0.1:9090' } $null $temp) }
    function Item($Film) { return @((Get-Content -LiteralPath $script:stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).items | Where-Object hash -eq $Film.hash)[0] }
    function Confirm-InClient($Film) { $script:clientRows = @($script:clientRows) + @(,(New-TestRow $Film.hash ('D:\Фильмы\rt-' + $Film.topic + '\Film.mkv') -Size $Film.size)) }

    # --- 1. Network down, then a damaged file, then success: added once, with the personal file -------------------
    $f = $films['900000002']
    Reset-Chain
    $script:routeOk = $false
    $message = Poll $f
    Assert ((Item $f).status -eq 'WaitingAuth' -and (Item $f).reason -eq 'RuTrackerUnavailable' -and $script:launches.Count -eq 0) 'network failure did not defer'
    Assert ($script:http.Count -eq 0 -and !$script:fakeD.ContainsKey('D:\Фильмы\rt-900000002') -and $message -match 'публичная версия не добавляется') 'request or folder although the route failed'
    $script:routeOk = $true; Reset-RuTrackerRoute
    $damaged = [byte[]]$f.personal[0..($f.personal.Length - 20)]
    $script:answers = @{ login = @('login-ok'); dl = @(,$damaged) }
    $null = Poll $f
    Assert ((Item $f).status -eq 'WaitingAuth' -and (Item $f).reason -eq 'PersonalTorrentInvalid' -and $script:launches.Count -eq 0) 'damaged personal file not deferred'
    Assert ((@(Calls 'login').Count -eq 1) -and $script:storedSession -match 'bb_session') 'login not performed once'
    $script:http.Clear()
    $script:answers = @{ dl = @(,$f.personal) }
    $null = Poll $f
    Assert ($script:launches.Count -eq 1 -and (Item $f).status -eq 'Submitted' -and (Item $f).tracker -eq 'bt2.rutracker.cx') 'personal file not submitted after recovery'
    Assert (@(Calls 'login').Count -eq 0 -and @(Calls 'dl').Count -eq 1 -and $script:http[0].url -eq 'https://rutracker.org/forum/dl.php?t=900000002') 'stored session not reused'
    $sent = $script:launches[0]
    Assert ((Get-TestSha1 $sent.bytes) -eq (Get-TestSha1 $f.personal) -and $sent.file -like '*TorrentControl*personal*') 'uTorrent did not get exactly the personal file from RuTracker'
    Assert ([Text.Encoding]::ASCII.GetString($sent.bytes) -notmatch 'ann\?magnet') 'public announce submitted'
    Confirm-InClient $f
    $null = Poll $f
    Assert ((Item $f).status -eq 'Confirmed') 'added film not confirmed'
    $script:http.Clear()
    foreach ($i in 1..3) { $null = Poll $f }
    Assert ($script:launches.Count -eq 1 -and $script:http.Count -eq 0) 'confirmed film fetched or added again'

    # --- 2. Topic re-released with another hash: the old version is never added ----------------------------------
    $f = $films['900000003']
    Reset-Chain
    $script:storedSession = 'bb_session=0-FAKE-CHAIN-SESSION'
    $script:answers = @{ dl = @(,$rereleasedBytes) }
    $null = Poll $f
    Assert ((Item $f).status -eq 'Rejected' -and (Item $f).reason -eq 'TopicHashChanged' -and $script:launches.Count -eq 0) 're-released topic not rejected'
    $script:http.Clear(); $null = Poll $f
    Assert ($script:http.Count -eq 0 -and $script:launches.Count -eq 0) 'rejected topic fetched again'

    # --- 3. CAPTCHA: one login attempt, then nothing until the person logs in again ----------------------------
    $f = $films['900000004']
    Reset-Chain
    $script:answers = @{ dl = @('login-page'); login = @('captcha') }
    $script:storedSession = 'bb_session=0-FAKE-EXPIRED'
    $null = Poll $f
    Assert ((Item $f).status -eq 'WaitingAuth' -and (Item $f).reason -eq 'RuTrackerCaptchaRequired' -and @(Calls 'login').Count -eq 1) 'CAPTCHA not reported'
    $script:http.Clear()
    foreach ($i in 1..3) { $null = Poll $f }
    Assert ($script:http.Count -eq 0 -and $script:launches.Count -eq 0) 'requests or additions while blocked by CAPTCHA'
    # The person runs 9-RuTracker-login.cmd (new session, block cleared): the film is added on the next poll.
    Save-RuTrackerState $temp '' -LoginAttempt
    $script:storedSession = 'bb_session=0-FAKE-CHAIN-SESSION'
    $script:answers = @{ dl = @(,$f.personal) }
    $null = Poll $f
    Assert ($script:launches.Count -eq 1 -and (Item $f).status -eq 'Submitted') 'not added after a new login'

    # --- 4. Crash after the personal file was stored: the next run uses it without the network, once ----------
    $f = $films['900000005']
    Reset-Chain
    $null = Save-PersonalTorrentBytes $f.personal $f.hash $f.topic
    Save-AutoJson @{ version = 1; enabledAt = '2026-10-24T00:00:00Z'; knownTopics = @('900000001', '900000005')
        items = @([pscustomobject]@{ topic = $f.topic; hash = $f.hash; title = $f.title; status = 'WaitingAuth'; bytes = 0; path = ''; reason = 'RuTrackerUnavailable'; submittedAt = ''; lastAttempt = '' }) } $script:stateFile
    $script:routeOk = $false
    $null = Poll $f
    Assert ($script:launches.Count -eq 1 -and $script:http.Count -eq 0 -and (Item $f).status -eq 'Submitted') 'stored personal file not used offline after a crash'
    $null = Poll $f
    Assert ($script:launches.Count -eq 1) 'added twice after recovery'

    # --- 5. Already in uTorrent (manual or earlier): neither fetched nor added; nothing changed ----------------
    $f = $films['900000006']
    Reset-Chain
    $script:clientRows = @($other, (New-TestRow $f.hash 'E:\Manual\Film 6' -Size $f.size))
    $null = Poll $f
    Assert ((Item $f).status -eq 'Existing' -and $script:http.Count -eq 0 -and $script:launches.Count -eq 0) 'existing torrent fetched or added'

    # --- No secret in any local journal or report ------------------------------------------------------------------
    foreach ($name in @('auto-state.json', 'auto-downloads.html', 'rutracker-state.json')) {
        $text = Get-FileText (Join-Path $temp $name)
        Assert ($text -notmatch 'FAKE-CHAIN-KEY|FAKE-CHAIN-PASSWORD|FAKE-CHAIN-SESSION|kk=') "$name contains a secret"
    }
} finally { $env:LOCALAPPDATA = $savedLocal; Remove-TestDirectory $temp }
"PASS Test-AutoChain: $script:AssertCount assertions"
