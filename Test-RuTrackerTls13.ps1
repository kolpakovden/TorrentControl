param([string]$Proxy = 'https://ps1.blockme.site:443', [string]$Target = 'rutracker.org', [int]$TimeoutSec = 15, [switch]$ByName)
# Full anonymous test of the TLS 1.3 route before it is used by TorrentControl (diagnostic, changes nothing).
# For every IPv4 address of the proxy (or the name only with -ByName):
#   TCP -> TLS to the proxy (Windows Schannel, certificate validated for the proxy NAME) -> CONNECT target:443 ->
#   TLS 1.3 to the target (RuTrackerTls13.cs / BouncyCastle 2.7.0 with pinned SHA-256; certificate chain validated by
#   Windows X509Chain against this computer's trusted roots, serverAuth usage and dates, plus the host name) ->
#   anonymous "GET /forum/index.php" (no login, no cookie): only the status line is read.
# Then a mandatory negative check on the real certificate: the same handshake expecting another name MUST be refused.
# It is done through the first working address that answers again; if none does, the report says NOT CHECKED.
# For the TLS to the proxy a refused certificate (its SslPolicyErrors) is told apart from a network failure.
# Exit codes: 0 = at least one address works and the wrong name was refused; 2 = no address works; 3 = a wrong name was
# ACCEPTED (validation broken); 4 = addresses work, but the negative check could not be done; 1 = the test stopped.
# The report (addresses, versions, certificate names, codes - no secrets) goes to rutracker-tls13-test.txt here.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\RuTrackerTls13.ps1"

