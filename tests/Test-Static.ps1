. "$PSScriptRoot\TestCommon.ps1"
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scripts = @(Get-ChildItem -LiteralPath $repo -Filter '*.ps1') + @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1')

# --- Every script parses in this PowerShell (the CI runs this under Windows PowerShell 5.1 too) ------
foreach ($file in $scripts) {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert (@($errors).Count -eq 0) "parse errors in $($file.Name): $(@($errors | ForEach-Object { $_.Message }) -join '; ')"
    # Windows PowerShell 5.1 reads BOM-less scripts as ANSI and would corrupt 'D:\Фильмы'.
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0
    Assert ($hasBom -or !$nonAscii) "$($file.Name) contains non-ASCII text without a UTF-8 BOM"
}
foreach ($file in @(Get-ChildItem -LiteralPath $repo -Filter '*.cmd')) {
    Assert (@([IO.File]::ReadAllBytes($file.FullName) | Where-Object { $_ -gt 127 }).Count -eq 0) "$($file.Name) must stay ASCII"
}

# --- Production code never deletes data, changes client settings or acts on torrents via WebUI -------
# One exception, in TrackerMigration.ps1 only: reading a torrent's properties and replacing its tracker list.
$allowedWebUI = @{
    'TrackerMigration.ps1' = @("'&action=getprops&hash=' + `$Hash", "'&action=setprops&hash=' + `$Hash + '&s=trackers&v=' + [uri]::EscapeDataString(`$Trackers)")
}
foreach ($file in @(Get-ChildItem -LiteralPath $repo | Where-Object { $_.Extension -in @('.ps1', '.cs') })) {
    $text = [IO.File]::ReadAllText($file.FullName)
    if ($allowedWebUI.ContainsKey($file.Name)) {
        foreach ($allowed in $allowedWebUI[$file.Name]) {
            Assert (([regex]::Matches($text, [regex]::Escape($allowed))).Count -eq 1) "$($file.Name): expected exactly one '$allowed'"
            $text = $text.Replace($allowed, '')
        }
    }
    if ($file.Extension -eq '.ps1') { $text = [regex]::Replace($text, '(?m)^\s*#.*$', '') }   # whole-line comments may describe what is forbidden
    foreach ($pattern in @('Remove-Item', '::Delete\(', '\.Delete\(', 'removedata', 'setsetting', 'setprops', 'getprops', 'action=(?!getsettings\b)', 'Move-Item', 'recheck', 'setlabel')) {
        Assert ($text -notmatch $pattern) "$($file.Name) contains forbidden operation '$pattern'"
    }
}

# --- Cleanup remains a reporting-only module: no mutation or network calls. ----------------------
$cleanupText = [IO.File]::ReadAllText((Join-Path $repo 'Cleanup.ps1'))
foreach ($pattern in @('Invoke-WebRequest', 'Invoke-RestMethod', 'Start-Process', 'Fetch-List', 'New-Item', 'Save-AutoJson', 'Out-File', 'Copy-Item')) {
    Assert ($cleanupText -notmatch $pattern) "Cleanup.ps1 must not use '$pattern'"
}

