. "$PSScriptRoot\TestCommon.ps1"
. "$PSScriptRoot\..\AutoLoad.ps1"
. "$PSScriptRoot\..\RuTracker.ps1"
if (!('TorrentMetadata' -as [type])) { Add-Type -Path "$PSScriptRoot\..\TorrentMetadata.cs" }
# Offline only: every RuTracker request goes to a stub, all keys, passwords and cookies are fake.
$temp = New-TestDirectory
$savedLocal = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = Join-Path $temp 'LocalAppData'
    $src = Join-Path $temp 'src'
    $null = Microsoft.PowerShell.Management\New-Item -Path $src -ItemType Directory
    function Read-Bytes([string]$Path) { return ,[IO.File]::ReadAllBytes($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)) }
    function Test-Path2([string]$Path) { return [IO.File]::Exists($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)) }

    # --- Announce analysis: confirmed RuTracker servers, any key parameter name, any key length --------------
    $servers = @('bt.t-ru.org', 'bt2.rutracker.cx', 'bt3.t-ru.org', 'bt4.rutracker.org')
    $keys = @(@('kk', 'FAKEkk01'), @('pk', ('0123456789abcdef' * 2)), @('uk', 'FAKE-uk-key-of-another-length-123456'), @('kk', 'x1y2'))
    foreach ($server in $servers) {
        foreach ($key in $keys) {
            $url = 'http://' + $server + '/ann?' + $key[0] + '=' + $key[1]
            $info = Get-AnnounceInfo $url
            Assert ($info.valid -and $info.personal -and !$info.public -and $info.host -eq $server) "personal announce not recognised: $server $($key[0])"
        }
    }
    Assert ((Get-AnnounceInfo 'https://bt2.rutracker.cx/ann?pk=abc&uk=def').personal) 'two key parameters'
    Assert ((Get-AnnounceInfo 'http://BT2.RuTracker.CX/ann?kk=FAKEcase').host -eq 'bt2.rutracker.cx') 'host case matters'
    Assert ((Get-AnnounceInfo 'http://bt12.t-ru.org/ann?somekey=FAKE-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789').personal) 'server number or key name/length fixed'
    # Not RuTracker: a query parameter on any other host never makes a tracker personal (and never public).
    $foreign = @(
        'https://example.com/announce?id=123', 'http://example.com/ann?kk=FAKEforeign', 'http://tracker.example.org/ann?pk=FAKEforeign',
        'http://bt2.rutracker.cx.example.com/ann?kk=FAKEforeign', 'http://evil-rutracker.cx/ann?kk=FAKEforeign', 'http://bt2.evilrutracker.cx/ann?kk=FAKEforeign',
        'http://rutracker.cx/ann?kk=FAKEforeign', 'http://www.rutracker.org/ann?kk=FAKEforeign', 'http://bt2.forum.rutracker.org/ann?kk=FAKEforeign',
        'http://bt2.rutracker.cc/ann?kk=FAKEforeign', 'http://bt2.rutracker.net/ann?kk=FAKEforeign', 'http://bt2.t-ru.org.example/ann?kk=FAKEforeign',
        'http://tracker2.t-ru.org/ann?kk=FAKEforeign', 'http://btx.t-ru.org/ann?kk=FAKEforeign', 'http://bt123.t-ru.org/ann?kk=FAKEforeign',
        'http://bt2.rutracker.cx/announce?kk=FAKEforeign', 'http://bt2.rutracker.cx/ann/?kk=FAKEforeign', 'http://bt2.rutracker.cx/x/ann?kk=FAKEforeign',
        'http://bt2.rutracker.cx/./ann?kk=FAKEforeign', 'http://bt2.rutracker.cx:8080/ann?kk=FAKEforeign', 'http://bt2.rutracker.cx:80/ann?kk=FAKEforeign',
        'http://bt2.rutracker.cx/ann?kk=FAKEforeign&magnet', 'http://bt2.rutracker.cx/ann?magnet&kk=FAKEforeign', 'http://bt2.rutracker.cx/ann?kk==x',
        'http://bt2.rutracker.cx/ann?=FAKEforeign', 'http://bt2.rutracker.cx/ann?1k=FAKEforeign', 'http://bt2.rutracker.cx/ann?kk=FAKE"x',
        'http://bt2.rutracker.cx\ann?kk=FAKEforeign', 'http://example.com/ann?magnet', 'http://retracker.local/announce?kk=FAKEforeign')
    foreach ($url in $foreign) {
        $a = Get-AnnounceInfo $url
        Assert (!$a.personal -and !$a.public -and !$a.neutral) "foreign or malformed tracker classified as RuTracker/neutral: $url"
    }
    Assert ((Get-AnnounceInfo 'http://retracker.local/announce').neutral -and !(Get-AnnounceInfo 'http://retracker.local/announce').personal) 'retracker not neutral'
    Assert (!(Get-AnnounceInfo 'http://tracker.example/announce').neutral) 'any keyless tracker treated as neutral'
    # Tracker sets: one foreign or public entry makes a list unexpected.
    function Set-Kind($Urls) { $s = Get-TrackerSetInfo $Urls; return ('{0}/{1}/{2}/{3}' -f $s.personal, $s.public, $s.neutral, $s.other) }
    Assert ((Set-Kind @('http://bt2.rutracker.cx/ann?kk=FAKEset1', 'http://retracker.local/announce')) -eq '1/0/1/0') 'personal + retracker'
    Assert ((Set-Kind @('http://bt2.rutracker.cx/ann?kk=FAKEset1', 'https://example.com/announce?id=123')) -eq '1/0/0/1') 'personal + foreign'
    Assert ((Set-Kind @('http://bt2.rutracker.cx/ann?kk=FAKEset1', 'http://bt.t-ru.org/ann?magnet')) -eq '1/1/0/0') 'personal + public'
    Assert ((Set-Kind @('https://example.com/announce?id=FAKEforeignkey')) -eq '0/0/0/1') 'foreign only'
    Assert ((Protect-SecretText 'x FAKEforeignkey y') -eq 'x *** y') 'key of a foreign tracker not registered as secret'
    $public = Get-AnnounceInfo 'http://bt.t-ru.org/ann?magnet'
    Assert ($public.valid -and $public.public -and !$public.personal) 'public magnet announce not recognised'
    Assert ((Get-AnnounceInfo 'http://bt4.t-ru.org/ann?magnet').public) 'public announce on another server'
    Assert (!(Get-AnnounceInfo 'http://bt2.rutracker.cx/ann').personal) 'announce without a key treated as personal'
    Assert (!(Get-AnnounceInfo 'http://retracker.local/announce').personal) 'retracker treated as personal'
    Assert (!(Get-AnnounceInfo 'http://bt2.rutracker.cx/ann?kk=').personal) 'empty key treated as personal'
    foreach ($bad in @('udp://bt2.rutracker.cx:80/ann?kk=abcd', 'http://user:pw@bt2.rutracker.cx/ann?kk=abcd', 'http://bt2.rutracker.cx/ann?kk=abcd#x', 'ann?kk=abcd', '')) {
        Assert (!(Get-AnnounceInfo $bad).valid) "unsafe announce accepted: $bad"
    }

    # --- Personal .torrent check: same infohash, valid file, personal announce, file left unchanged -----------
    $info = New-TestInfo 'Film.mkv' 58 'p0'
    $n = 0
    foreach ($server in $servers) {
        foreach ($key in $keys) {
            $n++
            $url = 'http://' + $server + '/ann?' + $key[0] + '=' + $key[1]
            $path = Join-Path $src "personal-$n.torrent"
            if ($n % 2) { $hash = New-TestTorrentFile $path $info $url }
            else { $hash = New-TestTorrentFile $path $info $url @(@($url), @('http://retracker.local/announce')) }
            $before = Get-TestSha1 (Read-Bytes $path)
            $checked = Test-PersonalTorrent $path $hash
            Assert ($checked.host -eq $server -and $checked.size -eq 58) "personal torrent not accepted: $server $($key[0])"
            Assert ([string]@($checked.tiers)[0][0] -eq $url) 'announce of the site file not kept exactly'
            if (!($n % 2)) { Assert (@($checked.tiers).Count -eq 2 -and [string]@($checked.tiers)[1][0] -eq 'http://retracker.local/announce') 'announce-list tiers not kept' }
            Assert ((Get-TestSha1 (Read-Bytes $path)) -eq $before) 'personal torrent file was rewritten'
            Assert ((Protect-SecretText ("tracker " + $url)) -notmatch [regex]::Escape($key[1])) 'key of a checked torrent not masked'
        }
    }
    $hash = New-TestTorrentFile (Join-Path $src 'public.torrent') $info 'http://bt.t-ru.org/ann?magnet' @(,@('http://bt.t-ru.org/ann?magnet'))
    Assert-Throws { Test-PersonalTorrent (Join-Path $src 'public.torrent') $hash } 'PersonalAnnounceMissing' 'public torrent accepted as personal'
    $null = New-TestTorrentFile (Join-Path $src 'noannounce.torrent') $info
    Assert-Throws { Test-PersonalTorrent (Join-Path $src 'noannounce.torrent') $hash } 'PersonalAnnounceMissing' 'torrent without announce accepted'
    $null = New-TestTorrentFile (Join-Path $src 'retracker.torrent') $info 'http://retracker.local/announce'
    Assert-Throws { Test-PersonalTorrent (Join-Path $src 'retracker.torrent') $hash } 'PersonalAnnounceMissing' 'retracker-only torrent accepted'
    # Mixed lists: the personal announce plus a public RuTracker or any foreign tracker is not used (fail-closed).
    $mixedCases = @(
        @('public', @(@('http://bt3.t-ru.org/ann?pk=FAKEmixed'), @('http://bt.t-ru.org/ann?magnet')), 'PersonalTrackersUnexpected'),
        @('foreign-keyed', @(@('http://bt3.t-ru.org/ann?pk=FAKEmixed'), @('https://example.com/announce?id=123')), 'PersonalTrackersUnexpected'),
        @('foreign-same-tier', @(,@('http://bt3.t-ru.org/ann?pk=FAKEmixed', 'http://tracker.example/announce')), 'PersonalTrackersUnexpected'),
        @('unknown-domain', @(@('http://bt3.t-ru.org/ann?pk=FAKEmixed'), @('http://bt2.rutracker.cc/ann?kk=FAKEmixed')), 'PersonalTrackersUnexpected'),
        @('foreign-only', @(,@('https://example.com/announce?id=FAKEforeign123')), 'PersonalAnnounceMissing'),
        @('lookalike-only', @(,@('http://bt2.rutracker.cx.example.com/ann?kk=FAKElookalike')), 'PersonalAnnounceMissing'),
        @('unconfirmed-domain-only', @(,@('http://bt2.rutracker.cc/ann?kk=FAKEunconfirmed')), 'PersonalAnnounceMissing'))
    foreach ($case in $mixedCases) {
        $path = Join-Path $src ('mixed-' + $case[0] + '.torrent')
        $null = New-TestTorrentFile $path $info ([string]@($case[1])[0][0]) $case[1]
        Assert-Throws { Test-PersonalTorrent $path $hash } $case[2] "mixed tracker list accepted: $($case[0])"
    }
    $null = New-TestTorrentFile (Join-Path $src 'foreign-announce.torrent') $info 'https://example.com/announce?id=123'
    Assert-Throws { Test-PersonalTorrent (Join-Path $src 'foreign-announce.torrent') $hash } 'PersonalAnnounceMissing' 'foreign announce with a query accepted as personal'
    $other = New-TestTorrentFile (Join-Path $src 'other.torrent') (New-TestInfo 'Film.mkv' 58 'other') 'http://bt2.rutracker.cx/ann?kk=FAKEother'
    Assert-Throws { Test-PersonalTorrent (Join-Path $src 'other.torrent') $hash } 'PersonalHashMismatch' 'infohash mismatch accepted'
    $good = Read-Bytes (Join-Path $src 'personal-1.torrent')
    [IO.File]::WriteAllBytes($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $src 'cut.torrent')), [byte[]]$good[0..($good.Length - 10)])
    Assert-Throws { Test-PersonalTorrent (Join-Path $src 'cut.torrent') $hash } 'PersonalTorrentInvalid' 'damaged torrent accepted'
    [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $src 'page.torrent')), '<html><body>Вход</body></html>')
    Assert-Throws { Test-PersonalTorrent (Join-Path $src 'page.torrent') $hash } 'PersonalTorrentInvalid' 'HTML page accepted as torrent'
    $null = New-TestTorrentFile (Join-Path $src 'space.torrent') $info 'http://bt2.rutracker.cx/ann?kk=FAKE key'
    Assert-Throws { Test-PersonalTorrent (Join-Path $src 'space.torrent') $hash } 'PersonalTorrentInvalid' 'announce with a space accepted'

    # --- Masking: nothing secret reaches logs, reports or error messages ------------------------------------
    Add-RuTrackerSecret 'FAKE-REGISTERED-SECRET'
    $masked = Protect-SecretText 'GET http://bt2.rutracker.cx/ann?kk=FAKEurlkey99&info_hash=%12 bb_session=0-FAKE-cookie; login_password=FAKEpass passkey: FAKEpk cap_code_ab12=QWE FAKE-REGISTERED-SECRET'
    foreach ($secret in @('FAKEurlkey99', '0-FAKE-cookie', 'FAKEpass', 'FAKEpk', 'QWE', 'FAKE-REGISTERED-SECRET')) { Assert ($masked -notmatch [regex]::Escape($secret)) "not masked: $secret" }
    Assert ($masked -match 'bt2\.rutracker\.cx/ann\?kk=\*\*\*') 'host should stay readable'
    Assert ((Protect-SecretText 'Обычный текст без секретов.') -eq 'Обычный текст без секретов.') 'plain text changed'
    Assert ((Get-RuTrackerCode ([Exception]'RuTrackerCaptchaRequired')) -eq 'RuTrackerCaptchaRequired') 'known code lost'
    Assert ((Get-RuTrackerCode ([Exception]'The remote server returned http://x/?kk=FAKE')) -eq 'RuTrackerUnavailable') 'raw exception text passed on'

    # --- Form encoding and CAPTCHA parsing (verified RuTracker form fields) ---------------------------------
    Assert ((ConvertTo-FormValue 'Вход') -eq '%C2%F5%EE%E4') 'login button not windows-1251'
    Assert ((ConvertTo-FormValue 'a b+c&d=Ё') -eq 'a%20b%2Bc%26d%3D%A8') 'form value not escaped'
    $captchaHtml = '<form><img src="https://static.rutracker.cc/captcha/0/12/FAKEcaptcha.jpg?1" alt="pic"><input type="hidden" name="cap_sid" value="FAKEsid123"><input type="text" name="cap_code_FAKE0f1e" value=""></form>'
    $captcha = Get-RuTrackerCaptcha $captchaHtml
    Assert ($captcha.image -eq 'https://static.rutracker.cc/captcha/0/12/FAKEcaptcha.jpg?1' -and $captcha.sid -eq 'FAKEsid123' -and $captcha.field -eq 'cap_code_FAKE0f1e') 'captcha not parsed'
    Assert ((Get-RuTrackerCaptcha '<input value="FAKEsid2" name="cap_sid"><img src="https://static.rutracker.cc/captcha/a.png"><input name="cap_code_x1">').sid -eq 'FAKEsid2') 'captcha with value before name'
    Assert ($null -eq (Get-RuTrackerCaptcha '<img src="https://evil.example/captcha/a.png"><input name="cap_sid" value="s"><input name="cap_code_x">')) 'captcha from another host accepted'
    Assert ($null -eq (Get-RuTrackerCaptcha '<html>Неверный пароль</html>')) 'captcha found where none'

    # --- Cookie session text ------------------------------------------------------------------------------
    $session = New-RuTrackerSession 'bb_session=0-FAKE-sess-1; bb_guid=FAKEguid; bad pair=1; x=y z'
    Assert (Test-RuTrackerLoggedIn $session) 'stored session not restored'
    $text = Get-SessionCookieText $session
    Assert ($text -match 'bb_session=0-FAKE-sess-1' -and $text -match 'bb_guid=FAKEguid' -and $text -notmatch 'bad') 'session text wrong'
    Assert (!(Test-RuTrackerLoggedIn (New-RuTrackerSession ''))) 'empty session logged in'

    # --- Stored secrets: DPAPI round trip (Windows only), damaged files fail closed ------------------------
    $store = Join-Path $temp 'store'
    $null = Microsoft.PowerShell.Management\New-Item -Path $store -ItemType Directory
    $credential = New-Object Management.Automation.PSCredential('fake-user', (ConvertTo-SecureString 'FAKE-PASSWORD-55' -AsPlainText -Force))
    if ($script:OnWindows) {
        Save-RuTrackerSessionText $store 'bb_session=0-FAKE-SESSION-77'
        Assert ((Get-FileText (Join-Path $store 'rutracker-session.xml')) -notmatch 'FAKE-SESSION') 'session cookie stored in clear text'
        Assert ((Read-RuTrackerSessionText $store) -eq 'bb_session=0-FAKE-SESSION-77') 'session round trip'
        $credential | Export-Clixml -LiteralPath (Join-Path $store 'rutracker-credential.xml')
        Assert ((Get-FileText (Join-Path $store 'rutracker-credential.xml')) -notmatch 'FAKE-PASSWORD') 'password stored in clear text'
        Assert ((Read-RuTrackerCredential $store).GetNetworkCredential().Password -eq 'FAKE-PASSWORD-55') 'credential round trip'
    }
    [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $store 'rutracker-session.xml')), 'not xml')
    Assert ((Read-RuTrackerSessionText $store) -eq '') 'damaged session file used'
    Assert ($null -eq (Read-RuTrackerCredential (Join-Path $temp 'nothing'))) 'missing credential file'
    [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $store 'rutracker-credential.xml')), 'not xml')
    Assert-Throws { Read-RuTrackerCredential $store } 'RuTrackerCredentialUnreadable' 'unreadable credential (other Windows user) not reported'
    [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $store 'rutracker-state.json')), '{broken')
    Assert ((Read-RuTrackerState $store).blocked -eq 'RuTrackerLoginFailed') 'damaged state did not block automatic login'
    Assert ((Read-RuTrackerState (Join-Path $temp 'nothing')).blocked -eq '') 'missing state blocked'
    # Optional proxy for RuTracker requests only.
    Assert ((Read-RuTrackerProxy (Join-Path $temp 'nothing')) -eq '') 'proxy without a file'
    $proxyFile = Join-Path $store 'rutracker-proxy.txt'
    foreach ($case in @(@("http://127.0.0.1:8118`r`n", 'http://127.0.0.1:8118'), @('http://proxy.lan:3128/', 'http://proxy.lan:3128'),
        @('https://ps1.blockme.site:443', 'https://ps1.blockme.site:443'), @('https://PS1.Blockme.Site', 'https://ps1.blockme.site:443'), @('http://proxy.lan', 'http://proxy.lan:80'))) {
        [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($proxyFile), $case[0])
        Assert ((Read-RuTrackerProxy $store) -eq $case[1]) "proxy not read: $($case[0])"
    }
    foreach ($bad in @('http://user:FAKEpw@127.0.0.1:8118', 'https://user:FAKEpw@ps1.blockme.site:443', 'socks5://127.0.0.1:1080', 'ftp://127.0.0.1:21', 'http://127.0.0.1:8118/path', 'https://ps1.blockme.site/pac', '127.0.0.1:8118', '')) {
        [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($proxyFile), $bad)
        Assert-Throws { Read-RuTrackerProxy $store } 'RuTrackerProxyInvalid' "bad proxy accepted: $bad"
    }

    # --- HTTP stub: records every request; the response comes from $script:route ---------------------------
    $script:http = New-Object Collections.ArrayList
    $script:allUrls = New-Object Collections.ArrayList
    $script:route = @{}
    # Route check (RuTrackerRoute.cs, tested live in Test-RuTrackerNet.ps1) and Windows proxy are stubbed here.
    function New-Route([bool]$Ok, [string]$Code, [string]$Stage) { return [pscustomobject]@{ Ok = $Ok; Code = $Code; Stage = $Stage; ProxyStatus = 0; HttpStatus = 200; TlsErrors = ''; Addresses = 1; ElapsedMs = 1 } }
    $routeOk = New-Route $true 'Ok' 'Http'
    $script:routeResult = $routeOk; $script:routeCalls = 0; $script:routeProxy = $null; $script:systemProxy = ''
    function Invoke-RuTrackerRouteCheck([string]$Proxy, [string]$HostName = 'rutracker.org', [int]$TimeoutMs = 0) { $script:routeCalls++; $script:routeProxy = $Proxy; return $script:routeResult }
    function Get-SystemRuTrackerProxy { return $script:systemProxy }
    function Invoke-RuTrackerHttp([string]$Method, [string]$Url, $Session, [string]$Form = '') {
        [void]$script:http.Add([pscustomobject]@{ method = $Method; url = $Url; form = $Form })
        [void]$script:allUrls.Add($Url)
        $script:proxySeen = $script:RuTrackerProxy
        $kind = 'dl'; if ($Url -like '*login.php') { $kind = 'login' }
        $answer = $script:route[$kind]
        if ($answer -is [Collections.IList] -and $answer -isnot [byte[]] -and $answer.Count) { $next = $answer[0]; $script:route[$kind] = @($answer | Select-Object -Skip 1); $answer = $next }
        switch ($answer) {
            'ok' { $Session.Cookies.Add([Uri]'https://rutracker.org/forum/', (New-Object Net.Cookie('bb_session', '0-FAKE-NEW-SESSION-9'))); return [pscustomobject]@{ status = 200; contentType = 'text/html'; bytes = (Get-RuTrackerEncoding).GetBytes('<html>Главная</html>') } }
            'captcha' { return [pscustomobject]@{ status = 200; contentType = 'text/html; charset=windows-1251'; bytes = (Get-RuTrackerEncoding).GetBytes($captchaHtml) } }
            'wrong' { return [pscustomobject]@{ status = 200; contentType = 'text/html'; bytes = (Get-RuTrackerEncoding).GetBytes('<html>Неверный пароль</html>') } }
            'loginpage' { return [pscustomobject]@{ status = 200; contentType = 'text/html; charset=windows-1251'; bytes = (Get-RuTrackerEncoding).GetBytes('<html><form action="login.php">Вход</form></html>') } }
            'offline' { return [pscustomobject]@{ status = 0; contentType = ''; bytes = [byte[]]@() } }
            '404' { return [pscustomobject]@{ status = 404; contentType = 'text/html'; bytes = [byte[]]@() } }
            'ok-redirect' { $Session.Cookies.Add([Uri]'https://rutracker.org/forum/', (New-Object Net.Cookie('bb_session', '0-FAKE-NEW-SESSION-9'))); return [pscustomobject]@{ status = 302; contentType = 'text/html'; bytes = [byte[]]@(); location = 'https://evil.example/collect' } }
            'redirect-same' { return [pscustomobject]@{ status = 302; contentType = 'text/html'; bytes = [byte[]]@(); location = '/forum/dl.php?t=6612345&r=1' } }
            'redirect-loop' { return [pscustomobject]@{ status = 302; contentType = 'text/html'; bytes = [byte[]]@(); location = 'dl.php?t=6612345&r=1' } }
            'redirect-evil' { return [pscustomobject]@{ status = 302; contentType = 'text/html'; bytes = [byte[]]@(); location = 'https://evil.example/forum/dl.php?t=1' } }
            'redirect-http' { return [pscustomobject]@{ status = 302; contentType = 'text/html'; bytes = [byte[]]@(); location = 'http://rutracker.org/forum/dl.php?t=1' } }
            'redirect-port' { return [pscustomobject]@{ status = 307; contentType = 'text/html'; bytes = [byte[]]@(); location = 'https://rutracker.org:8443/forum/dl.php?t=1' } }
            '429' { return [pscustomobject]@{ status = 429; contentType = 'text/html'; bytes = [byte[]]@() } }
            default { return [pscustomobject]@{ status = 200; contentType = 'application/x-bittorrent'; bytes = (Read-Bytes $answer) } }
        }
    }
    # Callers wrap the result in @(): Windows PowerShell 5.1 unrolls a one-element array and a lone object has no Count.
    function Get-Calls([string]$Kind) { return @($script:http | Where-Object { ($Kind -eq 'login') -eq ($_.url -like '*login.php') }) }

    # Login: verified form, cp1251, no automatic retry.
    $script:route.login = 'ok'
    $login = Invoke-RuTrackerLogin $credential
    $call = $script:http[0]
    Assert ($login.ok -and $call.method -eq 'Post' -and $call.url -eq 'https://rutracker.org/forum/login.php') 'login request wrong'
    Assert ($call.form -eq 'login_username=fake-user&login_password=FAKE-PASSWORD-55&login=%C2%F5%EE%E4') "login form wrong: $(Protect-SecretText $call.form)"
    Assert ((Protect-SecretText 'FAKE-PASSWORD-55 0-FAKE-NEW-SESSION-9') -eq '*** ***') 'password or new cookie not registered as secret'
    $script:route.login = 'captcha'
    $login = Invoke-RuTrackerLogin $credential
    Assert (!$login.ok -and $login.captcha.field -eq 'cap_code_FAKE0f1e') 'captcha not reported'
    $script:route.login = 'ok'
    $null = Invoke-RuTrackerLogin $credential $login.captcha 'Ab3d' $login.session
    Assert ($script:http[-1].form -match '&cap_sid=FAKEsid123&cap_code_FAKE0f1e=Ab3d$') 'captcha answer not sent'
    # The redirect of the login answer is never followed (the session cookie comes with the 302 itself).
    $script:http.Clear(); $script:route.login = 'ok-redirect'
    $login = Invoke-RuTrackerLogin $credential
    Assert ($login.ok -and $script:http.Count -eq 1 -and @($script:allUrls | Where-Object { $_ -match 'evil' }).Count -eq 0) 'login redirect followed'
    $script:route.login = 'wrong'
    $login = Invoke-RuTrackerLogin $credential
    Assert (!$login.ok -and $null -eq $login.captcha) 'wrong password not reported'
    $script:route.login = 'offline'
    Assert-Throws { Invoke-RuTrackerLogin $credential } 'RuTrackerUnavailable' 'network failure not reported'

    # --- Get-PersonalTorrent: stored credential and session replaced by in-memory stubs ---------------------
    $script:storedCredential = $null; $script:storedSession = ''
    function Read-RuTrackerCredential([string]$Directory) { return $script:storedCredential }
    function Read-RuTrackerSessionText([string]$Directory) { return $script:storedSession }
    function Save-RuTrackerSessionText([string]$Directory, [string]$CookieText) { $script:storedSession = $CookieText }
    $dir = Join-Path $temp 'app'
    $null = Microsoft.PowerShell.Management\New-Item -Path $dir -ItemType Directory
    function Clear-Personal {
        # A stored personal file is used before the network (imports): network cases start without one.
        $folder = Join-Path $env:LOCALAPPDATA 'TorrentControl\personal'
        if ($env:LOCALAPPDATA -and (Microsoft.PowerShell.Management\Test-Path -LiteralPath $folder)) {
            Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $folder -File | Microsoft.PowerShell.Management\Remove-Item -Force
        }
    }
    function Reset-Login([long]$LoginAt = 0) {
        Save-AutoJson ([ordered]@{ version = 1; blocked = ''; checkedAt = ''; loginAt = $LoginAt; host = '' }) (Join-Path $dir 'rutracker-state.json')
        $script:http.Clear()
        Clear-Personal
    }
    $topic = '6612345'
    $site = Join-Path $src 'personal-6.torrent'   # bt2.rutracker.cx with a pk key and two tiers
    $siteHash = Get-TestSha1 (ConvertTo-TestBencode $info)
    Reset-Login
    Assert-Throws { Get-PersonalTorrent $dir $topic $siteHash } 'RuTrackerNotConfigured' 'missing login not reported'
    Assert ($script:http.Count -eq 0) 'request without a configured login'
    $script:storedCredential = $credential
    # Valid stored session: one download, nothing else.
    $script:storedSession = 'bb_session=0-FAKE-STORED-1'
    $script:route.dl = $site
    $result = Get-PersonalTorrent $dir $topic $siteHash
    $expectedPath = Join-Path (Join-Path $env:LOCALAPPDATA 'TorrentControl\personal') ($siteHash + '.torrent')
    Assert ($script:http.Count -eq 1 -and $script:http[0].method -eq 'Get' -and $script:http[0].url -eq 'https://rutracker.org/forum/dl.php?t=6612345') 'download request wrong'
    Assert ($result.path -eq $expectedPath -and $result.host -eq 'bt2.rutracker.cx' -and $result.size -eq 58) 'personal torrent result wrong'
    Assert ((Get-TestSha1 (Read-Bytes $result.path)) -eq (Get-TestSha1 (Read-Bytes $site))) 'site file not saved byte for byte'
    Assert ($result.path -like "$($env:LOCALAPPDATA)*" -and $result.path -notlike "$dir*") 'personal torrent not in the Windows profile folder'
    Assert ($script:proxySeen -eq '') 'proxy used without rutracker-proxy.txt'
    # A stored verified file is used without any request (the same file was just downloaded and stored).
    $script:http.Clear(); $calls = $script:routeCalls
    $again = Get-PersonalTorrent $dir $topic $siteHash
    Assert ($again.source -eq 'Local' -and $again.path -eq $expectedPath -and $script:http.Count -eq 0 -and $script:routeCalls -eq $calls) 'stored personal file not used offline'
    Clear-Personal
    [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $dir 'rutracker-proxy.txt')), 'http://127.0.0.1:8118')
    $null = Get-PersonalTorrent $dir $topic $siteHash
    Assert ($script:proxySeen -eq 'http://127.0.0.1:8118') 'configured proxy not used'
    Clear-Personal
    [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $dir 'rutracker-proxy.txt')), 'socks5://127.0.0.1:1080')
    $script:http.Clear()
    Assert-Throws { Get-PersonalTorrent $dir $topic $siteHash } 'RuTrackerProxyInvalid' 'invalid proxy file ignored'
    Assert ($script:http.Count -eq 0) 'request despite an invalid proxy file'
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath (Join-Path $dir 'rutracker-proxy.txt')
    $script:route.dl = $site
    # Expired session: one login, new session stored, then the download.
    Reset-Login
    $script:route.dl = @('loginpage', $site); $script:route.login = 'ok'
    $result = Get-PersonalTorrent $dir $topic $siteHash
    Assert ($script:http.Count -eq 3 -and @(Get-Calls 'login').Count -eq 1 -and $result.host -eq 'bt2.rutracker.cx') 'expired session not renewed once'
    Assert ($script:storedSession -match 'bb_session=0-FAKE-NEW-SESSION-9') 'renewed session not stored'
    Assert ((Read-RuTrackerState $dir).loginAt -gt 0 -and !(Read-RuTrackerState $dir).blocked) 'login time not recorded'
    # A second expiry right after a login: no new login (throttle), the record waits.
    $script:route.dl = 'loginpage'; $script:http.Clear(); Clear-Personal
    Assert-Throws { Get-PersonalTorrent $dir $topic $siteHash } 'RuTrackerAuthExpired' 'expired session after a fresh login'
    Assert (@(Get-Calls 'login').Count -eq 0) 'automatic login repeated within the pause'
    # Fresh login still gives an HTML page instead of a file: reported, no loop.
    Reset-Login
    $script:route.dl = 'loginpage'; $script:route.login = 'ok'
    Assert-Throws { Get-PersonalTorrent $dir $topic $siteHash } 'RuTrackerAuthExpired' 'HTML after login accepted'
    Assert (@(Get-Calls 'login').Count -eq 1) 'more than one automatic login'
    # CAPTCHA or refusal: one attempt, then blocked without any request until Setup-RuTracker.ps1.
    foreach ($case in @(@('captcha', 'RuTrackerCaptchaRequired'), @('wrong', 'RuTrackerLoginFailed'))) {
        Reset-Login
        $script:storedSession = ''
        $script:route.login = $case[0]
        Assert-Throws { Get-PersonalTorrent $dir $topic $siteHash } $case[1] "$($case[0]) not reported"
        Assert (@(Get-Calls 'login').Count -eq 1 -and @(Get-Calls 'dl').Count -eq 0) "$($case[0]): retried or downloaded"
        $script:http.Clear(); $script:route.login = 'ok'
        Assert-Throws { Get-PersonalTorrent $dir $topic $siteHash } $case[1] "$($case[0]) did not block"
        Assert ($script:http.Count -eq 0) "$($case[0]): requests while blocked"
    }
    $stateText = Get-FileText (Join-Path $dir 'rutracker-state.json')
    foreach ($secret in @('FAKE-PASSWORD-55', 'FAKE-STORED-1', 'FAKE-NEW-SESSION', 'fake-user', 'FAKEsid123')) { Assert ($stateText -notmatch [regex]::Escape($secret)) "state file holds a secret: $secret" }
    # Site problems and bad files: fixed codes, nothing returned.
    $script:storedSession = 'bb_session=0-FAKE-STORED-1'
    $cases = @(
        @('404', 'RuTrackerTopicUnavailable'), @('offline', 'RuTrackerUnavailable'),
        @((Join-Path $src 'other.torrent'), 'PersonalHashMismatch'), @((Join-Path $src 'public.torrent'), 'PersonalAnnounceMissing'),
        @((Join-Path $src 'cut.torrent'), 'PersonalTorrentInvalid'), @((Join-Path $src 'mixed-foreign-keyed.torrent'), 'PersonalTrackersUnexpected'),
        @((Join-Path $src 'foreign-announce.torrent'), 'PersonalAnnounceMissing'))
    foreach ($case in $cases) {
        Reset-Login
        $script:route.dl = $case[0]
        Assert-Throws { Get-PersonalTorrent $dir $topic $siteHash } $case[1] "download case $($case[1])"
        Assert (@(Get-Calls 'login').Count -eq 0) "$($case[1]) caused a login"
    }
    Reset-Login
    Assert-Throws { Get-PersonalTorrent $dir 'abc' $siteHash } 'RuTrackerTopicUnavailable' 'bad topic id requested'
    Assert ($script:http.Count -eq 0) 'request for a bad topic id'
    # --- The route is checked anonymously before any password or cookie leaves the computer ----------------
    $script:storedSession = 'bb_session=0-FAKE-STORED-1'; $script:route.dl = $site; $script:route.login = 'ok'
    $routeCases = @(
        @('ProxyUnreachable', 'ProxyConnect', 'RuTrackerProxyUnavailable'), @('ProxyAuthRequired', 'ProxyTunnel', 'RuTrackerProxyUnavailable'),
        @('ProxyRefused', 'ProxyTunnel', 'RuTrackerProxyUnavailable'), @('TlsCertificateInvalid', 'Tls', 'RuTrackerTlsFailed'),
        @('TlsFailed', 'Tls', 'RuTrackerTlsFailed'), @('HttpRateLimited', 'Http', 'RuTrackerBlocked'), @('HttpForbidden', 'Http', 'RuTrackerBlocked'),
        @('DnsFailed', 'Dns', 'RuTrackerUnavailable'), @('ConnectFailed', 'Connect', 'RuTrackerUnavailable'), @('Timeout', 'Connect', 'RuTrackerUnavailable'))
    foreach ($case in $routeCases) {
        Reset-Login; Reset-RuTrackerRoute
        $script:routeResult = New-Route $false $case[0] $case[1]
        Assert-Throws { Get-PersonalTorrent $dir $topic $siteHash } $case[2] "route $($case[0]) not reported"
        Assert ($script:http.Count -eq 0) "cookie sent although the route failed ($($case[0]))"
        Assert-Throws { Invoke-RuTrackerLogin $credential } $case[2] "login despite route $($case[0])"
        Assert ($script:http.Count -eq 0) "password sent although the route failed ($($case[0]))"
        Assert (!(Read-RuTrackerState $dir).blocked) "network problem $($case[0]) blocked automatic logins"
    }
    # Through the configured proxy, network failures are reported as a proxy problem.
    $proxyFile = Join-Path $dir 'rutracker-proxy.txt'
    [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($proxyFile), 'http://127.0.0.1:12334')
    foreach ($code in @('Timeout', 'DnsFailed', 'ConnectFailed')) {
        Reset-Login; Reset-RuTrackerRoute
        $script:routeResult = New-Route $false $code 'ProxyConnect'
        Assert-Throws { Get-PersonalTorrent $dir $topic $siteHash } 'RuTrackerProxyUnavailable' "proxy $code not reported as a proxy problem"
        Assert ($script:routeProxy -eq 'http://127.0.0.1:12334' -and $script:http.Count -eq 0) "route not checked through the proxy ($code)"
    }
    # A working route is checked once and reused for 10 minutes; a different proxy is checked again.
    $script:routeResult = $routeOk; Reset-RuTrackerRoute; $script:routeCalls = 0
    Reset-Login; $null = Get-PersonalTorrent $dir $topic $siteHash
    Reset-Login; $null = Get-PersonalTorrent $dir $topic $siteHash
    Assert ($script:routeCalls -eq 1 -and $script:proxySeen -eq 'http://127.0.0.1:12334') 'working route not reused or proxy not used'
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $proxyFile
    Reset-Login; $null = Get-PersonalTorrent $dir $topic $siteHash
    Assert ($script:routeCalls -eq 2 -and $script:routeProxy -eq '' -and $script:proxySeen -eq '') 'route not re-checked after the proxy changed'
    # Windows proxy setting is used only without rutracker-proxy.txt (read, never changed).
    $script:systemProxy = 'http://10.0.0.5:3128'
    Reset-Login; Reset-RuTrackerRoute; $null = Get-PersonalTorrent $dir $topic $siteHash
    Assert ($script:routeProxy -eq 'http://10.0.0.5:3128' -and $script:proxySeen -eq 'http://10.0.0.5:3128') 'Windows proxy not used'
    [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($proxyFile), 'http://127.0.0.1:12334')
    Reset-Login; Reset-RuTrackerRoute; $null = Get-PersonalTorrent $dir $topic $siteHash
    Assert ($script:routeProxy -eq 'http://127.0.0.1:12334') 'rutracker-proxy.txt does not take precedence'
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $proxyFile
    $script:systemProxy = ''; Reset-RuTrackerRoute

    # --- Redirects are followed only inside https://rutracker.org/forum/ ------------------------------------
    Reset-Login; $script:route.dl = @('redirect-same', $site)
    $result = Get-PersonalTorrent $dir $topic $siteHash
    Assert (@(Get-Calls 'dl').Count -eq 2 -and $script:http[1].url -eq 'https://rutracker.org/forum/dl.php?t=6612345&r=1' -and $result.host -eq 'bt2.rutracker.cx') 'same-site redirect not followed'
    foreach ($case in @('redirect-evil', 'redirect-http', 'redirect-port')) {
        Reset-Login; $script:route.dl = $case
        Assert-Throws { Get-PersonalTorrent $dir $topic $siteHash } 'RuTrackerRedirectRefused' "$case followed"
        Assert ($script:http.Count -eq 1) "$($case): a second request was made"
    }
    Reset-Login; $script:route.dl = 'redirect-loop'
    Assert-Throws { Get-PersonalTorrent $dir $topic $siteHash } 'RuTrackerRedirectRefused' 'redirect loop accepted'
    Assert ($script:http.Count -eq 4) 'redirect loop not bounded'
    Reset-Login; $script:route.dl = '429'
    Assert-Throws { Get-PersonalTorrent $dir $topic $siteHash } 'RuTrackerBlocked' 'HTTP 429 not reported'
    Assert (@(Get-Calls 'login').Count -eq 0) 'HTTP 429 caused a login'
    Assert ((Resolve-RuTrackerRedirect 'https://rutracker.org/forum/dl.php?t=1' 'dl.php?t=2') -eq 'https://rutracker.org/forum/dl.php?t=2') 'relative redirect'
    foreach ($bad in @('https://rutracker.org.evil.example/forum/x', 'https://evil.example/forum/', 'http://rutracker.org/forum/x', 'https://rutracker.org:8443/forum/x',
        'https://user:pw@rutracker.org/forum/x', 'https://rutracker.org/other/x', '', '//evil.example/forum/x', 'https://RUTRACKER.org.evil.example/forum/')) {
        Assert-Throws { Resolve-RuTrackerRedirect 'https://rutracker.org/forum/dl.php?t=1' $bad } 'RuTrackerRedirectRefused' "redirect accepted: $bad"
    }
    $script:route.dl = $site
    $env:LOCALAPPDATA = ''
    Assert-Throws { Get-PersonalTorrent $dir $topic $siteHash } 'LocalAppDataMissing' 'missing profile folder'
    $env:LOCALAPPDATA = Join-Path $temp 'LocalAppData'
    # Only rutracker.org/forum login.php and dl.php are ever requested.
    Assert ($script:allUrls.Count -gt 20 -and @($script:allUrls | Where-Object { $_ -notmatch '^https://rutracker\.org/forum/(login\.php|dl\.php\?t=\d+(&r=1)?)$' }).Count -eq 0) 'unexpected address requested'
} finally { $env:LOCALAPPDATA = $savedLocal; Remove-TestDirectory $temp }
"PASS Test-RuTracker: $script:AssertCount assertions"
