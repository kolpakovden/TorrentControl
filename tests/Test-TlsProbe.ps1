. "$PSScriptRoot\TestCommon.ps1"
. "$PSScriptRoot\..\Probe-RuTrackerTls.ps1"
# Offline checks of the diagnostic probe: well-formed hand-built ClientHello messages and correct reading of answers.
function Get-Extensions([byte[]]$Record) {
    # [int] casts: in PowerShell -shl on a [byte] stays a byte.
    # record(5) handshake(4) version(2) random(32) session(1+32) ciphers(2+n) compression(2) extensions(2+n)
    $p = 5 + 4 + 2 + 32
    $p += 1 + $Record[$p]
    $p += 2 + (([int]$Record[$p] -shl 8) -bor $Record[$p + 1])
    $p += 1 + $Record[$p]
    $end = $p + 2 + (([int]$Record[$p] -shl 8) -bor $Record[$p + 1]); $p += 2
    $types = New-Object Collections.Generic.List[int]
    while ($p + 4 -le $end) { $types.Add((([int]$Record[$p] -shl 8) -bor $Record[$p + 1])); $p += 4 + (([int]$Record[$p + 2] -shl 8) -bor $Record[$p + 3]) }
    Assert ($p -eq $end -and $end -eq $Record.Length) 'extension lengths inconsistent'
    return ,$types.ToArray()
}
foreach ($variant in @('tls13-alpn', 'tls13-noalpn', 'tls12-only', 'tls13-nosni')) {
    $hello = [TlsProbe]::BuildClientHello($variant, 'rutracker.org')
    Assert ($hello[0] -eq 0x16 -and ((([int]$hello[3] -shl 8) -bor $hello[4]) + 5) -eq $hello.Length -and $hello[5] -eq 1) "$variant record framing"
    Assert (((([int]$hello[6] -shl 16) -bor ([int]$hello[7] -shl 8) -bor $hello[8]) + 9) -eq $hello.Length) "$variant handshake length"
    $types = Get-Extensions $hello
    Assert (($types -contains 0) -eq ($variant -ne 'tls13-nosni')) "$variant SNI"
    Assert (($types -contains 0x2B) -eq $variant.StartsWith('tls13')) "$variant supported_versions"
    Assert (($types -contains 0x10) -eq ($variant -ne 'tls13-noalpn')) "$variant ALPN"
    Assert ([Text.Encoding]::ASCII.GetString($hello) -match 'rutracker\.org' -eq ($variant -ne 'tls13-nosni')) "$variant server name bytes"
}
function Bytes([string]$Hex) { return ,[byte[]]@(for ($i = 0; $i -lt $Hex.Length; $i += 2) { [Convert]::ToByte($Hex.Substring($i, 2), 16) }) }
$random = 'AB' * 32
$sh13 = Bytes ('020000' + '2E' + '0303' + $random + '00' + '1301' + '00' + '0006' + '002B00020304')
$d = [TlsProbe]::Describe((Bytes '1603030034'), $sh13)
Assert ($d[0] -eq 'ServerHello' -and $d[1] -eq 'TLS 1.3, cipher 0x1301') "TLS 1.3 ServerHello: $($d -join ' / ')"
$sh12 = Bytes ('020000' + '35' + '0303' + $random + '00' + 'C02F' + '00' + '000D' + '0010000900070568747470' + '2F31' + '2E31')
Assert (([TlsProbe]::Describe((Bytes '160303003D'), $sh12))[1] -match '^TLS 1\.2, cipher 0xC02F') 'TLS 1.2 ServerHello'
$hrr = Bytes ('020000' + '2E' + '0303' + 'CF21AD74E59A6111BE1D8C021E65B891C2A211167ABB8C5E079E09E2C8A8339C' + '00' + '1301' + '00' + '0006' + '002B00020304')
Assert (([TlsProbe]::Describe((Bytes '1603030034'), $hrr))[0] -eq 'HelloRetryRequest') 'HelloRetryRequest'
$d = [TlsProbe]::Describe((Bytes '1503030002'), (Bytes '0246'))
Assert ($d[0] -eq 'Alert' -and $d[1] -eq 'fatal protocol_version (70)') "alert: $($d -join ' / ')"
Assert (([TlsProbe]::Describe((Bytes '1503030002'), (Bytes '0100')))[1] -eq 'warning close_notify (0)') 'close_notify'
Assert (([TlsProbe]::Describe([byte[]]@(), [byte[]]@()))[0] -eq 'Closed') 'closed connection'
$d = [TlsProbe]::Describe([Text.Encoding]::ASCII.GetBytes('HTTP/'), [Text.Encoding]::ASCII.GetBytes('1.1 400 Bad Request'))
Assert ($d[0] -eq 'NotTls' -and $d[1] -match '^HTTP/1\.1 400') "non-TLS answer: $($d -join ' / ')"
"PASS Test-TlsProbe: $script:AssertCount assertions"