# --- P0: personal RuTracker .torrent, secrets stay on this computer ----------------------------------
$production = @(Get-ChildItem -LiteralPath $repo | Where-Object { $_.Extension -in @('.ps1', '.cs', '.cmd') })
foreach ($file in $production) {
    $text = [IO.File]::ReadAllText($file.FullName)
    # Browser cookie stores are never read; the session comes only from the person's own login in Setup-RuTracker.ps1.
    foreach ($pattern in @('(?i)cookies\.sqlite', '(?i)Network\\Cookies', '(?i)Login Data', '(?i)\\User Data\\', '(?i)Mozilla\\Firefox', '(?i)ProtectedData\]::Unprotect')) {
        Assert ($text -notmatch $pattern) "$($file.Name) touches browser data: '$pattern'"
    }
    Assert ($text -notmatch 'api\.github\.com') "$($file.Name): the local client never writes to GitHub"
    if ($file.Name -ne 'RuTracker.ps1') {
        # PersonalImport.ps1 only shows the download link to the person (opened in Firefox), it never requests it.
        if ($file.Name -eq 'PersonalImport.ps1') { $text = $text.Replace("download = 'https://rutracker.org/forum/dl.php?t=' + `$Topic", '') }
        Assert ($text -notmatch "(?i)'Post'|-Method\s+Post|login\.php|dl\.php|login_password") "$($file.Name) talks to RuTracker outside RuTracker.ps1"
    }
}
foreach ($name in @('AutoLoad.ps1', 'TorrentMetadata.cs', 'TrackerMigration.ps1', 'Setup-RuTracker.ps1')) {
    # The public magnet announce is only recognised (RuTracker.ps1), never written into a torrent.
    $path = Join-Path $repo $name
    if (Test-Path -LiteralPath $path) { Assert ([IO.File]::ReadAllText($path) -notmatch 'ann\?magnet|https?://[^\s''"]*t-ru\.org') "$name contains the public announce" }
}
$ru = [IO.File]::ReadAllText((Join-Path $repo 'RuTracker.ps1'))
$hosts = @([regex]::Matches([regex]::Replace($ru, '(?m)^\s*#.*$', '').Replace('\.', '.'), 'https?://[A-Za-z0-9.-]+') | ForEach-Object { $_.Value } | Select-Object -Unique)
Assert (@($hosts | Where-Object { $_ -notin @('https://rutracker.org', 'http://bt.t-ru.org', 'https://static.rutracker.cc', 'https://ps1.blockme.site') }).Count -eq 0) "RuTracker.ps1 addresses: $($hosts -join ', ')"
Assert ($ru -match [regex]::Escape("Join-Path `$env:LOCALAPPDATA 'TorrentControl\personal'")) 'personal torrents must live in the Windows profile'
# Only confirmed RuTracker tracker domains count as personal; widening the list needs a real file as evidence.
Assert ($ru -match [regex]::Escape("`$script:RuTrackerTrackerDomains = @('t-ru.org', 'rutracker.cx', 'rutracker.org')")) 'RuTracker tracker domains changed without review'
Assert ($ru -match [regex]::Escape("`$script:NeutralTrackerHosts = @('retracker.local')")) 'neutral tracker list changed without review'
# --- Network access to RuTracker: only TorrentControl's own requests, nothing on the computer changes ---------
foreach ($file in $production) {
    $text = [regex]::Replace([IO.File]::ReadAllText($file.FullName), '(?m)^\s*#.*$', '')
    foreach ($pattern in @('(?i)Set-ItemProperty', '(?i)New-ItemProperty', '(?i)\bnetsh\b', '(?i)Set-DnsClient', '(?i)\broute(\.exe)?\s+(add|change|delete)',
        '(?i)Add-VpnConnection', '(?i)DefaultWebProxy\s*=', '(?i)\breg(\.exe)?\s+(add|delete)', '(?i)ServerCertificateValidationCallback', '(?i)SkipCertificateCheck',
        '(?i)CheckCertificateRevocationList', '(?i)AllowAutoRedirect\s*=\s*\$true', '(?i)(Start|Stop)-Process[^\r\n]*(hiddify|sing-?box)', 'http://rutracker')) {
        Assert ($text -notmatch $pattern) "$($file.Name) changes network settings or weakens TLS: '$pattern'"
    }
    if ($file.Name -eq 'Test-RuTrackerTls13.ps1') {
        # The PC test only records the errors Windows found, to tell a refused proxy certificate from a network error.
        Assert (([regex]::Matches($text, 'RemoteCertificateValidationCallback')).Count -eq 1 -and $text -match [regex]::Escape('return ($errors -eq [Net.Security.SslPolicyErrors]::None)')) "$($file.Name) relaxes certificate validation"
    } elseif ($file.Name -ne 'RuTrackerRoute.cs') {
        Assert ($text -notmatch 'RemoteCertificateValidationCallback|SslPolicyErrors') "$($file.Name) handles certificate validation"
    }
}
$route = [IO.File]::ReadAllText((Join-Path $repo 'RuTrackerRoute.cs'))
Assert (([regex]::Matches($route, 'new SslStream\(')).Count -eq 1 -and $route -match [regex]::Escape('{ seen = errors; return errors == SslPolicyErrors.None; }')) 'RuTrackerRoute.cs must accept only certificates without errors'
Assert ($route -match [regex]::Escape('"CONNECT " + host + ":" + port + " HTTP/1.1') -and $route -match [regex]::Escape('stream = AuthenticateProxy(stream, proxyHost);')) 'the route must use HTTP CONNECT and validate the certificate of an https proxy'
# TLS with the site only through RuTrackerTls13 (TLS 1.3 on Windows 10; chain + host name); Schannel only for the proxy.
Assert (([regex]::Matches($route, 'AuthenticateAsClient\(')).Count -eq 1 -and ([regex]::Matches($route, [regex]::Escape('RuTrackerTls13.Connect('))).Count -eq 1 -and
    $route -match [regex]::Escape('session = RuTrackerTls13.Connect(inner, host, host);')) 'TLS with the site must go through RuTrackerTls13 with the host as the expected name'
