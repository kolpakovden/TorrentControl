param([string]$TrustedPki = '')
. "$PSScriptRoot\TestCommon.ps1"
. "$PSScriptRoot\..\AutoLoad.ps1"
. "$PSScriptRoot\..\RuTracker.ps1"
. "$PSScriptRoot\..\Test-RuTrackerConnection.ps1"   # Format-RouteResult (its main block does not run when dot-sourced)
. "$PSScriptRoot\..\Test-RuTrackerTls13.ps1"         # Open-Tunnel, Invoke-WrongNameCheck of the PC test (same)
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
        Assert (!$r.Ok -and $r.Code -eq 'ProxyCertificateInvalid' -and $r.Stage -eq 'ProxyTls' -and $r.TlsErrors -match 'RemoteCertificate(ChainErrors|NameMismatch)' -and $r.Attempts -eq 1) "untrusted proxy certificate: $($r.Code)/$($r.TlsErrors)/$($r.Attempts)"
        Assert ((Get-RuTrackerFailureCode $r.Code) -eq 'RuTrackerTlsFailed') 'a refused proxy certificate is not reported as a TLS/certificate problem'
        $seen = Get-Seen $p1
        Assert ($seen.proxy -eq '' -and $p2.Connections -eq 0) 'CONNECT sent to an untrusted proxy or another address tried'

        # Failover: closed connection, refused tunnel, then the third address, whose site certificate is refused: the
        # search stops there (the fourth address is not contacted).
        $f1 = New-TlsProxy '127.0.0.1' 0 'ok' $null $site
        $null = New-TlsProxy '127.0.0.2' $f1.Port 'close' $null $site
        $f3 = New-TlsProxy '127.0.0.3' $f1.Port 'refuse-403' $null $site
        $f4 = New-TlsProxy '127.0.0.4' $f1.Port 'ok' $null $site
        Set-TestAddresses 'failover.test' @('127.0.0.2', '127.0.0.3', '127.0.0.1', '127.0.0.4')
        $r = [RuTrackerRoute]::Check('http', 'failover.test', $f1.Port, 'rutracker.org', '/forum/index.php', 8000)
        Assert ($r.Code -eq 'TlsCertificateInvalid' -and $r.Attempts -eq 3 -and $r.Addresses -eq 4 -and $r.Endpoint -eq ('127.0.0.1:' + $f1.Port)) "failover: $($r.Code)/$($r.Attempts)/$($r.Endpoint)"
        Assert ($f3.Connections -eq 1 -and $f4.Connections -eq 0) 'failover order kept or search not stopped at a refused certificate'
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
        # Nothing listens on any address: every address is tried (each refusal is quick), then ProxyUnreachable.
        $closed = [FakeTlsProxy]::new('127.0.0.1', 0, 'close', $null, $site, '1.3')
        $port = $closed.Port
        $closed.Dispose()
        Set-TestAddresses 'down.test' @('127.0.0.5', '127.0.0.6', '127.0.0.7', '127.0.0.8')
        $r = [RuTrackerRoute]::Check('https', 'down.test', $port, 'rutracker.org', '/forum/index.php', 8000)
        Assert ($r.Code -eq 'ProxyUnreachable' -and $r.Stage -eq 'ProxyConnect' -and $r.Attempts -eq 4) "no proxy address answers: $($r.Code)/$($r.Attempts)"
        $send = [RuTrackerRoute]::Send('https', 'down.test', $port, 'POST', 'https://rutracker.org/forum/login.php', (New-Object Net.CookieContainer), 'application/x-www-form-urlencoded',
            [Text.Encoding]::ASCII.GetBytes('login_password=FAKE-PASSWORD-TLS-1'), 'TorrentControl-test', 8000, 4000000)
        Assert ($send.Status -eq 0 -and $send.Error -eq 'ProxyUnreachable') "request with no proxy address: $($send.Error)"
        $script:RuTrackerProxy = 'https://down.test:' + $port
        Reset-RuTrackerRoute
        Assert-Throws { Assert-RuTrackerRoute } 'RuTrackerProxyUnavailable' 'route check with no proxy address'
        # --- A pool of 9 proxy addresses (like ps1.blockme.site) whose first three do not work ------------------
        # The old limit of 3 attempts is gone: the 4th address is reached. Its site certificate is untrusted here,
        # so the search stops there and no further address is contacted.
        $pool = @(2..10 | ForEach-Object { '127.0.0.' + $_ })
        $p5 = New-TlsProxy '127.0.0.5' 0 'ok' $null $site
        $poolPort = $p5.Port
        $null = New-TlsProxy '127.0.0.3' $poolPort 'close' $null $site
        $null = New-TlsProxy '127.0.0.4' $poolPort 'site-garbage' $null $site
        $rest = @(foreach ($n in 6..10) { New-TlsProxy ('127.0.0.' + $n) $poolPort 'ok' $null $site })
        Set-TestAddresses 'pool9.test' $pool
        $r = [RuTrackerRoute]::Check('http', 'pool9.test', $poolPort, 'rutracker.org', '/forum/index.php', 5000)
        Assert ($r.Code -eq 'TlsCertificateInvalid' -and $r.Attempts -eq 4 -and $r.Addresses -eq 9 -and $r.Endpoint -eq ('127.0.0.5:' + $poolPort) -and $r.AddressSource -eq 'dns') "pool of 9, first three down: $($r.Code)/$($r.Attempts)/$($r.Endpoint)"
        Assert ((@($r.AttemptCodes) -join ',') -eq 'ProxyUnreachable,ProxyRefused,TlsFailed,TlsCertificateInvalid' -and (@($r.AttemptAddresses) -join ',') -eq '127.0.0.2,127.0.0.3,127.0.0.4,127.0.0.5') "attempt log: $(@($r.AttemptAddresses) -join ',') / $(@($r.AttemptCodes) -join ',')"
        Assert (@($rest | Where-Object { $_.Connections -gt 0 }).Count -eq 0 -and (@($r.DnsAddresses) -join ',') -eq ($pool -join ',')) 'an address after a refused certificate was contacted'
        # The learned order: preferred first, recently failed last, unknown in DNS order between them.
        $r = [RuTrackerRoute]::Check('http', 'pool9.test', $poolPort, 'rutracker.org', '/forum/index.php', 5000, [string[]]@('127.0.0.8'), [string[]]@('127.0.0.2', '127.0.0.3', '127.0.0.4'))
        Assert ($r.Attempts -eq 1 -and @($r.AttemptAddresses)[0] -eq '127.0.0.8') "preferred address not first: $(@($r.AttemptAddresses) -join ',')"
        $r = [RuTrackerRoute]::Check('http', 'pool9.test', $poolPort, 'rutracker.org', '/forum/index.php', 5000, [string[]]@(), [string[]]@('127.0.0.2', '127.0.0.3', '127.0.0.4'))
        Assert ($r.Attempts -eq 1 -and @($r.AttemptAddresses)[0] -eq '127.0.0.5') "recently failed addresses not moved back: $(@($r.AttemptAddresses) -join ',')"
        # The DNS pool changed: a remembered address that DNS no longer gives is not used.
        $r = [RuTrackerRoute]::Check('http', 'pool9.test', $poolPort, 'rutracker.org', '/forum/index.php', 5000, [string[]]@('127.0.0.99'), [string[]]@())
        Assert (@($r.AttemptAddresses) -notcontains '127.0.0.99' -and @($r.AttemptAddresses)[0] -eq '127.0.0.2') "address outside the DNS answer used: $(@($r.AttemptAddresses) -join ',')"
        # DNS gives nothing: only then the remembered addresses (the certificate is still checked for the name).
        $r = [RuTrackerRoute]::Check('http', 'nodns.test', $poolPort, 'rutracker.org', '/forum/index.php', 5000, [string[]]@('127.0.0.5'), [string[]]@())
        Assert ($r.AddressSource -eq 'cache' -and $r.Attempts -eq 1 -and @($r.AttemptAddresses)[0] -eq '127.0.0.5' -and @($r.DnsAddresses).Count -eq 0) "remembered address not used without DNS: $($r.AddressSource)/$($r.Code)"
        $r = [RuTrackerRoute]::Check('http', 'nodns.test', $poolPort, 'rutracker.org', '/forum/index.php', 5000)
        Assert ($r.Code -eq 'ProxyUnreachable' -and $r.Attempts -eq 0) "no DNS and nothing remembered: $($r.Code)/$($r.Attempts)"

        # TLS to an https proxy: a network failure (no answer, broken handshake) moves on to the next address, a
        # refused certificate stops the search.
        $t2 = New-TlsProxy '127.0.0.2' 0 'silent' $proxyLeaf $site
        $null = New-TlsProxy '127.0.0.3' $t2.Port 'close' $proxyLeaf $site
        $t4 = New-TlsProxy '127.0.0.4' $t2.Port 'ok' $proxyLeaf $site
        $t5 = New-TlsProxy '127.0.0.5' $t2.Port 'ok' $proxyLeaf $site
        Set-TestAddresses 'tlspool.test' @('127.0.0.2', '127.0.0.3', '127.0.0.4', '127.0.0.5')
        $r = [RuTrackerRoute]::Check('https', 'tlspool.test', $t2.Port, 'rutracker.org', '/forum/index.php', 10000)
        Assert ($r.Code -eq 'ProxyCertificateInvalid' -and (@($r.AttemptCodes) -join ',') -eq 'Timeout,ProxyTlsFailed,ProxyCertificateInvalid' -and $r.TlsErrors -match 'RemoteCertificate' -and $t5.Connections -eq 0) "network vs certificate failures of the proxy TLS: $(@($r.AttemptCodes) -join ',')/$($r.TlsErrors)"
        Assert ((Get-Seen $t4).proxy -eq '') 'CONNECT sent to a proxy whose certificate was refused'

        # Time: 9 addresses that never answer. A new address is started only if its handshakes can end with one
        # timeout left; the whole request ends within its hard limit (3 timeouts), not after 9 waits.
        $s2 = New-TlsProxy '127.0.0.2' 0 'silent' $proxyLeaf $site
        foreach ($n in 3..10) { $null = New-TlsProxy ('127.0.0.' + $n) $s2.Port 'silent' $proxyLeaf $site }
        Set-TestAddresses 'slowpool.test' $pool
        $r = [RuTrackerRoute]::Check('https', 'slowpool.test', $s2.Port, 'rutracker.org', '/forum/index.php', 2000)
        Assert ($r.Code -eq 'Timeout' -and $r.Attempts -ge 1 -and $r.Attempts -le 3 -and $r.ElapsedMs -lt 6500) "slow pool not bounded: $($r.Code)/$($r.Attempts)/$($r.ElapsedMs)"

        # --- Test-RuTrackerTls13.ps1 (PC test): proxy TLS failures told apart; the wrong-name check is never faked ---
        $u2 = New-TlsProxy '127.0.0.2' 0 'ok' $proxyLeaf $site
        $null = New-TlsProxy '127.0.0.3' $u2.Port 'close' $proxyLeaf $site
        $null = New-TlsProxy '127.0.0.4' $u2.Port 'silent' $proxyLeaf $site
        $tunnel = Open-Tunnel 'proxy.test' '127.0.0.2' $u2.Port $true 'rutracker.org' 4000
        $tunnel.client.Close()
        Assert ($tunnel.failure -match '^certificate of the proxy REJECTED \(RemoteCertificate') "PC test: refused proxy certificate not reported as such: $($tunnel.failure)"
        $tunnel = Open-Tunnel 'proxy.test' '127.0.0.3' $u2.Port $true 'rutracker.org' 4000
        $tunnel.client.Close()
        Assert ($tunnel.failure -match '^TLS to the proxy broke off .*certificate not involved$') "PC test: network failure of the proxy TLS: $($tunnel.failure)"
        $tunnel = Open-Tunnel 'proxy.test' '127.0.0.4' $u2.Port $true 'rutracker.org' 2000
        $tunnel.client.Close()
        Assert ($tunnel.failure -match '^TLS to the proxy: no answer \(timeout\)') "PC test: silent proxy: $($tunnel.failure)"
        $check = Invoke-WrongNameCheck 'proxy.test' @() $u2.Port $true 'rutracker.org' 2000
        Assert ($check.text -eq 'NOT CHECKED: no address works') "PC test without working addresses: $($check.text)"
        $check = Invoke-WrongNameCheck 'proxy.test' @(('127.0.0.3:' + $u2.Port), ('127.0.0.4:' + $u2.Port)) $u2.Port $true 'rutracker.org' 2000
        Assert ($check.exitCode -eq 4 -and $check.text -match '^NOT CHECKED: none of the 2 working addresses answered again') "PC test, working addresses gone: $($check.exitCode)/$($check.text)"

        # --- The learned order kept between runs (rutracker-proxy-addresses.json) -------------------------------------
        $script:RuTrackerAddressFile = Join-Path $temp 'rutracker-proxy-addresses.json'
        $script:RuTrackerAddressMemory = @{}
        $key = 'http://pool9.test:' + $poolPort
        $r = Invoke-RuTrackerRouteCheck $key 'rutracker.org' 5000
        Assert ($r.Attempts -eq 4 -and [IO.File]::Exists($script:RuTrackerAddressFile)) "first run: $($r.Attempts)"
        $saved = Get-Content -LiteralPath $script:RuTrackerAddressFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($saved.version -eq 1 -and $saved.proxy -eq $key -and @($saved.addresses).Count -eq 9 -and @($saved.addresses | Where-Object { $_.lastFail }).Count -eq 4) "address file: $(@($saved.addresses).Count)"
        # Next scheduled run (new process): the four failed addresses are tried last.
        $script:RuTrackerAddressMemory = @{}
        $r = Invoke-RuTrackerRouteCheck $key 'rutracker.org' 5000
        Assert ($r.Attempts -eq 1 -and @($r.AttemptAddresses)[0] -eq '127.0.0.6') "failed addresses not moved back between runs: $(@($r.AttemptAddresses) -join ',')"
        # A damaged or foreign file only loses the order.
        [IO.File]::WriteAllText($script:RuTrackerAddressFile, '{ not json')
        $script:RuTrackerAddressMemory = @{}
        $hints = Get-RuTrackerAddressHints $key
        Assert (@($hints.preferred).Count -eq 0 -and @($hints.avoid).Count -eq 0) 'damaged address file used'
        $old = [DateTimeOffset]::UtcNow
        $entries = @(
            @{ address = '127.0.0.6'; lastOk = $old.AddDays(-1).ToString('o'); lastFail = ''; failCode = ''; seen = $old.AddDays(-1).ToString('o') },
            @{ address = '127.0.0.7'; lastOk = $old.AddHours(-1).ToString('o'); lastFail = ''; failCode = ''; seen = $old.AddHours(-1).ToString('o') },
            @{ address = '127.0.0.8'; lastOk = ''; lastFail = $old.AddHours(-1).ToString('o'); failCode = 'Timeout'; seen = $old.AddHours(-1).ToString('o') },
            @{ address = '127.0.0.9'; lastOk = ''; lastFail = $old.AddHours(-8).ToString('o'); failCode = 'Timeout'; seen = $old.AddHours(-8).ToString('o') },
            @{ address = '127.0.0.10'; lastOk = $old.AddDays(-9).ToString('o'); lastFail = ''; failCode = ''; seen = $old.AddDays(-9).ToString('o') },
            @{ address = 'not-an-address'; lastOk = $old.ToString('o'); lastFail = ''; failCode = ''; seen = $old.ToString('o') })
        Save-AutoJson ([ordered]@{ version = 1; proxy = 'https://other.test:443'; addresses = $entries }) $script:RuTrackerAddressFile
        $script:RuTrackerAddressMemory = @{}
        Assert (@((Get-RuTrackerAddressHints $key).preferred).Count -eq 0) 'address file of another proxy used'
        Save-AutoJson ([ordered]@{ version = 1; proxy = $key; addresses = $entries }) $script:RuTrackerAddressFile
        $script:RuTrackerAddressMemory = @{}
        $hints = Get-RuTrackerAddressHints $key
        # .7 worked most recently, then .6; .8 failed an hour ago (last); .9 failed 8 h ago (unknown again);
        # .10 was not seen for 9 days (forgotten); an invalid entry is dropped.
        Assert ((@($hints.preferred) -join ',') -eq '127.0.0.7,127.0.0.6' -and (@($hints.avoid) -join ',') -eq '127.0.0.8') "learned order: $(@($hints.preferred) -join ',') / $(@($hints.avoid) -join ',')"
        $script:RuTrackerAddressFile = ''
        $script:RuTrackerAddressMemory = @{}

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
        $r = Invoke-RuTrackerRouteCheck ('https://failover.test:' + $w1.Port) 'rutracker.org' 8000
        Assert ($r.Ok -and $r.Attempts -eq 3 -and $r.Endpoint -eq ('127.0.0.1:' + $w1.Port)) "failover to the working address: $($r.Code)/$($r.Attempts)/$($r.Endpoint)"
        $r = Invoke-RuTrackerRouteCheck ('https://failover.test:' + $w1.Port) 'rutracker.org' 8000
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
        Assert ($r.Code -eq 'ProxyCertificateInvalid' -and $r.TlsErrors -match 'RemoteCertificateNameMismatch' -and $r.Attempts -eq 1 -and $n2.Connections -eq 0) "proxy certificate for another name: $($r.Code)/$($r.TlsErrors)/$($r.Attempts)"
        Assert ((Get-Seen $n1).proxy -eq '') 'CONNECT sent to a proxy with a certificate for another name'

        # --- 9 proxy addresses, the first three down: personal .torrent end to end, order kept between runs ---------
        $poolLeaf = $ca.IssueServer('pool.test')
        $torrentBytes = [IO.File]::ReadAllBytes($personal)
        $good = @{}
        $good['5'] = New-TlsProxy '127.0.0.5' 0 'ok' $poolLeaf $site
        $port9 = $good['5'].Port
        $null = New-TlsProxy '127.0.0.3' $port9 'close' $poolLeaf $site
        $null = New-TlsProxy '127.0.0.4' $port9 'site-garbage' $poolLeaf $site
        foreach ($n in 6..10) { $good[[string]$n] = New-TlsProxy ('127.0.0.' + $n) $port9 'ok' $poolLeaf $site }
        foreach ($server in $good.Values) { $server.Password = 'FAKE-PASSWORD-TLS-1'; $server.Torrent = $torrentBytes }
        Set-TestAddresses 'pool.test' @(2..10 | ForEach-Object { '127.0.0.' + $_ })
        $app9 = New-App $temp ('https://pool.test:' + $port9)
        $addressFile = Join-Path $app9 'rutracker-proxy-addresses.json'
        function Start-Run { $script:RuTrackerAddressMemory = @{}; Reset-RuTrackerRoute; Get-PersonalFiles | ForEach-Object { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $_.FullName } }
        function Get-Saved([string]$Address) { return @((Get-Content -LiteralPath $addressFile -Raw -Encoding UTF8 | ConvertFrom-Json).addresses | Where-Object address -eq $Address)[0] }
        $script:storedSession = ''
        Start-Run
        $result = Get-PersonalTorrent $app9 '6612345' $hash
        $route = $script:RuTrackerLastRoute
        Assert ($result.host -eq 'bt2.rutracker.cx' -and $route.Ok -and $route.Attempts -eq 4 -and $route.Endpoint -eq ('127.0.0.5:' + $port9)) "pool, first run: $($route.Code)/$($route.Attempts)/$($route.Endpoint)"
        Assert ([IO.File]::Exists($addressFile) -and (Get-Saved '127.0.0.5').lastOk -and (Get-Saved '127.0.0.2').lastFail -and (Get-Saved '127.0.0.4').failCode -eq 'TlsFailed') 'pool results not kept in rutracker-proxy-addresses.json'
        $seen = Get-Seen $good['5']
        Assert ($seen.site -match 'POST /forum/login\.php' -and $seen.site -match 'GET /forum/dl\.php' -and @($good.Values | Where-Object { $_ -ne $good['5'] -and $_.Connections -gt 0 }).Count -eq 0) 'login and download did not go straight to the working address'
        Assert-NoSecret ([IO.File]::ReadAllText($addressFile)) 'rutracker-proxy-addresses.json'
        # Next scheduled run (a new process, only the file is left): it starts with the last working address.
        Start-Run
        $null = Get-PersonalTorrent $app9 '6612345' $hash
        Assert ($script:RuTrackerLastRoute.Attempts -eq 1 -and $script:RuTrackerLastRoute.Endpoint -eq ('127.0.0.5:' + $port9)) "last working address not used first: $($script:RuTrackerLastRoute.Attempts)"
        # The working address goes away: the next run moves on to another one and remembers it; the run after that
        # starts there.
        $good['5'].Dispose()
        Start-Run
        $null = Get-PersonalTorrent $app9 '6612345' $hash
        $route = $script:RuTrackerLastRoute
        Assert ($route.Ok -and (@($route.AttemptAddresses) -join ',') -eq '127.0.0.5,127.0.0.6' -and (@($route.AttemptCodes) -join ',') -eq 'ProxyUnreachable,Ok') "recovery after the working address changed: $(@($route.AttemptAddresses) -join ',') / $(@($route.AttemptCodes) -join ',')"
        Start-Run
        $null = Get-PersonalTorrent $app9 '6612345' $hash
        Assert ($script:RuTrackerLastRoute.Attempts -eq 1 -and $script:RuTrackerLastRoute.Endpoint -eq ('127.0.0.6:' + $port9)) "new working address not remembered: $($script:RuTrackerLastRoute.Endpoint)"
        Assert ((Get-Saved '127.0.0.5').failCode -eq 'ProxyUnreachable' -and (Get-Saved '127.0.0.6').lastOk) 'address file not updated after the change'
        # Diagnostics: every address separately (15-RuTracker-connection.cmd); -Save makes it the starting order.
        $probe = @(Invoke-RuTrackerAddressProbe ('https://pool.test:' + $port9) 5000)
        $codes = @($probe | ForEach-Object { ([string]$_.Endpoint -split ':')[0] + '=' + $_.Code }) -join ','
        Assert ($probe.Count -eq 9 -and $codes -match '127\.0\.0\.2=ProxyUnreachable' -and $codes -match '127\.0\.0\.3=ProxyTlsFailed' -and $codes -match '127\.0\.0\.4=TlsFailed' -and $codes -match '127\.0\.0\.5=ProxyUnreachable' -and @($probe | Where-Object { $_.Ok }).Count -eq 5) "probe of every address: $codes"
        $diagnosed = Join-Path $temp 'diagnosed'
        $null = Microsoft.PowerShell.Management\New-Item -Path $diagnosed -ItemType Directory
        Save-RuTrackerAddressProbe $diagnosed ('https://pool.test:' + $port9) $probe
        $script:RuTrackerAddressMemory = @{}
        $hints = Get-RuTrackerAddressHints ('https://pool.test:' + $port9)
        Assert (@($hints.preferred).Count -eq 5 -and @($hints.avoid).Count -eq 4) "probe not saved as the starting order: $(@($hints.preferred).Count)/$(@($hints.avoid).Count)"
        $script:RuTrackerAddressFile = ''

        # PC test (Test-RuTrackerTls13.ps1): the wrong-name check uses the next working address that answers again.
        $n2 = New-TlsProxy '127.0.0.2' 0 'close' $proxyLeaf $site
        $null = New-TlsProxy '127.0.0.3' $n2.Port 'ok' $proxyLeaf $site
        $check = Invoke-WrongNameCheck 'proxy.test' @(('127.0.0.2:' + $n2.Port), ('127.0.0.3:' + $n2.Port)) $n2.Port $true 'rutracker.org' 4000
        Assert ($check.exitCode -eq 0 -and $check.text -match '^OK via 127\.0\.0\.3, refused \(TlsCertificateInvalid: certificate is not issued for example\.com') "PC test wrong-name check: $($check.exitCode)/$($check.text)"

        # --- A request is sent once: a broken answer after the request is never followed by another address -------
        $postLeaf = $ca.IssueServer('post.test')
        $d2 = New-TlsProxy '127.0.0.2' 0 'drop-after-request' $postLeaf $site
        $d3 = New-TlsProxy '127.0.0.3' $d2.Port 'ok' $postLeaf $site
        Set-TestAddresses 'post.test' @('127.0.0.2', '127.0.0.3')
        $send = [RuTrackerRoute]::Send('https', 'post.test', $d2.Port, 'POST', 'https://rutracker.org/forum/login.php', (New-Object Net.CookieContainer), 'application/x-www-form-urlencoded',
            [Text.Encoding]::ASCII.GetBytes('login_username=fake&login_password=FAKE-PASSWORD-TLS-1'), 'TorrentControl-test', 5000, 4000000)
        $seen = Get-Seen $d2
        Assert ($send.Status -eq 0 -and $send.Error -eq 'HttpUnexpected' -and (@($send.AttemptAddresses) -join ',') -eq '127.0.0.2' -and $d3.Connections -eq 0) "request repeated through another address: $($send.Error)/$(@($send.AttemptAddresses) -join ',')/$($d3.Connections)"
        Assert (([regex]::Matches($seen.site, 'POST /forum/login\.php')).Count -eq 1) 'POST sent more than once'
        "PASS trusted TLS: $script:AssertCount assertions"
        exit 0
    }
} finally {
    foreach ($server in $script:servers) { $server.Dispose() }
    $env:LOCALAPPDATA = $savedLocal
    Remove-TestDirectory $temp
}
"PASS Test-RuTrackerTls: $script:AssertCount assertions"