function Open-Tunnel([string]$ProxyHost, [string]$Address, [int]$Port, [bool]$ProxyTls, [string]$Target, [int]$TimeoutMs) {
    $state = [ordered]@{ client = $null; stream = $null; address = ''; proxyTls = ''; connect = ''; failure = '' }
    $client = New-Object Net.Sockets.TcpClient
    $state.client = $client
    $endpoint = $ProxyHost; if ($Address) { $endpoint = $Address }
    $pending = $client.BeginConnect($endpoint, $Port, $null, $null)
    if (!$pending.AsyncWaitHandle.WaitOne($TimeoutMs)) { $state.failure = 'no TCP connection to the proxy'; return [pscustomobject]$state }
    try { $client.EndConnect($pending) } catch { $state.failure = 'TCP to the proxy refused'; return [pscustomobject]$state }
    $state.address = [string]$client.Client.RemoteEndPoint
    $client.ReceiveTimeout = $TimeoutMs; $client.SendTimeout = $TimeoutMs
    $network = $client.GetStream(); $network.ReadTimeout = $TimeoutMs; $network.WriteTimeout = $TimeoutMs
    $stream = $network
    if ($ProxyTls) {
        # Windows validates the proxy certificate for the proxy NAME; the callback only records what it found.
        $script:seenProxyErrors = [Net.Security.SslPolicyErrors]::None
        $callback = [Net.Security.RemoteCertificateValidationCallback] { param($s, $c, $ch, $errors) $script:seenProxyErrors = $errors; return ($errors -eq [Net.Security.SslPolicyErrors]::None) }
        $outer = New-Object Net.Security.SslStream($network, $false, $callback)
        try { $outer.AuthenticateAsClient($ProxyHost) }
        catch {
            if ($script:seenProxyErrors -ne [Net.Security.SslPolicyErrors]::None) { $state.failure = 'certificate of the proxy REJECTED (' + $script:seenProxyErrors + ')' }
            elseif (Test-TimeoutError $_.Exception) { $state.failure = 'TLS to the proxy: no answer (timeout), certificate not involved' }
            else { $state.failure = 'TLS to the proxy broke off (network/protocol, ' + (Get-ExceptionChain $_.Exception) + '), certificate not involved' }
            return [pscustomobject]$state
        }
        $state.proxyTls = [string]$outer.SslProtocol
        $stream = $outer
    }
    $ask = [Text.Encoding]::ASCII.GetBytes("CONNECT $($Target):443 HTTP/1.1`r`nHost: $($Target):443`r`nUser-Agent: TorrentControl-tls13-test`r`n`r`n")
    $stream.Write($ask, 0, $ask.Length); $stream.Flush()
    $head = New-Object Text.StringBuilder
    while ($head.Length -lt 16384) {
        $b = $stream.ReadByte(); if ($b -lt 0) { break }
        [void]$head.Append([char]$b)
        if ($head.Length -ge 4 -and $head.ToString($head.Length - 4, 4) -eq "`r`n`r`n") { break }
    }
    $text = $head.ToString()
    $state.connect = if ($text.Length -ge 12) { $text.Substring(9, 3) } else { 'none' }
    if ($state.connect -ne '200') { $state.failure = 'CONNECT answer ' + $state.connect; return [pscustomobject]$state }
    $state.stream = $stream
    return [pscustomobject]$state
}
function Test-TimeoutError($Exception) {
    for ($e = $Exception; $null -ne $e; $e = $e.InnerException) {
        if ($e -is [TimeoutException]) { return $true }
        if ($e -is [Net.Sockets.SocketException] -and [string]$e.SocketErrorCode -eq 'TimedOut') { return $true }
    }
    return $false
}
function Get-ExceptionChain($Exception) {
    $names = @(); for ($e = $Exception; $null -ne $e; $e = $e.InnerException) { $names += $e.GetType().Name }
    return ($names -join ' <- ')
}
function Invoke-WrongNameCheck([string]$ProxyHost, [string[]]$Working, [int]$Port, [bool]$ProxyTls, [string]$Target, [int]$TimeoutMs) {
    # The certificate of the target, received through a working proxy address, must be REFUSED for another name.
    # Every working address is tried in turn until one answers again; the result names the address used. Without
    # any working address, or if none answers again, the check is reported as NOT CHECKED (exit code 4), never as OK.
    if (!@($Working).Count) { return [pscustomobject]@{ text = 'NOT CHECKED: no address works'; exitCode = 0 } }
    $notes = @()
    foreach ($endpoint in @($Working)) {
        $address = ($endpoint -split ':')[0]
        $tunnel = Open-Tunnel $ProxyHost $address $Port $ProxyTls $Target $TimeoutMs
        try {
            if ($tunnel.failure) { $notes += ($address + ': ' + $tunnel.failure); continue }
            $handshake = $null
            try { $s = [RuTrackerTls13]::Connect($tunnel.stream, $Target, 'example.com'); $s.Dispose(); $handshake = 'ACCEPTED' }
            catch { $handshake = Get-Tls13Failure $_ }
            if ($handshake -eq 'ACCEPTED') { return [pscustomobject]@{ text = 'VALIDATION FAILED via ' + $address + ': a certificate of ' + $Target + ' was accepted for example.com'; exitCode = 3 } }
            if ($handshake -match '^TlsCertificateInvalid: ') { return [pscustomobject]@{ text = 'OK via ' + $address + ', refused (' + $handshake + ')'; exitCode = 0 } }
            $notes += ($address + ': handshake did not reach the certificate (' + $handshake + ')')
        } finally { if ($tunnel.client) { $tunnel.client.Close() } }
    }
    return [pscustomobject]@{ text = 'NOT CHECKED: none of the ' + @($Working).Count + ' working addresses answered again (' + ($notes -join '; ') + ')'; exitCode = 4 }
}
function Get-Tls13Failure($ErrorRecord) {
    $e = $ErrorRecord.Exception
    while ($null -ne $e -and $e -isnot [RuTrackerTls13Failure]) { $e = $e.InnerException }
    if ($null -ne $e) { return ($e.Code + ': ' + $e.Detail) }
    return $ErrorRecord.Exception.GetType().Name
}