Assert (([regex]::Matches($route, 'return Secure\(')).Count -eq 2 -and $route -match [regex]::Escape('return Secure(Prepare(client, timeoutMs), host);') -and $route -match [regex]::Escape('return Secure(stream, host);')) 'every route (direct and proxy) must end in TLS with the site'
# Another proxy address only before the request and never after a refused certificate or a proxy password request.
$retry = [regex]::Match($route, '(?s)static bool MayTryAnotherAddress\(string code\) \{.*?\n        \}').Value
Assert ($retry -and $retry -notmatch 'CertificateInvalid|ProxyAuthRequired|Http' -and $retry -match '"ProxyTlsFailed":') 'proxy failover must stop at certificate and password failures'
# A certificate the callback refused is its own code (ProxyCertificateInvalid), never a network failure of the address.
Assert ($route -match [regex]::Escape('if (seen != SslPolicyErrors.None) { TlsErrors = seen.ToString(); throw new RuTrackerRouteFailure("ProxyCertificateInvalid"); }')) 'a refused proxy certificate must stop the search for another address'
foreach ($file in $production) { Assert ([IO.File]::ReadAllText($file.FullName) -notmatch 'TestAddresses' -or $file.Name -eq 'RuTrackerRoute.cs') "$($file.Name) sets test proxy addresses" }
Assert ($route -match [regex]::Escape('if (name.EndsWith(".test", StringComparison.OrdinalIgnoreCase)) {')) 'test addresses must stay limited to the reserved .test domain'
Assert ($route -match [regex]::Escape('WaitOne(Math.Min(timeoutMs, Math.Min(limitMs, MaxConnectMs)))') -and $ru -match '(?s)function Get-PersonalTorrent\(.*?\$script:RuTrackerDeadline = \[DateTime\]::UtcNow\.AddSeconds\(\$script:RuTrackerBudgetSeconds\).*?finally \{ \$script:RuTrackerDeadline = \$null \}') 'RuTracker requests must stay inside the 5-minute limit of the scheduled task'
# One monitor run stays inside the 5-minute limit of the scheduled task (Monitor.ps1 -Setup registers it).
$monitor = [IO.File]::ReadAllText((Join-Path $repo 'Monitor.ps1'))
$autoText = [IO.File]::ReadAllText((Join-Path $repo 'AutoLoad.ps1'))
Assert ($monitor -match [regex]::Escape('-ExecutionTimeLimit (New-TimeSpan -Minutes 5)') -and $autoText -match [regex]::Escape('$script:AutoRunLimitSeconds=300')) 'run limit and task limit differ'
Assert ($monitor -match '(?s)\} else \{.*?\$script:AutoRunDeadline = Get-AutoRunDeadline\s+Collect') 'a scheduled run must set the run limit before Collect'
Assert ($autoText -match '(?s)Test-AutoTimeLeft \$script:AutoItemSeconds.*?Test-AutoTimeLeft \$script:AutoRuTrackerMinSeconds.*?Get-PersonalTorrent') 'autoload must check the time left before a record and before RuTracker'
Assert ($ru -match [regex]::Escape('if ($null -ne $script:AutoRunDeadline -and $script:AutoRunDeadline -lt $script:RuTrackerDeadline) { $script:RuTrackerDeadline = $script:AutoRunDeadline }')) 'RuTracker must respect the run limit'
Assert ($route -match [regex]::Escape('guard = new Timer(Expire, null, 3L * timeoutMs, System.Threading.Timeout.Infinite);') -and $route -match [regex]::Escape('if (expired) return "Timeout";')) 'a request must end after 3 timeouts at the latest'
Assert ($ru -match [regex]::Escape('$script:RuTrackerBudgetSeconds = 120') -and ([regex]::Matches($ru, 'Get-RuTrackerTimeout ')).Count -ge 2) 'time budget not applied to every request'
Assert ($route -match '(?s)Stream ThroughProxy\(.*?return Secure\(stream, host\);\s*\}' -and $route -match [regex]::Escape('public const int MaxProxyAddresses = 16;') -and $route -match [regex]::Escape('const int MaxAttemptMs = 5000;') -and
    $route -match [regex]::Escape('if (i > 0 && watch.ElapsedMilliseconds + attemptMs > totalMs - timeoutMs) break;')) 'failover attempt must end before the request, bounded by the time of the request'
