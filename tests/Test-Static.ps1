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

# --- Production code never deletes, moves or renames data, stops torrents or changes client settings ---
# 1.9 cleanup is Dry Run only: no deletion or stop operation may exist anywhere in production code.
foreach ($file in @(Get-ChildItem -LiteralPath $repo | Where-Object { $_.Extension -in @('.ps1', '.cs', '.cmd') })) {
    $text = [IO.File]::ReadAllText($file.FullName)
    foreach ($pattern in @('Remove-', '::Delete\(', '\.Delete\(', 'DeleteFile', 'DeleteDirectory', 'Move-Item', 'Rename-Item', 'Clear-Content',
        '\brmdir\b', '\brd\s+/', '\bdel\s', '\berase\s', 'Stop-Process', 'removedata', 'setsetting', 'setprops', 'action=(?!getsettings\b)')) {
        Assert ($text -notmatch $pattern) "$($file.Name) contains forbidden operation '$pattern'"
    }
}
# The cleanup module only reads history and writes its own reports.
$cleanupText = [IO.File]::ReadAllText((Join-Path $repo 'Cleanup.ps1'))
foreach ($pattern in @('Invoke-WebRequest', 'Invoke-RestMethod', 'Start-Process', 'Fetch-List', 'New-Item', 'Save-AutoJson', 'Out-File', 'Copy-Item')) {
    Assert ($cleanupText -notmatch $pattern) "Cleanup.ps1 must not use '$pattern'"
}

# --- C# helpers compile with this runtime's compiler (C# 5 under Windows PowerShell 5.1) -----------
foreach ($type in @('ResumePaths', 'TorrentMetadata')) {
    if (!($type -as [type])) { Add-Type -Path (Join-Path $repo "$type.cs") }
    Assert ($type -as [type]) "$type did not compile"
}

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
    [TorrentMetadata]::Sanitize($fixture, '51CE70C03EC2FBF311F03C4B6570951C3CF28F3A')
    Assert ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($fixture)) -like 'd8:announce29:http://bt.t-ru.org/ann?magnet4:info*') 'tracker replaced by the known public one'
    Assert ([TorrentMetadata]::Verify($fixture, '51CE70C03EC2FBF311F03C4B6570951C3CF28F3A') -eq 58) 'sanitized torrent keeps the infohash'
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