if ($MyInvocation.InvocationName -ne '.') {
    $report = New-Object Collections.Generic.List[string]
    $exitCode = 0
    try {
        Initialize-RuTrackerTransport 3>$null
        $uri = [Uri]$Proxy
        if ($uri.Scheme -notin @('http', 'https') -or $uri.UserInfo) { throw 'ProxyInvalid' }
        $timeout = [math]::Max(3, $TimeoutSec) * 1000
        $report.Add('TorrentControl TLS 1.3 route test ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' - proxy ' + $uri.Host + ':' + $uri.Port + ', target ' + $Target)
        $report.Add('Windows ' + [Environment]::OSVersion.Version + ', PowerShell ' + $PSVersionTable.PSVersion + '; TLS 1.3 by BouncyCastle 2.7.0 (SHA-256 verified); anonymous, no login, no cookie.')
        $addresses = @('')
        if (!$ByName) {
            try { $addresses = @([Net.Dns]::GetHostAddresses($uri.Host) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.ToString() } | Select-Object -First 16) } catch { $addresses = @('') }
            if (!$addresses.Count) { $addresses = @('') }
        }
        $working = New-Object Collections.Generic.List[string]
        foreach ($address in $addresses) {
            $started = [DateTime]::UtcNow
            $tunnel = Open-Tunnel $uri.Host $address $uri.Port ($uri.Scheme -eq 'https') $Target $timeout
            $line = '{0,-20} proxy TLS {1,-6} CONNECT {2,-4} ' -f $tunnel.address, $tunnel.proxyTls, $tunnel.connect
            try {
                if ($tunnel.failure) { $line += 'FAILED: ' + $tunnel.failure; continue }
                $session = $null
                try { $session = [RuTrackerTls13]::Connect($tunnel.stream, $Target, $Target) }
                catch { $line += 'TLS to ' + $Target + ' FAILED: ' + (Get-Tls13Failure $_); continue }
                try {
                    $request = [Text.Encoding]::ASCII.GetBytes("GET /forum/index.php HTTP/1.1`r`nHost: $Target`r`nUser-Agent: TorrentControl-tls13-test`r`nAccept: text/html`r`nAccept-Encoding: identity`r`nConnection: close`r`n`r`n")
                    $session.Stream.Write($request, 0, $request.Length); $session.Stream.Flush()
                    $status = New-Object Text.StringBuilder
                    while ($status.Length -lt 200) { $b = $session.Stream.ReadByte(); if ($b -lt 0 -or $b -eq 10) { break }; if ($b -ne 13) { [void]$status.Append([char]$b) } }
                    $line += $session.Version + ' ' + $session.CipherSuite + ' ALPN ' + $session.Alpn + '; certificate ' + $session.Subject + ' / issuer ' + $session.Issuer + ' / until ' + $session.NotAfter + '; GET -> ' + $status.ToString()
                    if ($status.ToString() -match '^HTTP/1\.[01] [23]\d\d') { $working.Add($tunnel.address) }
                } catch { $line += 'TLS OK, but the request failed: ' + $_.Exception.GetType().Name }
                finally { $session.Dispose() }
            } finally {
                if ($tunnel.client) { $tunnel.client.Close() }
                $report.Add($line + ' [' + [int]([DateTime]::UtcNow - $started).TotalMilliseconds + ' ms]')
            }
        }
        # Mandatory negative check on the real certificate (Invoke-WrongNameCheck).
        $check = Invoke-WrongNameCheck $uri.Host @($working) $uri.Port ($uri.Scheme -eq 'https') $Target $timeout
        $negative = $check.text
        if ($check.exitCode -gt 0 -and ($exitCode -eq 0 -or $check.exitCode -eq 3)) { $exitCode = $check.exitCode }
        $report.Add('Check that a wrong name is refused: ' + $negative)
        $report.Add('RESULT: ' + $working.Count + ' of ' + $addresses.Count + ' proxy addresses give a validated TLS 1.3 connection to ' + $Target + ' with an HTTP answer.')
        if (!$working.Count -and $exitCode -eq 0) { $exitCode = 2 }
    } catch {
        $code = [string]$_.Exception.Message
        if ($code -notmatch '^[A-Za-z]+$') { $code = $_.Exception.GetType().Name }
        $report.Add('Test stopped: ' + $code)
        $exitCode = 1
    }
    foreach ($line in $report) { Write-Host $line }
    [IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'rutracker-tls13-test.txt'), [string[]]$report, (New-Object Text.UTF8Encoding($true)))
    Write-Host ('Saved: ' + (Join-Path $PSScriptRoot 'rutracker-tls13-test.txt'))
    exit $exitCode
}