# The order of proxy addresses is learned by RuTracker.ps1 (rutracker-proxy-addresses.json), not fixed in code.
Assert ($ru -match [regex]::Escape("addresses = Join-Path `$Directory 'rutracker-proxy-addresses.json'") -and $ru -match [regex]::Escape('$hints.preferred, $hints.avoid)') -and $route -notmatch 'LastGood') 'proxy address order must come from the learned state'
Assert ([IO.File]::ReadAllText((Join-Path $repo '.gitignore')) -match '(?m)^rutracker-proxy-addresses\.json\s*$') 'rutracker-proxy-addresses.json is not in .gitignore'
Assert ($route -notmatch 'HttpWebRequest|HttpClient|WebClient|AllowAutoRedirect') 'RuTrackerRoute.cs is the only transport and never follows redirects'
Assert (([regex]::Matches($ru, [regex]::Escape('[RuTrackerRoute]::Send('))).Count -eq 1 -and $ru -notmatch 'Invoke-WebRequest|WebRequest\]::Create|HttpClient|Net\.WebProxy') 'RuTracker requests must go through RuTrackerRoute.cs only'
Assert ($ru -match '(?s)function Get-PersonalTorrent.*?Assert-RuTrackerRoute.*?Read-RuTrackerSessionText' -and $ru -match '(?s)function Invoke-RuTrackerLogin.*?Assert-RuTrackerRoute.*?login_password') 'route must be checked before a cookie or password is sent'
$diagnostics = [IO.File]::ReadAllText((Join-Path $repo 'Test-RuTrackerConnection.ps1'))
Assert ($diagnostics.Contains('. "$PSScriptRoot\AutoLoad.ps1"')) 'standalone RuTracker diagnostics must load atomic JSON writer for proxy address history'
foreach ($pattern in @('Read-RuTrackerCredential', 'Read-RuTrackerSessionText', 'Import-Clixml', 'Invoke-RuTrackerLogin', 'Get-PersonalTorrent', 'Invoke-RuTrackerHttp', 'Start-Process', 'Stop-Process', 'Set-Content', 'Out-File')) {
    Assert ($diagnostics -notmatch $pattern) "Test-RuTrackerConnection.ps1 must stay anonymous and read-only: '$pattern'"
}

