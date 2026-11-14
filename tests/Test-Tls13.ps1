. "$PSScriptRoot\TestCommon.ps1"
. "$PSScriptRoot\..\RuTrackerTls13.ps1"
if (!('FakeProxy' -as [type])) { Add-Type -Path "$PSScriptRoot\FakeProxy.cs" }
# TLS 1.3 component (RuTrackerTls13.cs + pinned BouncyCastle). Offline: only fake servers on 127.0.0.1.
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Initialize-RuTrackerTls13 3>$null
Assert ('RuTrackerTls13' -as [type]) 'TLS 1.3 component did not compile with the pinned library'

# --- Pinned library: constants = SOURCE.txt = the files ----------------------------------------------------
$source = [IO.File]::ReadAllText((Join-Path $repo 'lib\bouncycastle\2.7.0\SOURCE.txt'))
foreach ($edition in @('Desktop', 'Core')) {
    $entry = $script:RuTrackerTls13Library[$edition]
    $bytes = [IO.File]::ReadAllBytes((Join-Path $repo $entry.path))
    Assert ((Get-TestSha256 $bytes) -eq $entry.sha256) "$edition library differs from the pinned SHA-256"
    Assert ($source -match $entry.sha256.ToLowerInvariant()) "$edition SHA-256 not documented in SOURCE.txt"
}
# A replaced or missing library is never loaded (fresh process: the types of this one are already loaded).
$exe = (Get-Process -Id $PID).Path
foreach ($case in @(@('replaced', 'TlsLibraryInvalid'), @('missing', 'TlsLibraryMissing'))) {
    $copy = Join-Path $PSScriptRoot ('autoload-test-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = Microsoft.PowerShell.Management\New-Item -Path $copy -ItemType Directory
        foreach ($name in @('RuTrackerTls13.ps1', 'RuTrackerTls13.cs')) { Microsoft.PowerShell.Management\Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $copy }
        if ($case[0] -eq 'replaced') {
            foreach ($edition in @('net461', 'net6.0')) {
                $dir = Join-Path $copy "lib\bouncycastle\2.7.0\$edition"
                $null = Microsoft.PowerShell.Management\New-Item -Path $dir -ItemType Directory -Force
                $bytes = [IO.File]::ReadAllBytes((Join-Path $repo "lib\bouncycastle\2.7.0\$edition\BouncyCastle.Cryptography.dll"))
                $bytes[$bytes.Length - 100] = $bytes[$bytes.Length - 100] -bxor 0xFF
                [IO.File]::WriteAllBytes((Join-Path $dir 'BouncyCastle.Cryptography.dll'), $bytes)
            }
        }
        $script = Join-Path $copy 'RuTrackerTls13.ps1'
        $out = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ". '$script'; try { Initialize-RuTrackerTls13 3>`$null; 'LOADED' } catch { `$_.Exception.Message }" 2>&1 | Out-String
        Assert ($out.Trim() -eq $case[1]) "$($case[0]) library: '$($out.Trim())'"
    } finally { Remove-TestDirectory $copy }
}

# --- Host name rules ----------------------------------------------------------------------------------------
$names = @(
    @('rutracker.org', 'rutracker.org', $true), @('RuTracker.ORG', 'rutracker.org', $true), @('rutracker.org.', 'rutracker.org', $true),
    @('*.rutracker.org', 'static.rutracker.org', $true), @('*.rutracker.org', 'rutracker.org', $false), @('*.rutracker.org', 'a.b.rutracker.org', $false),
    @('*.org', 'rutracker.org', $false), @('*', 'rutracker.org', $false), @('r*.org', 'rutracker.org', $false), @('*.*.org', 'a.b.org', $false),
    @('rutracker.org', 'rutracker.org.evil.example', $false), @('rutracker.org', 'xrutracker.org', $false), @('', 'rutracker.org', $false))
foreach ($n in $names) { Assert ([RuTrackerTls13]::NameMatches($n[0], $n[1]) -eq $n[2]) "name rule '$($n[0])' vs '$($n[1])'" }

# --- Failures are fixed codes and never hang -----------------------------------------------------------------
function Connect-Fake([string]$Mode, [int]$TimeoutMs) {
    $server = New-Object FakeProxy($Mode)
    $client = New-Object Net.Sockets.TcpClient('127.0.0.1', $server.Port)
    try {
        $stream = $client.GetStream(); $stream.ReadTimeout = $TimeoutMs; $stream.WriteTimeout = $TimeoutMs
        $started = [DateTime]::UtcNow
        try { $null = [RuTrackerTls13]::Connect($stream, 'rutracker.org', 'rutracker.org'); return 'ACCEPTED' }
        catch {
            $e = $_.Exception; while ($null -ne $e -and $e -isnot [RuTrackerTls13Failure]) { $e = $e.InnerException }
            Assert (([DateTime]::UtcNow - $started).TotalSeconds -lt 20) "$Mode took too long"
            if ($null -eq $e) { return $_.Exception.GetType().Name }
            return $e.Code
        }
    } finally { $client.Close(); $server.Dispose() }
}
Assert ((Connect-Fake 'tls-garbage' 5000) -eq 'TlsFailed') 'non-TLS answer not reported as TlsFailed'
Assert ((Connect-Fake 'silent' 1500) -in @('Timeout', 'TlsFailed')) 'silent server not stopped by the timeout'
"PASS Test-Tls13: $script:AssertCount assertions"
