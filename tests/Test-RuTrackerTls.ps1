param([string]$TrustedPki = '')
. "$PSScriptRoot\TestCommon.ps1"
. "$PSScriptRoot\..\AutoLoad.ps1"
. "$PSScriptRoot\..\RuTracker.ps1"
. "$PSScriptRoot\..\Test-RuTrackerConnection.ps1"   # Format-RouteResult (its main block does not run when dot-sourced)
# Real TLS end to end with the production transport (RuTrackerRoute.cs + RuTrackerTls13.cs, through RuTracker.ps1):
# fake proxies on 127.0.0.x (tests\FakeTlsServer.cs) play the official HTTPS proxy and, inside the tunnel,
# rutracker.org with TLS 1.3 only, using throwaway test certificates. Nothing reaches the network, no certificate
# store or setting is changed, only fake passwords, cookies and keys are used.
#   no parameter  (every platform) the test CA is trusted nowhere: refusals, proxy address failover, nothing of a
#                 request is sent before both certificates are validated. On Linux this file then runs itself again
#                 as a child process with SSL_CERT_FILE = only the test CA (.NET on Linux reads its trust file at
#                 start; Windows has no such per-process switch without touching the certificate store).
#   -TrustedPki   the working paths: anonymous check, login, personal .torrent, failover, and certificates of the
#                 trusted test CA that must still be refused (name, dates, usage) and another CA.
Initialize-RuTrackerTransport 3>$null
if (!('FakeTlsProxy' -as [type])) {
    $references = Get-RuTrackerTransportReferences
    if ($PSVersionTable.PSEdition -eq 'Core') { Add-Type -Path "$PSScriptRoot\FakeTlsServer.cs" -ReferencedAssemblies ($references + 'System.Threading.Thread') -IgnoreWarnings 3>$null }
    else { Add-Type -Path "$PSScriptRoot\FakeTlsServer.cs" -ReferencedAssemblies $references }
}