# --- TLS 1.3 component: strict certificate validation, library loaded only from verified bytes ---------------
$tls13 = [IO.File]::ReadAllText((Join-Path $repo 'RuTrackerTls13.cs'))
foreach ($required in @('if (!x509.Build(leaf))', 'x509.ChainPolicy.VerificationFlags = X509VerificationFlags.NoFlag;', 'ApplicationPolicy.Add(new Oid("1.3.6.1.5.5.7.3.1"))',
    'throw new TlsFatalAlert(AlertDescription.bad_certificate);', 'if (!NameInCertificate(leafBytes, owner.ExpectedName))', 'CertificateCheck.Validate(serverCertificate == null ? null : serverCertificate.Certificate, owner)')) {
    Assert ($tls13.Contains($required)) "RuTrackerTls13.cs lost a validation step: $required"
}
Assert ($tls13 -notmatch 'AllowUnknownCertificateAuthority|IgnoreInvalidName|IgnoreNotTimeValid|IgnoreWrongUsage|X509VerificationFlags\.All|AllFlags|CustomTrustStore|TrustMode|ChainPolicy\.CustomTrust') 'RuTrackerTls13.cs relaxes certificate validation'
$loader = [IO.File]::ReadAllText((Join-Path $repo 'RuTrackerTls13.ps1'))
Assert ($loader -match [regex]::Escape("`$script:RuTrackerTransportSources = @('RuTrackerTls13.cs', 'RuTrackerRoute.cs')")) 'the transport must be compiled as one unit by RuTrackerTls13.ps1'
foreach ($file in @(Get-ChildItem -LiteralPath $repo -Filter '*.ps1')) {
    if ($file.Name -eq 'RuTrackerTls13.ps1') { continue }
    Assert ([IO.File]::ReadAllText($file.FullName) -notmatch 'Add-Type[^\r\n]*RuTracker(Route|Tls13)\.cs') "$($file.Name) loads the transport on its own"
}
Assert ($ru -match [regex]::Escape('. "$PSScriptRoot\RuTrackerTls13.ps1"') -and ([regex]::Matches($ru, 'Initialize-RuTrackerNet\r?\n')).Count -eq 3) 'RuTracker.ps1 must use the shared loader'
Assert ($loader -match [regex]::Escape('if ($hash -ne $entry.sha256) { throw ''TlsLibraryInvalid'' }') -and $loader -match [regex]::Escape('[Reflection.Assembly]::Load($bytes)') -and $loader -notmatch 'LoadFrom|LoadFile|UnsafeLoadFrom|Unblock-File') 'the TLS library must be loaded only from SHA-256-verified bytes'
$libFiles = @(Get-ChildItem -LiteralPath (Join-Path $repo 'lib') -Recurse -File | ForEach-Object { $_.FullName.Substring($repo.Length + 1).Replace('\', '/') } | Sort-Object)
Assert (($libFiles -join ',') -eq 'lib/bouncycastle/2.7.0/LICENSE.md,lib/bouncycastle/2.7.0/net461/BouncyCastle.Cryptography.dll,lib/bouncycastle/2.7.0/net6.0/BouncyCastle.Cryptography.dll,lib/bouncycastle/2.7.0/SOURCE.txt') "unexpected files in lib: $($libFiles -join ', ')"

# --- README: every PowerShell command block parses (the deployment blocks also run in Test-Deployment.ps1) ------
$readmeText = [IO.File]::ReadAllText((Join-Path $repo 'README.md'))
$blocks = @([regex]::Matches($readmeText, '(?s)```powershell\r?\n(.*?)\r?\n```'))
Assert ($blocks.Count -ge 5) "README PowerShell blocks: $($blocks.Count)"
foreach ($block in $blocks) {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($block.Groups[1].Value, [ref]$tokens, [ref]$errors)
    Assert (@($errors).Count -eq 0) "README command block does not parse: $(@($errors | ForEach-Object { $_.Message }) -join '; ')"
}
# --- Import of personal .torrent files and the Dry Run: offline, read-only for uTorrent and C:\TorrentMonitor -----
foreach ($name in @('PersonalImport.ps1', 'Import-PersonalTorrent.ps1', 'Test-PersonalMigration.ps1')) {
    $text = [regex]::Replace([IO.File]::ReadAllText((Join-Path $repo $name)), '(?m)^\s*#.*$', '')
    foreach ($pattern in @('Invoke-RuTrackerHttp', 'Invoke-RuTrackerRouteCheck', 'Read-RuTrackerCredential', 'Read-RuTrackerSessionText', 'Invoke-RuTrackerLogin',
        'Get-PersonalTorrent\s', 'setprops', 'Export-Clixml', 'Set-Content', 'Out-File', 'Add-Content', 'Save-AutoJson', 'Start-Process', 'Set-Acl', 'Invoke-WebRequest')) {
        Assert ($text -notmatch $pattern) "$name must stay offline and read-only: '$pattern'"
    }
    foreach ($write in [regex]::Matches($text, '\[IO\.File\]::Write\w+\(([^,]+)')) {
        Assert ($write.Groups[1].Value -match '^\(Join-Path \$(ReportDirectory|PSScriptRoot) ') "$name writes outside its report folder: $($write.Value)"
    }
}
$check = [IO.File]::ReadAllText((Join-Path $repo 'Test-PersonalMigration.ps1'))
Assert ($check -match [regex]::Escape("function Set-WebUITrackers { throw 'ReadOnlyViolation' }") -and $check -match [regex]::Escape("function Invoke-TrackerMigration { throw 'ReadOnlyViolation' }")) 'the Dry Run must disable the changing migration functions'
Assert ($ru -match '(?s)function Get-PersonalTorrent\(.*?Get-ImportedPersonalTorrent.*?Resolve-RuTrackerProxy.*?Read-RuTrackerCredential.*?Assert-RuTrackerRoute') 'a verified local file must be used before any network step'
Assert ($ru -match '(?s)function Save-PersonalTorrentBytes.*?Test-PersonalTorrent \$temp.*?Replace\(\$temp, \$final') 'a personal file must be verified before it replaces the stored one'
foreach ($file in $production) {
    if ($file.Name -ne 'RuTracker.ps1') { Assert ([IO.File]::ReadAllText($file.FullName) -notmatch 'Set-Acl') "$($file.Name) changes permissions" }
}
Assert (([regex]::Matches($ru, 'Set-Acl')).Count -eq 1 -and $ru -match '(?s)function Protect-PersonalTorrentDirectory.*?Set-Acl -LiteralPath \$Folder') 'permissions are changed only for the personal folder'

# Raw exception texts (which could quote a URL with a key) are never written to the console, logs or reports.
foreach ($file in @(Get-ChildItem -LiteralPath $repo -Filter '*.ps1')) {
    foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
        if ($line -match 'Exception\.Message' -and $line -match 'Write-Host|Write-Output|Add-Content|Set-Content|Out-File|ConvertTo-Html') {
            Assert $false "$($file.Name) writes a raw exception message: $($line.Trim())"
        }
    }
}
$ignored = [IO.File]::ReadAllText((Join-Path $repo '.gitignore'))
foreach ($name in @('rutracker-credential.xml', 'rutracker-session.xml', 'rutracker-state.json', 'tracker-migration.json', 'tracker-migration.html', 'tracker-migration.csv', 'credential.xml')) {
    Assert ($ignored -match ('(?m)^' + [regex]::Escape($name) + '\s*$')) "$name is not in .gitignore"
}
# The GitHub side (Actions, cache, feed) never logs in to RuTracker or handles personal files.
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $repo 'scripts') -File) + @(Get-ChildItem -LiteralPath (Join-Path $repo '.github\workflows') -File)) {
    Assert ([IO.File]::ReadAllText($file.FullName) -notmatch '(?i)login\.php|dl\.php|bb_session|login_password|passkey|personal') "$($file.Name) handles RuTracker accounts"
}

