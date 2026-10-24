$ErrorActionPreference = 'Stop'
try {
    # A private, trackerless test torrent containing only our own short text file.
    # No global uTorrent settings are changed.
    $clients = @(Get-Process -Name utorrent -ErrorAction Stop)
    if ($clients.Count -ne 1 -or !$clients[0].Path) { throw 'ExpectedExactlyOneRunningClient' }
    $exe = $clients[0].Path
    $directory = 'D:\Фильмы'
    $payload = [Text.Encoding]::UTF8.GetBytes("TorrentControl download-directory test. No movie data.\r\n")
    if (!(Test-Path -LiteralPath 'D:\')) { throw 'DriveDUnavailable' }
    $null = New-Item -ItemType Directory -Path $directory -Force
    $file = Join-Path $directory 'TorrentControl-path-test.txt'
    if (Test-Path -LiteralPath $file) {
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) -ne [Convert]::ToBase64String($payload)) { throw 'ExistingTestFileHasDifferentContents' }
    } else { [IO.File]::WriteAllBytes($file,$payload) }
    $sha = [Security.Cryptography.SHA1]::Create()
    try { $piece = $sha.ComputeHash($payload) } finally { $sha.Dispose() }
    $stream = New-Object IO.MemoryStream
    try {
        $head = [Text.Encoding]::ASCII.GetBytes(('d4:infod6:lengthi{0}e4:name28:TorrentControl-path-test.txt12:piece lengthi16384e6:pieces20:' -f $payload.Length))
        $tail = [Text.Encoding]::ASCII.GetBytes('7:privatei1eee')
        $stream.Write($head,0,$head.Length)
        $stream.Write($piece,0,$piece.Length)
        $stream.Write($tail,0,$tail.Length)
        $torrent = Join-Path $PSScriptRoot 'TorrentControl-path-test.torrent'
        [IO.File]::WriteAllBytes($torrent,$stream.ToArray())
    } finally { $stream.Dispose() }
    Start-Process -FilePath $exe -ArgumentList ('/DIRECTORY "{0}" "{1}"' -f $directory,$torrent) -WindowStyle Hidden
    Write-Host 'Test submitted to the running uTorrent. This is NOT confirmation of its save path.'
    Write-Host 'Find TorrentControl-path-test.txt in uTorrent and inspect General -> Save As.'
    Write-Host 'Expected: D:\Фильмы\TorrentControl-path-test.txt and 100% complete.'
    Write-Host 'Leave WebTLO settings unchanged. Automatic movie downloads are still disabled.'
} catch {
    Write-Host ('TEST FAILED: ' + $_.Exception.GetType().Name) -ForegroundColor Red
    exit 1
}
