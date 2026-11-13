. "$PSScriptRoot\TestCommon.ps1"
. "$PSScriptRoot\..\AutoLoad.ps1"
. "$PSScriptRoot\..\Test-RuTrackerConnection.ps1"
if (!('RuTrackerRoute' -as [type])) { Add-Type -Path "$PSScriptRoot\..\RuTrackerRoute.cs" }
if (!('FakeProxy' -as [type])) { Add-Type -Path "$PSScriptRoot\FakeProxy.cs" }
# Network layer with real sockets, but only to fake proxies on 127.0.0.1 (tests\FakeProxy.cs) and to the reserved
# name rutracker.invalid: nothing reaches rutracker.org, Hiddify or any other real service. Fake secrets only.

function Get-NetworkSnapshot {
    # Process and computer network settings that TorrentControl must never change.
    $parts = New-Object Collections.Generic.List[string]
    $parts.Add('protocol=' + [Net.ServicePointManager]::SecurityProtocol)
    $parts.Add('callback=' + ($null -ne [Net.ServicePointManager]::ServerCertificateValidationCallback))
    try { $parts.Add('default=' + [Net.WebRequest]::DefaultWebProxy.GetProxy([Uri]'https://rutracker.org/forum/')) } catch { $parts.Add('default=error') }
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'ALL_PROXY')) { $parts.Add($name + '=' + [Environment]::GetEnvironmentVariable($name)) }
    if ($script:OnWindows) {
        $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        foreach ($name in @('ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL', 'AutoDetect')) { $parts.Add($name + '=' + [string]$settings.$name) }
    }
    return ($parts -join "`n")
}
function Get-ProxyText($Proxy) { Start-Sleep -Milliseconds 200; return $Proxy.AllRequests() }
$networkBefore = Get-NetworkSnapshot
$temp = New-TestDirectory
$savedLocal = $env:LOCALAPPDATA
$proxies = New-Object Collections.Generic.List[object]
function New-FakeProxy([string]$Mode) { $p = New-Object FakeProxy($Mode); $proxies.Add($p); return $p }
try {
    $env:LOCALAPPDATA = Join-Path $temp 'LocalAppData'
    $secrets = @('FAKE-PASSWORD-NET-1', '0-FAKE-COOKIE-NET-2', 'login_password', 'bb_session', '/forum/', 'Cookie:', 'Authorization')

    # --- RuTrackerRoute: anonymous check, HTTP CONNECT through the proxy, TLS kept end-to-end ----------------
    $garbage = New-FakeProxy 'connect-garbage'
    $r = [RuTrackerRoute]::Check('127.0.0.1', $garbage.Port, 'rutracker.org', '/forum/index.php', 3000)
    Assert (!$r.Ok -and $r.Code -eq 'TlsFailed' -and $r.Stage -eq 'Tls' -and $r.ProxyStatus -eq 200) "non-TLS answer after CONNECT: $($r.Code)/$($r.Stage)"
    $seen = Get-ProxyText $garbage
    Assert ($seen -match '^CONNECT rutracker\.org:443 HTTP/1\.1\r\nHost: rutracker\.org:443\r\n') "proxy did not get a CONNECT for rutracker.org:443: $seen"
    foreach ($s in $secrets) { Assert ($seen -notmatch [regex]::Escape($s)) "proxy saw '$s' outside TLS" }
    Assert (@($garbage.TunnelBytes)[0][0] -eq 22) 'the tunnel did not start with a TLS handshake'
    $cases = @(@('connect-403', 'ProxyRefused', 'ProxyTunnel', 403), @('connect-407', 'ProxyAuthRequired', 'ProxyTunnel', 407), @('close', 'ProxyRefused', 'ProxyTunnel', 0))
    foreach ($case in $cases) {
        $p = New-FakeProxy $case[0]
        $r = [RuTrackerRoute]::Check('127.0.0.1', $p.Port, 'rutracker.org', '/forum/index.php', 3000)
        Assert (!$r.Ok -and $r.Code -eq $case[1] -and $r.Stage -eq $case[2] -and $r.ProxyStatus -eq $case[3]) "$($case[0]): $($r.Code)/$($r.Stage)/$($r.ProxyStatus)"
    }
    $silent = New-FakeProxy 'silent'
    $r = [RuTrackerRoute]::Check('127.0.0.1', $silent.Port, 'rutracker.org', '/forum/index.php', 1500)
    Assert ($r.Code -eq 'Timeout' -and $r.Stage -eq 'ProxyTunnel' -and $r.ElapsedMs -lt 8000) "silent proxy: $($r.Code)/$($r.Stage)/$($r.ElapsedMs)"
    $closed = [FakeProxy]::ClosedPort()
    # Windows needs about 2 s to report a refused local connection: allow for it.
    $r = [RuTrackerRoute]::Check('127.0.0.1', $closed, 'rutracker.org', '/forum/index.php', 8000)
    Assert ($r.Code -eq 'ProxyUnreachable' -and $r.Stage -eq 'ProxyConnect') "closed proxy port: $($r.Code)/$($r.Stage)"
    # Direct connection with a DNS failure (reserved name, never resolvable).
    $r = [RuTrackerRoute]::Check('', 0, 'rutracker.invalid', '/forum/index.php', 5000)
    Assert (!$r.Ok -and $r.Stage -eq 'Dns' -and $r.Code -in @('DnsFailed', 'Timeout')) "direct DNS failure: $($r.Code)/$($r.Stage)"
    # Certificate errors are reported as such and never accepted (the callback only records them).
    foreach ($errors in @('RemoteCertificateChainErrors', 'RemoteCertificateNameMismatch', 'RemoteCertificateNotAvailable')) {
        Assert ([RuTrackerRoute]::TlsCode([Net.Security.SslPolicyErrors]$errors) -eq 'TlsCertificateInvalid') "$errors not a certificate error"
    }
    Assert ([RuTrackerRoute]::TlsCode([Net.Security.SslPolicyErrors]::None) -eq 'TlsFailed') 'handshake failure without certificate errors'

    # --- Error classification: fixed codes from the exception chain, never the message ----------------------
    function New-WebError([string]$Status, $Inner = $null) { return (New-Object Net.WebException('https://rutracker.org/forum/login.php?kk=FAKE', $Inner, [Net.WebExceptionStatus]$Status, $null)) }
    $map = @(
        @((New-WebError 'TrustFailure'), 'TlsCertificateInvalid'), @((New-WebError 'SecureChannelFailure'), 'TlsFailed'),
        @((New-WebError 'NameResolutionFailure'), 'DnsFailed'), @((New-WebError 'ProxyNameResolutionFailure'), 'ProxyUnreachable'),
        @((New-WebError 'Timeout'), 'Timeout'), @((New-WebError 'ConnectFailure' (New-Object Net.Sockets.SocketException(10061))), 'ConnectFailed'),
        @((New-Object Net.Sockets.SocketException(11001)), 'DnsFailed'), @((New-Object Net.Sockets.SocketException(10060)), 'Timeout'),
        @((New-Object Security.Authentication.AuthenticationException('x')), 'TlsFailed'),
        @((New-Object Exception('wrapper', (New-Object Security.Authentication.AuthenticationException('inner')))), 'TlsFailed'),
        @((New-Object Exception('https://rutracker.org/forum/dl.php?t=1 kk=FAKE')), 'NetworkError'))
    foreach ($case in $map) { Assert ((Get-RuTrackerNetError $case[0]) -eq $case[1]) "classification $($case[1])" }
    $script:RuTrackerProxy = ''
    $direct = @{ DnsFailed = 'RuTrackerUnavailable'; ConnectFailed = 'RuTrackerUnavailable'; Timeout = 'RuTrackerUnavailable'; NetworkError = 'RuTrackerUnavailable'
        TlsFailed = 'RuTrackerTlsFailed'; TlsCertificateInvalid = 'RuTrackerTlsFailed'; HttpForbidden = 'RuTrackerBlocked'; HttpRateLimited = 'RuTrackerBlocked' }
    foreach ($key in $direct.Keys) { Assert ((Get-RuTrackerFailureCode $key) -eq $direct[$key]) "direct $key" }
    $script:RuTrackerProxy = 'http://127.0.0.1:12334'
    foreach ($key in @('DnsFailed', 'ConnectFailed', 'Timeout', 'NetworkError', 'ProxyUnreachable', 'ProxyRefused', 'ProxyAuthRequired')) {
        Assert ((Get-RuTrackerFailureCode $key) -eq 'RuTrackerProxyUnavailable') "via proxy $key"
    }
    Assert ((Get-RuTrackerFailureCode 'TlsCertificateInvalid') -eq 'RuTrackerTlsFailed') 'TLS failure via proxy'

    # --- Real HTTP requests (HttpWebRequest) through the fake proxies ---------------------------------------
    $script:RuTrackerTimeoutMs = 3000
    $form = 'login_username=fake&login_password=FAKE-PASSWORD-NET-1&login=%C2%F5%EE%E4'
    $tls = New-FakeProxy 'connect-garbage'
    $script:RuTrackerProxy = 'http://127.0.0.1:' + $tls.Port
    $response = Invoke-RuTrackerHttp 'Post' 'https://rutracker.org/forum/login.php' (New-RuTrackerSession 'bb_session=0-FAKE-COOKIE-NET-2') $form
    Assert ($response.status -eq 0 -and (Get-RuTrackerFailureCode $response.error) -in @('RuTrackerTlsFailed', 'RuTrackerProxyUnavailable')) "TLS failure through the proxy: $($response.error)"
    $seen = Get-ProxyText $tls
    Assert ($seen -match '^CONNECT rutracker\.org:443 HTTP/1\.1') 'HTTPS request not sent through HTTP CONNECT'
    foreach ($s in $secrets) { Assert ($seen -notmatch [regex]::Escape($s)) "password or cookie visible to the proxy: '$s'" }
    Assert (@($tls.TunnelBytes)[0][0] -eq 22) 'request not protected by TLS inside the tunnel'
    foreach ($case in @(@('closed', $closed), @('silent', (New-FakeProxy 'silent').Port))) {
        $script:RuTrackerProxy = 'http://127.0.0.1:' + $case[1]
        $started = [DateTime]::UtcNow
        $response = Invoke-RuTrackerHttp 'Get' 'https://rutracker.org/forum/dl.php?t=1' (New-RuTrackerSession 'bb_session=0-FAKE-COOKIE-NET-2')
        Assert ($response.status -eq 0 -and (Get-RuTrackerFailureCode $response.error) -eq 'RuTrackerProxyUnavailable') "$($case[0]) proxy: $($response.error)"
        Assert (([DateTime]::UtcNow - $started).TotalSeconds -lt 12) "$($case[0]) proxy: no timeout ($([int]([DateTime]::UtcNow - $started).TotalSeconds) s)"
    }
    # Only HTTPS to rutracker.org/forum/ and the CAPTCHA host: anything else is refused before any connection.
    $guard = New-FakeProxy 'connect-garbage'
    $script:RuTrackerProxy = 'http://127.0.0.1:' + $guard.Port
    foreach ($url in @('http://rutracker.org/forum/login.php', 'https://rutracker.org.evil.example/forum/login.php', 'https://evil.example/forum/', 'https://rutracker.org/other')) {
        Assert-Throws { Invoke-RuTrackerHttp 'Post' $url (New-RuTrackerSession) $form } 'RuTrackerRedirectRefused' "request allowed to $url"
    }
    Assert ((Get-ProxyText $guard) -eq '') 'a refused address was contacted'

    # --- Password and cookie are not sent before the route works (real route check) ------------------------
    $credential = New-Object Management.Automation.PSCredential('fake-user', (ConvertTo-SecureString 'FAKE-PASSWORD-NET-1' -AsPlainText -Force))
    foreach ($case in @(@('connect-403', 'RuTrackerProxyUnavailable'), @('connect-407', 'RuTrackerProxyUnavailable'), @('connect-garbage', 'RuTrackerTlsFailed'))) {
        $p = New-FakeProxy $case[0]
        $script:RuTrackerProxy = 'http://127.0.0.1:' + $p.Port
        Reset-RuTrackerRoute
        Assert-Throws { Invoke-RuTrackerLogin $credential } $case[1] "login through $($case[0])"
        $seen = Get-ProxyText $p
        Assert (([regex]::Matches($seen, 'CONNECT ')).Count -eq 1 -and $seen -match 'TorrentControl-route-check') "$($case[0]): more than the anonymous route check was sent"
        foreach ($s in $secrets) { Assert ($seen -notmatch [regex]::Escape($s)) "$($case[0]): '$s' sent" }
    }
    # The same for the automatic path, with rutracker-proxy.txt and a stored session; no public fallback.
    $app = Join-Path $temp 'app'
    $null = Microsoft.PowerShell.Management\New-Item -Path $app -ItemType Directory
    function Read-RuTrackerCredential([string]$Directory) { return $credential }
    function Read-RuTrackerSessionText([string]$Directory) { return 'bb_session=0-FAKE-COOKIE-NET-2' }
    function Get-SystemRuTrackerProxy { return '' }
    $p = New-FakeProxy 'connect-garbage'
    [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $app 'rutracker-proxy.txt')), "http://127.0.0.1:$($p.Port)`r`n")
    Reset-RuTrackerRoute
    Assert-Throws { Get-PersonalTorrent $app '6612345' ('A' * 40) } 'RuTrackerTlsFailed' 'TLS failure did not stop the download'
    $seen = Get-ProxyText $p
    Assert (([regex]::Matches($seen, 'CONNECT ')).Count -eq 1 -and $seen -match 'TorrentControl-route-check') 'cookie request made after a failed route check'
    Assert (!(Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'TorrentControl\personal'))) 'a file was written after a network failure'
    Assert (!(Read-RuTrackerState $app).blocked) 'network failure blocked automatic logins'

    # --- Diagnostics (Test-RuTrackerConnection.ps1) -----------------------------------------------------------
    $hiddify = New-FakeProxy 'connect-403'
    $webui = New-FakeProxy 'connect-garbage'     # stands for the uTorrent WebUI: must never be probed
    $sockets = @(
        [pscustomobject]@{ Address = '127.0.0.1'; Port = 12334; Process = 'Hiddify' }, [pscustomobject]@{ Address = '::1'; Port = 12334; Process = 'Hiddify' },
        [pscustomobject]@{ Address = '127.0.0.1'; Port = $hiddify.Port; Process = 'HiddifyCli' }, [pscustomobject]@{ Address = '0.0.0.0'; Port = 12338; Process = 'sing-box' },
        [pscustomobject]@{ Address = '127.0.0.1'; Port = $webui.Port; Process = 'uTorrent' }, [pscustomobject]@{ Address = '192.168.1.5'; Port = 12340; Process = 'Hiddify' },
        [pscustomobject]@{ Address = '127.0.0.1'; Port = 5000; Process = 'chrome' })
    $found = @(Get-LocalProxyCandidates $sockets)
    $expected = @(@(12334, 12338, $hiddify.Port) | Sort-Object | ForEach-Object { 'http://127.0.0.1:' + $_ }) -join ','
    Assert ((@($found | ForEach-Object { $_.url }) -join ',') -eq $expected) "candidates: $(@($found | ForEach-Object { $_.url }) -join ',')"
    $script:checks = New-Object Collections.ArrayList
    $script:credentialRead = $false
    function Read-RuTrackerCredential([string]$Directory) { $script:credentialRead = $true; return $null }
    function Get-ListeningSockets { return ,$sockets }
    function Invoke-RuTrackerRouteCheck([string]$Proxy, [string]$HostName = 'rutracker.org', [int]$TimeoutMs = 0) {
        [void]$script:checks.Add($Proxy)
        if (!$Proxy) { return [RuTrackerRoute]::Check('', 0, 'rutracker.invalid', '/forum/index.php', 5000) }   # direct: DNS failure
        if ($Proxy -eq 'http://127.0.0.1:12334') { return [pscustomobject]@{ Ok = $true; Code = 'Ok'; Stage = 'Http'; ProxyStatus = 200; HttpStatus = 200; TlsErrors = ''; Addresses = 0; ElapsedMs = 420 } }
        $uri = [Uri]$Proxy
        return [RuTrackerRoute]::Check($uri.Host, $uri.Port, 'rutracker.org', '/forum/index.php', $TimeoutMs)
    }
    $slow = [pscustomobject]@{ Ok = $false; Code = 'Timeout'; Stage = 'ProxyConnect'; ProxyStatus = 0; HttpStatus = 0; TlsErrors = ''; Addresses = 0; ElapsedMs = 8000 }
    Assert ((Format-RouteResult $slow 8) -match '^на этом адресе и порту ничего не принимает соединения.*\(нет ответа за 8 с\)') 'timeout at the proxy not explained'
    $cert = [pscustomobject]@{ Ok = $false; Code = 'TlsCertificateInvalid'; Stage = 'Tls'; ProxyStatus = 200; HttpStatus = 0; TlsErrors = 'RemoteCertificateChainErrors'; Addresses = 0; ElapsedMs = 10 }
    Assert ((Format-RouteResult $cert 8) -match 'сертификат rutracker\.org не прошёл проверку \(RemoteCertificateChainErrors\)') 'certificate error not explained'
    $diag = Join-Path $temp 'diag'
    $null = Microsoft.PowerShell.Management\New-Item -Path $diag -ItemType Directory
    $report = Invoke-RuTrackerDiagnostics $diag '' -FindLocalProxy 3
    $text = $report.lines -join "`n"
    Assert ($report.working -eq 'http://127.0.0.1:12334' -and !$report.directOk) "working route: $($report.working)"
    Assert ($text -match 'DNS rutracker\.org на этом компьютере: (имя rutracker\.org не разрешается|нет ответа)' -and $text -match 'http://127\.0\.0\.1:12334 \(процесс Hiddify\): РАБОТАЕТ') "report: $text"
    Assert ($text -match ('http://127\.0\.0\.1:' + $hiddify.Port + ' \(процесс HiddifyCli\): прокси не открыл туннель к rutracker\.org:443 \(ответ 403\)')) "refused proxy not explained: $text"
    Assert ($text -match 'ИТОГ: рабочий маршрут через http://127\.0\.0\.1:12334') 'verdict missing'
    Assert ((Get-ProxyText $webui) -eq '' -and $script:checks -notcontains ('http://127.0.0.1:' + $webui.Port)) 'the uTorrent WebUI port was probed'
    Assert (!$script:credentialRead) 'diagnostics read the RuTracker credential'
    foreach ($s in $secrets + @('FAKE')) { Assert ($text -notmatch [regex]::Escape($s)) "report contains '$s'" }
    Assert (!(Test-Path -LiteralPath (Join-Path $diag 'rutracker-proxy.txt'))) 'proxy saved without -Save'
    Assert ((Save-RuTrackerProxy $diag $report.working) -eq 'http://127.0.0.1:12334' -and (Read-RuTrackerProxy $diag) -eq 'http://127.0.0.1:12334') 'proxy not saved'
    Assert-Throws { Save-RuTrackerProxy $diag 'socks5://127.0.0.1:12334' } 'RuTrackerProxyInvalid' 'SOCKS proxy saved'
    Assert-Throws { Invoke-RuTrackerDiagnostics $diag 'http://user:pw@127.0.0.1:1' } 'RuTrackerProxyInvalid' 'proxy with a password accepted'
    # Nothing works: Hiddify guidance, no external proxy suggested, nothing saved.
    function Get-ListeningSockets { return ,@() }
    $empty = Join-Path $temp 'empty'
    $null = Microsoft.PowerShell.Management\New-Item -Path $empty -ItemType Directory
    $report = Invoke-RuTrackerDiagnostics $empty ('http://127.0.0.1:' + $closed) -FindLocalProxy 8
    $text = $report.lines -join "`n"
    Assert (!$report.working -and $text -match 'ничего не принимает соединения' -and $text -match 'не найдены') "unreachable proxy not explained: $text"
    Assert ($text -match '«Режим службы» → «Только прокси»' -and $text -match '«Порт прокси \(SOCKS5/4, HTTP\)»' -and $text -match 'Внешние прокси из интернета автоматически не предлагаются') 'Hiddify guidance missing'
    Assert ($text -notmatch 'blockme|https?://(?!127\.0\.0\.1)[a-z]') 'an external proxy was suggested'
    Assert (!(Test-Path -LiteralPath (Join-Path $empty 'rutracker-proxy.txt'))) 'proxy file written although nothing works'
} finally {
    foreach ($p in $proxies) { $p.Dispose() }
    $env:LOCALAPPDATA = $savedLocal
    Remove-TestDirectory $temp
}
Assert ((Get-NetworkSnapshot) -eq $networkBefore) 'network settings of the process or computer changed'
"PASS Test-RuTrackerNet: $script:AssertCount assertions"