# --- C# helpers compile with this runtime's compiler (C# 5 under Windows PowerShell 5.1) -----------
foreach ($type in @('ResumePaths', 'TorrentMetadata')) {
    if (!($type -as [type])) { Add-Type -Path (Join-Path $repo "$type.cs") }
    Assert ($type -as [type]) "$type did not compile"
}
. (Join-Path $repo 'RuTrackerTls13.ps1')
Initialize-RuTrackerTransport 3>$null
Assert (('RuTrackerRoute' -as [type]) -and ('RuTrackerTls13' -as [type])) 'the RuTracker transport did not compile'

function Write-Bencode($Stream, $Value) {
    if ($Value -is [byte[]]) {
        $head = [Text.Encoding]::ASCII.GetBytes("$($Value.Length):"); $Stream.Write($head, 0, $head.Length); $Stream.Write($Value, 0, $Value.Length); return
    }
    if ($Value -is [string]) { Write-Bencode $Stream ([Text.Encoding]::UTF8.GetBytes($Value)); return }
    if ($Value -is [int] -or $Value -is [long]) { $b = [Text.Encoding]::ASCII.GetBytes("i$($Value)e"); $Stream.Write($b, 0, $b.Length); return }
    if ($Value -is [Collections.IDictionary]) {
        $Stream.WriteByte(100); foreach ($key in @($Value.Keys)) { Write-Bencode $Stream ([string]$key); Write-Bencode $Stream $Value[$key] }; $Stream.WriteByte(101); return
    }
    if ($Value -is [Collections.IList]) { $Stream.WriteByte(108); foreach ($item in $Value) { Write-Bencode $Stream $item }; $Stream.WriteByte(101); return }
    throw 'Unsupported bencode value'
}
function ConvertTo-Bencode($Value) { $ms = New-Object IO.MemoryStream; Write-Bencode $ms $Value; return ,$ms.ToArray() }
function ConvertFrom-Hex([string]$Hex) { return ,[byte[]]@(for ($i = 0; $i -lt $Hex.Length; $i += 2) { [Convert]::ToByte($Hex.Substring($i, 2), 16) }) }
function Get-Sha1Hex([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA1]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '') } finally { $sha.Dispose() }
}