$script:servers = New-Object Collections.Generic.List[object]
function New-TlsProxy([string]$Address, [int]$Port, [string]$Behaviour, $ProxyLeaf, $SiteLeaf, [string]$SiteTls = '1.3') {
    $server = [FakeTlsProxy]::new($Address, $Port, $Behaviour, $ProxyLeaf, $SiteLeaf, $SiteTls)
    $script:servers.Add($server)
    return $server
}
function Set-TestAddresses([string]$Name, [string[]]$Addresses) {
    [RuTrackerRoute]::TestAddresses[$Name] = [Net.IPAddress[]]@($Addresses | ForEach-Object { [Net.IPAddress]::Parse($_) })
}
function Get-Seen($Server) { Start-Sleep -Milliseconds 300; return [pscustomobject]@{ proxy = $Server.AllProxyRequests(); site = $Server.AllSiteRequests() } }
function Assert-NoSecret([string]$Text, [string]$Why) {
    foreach ($secret in @('FAKE-PASSWORD-TLS-1', '0-FAKE-SESSION-TLS-7', 'FAKE-TLS-KEY-9', 'login_password', 'bb_session', 'Cookie:', '/forum/', 'kk=')) {
        Assert ($Text -notmatch [regex]::Escape($secret)) "$Why contains '$secret'"
    }
}
$script:credential = New-Object Management.Automation.PSCredential('fake-user', (ConvertTo-SecureString 'FAKE-PASSWORD-TLS-1' -AsPlainText -Force))
$script:storedSession = ''
# Windows DPAPI files are replaced by memory here; the transport, login and file checks are the real ones.
function Read-RuTrackerCredential([string]$Directory) { return $script:credential }
function Read-RuTrackerSessionText([string]$Directory) { return $script:storedSession }
function Save-RuTrackerSessionText([string]$Directory, [string]$CookieText) { $script:storedSession = $CookieText }
function Get-SystemRuTrackerProxy { return '' }
function New-App([string]$Root, [string]$Proxy) {
    $app = Join-Path $Root ('app-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = Microsoft.PowerShell.Management\New-Item -Path $app -ItemType Directory
    [IO.File]::WriteAllText((Join-Path $app 'rutracker-proxy.txt'), $Proxy + "`r`n")
    return $app
}
function Get-PersonalFiles { $folder = Join-Path $env:LOCALAPPDATA 'TorrentControl\personal'; if (!(Test-Path -LiteralPath $folder)) { return @() }; return @(Get-ChildItem -LiteralPath $folder -Filter '*.torrent') }

$temp = New-TestDirectory
$savedLocal = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = Join-Path $temp 'LocalAppData'
    if (!$TrustedPki) {
        # ===================== The test CA is not trusted on this computer (every platform) =====================
        $ca = [TestPki]::CreateAuthority('TorrentControl Test CA (untrusted)')
        $site = $ca.IssueServer('rutracker.org')
        $proxyLeaf = $ca.IssueServer('proxy.test')

        # Site certificate from an untrusted CA: refused in the handshake; the other address is not tried; the site
        # never received a byte of HTTP.
        $a = New-TlsProxy '127.0.0.1' 0 'ok' $null $site
        $b = New-TlsProxy '127.0.0.2' $a.Port 'ok' $null $site
        Set-TestAddresses 'site-untrusted.test' @('127.0.0.1', '127.0.0.2')
        $r = [RuTrackerRoute]::Check('http', 'site-untrusted.test', $a.Port, 'rutracker.org', '/forum/index.php', 8000)
        Assert (!$r.Ok -and $r.Code -eq 'TlsCertificateInvalid' -and $r.Stage -eq 'Tls' -and $r.TlsErrors -match '^chain not trusted: ' -and $r.Attempts -eq 1 -and $r.ProxyStatus -eq 200) "untrusted site certificate: $($r.Code)/$($r.Stage)/$($r.TlsErrors)/$($r.Attempts)"
        $seen = Get-Seen $a
        Assert ($seen.site -eq '' -and $b.Connections -eq 0) 'request sent after a refused certificate or another address tried'
        Assert ($seen.proxy -match '^CONNECT rutracker\.org:443 HTTP/1\.1\r\n') "proxy did not get CONNECT: $($seen.proxy)"
        Assert ((Format-RouteResult $r 8) -match 'сертификат rutracker\.org не прошёл проверку \(chain not trusted: ') 'certificate refusal not explained'

        # The login is not attempted: the route check fails first, the password never leaves the computer.
        $script:RuTrackerProxy = 'http://site-untrusted.test:' + $a.Port
        Reset-RuTrackerRoute
        Assert-Throws { Invoke-RuTrackerLogin $script:credential } 'RuTrackerTlsFailed' 'login through a site with an untrusted certificate'
        $seen = Get-Seen $a
        Assert ($seen.site -eq '' -and ([regex]::Matches($seen.proxy, 'CONNECT ')).Count -eq 2 -and $seen.proxy -match 'TorrentControl-route-check') 'more than the anonymous route check was attempted'
        Assert-NoSecret ($seen.proxy + $seen.site) 'login with an untrusted site'
        # Automatic download: fixed code, no file, no public version.
        $app = New-App $temp ('http://site-untrusted.test:' + $a.Port)
        Reset-RuTrackerRoute
        Assert-Throws { Get-PersonalTorrent $app '6612345' ('A' * 40) } 'RuTrackerTlsFailed' 'download with an untrusted site certificate'
        Assert ((Get-PersonalFiles).Count -eq 0) 'a personal file was written after a TLS refusal'

        # HTTPS proxy with an untrusted certificate: refused before CONNECT; no other address.
        $p1 = New-TlsProxy '127.0.0.1' 0 'ok' $proxyLeaf $site
        $p2 = New-TlsProxy '127.0.0.2' $p1.Port 'ok' $proxyLeaf $site
        Set-TestAddresses 'proxy-untrusted.test' @('127.0.0.1', '127.0.0.2')
        $r = [RuTrackerRoute]::Check('https', 'proxy-untrusted.test', $p1.Port, 'rutracker.org', '/forum/index.php', 8000)
        Assert (!$r.Ok -and $r.Code -eq 'ProxyTlsFailed' -and $r.Stage -eq 'ProxyTls' -and $r.TlsErrors -match 'RemoteCertificate(ChainErrors|NameMismatch)' -and $r.Attempts -eq 1) "untrusted proxy certificate: $($r.Code)/$($r.TlsErrors)/$($r.Attempts)"
        $seen = Get-Seen $p1
        Assert ($seen.proxy -eq '' -and $p2.Connections -eq 0) 'CONNECT sent to an untrusted proxy or another address tried'

        # Failover: closed connection, refused tunnel, then the third address (whose site certificate is refused).
        $f1 = New-TlsProxy '127.0.0.1' 0 'ok' $null $site
        $null = New-TlsProxy '127.0.0.2' $f1.Port 'close' $null $site
        $f3 = New-TlsProxy '127.0.0.3' $f1.Port 'refuse-403' $null $site
        $f4 = New-TlsProxy '127.0.0.4' $f1.Port 'ok' $null $site
        Set-TestAddresses 'failover.test' @('127.0.0.2', '127.0.0.3', '127.0.0.1', '127.0.0.4')
        $r = [RuTrackerRoute]::Check('http', 'failover.test', $f1.Port, 'rutracker.org', '/forum/index.php', 8000)
        Assert ($r.Code -eq 'TlsCertificateInvalid' -and $r.Attempts -eq 3 -and $r.Addresses -eq 4 -and $r.Endpoint -eq ('127.0.0.1:' + $f1.Port)) "failover: $($r.Code)/$($r.Attempts)/$($r.Endpoint)"
        Assert ($f3.Connections -eq 1 -and $f4.Connections -eq 0) 'failover order or the limit of 3 addresses not kept'
        # Not after a password request of the proxy.
        $g1 = New-TlsProxy '127.0.0.1' 0 'auth-407' $null $site
        $g2 = New-TlsProxy '127.0.0.2' $g1.Port 'ok' $null $site
        Set-TestAddresses 'auth.test' @('127.0.0.1', '127.0.0.2')
        $r = [RuTrackerRoute]::Check('http', 'auth.test', $g1.Port, 'rutracker.org', '/forum/index.php', 8000)
        Assert ($r.Code -eq 'ProxyAuthRequired' -and $r.Attempts -eq 1 -and $g2.Connections -eq 0) "proxy password request: $($r.Code)/$($r.Attempts)"
        # Non-TLS answer inside the tunnel on every address: TlsFailed after 3 attempts.
        $h1 = New-TlsProxy '127.0.0.1' 0 'site-garbage' $null $site
        $null = New-TlsProxy '127.0.0.2' $h1.Port 'site-garbage' $null $site
        Set-TestAddresses 'garbage.test' @('127.0.0.1', '127.0.0.2')
        $r = [RuTrackerRoute]::Check('http', 'garbage.test', $h1.Port, 'rutracker.org', '/forum/index.php', 8000)
        Assert ($r.Code -eq 'TlsFailed' -and $r.Stage -eq 'Tls' -and $r.Attempts -eq 2) "garbage on every address: $($r.Code)/$($r.Attempts)"
        # Nothing listens on any address: ProxyUnreachable after at most 3 attempts; the request path stops here.
        $closed = [FakeTlsProxy]::new('127.0.0.1', 0, 'close', $null, $site, '1.3')
        $port = $closed.Port
        $closed.Dispose()
        Set-TestAddresses 'down.test' @('127.0.0.5', '127.0.0.6', '127.0.0.7', '127.0.0.8')
        $r = [RuTrackerRoute]::Check('https', 'down.test', $port, 'rutracker.org', '/forum/index.php', 8000)
        Assert ($r.Code -eq 'ProxyUnreachable' -and $r.Stage -eq 'ProxyConnect' -and $r.Attempts -eq 3) "no proxy address answers: $($r.Code)/$($r.Attempts)"
        $send = [RuTrackerRoute]::Send('https', 'down.test', $port, 'POST', 'https://rutracker.org/forum/login.php', (New-Object Net.CookieContainer), 'application/x-www-form-urlencoded',
            [Text.Encoding]::ASCII.GetBytes('login_password=FAKE-PASSWORD-TLS-1'), 'TorrentControl-test', 8000, 4000000)
        Assert ($send.Status -eq 0 -and $send.Error -eq 'ProxyUnreachable') "request with no proxy address: $($send.Error)"
        $script:RuTrackerProxy = 'https://down.test:' + $port
        Reset-RuTrackerRoute
        Assert-Throws { Assert-RuTrackerRoute } 'RuTrackerProxyUnavailable' 'route check with no proxy address'
        # A name outside .test never uses the test addresses.
        Set-TestAddresses 'rutracker.invalid' @('127.0.0.1')
        $r = [RuTrackerRoute]::Check('', '', 0, 'rutracker.invalid', '/forum/index.php', 5000)
        Assert ($r.Stage -eq 'Dns' -and $r.Code -in @('DnsFailed', 'Timeout')) "test addresses used outside .test: $($r.Code)/$($r.Endpoint)"

        # A missing TLS library stops every request with one code, before anything is sent.
        $copy = Join-Path $temp 'no-lib'
        $null = Microsoft.PowerShell.Management\New-Item -Path $copy -ItemType Directory
        foreach ($name in @('RuTracker.ps1', 'RuTrackerTls13.ps1', 'RuTrackerTls13.cs', 'RuTrackerRoute.cs')) { Copy-Item -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..') $name) -Destination $copy }
        $exe = (Get-Process -Id $PID).Path
        $script = Join-Path $copy 'RuTracker.ps1'
        $out = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ". '$script'; try { `$null = Invoke-RuTrackerRouteCheck 'http://127.0.0.1:1'; 'SENT' } catch { `$_.Exception.Message }" 2>&1 | Out-String
        Assert ($out.Trim() -eq 'RuTrackerTlsComponentInvalid') "missing library: '$($out.Trim())'"

        # ===================== Working paths with a trusted test CA (Linux: child process) =====================
        if ($script:OnWindows) {
            Write-Host 'SKIP trusted part: Windows has no per-process trust file; it runs on Linux (SSL_CERT_FILE) in CI.'
        } else {
            $pki = Join-Path $temp 'pki'
            $null = Microsoft.PowerShell.Management\New-Item -Path (Join-Path $pki 'empty') -ItemType Directory -Force
            $trusted = [TestPki]::CreateAuthority('TorrentControl Test CA (trusted in the child only)')
            [IO.File]::WriteAllText((Join-Path $pki 'ca.pem'), $trusted.CertificatePem)
            [IO.File]::WriteAllBytes((Join-Path $pki 'ca.der'), $trusted.CertificateDer)
            [IO.File]::WriteAllBytes((Join-Path $pki 'ca.key'), $trusted.KeyDer)
            $saved = @{ file = $env:SSL_CERT_FILE; dir = $env:SSL_CERT_DIR }
            try {
                $env:SSL_CERT_FILE = Join-Path $pki 'ca.pem'
                $env:SSL_CERT_DIR = Join-Path $pki 'empty'
                $exe = (Get-Process -Id $PID).Path
                $output = & $exe -NoProfile -NonInteractive -File $PSCommandPath -TrustedPki $pki 2>&1 | Out-String
                $code = $LASTEXITCODE
            } finally { $env:SSL_CERT_FILE = $saved.file; $env:SSL_CERT_DIR = $saved.dir }
            Write-Host ($output.Trim())
            Assert ($code -eq 0 -and $output -match 'PASS trusted TLS') "trusted part failed (exit $code)"
        }
    } else {
        # ===================== Child process: the test CA is the only trusted root =====================
        $ca = [TestPki]::Load([IO.File]::ReadAllBytes((Join-Path $TrustedPki 'ca.der')), [IO.File]::ReadAllBytes((Join-Path $TrustedPki 'ca.key')))
        $site = $ca.IssueServer('rutracker.org')
        $proxyLeaf = $ca.IssueServer('proxy.test')

        # Anonymous route check through an HTTPS proxy (like ps1.blockme.site): TLS 1.2 to the proxy, TLS 1.3 inside.
        $p = New-TlsProxy '127.0.0.1' 0 'ok' $proxyLeaf $site
        $p.Password = 'FAKE-PASSWORD-TLS-1'
        Set-TestAddresses 'proxy.test' @('127.0.0.1')
        $r = [RuTrackerRoute]::Check('https', 'proxy.test', $p.Port, 'rutracker.org', '/forum/index.php', 8000)
        Assert ($r.Ok -and $r.Code -eq 'Ok' -and $r.HttpStatus -eq 200 -and $r.ProxyStatus -eq 200 -and $r.TlsVersion -eq 'TLS 1.3' -and $r.Attempts -eq 1) "https proxy route: $($r.Code)/$($r.Stage)/$($r.TlsErrors)/$($r.TlsVersion)"
        $seen = Get-Seen $p
        Assert ($seen.proxy -match '^CONNECT rutracker\.org:443 HTTP/1\.1\r\nHost: rutracker\.org:443\r\nUser-Agent: TorrentControl-route-check\r\n\r\n$') "proxy saw more than CONNECT: $($seen.proxy)"
        Assert ($seen.site -match '^GET /forum/index\.php HTTP/1\.1\r\nHost: rutracker\.org\r\n' -and $seen.site -notmatch 'Cookie:') "anonymous check: $($seen.site)"
        $text = Format-RouteResult $r 8
        Assert ($text -match '^РАБОТАЕТ \(HTTP 200, TLS 1\.3, сертификат rutracker\.org в порядке\); адрес прокси 127\.0\.0\.1:\d+, попыток 1 из 1') "report: $text"
        # Plain HTTP proxy (Hiddify) and a TLS 1.2-only site work as well.
        $h = New-TlsProxy '127.0.0.1' 0 'ok' $null $site '1.2'
        $r = [RuTrackerRoute]::Check('http', '127.0.0.1', $h.Port, 'rutracker.org', '/forum/index.php', 8000)
        Assert ($r.Ok -and $r.TlsVersion -eq 'TLS 1.2') "http proxy, TLS 1.2 site: $($r.Code)/$($r.TlsVersion)"

        # Failover to a working address; the next request starts with it.
        $failover = $ca.IssueServer('failover.test')
        Set-TestAddresses 'failover.test' @('127.0.0.2', '127.0.0.3', '127.0.0.1')
        $w1 = New-TlsProxy '127.0.0.1' 0 'ok' $failover $site
        $w2 = New-TlsProxy '127.0.0.2' $w1.Port 'close' $failover $site
        $w3 = New-TlsProxy '127.0.0.3' $w1.Port 'site-garbage' $failover $site
        $r = [RuTrackerRoute]::Check('https', 'failover.test', $w1.Port, 'rutracker.org', '/forum/index.php', 8000)
        Assert ($r.Ok -and $r.Attempts -eq 3 -and $r.Endpoint -eq ('127.0.0.1:' + $w1.Port)) "failover to the working address: $($r.Code)/$($r.Attempts)/$($r.Endpoint)"
        $r = [RuTrackerRoute]::Check('https', 'failover.test', $w1.Port, 'rutracker.org', '/forum/index.php', 8000)
        Assert ($r.Ok -and $r.Attempts -eq 1 -and $w2.Connections -eq 1 -and $w3.Connections -eq 1) "working address not preferred: $($r.Attempts)"

        # Login: the password goes only inside TLS with rutracker.org; the answer's redirect is not followed.
        $script:RuTrackerProxy = 'https://proxy.test:' + $p.Port
        Reset-RuTrackerRoute
        $login = Invoke-RuTrackerLogin $script:credential
        Assert ($login.ok -and (Test-RuTrackerLoggedIn $login.session)) 'login through the HTTPS proxy failed'
        $seen = Get-Seen $p
        Assert ($seen.site -match 'POST /forum/login\.php HTTP/1\.1' -and $seen.site -match 'login_password=FAKE-PASSWORD-TLS-1') 'login request not received by the site'
        Assert-NoSecret $seen.proxy 'what the proxy saw'
        $bad = New-Object Management.Automation.PSCredential('fake-user', (ConvertTo-SecureString 'FAKE-WRONG-PASSWORD' -AsPlainText -Force))
        $login = Invoke-RuTrackerLogin $bad
        Assert (!$login.ok -and $null -eq $login.captcha) 'a wrong password was accepted'

        # Personal .torrent end to end (Get-PersonalTorrent): route check, login, dl.php with the cookie, body ended by
        # close_notify, infohash and personal announce verified, file stored.
        $personal = Join-Path $temp 'personal.torrent'
        $hash = New-TestTorrentFile $personal (New-TestInfo 'Film.mkv' 2048 'tls') 'http://bt2.rutracker.cx/ann?kk=FAKE-TLS-KEY-9' @(@('http://bt2.rutracker.cx/ann?kk=FAKE-TLS-KEY-9'), @('http://retracker.local/announce')) '6612345'
        $p.Torrent = [IO.File]::ReadAllBytes($personal)
        $app = New-App $temp ('https://proxy.test:' + $p.Port)
        $script:storedSession = ''
        Reset-RuTrackerRoute
        $result = Get-PersonalTorrent $app '6612345' $hash
        Assert ($result.host -eq 'bt2.rutracker.cx' -and $result.source -eq 'RuTracker') "personal .torrent: $($result.host)/$($result.source)"
        Assert ((Get-TestSha256 ([IO.File]::ReadAllBytes($result.path))) -eq (Get-TestSha256 $p.Torrent)) 'stored file differs from the one served'
        Assert ($script:storedSession -match '^bb_session=0-FAKE-SESSION-TLS-7$') 'session not kept for the next download'
        $seen = Get-Seen $p
        Assert ($seen.site -match 'GET /forum/dl\.php\?t=6612345 HTTP/1\.1\r\n(?:[^\r\n]+\r\n)*?Cookie: bb_session=0-FAKE-SESSION-TLS-7\r\n') 'download without the session cookie'
        Assert-NoSecret $seen.proxy 'what the proxy saw'
        # A body without Content-Length ends with the connection, also when the server omits close_notify.
        $p.NoCloseNotify = $true
        $jar = New-Object Net.CookieContainer
        $jar.Add([Uri]'https://rutracker.org/forum/', (New-Object Net.Cookie('bb_session', '0-FAKE-SESSION-TLS-7')))
        $send = [RuTrackerRoute]::Send('https', 'proxy.test', $p.Port, 'GET', 'https://rutracker.org/forum/dl.php?t=6612345', $jar, '', $null, 'TorrentControl-test', 8000, 4000000)
        Assert ($send.Status -eq 200 -and $send.TlsVersion -eq 'TLS 1.3' -and (Get-TestSha256 $send.Body) -eq (Get-TestSha256 $p.Torrent)) "body without close_notify: $($send.Status)/$($send.Error)"
        $p.NoCloseNotify = $false
        # Expired session: the page instead of the file -> one login -> the file.
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $result.path
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath (Join-Path $app 'rutracker-state.json')
        $script:storedSession = 'bb_session=0-FAKE-EXPIRED'
        Reset-RuTrackerRoute
        $result = Get-PersonalTorrent $app '6612345' $hash
        Assert ($result.host -eq 'bt2.rutracker.cx' -and $script:storedSession -match '0-FAKE-SESSION-TLS-7') 'expired session not renewed'
        # A file of another release or with only the public announce is refused; nothing is stored, no public version.
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $result.path
        Assert-Throws { Get-PersonalTorrent $app '6612345' ('B' * 40) } 'PersonalHashMismatch' 'file of another release accepted'
        $public = Join-Path $temp 'public.torrent'
        $publicHash = New-TestTorrentFile $public (New-TestInfo 'Film.mkv' 2048 'pub') 'http://bt.t-ru.org/ann?magnet' @(,@('http://bt.t-ru.org/ann?magnet')) '6612345'
        $p.Torrent = [IO.File]::ReadAllBytes($public)
        Assert-Throws { Get-PersonalTorrent $app '6612345' $publicHash } 'PersonalAnnounceMissing' 'public .torrent accepted as personal'
        Assert ((Get-PersonalFiles).Count -eq 0) 'a refused file was stored'

        # Certificates of the trusted CA that must still be refused, and a certificate of another CA. The password
        # and the cookie are never sent; no other address is tried.
        $rogue = [TestPki]::CreateAuthority('Rogue CA')
        $now = [DateTime]::UtcNow
        $cases = @(
            @('name', $ca.IssueServer('rutracker.org.evil.example'), '^certificate is not issued for rutracker\.org$'),
            @('expired', $ca.Issue([string[]]@('rutracker.org'), $now.AddDays(-10), $now.AddDays(-1), 'server'), '^chain not trusted: .*NotTimeValid'),
            @('not yet valid', $ca.Issue([string[]]@('rutracker.org'), $now.AddDays(1), $now.AddDays(10), 'server'), '^chain not trusted: .*NotTimeValid'),
            @('client usage', $ca.Issue([string[]]@('rutracker.org'), $now.AddHours(-1), $now.AddDays(1), 'client'), '^chain not trusted: .*NotValidForUsage'),
            @('wildcard for another level', $ca.IssueServer('*.rutracker.org'), '^certificate is not issued for rutracker\.org$'),
            @('another CA', $rogue.IssueServer('rutracker.org'), '^chain not trusted: .*(UntrustedRoot|PartialChain)'))
        foreach ($case in $cases) {
            $name = 'bad-' + ($case[0] -replace '[^a-z]', '') + '.test'
            Set-TestAddresses $name @('127.0.0.1', '127.0.0.2')
            $proxyName = $ca.IssueServer($name)
            $c1 = New-TlsProxy '127.0.0.1' 0 'ok' $proxyName $case[1]
            $c2 = New-TlsProxy '127.0.0.2' $c1.Port 'ok' $proxyName $case[1]
            $r = [RuTrackerRoute]::Check('https', $name, $c1.Port, 'rutracker.org', '/forum/index.php', 8000)
            Assert (!$r.Ok -and $r.Code -eq 'TlsCertificateInvalid' -and $r.TlsErrors -match $case[2] -and $r.Attempts -eq 1) "$($case[0]): $($r.Code)/$($r.TlsErrors)/$($r.Attempts)"
            $app = New-App $temp ('https://' + $name + ':' + $c1.Port)
            $script:storedSession = 'bb_session=0-FAKE-SESSION-TLS-7'
            Reset-RuTrackerRoute
            Assert-Throws { Get-PersonalTorrent $app '6612345' $hash } 'RuTrackerTlsFailed' "$($case[0]): download not refused"
            $seen = Get-Seen $c1
            Assert ($seen.site -eq '' -and $c2.Connections -eq 0) "$($case[0]): request sent or another address tried"
            Assert-NoSecret $seen.proxy "$($case[0]): what the proxy saw"
        }
        Assert ((Get-PersonalFiles).Count -eq 0) 'a file was stored after a certificate refusal'
        # The proxy certificate must name the proxy: another name is refused before CONNECT, no other address.
        $n1 = New-TlsProxy '127.0.0.1' 0 'ok' ($ca.IssueServer('other.test')) $site
        $n2 = New-TlsProxy '127.0.0.2' $n1.Port 'ok' ($ca.IssueServer('other.test')) $site
        Set-TestAddresses 'named.test' @('127.0.0.1', '127.0.0.2')
        $r = [RuTrackerRoute]::Check('https', 'named.test', $n1.Port, 'rutracker.org', '/forum/index.php', 8000)
        Assert ($r.Code -eq 'ProxyTlsFailed' -and $r.TlsErrors -match 'RemoteCertificateNameMismatch' -and $r.Attempts -eq 1 -and $n2.Connections -eq 0) "proxy certificate for another name: $($r.Code)/$($r.TlsErrors)/$($r.Attempts)"
        Assert ((Get-Seen $n1).proxy -eq '') 'CONNECT sent to a proxy with a certificate for another name'
        "PASS trusted TLS: $script:AssertCount assertions"
        exit 0
    }
} finally {
    foreach ($server in $script:servers) { $server.Dispose() }
    $env:LOCALAPPDATA = $savedLocal
    Remove-TestDirectory $temp
}
"PASS Test-RuTrackerTls: $script:AssertCount assertions"