$temp = New-TestDirectory
try {
    # --- resume.dat reader (read-only) -------------------------------------------------------------
    $hA = 'A' * 40; $hB = 'B' * 40; $hC = 'C' * 40
    $resume = [ordered]@{
        '.fileguard' = 'ignored'
        'a.torrent' = [ordered]@{ info = (ConvertFrom-Hex $hA); path = 'D:\Хранитель\Фильм' }
        'b.torrent' = [ordered]@{ info = (ConvertFrom-Hex $hB); path = 'F:\B' }
        'b2.torrent' = [ordered]@{ info = (ConvertFrom-Hex $hB); path = 'F:\Other' }
        'c.torrent' = [ordered]@{ info = (ConvertFrom-Hex $hC) }
    }
    $file = Join-Path $temp 'resume.dat'
    [IO.File]::WriteAllBytes($file, (ConvertTo-Bencode $resume))
    $written = [IO.File]::GetLastWriteTimeUtc($file)
    $map = [ResumePaths]::Load($file)
    Assert ($map[$hA] -eq 'D:\Хранитель\Фильм') 'UTF-8 path from resume.dat'
    Assert (!$map.ContainsKey($hB)) 'conflicting paths must be dropped'
    Assert (!$map.ContainsKey($hC)) 'entry without path ignored'
    Assert ($map.ContainsKey($hA.ToLowerInvariant())) 'hash lookup is case-insensitive'
    Assert ([IO.File]::GetLastWriteTimeUtc($file) -eq $written) 'resume.dat must not be modified'
    [IO.File]::WriteAllBytes($file, [Text.Encoding]::ASCII.GetBytes('d9:a.torrentd4:info'))
    Assert-Throws { [ResumePaths]::Load($file) } $null 'truncated resume.dat must fail, not return a partial map'

    # --- Torrent metadata validation ------------------------------------------------------------------
    $fixture = Join-Path $temp 'fixture.torrent'
    [IO.File]::WriteAllBytes($fixture, [Convert]::FromBase64String('ZDQ6aW5mb2Q2Omxlbmd0aGk1OGU0Om5hbWUyODpUb3JyZW50Q29udHJvbC1wYXRoLXRlc3QudHh0MTI6cGllY2UgbGVuZ3RoaTE2Mzg0ZTY6cGllY2VzMjA6fif7fCP8oPWUPlhooe+04CEImto3OnByaXZhdGVpMWVlZQ=='))
    Assert ([TorrentMetadata]::Verify($fixture, '51CE70C03EC2FBF311F03C4B6570951C3CF28F3A') -eq 58) 'fixture size'
    Assert-Throws { [TorrentMetadata]::Verify($fixture, ('0' * 40)) } $null 'infohash mismatch accepted'
    # P0: the client never rewrites trackers (the old Sanitize put the public magnet announce into every file).
    Assert ($null -eq [TorrentMetadata].GetMethod('Sanitize')) 'tracker rewriting is back'
    Assert (@([TorrentMetadata]::ReadTrackers($fixture)).Count -eq 0) 'fixture has no trackers'
    $personalFile = Join-Path $temp 'personal.torrent'
    $tiers = @(@('http://bt4.rutracker.cc/ann?kk=FAKE01'), @('http://retracker.local/announce', 'http://bt4.rutracker.cc/ann?kk=FAKE01'))
    $fileBytes = ConvertTo-Bencode ([ordered]@{ announce = 'http://bt4.rutracker.cc/ann?kk=FAKE01'; 'announce-list' = @(foreach ($t in $tiers) { ,@($t) }); info = $good0 = [ordered]@{ length = 5; name = 'f.mkv'; 'piece length' = 16384; pieces = (New-Object byte[] 20) } })
    [IO.File]::WriteAllBytes($personalFile, $fileBytes)
    $read = @([TorrentMetadata]::ReadTrackers($personalFile))
    Assert ($read.Count -eq 2 -and $read[1].Count -eq 2 -and $read[1][1] -eq 'http://bt4.rutracker.cc/ann?kk=FAKE01') 'announce-list tiers read as stored'
    Assert ((Get-Sha1Hex ([IO.File]::ReadAllBytes($personalFile))) -eq (Get-Sha1Hex $fileBytes)) 'reading trackers changed the file'
    [IO.File]::WriteAllBytes($personalFile, (ConvertTo-Bencode ([ordered]@{ announce = 'http://bt2.rutracker.cx/ann?kk=FAKE01'; info = $good0 })))
    Assert (@([TorrentMetadata]::ReadTrackers($personalFile))[0][0] -eq 'http://bt2.rutracker.cx/ann?kk=FAKE01') 'announce without announce-list'
    [IO.File]::WriteAllBytes($personalFile, (ConvertTo-Bencode ([ordered]@{ announce = "http://bt2.rutracker.cx/ann?kk=FAKE`n01"; info = $good0 })))
    Assert-Throws { [TorrentMetadata]::ReadTrackers($personalFile) } $null 'tracker with a control character accepted'
    $cases = @(
        @{ why = 'executable payload'; info = [ordered]@{ length = 5; name = 'film.exe'; 'piece length' = 16384; pieces = (New-Object byte[] 20) } },
        @{ why = 'parent directory component'; info = [ordered]@{ files = @([ordered]@{ length = 5; path = @('..', 'x.mkv') }); name = 'Film'; 'piece length' = 16384; pieces = (New-Object byte[] 20) } },
        @{ why = 'reserved device name'; info = [ordered]@{ files = @([ordered]@{ length = 5; path = @('CON.mkv') }); name = 'Film'; 'piece length' = 16384; pieces = (New-Object byte[] 20) } },
        @{ why = 'file/directory collision'; windowsOnly = $true; info = [ordered]@{ files = @([ordered]@{ length = 5; path = @('a') }, [ordered]@{ length = 5; path = @('a', 'b.mkv') }); name = 'Film'; 'piece length' = 16384; pieces = (New-Object byte[] 20) } },
        @{ why = 'symlink'; info = [ordered]@{ attr = 'l'; length = 5; name = 'film.mkv'; 'piece length' = 16384; pieces = (New-Object byte[] 20) } }
    )
    foreach ($case in $cases) {
        # TorrentMetadata.cs builds Windows paths with '\'; .NET on Linux does not split them.
        if ($case.windowsOnly -and !$script:OnWindows) { continue }
        $infoBytes = ConvertTo-Bencode $case.info
        $path = Join-Path $temp 'case.torrent'
        [IO.File]::WriteAllBytes($path, (ConvertTo-Bencode ([ordered]@{ announce = 'http://evil.example/'; info = $case.info })))
        Assert-Throws { [TorrentMetadata]::Verify($path, (Get-Sha1Hex $infoBytes)) } $null "$($case.why) accepted"
    }
    $good = [ordered]@{ files = @([ordered]@{ length = 7; path = @('Film.mkv') }, [ordered]@{ length = 3; path = @('Subs', 'ru.srt') }); name = 'Фильм'; 'piece length' = 16384; pieces = (New-Object byte[] 20) }
    $path = Join-Path $temp 'good.torrent'
    [IO.File]::WriteAllBytes($path, (ConvertTo-Bencode ([ordered]@{ info = $good })))
    Assert ([TorrentMetadata]::Verify($path, (Get-Sha1Hex (ConvertTo-Bencode $good))) -eq 10) 'valid multi-file torrent'
} finally { Remove-TestDirectory $temp }
"PASS Test-Static: $script:AssertCount assertions"
