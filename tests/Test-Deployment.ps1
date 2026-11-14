. "$PSScriptRoot\TestCommon.ps1"
# The update and rollback commands of README.md («Развёртывание на рабочем ПК») are run exactly as written, against
# a simulated C:\TorrentMonitor 1.8 in a temporary folder (only the paths are replaced). Checks: data and settings are
# never changed by the update, the backup is complete, a running poll is waited for, rollback restores the 1.8
# program, moves the new files aside and disables autoload before the lock is released, and the tested copy with the
# RuTracker login is found by Setup-RuTracker.ps1. Nothing outside the temporary folder is touched.
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exe = (Get-Process -Id $PID).Path
$readme = [IO.File]::ReadAllText((Join-Path $repo 'README.md'))

function Get-ReadmeBlock([string]$Marker) {
    $at = $readme.IndexOf($Marker)
    Assert ($at -ge 0) "README section '$Marker' not found"
    $match = [regex]::Match($readme.Substring($at), '(?s)```powershell\r?\n(.*?)\r?\n```')
    Assert $match.Success "no PowerShell block after '$Marker'"
    return $match.Groups[1].Value
}
$releaseBlock = Get-ReadmeBlock '*1. Папка выпуска.*'
$updateBlock = Get-ReadmeBlock '*2. Обновление*'
$rollbackBlock = Get-ReadmeBlock '*Откат*'

function Convert-Block([string]$Text, [string]$Root, [string[]]$Skip = @()) {
    $lines = foreach ($line in ($Text -split "`r?`n")) {
        $skipIt = $false
        foreach ($prefix in $Skip) { if ($line.StartsWith($prefix)) { $skipIt = $true } }
        if (!$skipIt) { $line }
    }
    $text = $lines -join "`r`n"
    # Longer names first: they start with the shorter ones.
    $text = $text.Replace('C:\TorrentMonitor-backup-before-p0', "$Root\backup-before-p0").Replace('C:\TorrentMonitor-p0-removed-', "$Root\removed-")
    $text = $text.Replace('C:\TorrentControl-deploy', "$Root\deploy").Replace('C:\TorrentControl-p0-integration-test', "$Root\integration-test")
    $text = $text.Replace('C:\TorrentMonitor', "$Root\TorrentMonitor").Replace('powershell -NoProfile', "& '$exe' -NoProfile")
    # Safety: after the replacement no absolute path outside the temporary folder may remain (the real
    # C:\TorrentMonitor of this PC must never be touched by a test).
    $rest = $text.Replace($Root, '').Replace($exe, '')
    Assert ($rest -notmatch '(?i)(^|[^A-Za-z])[A-Za-z]:[\\/]' -and $rest -notmatch '(?i)SystemDrive|\$env:') "unreplaced path in a README command: $rest"
    # .NET on Linux does not treat '\' as a separator (the commands target Windows; the CI runs them there as written).
    if (!$script:OnWindows) { $text = $text.Replace('\', '/') }
    return $text
}
function Invoke-Commands([string]$Text, [string]$Root, [string]$Name) {
    $file = Join-Path $Root ($Name + '.ps1')
    [IO.File]::WriteAllText($file, $Text, (New-Object Text.UTF8Encoding($true)))
    $ErrorActionPreference = 'Continue'
    $out = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $file 2>&1 | Out-String
    $ErrorActionPreference = 'Stop'
    return $out
}
function Get-Tree([string]$Folder) {
    $map = @{}
    if (!(Test-Path -LiteralPath $Folder)) { return $map }
    foreach ($file in @(Get-ChildItem -LiteralPath $Folder -Recurse -File)) {
        if ($file.Name -eq 'monitor.lock') { continue }
        $map[$file.FullName.Substring($Folder.Length + 1).Replace('\', '/')] = (Get-FileHash -LiteralPath $file.FullName).Hash
    }
    return $map
}
function Write-Text([string]$Path, [string]$Text) {
    $null = Microsoft.PowerShell.Management\New-Item -Path (Split-Path $Path) -ItemType Directory -Force
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($true)))
}
$program18 = @('Monitor.ps1', 'Rules.ps1', 'LocalPaths.ps1', 'Feed.ps1', 'AutoLoad.ps1', 'Configure-AutoLoad.ps1', 'Check-DownloadFolder.ps1', 'Test-DownloadPath.ps1',
    'TorrentMetadata.cs', 'ResumePaths.cs', '1-Setup.cmd', '2-Run-once.cmd', '3-Check-download-folder.cmd', '4-Test-download-path.cmd', '6-Enable-autoload.cmd',
    '7-Disable-autoload.cmd', '8-Review-autoload.cmd', 'README.md', 'README.txt')
$data18 = [ordered]@{
    'config.json' = '{"url":"http://127.0.0.1:9090"}'; 'credential.xml' = '<Objs>FAKE-WEBUI-CREDENTIAL</Objs>'; 'state.json' = '{"version":1,"items":[]}'
    'state.json.bak' = '{"version":1,"items":[]}'; 'feed-state.json' = '{"version":1}'; 'monitor.log' = "2026-11-14 OK`r`n"; 'report.html' = '<html>report</html>'
    'auto-downloads.html' = '<html>journal</html>'; 'films.html' = '<html>films</html>'; 'metadata-cache\AAAA.torrent' = 'd4:infod4:name1:aee'
    'auto-state.json' = '{"version":1,"enabledAt":"2026-10-24T00:00:00Z","knownTopics":["1"],"items":[{"topic":"1","hash":"' + ('A' * 40) + '","status":"Confirmed","path":"D:\\Фильмы\\rt-1"}]}'
    'autoload.json' = '{"enabled":true,"destination":"D:\\Фильмы","reserveGiB":20}'
}
function New-Environment([string]$Root) {
    $prod = Join-Path $Root 'TorrentMonitor'
    foreach ($name in $program18) { Write-Text (Join-Path $prod $name) ('# TorrentControl 1.8 ' + $name) }
    foreach ($name in $data18.Keys) { Write-Text (Join-Path $prod $name) $data18[$name] }
    # Release folder (ZIP of the commit): the program files and lib of this checkout.
    $release = Join-Path $Root 'deploy\TorrentControl-release'
    $null = Microsoft.PowerShell.Management\New-Item -Path $release -ItemType Directory -Force
    foreach ($file in @(Get-ChildItem -LiteralPath $repo -File | Where-Object { $_.Extension -in @('.ps1', '.cs', '.cmd') -or $_.Name -like 'README.*' })) {
        Copy-Item -LiteralPath $file.FullName -Destination $release
    }
    Copy-Item -LiteralPath (Join-Path $repo 'lib') -Destination $release -Recurse
    # Tested copies: one where the login was done, one without it (must not be chosen).
    $tested = Join-Path $Root 'integration-test\TorrentControl-b003c76e51cd2070991ae73811f86b5876ef2694'
    $other = Join-Path $Root 'integration-test\TorrentControl-older'
    foreach ($folder in @($tested, $other)) { Write-Text (Join-Path $folder 'Setup-RuTracker.ps1') '# Setup' }
    Write-Text (Join-Path $tested 'rutracker-proxy.txt') "https://ps1.blockme.site:443`r`n"
    Write-Text (Join-Path $tested 'rutracker-state.json') '{"version":1,"blocked":"","loginAt":1,"host":"bt4.rutracker.cx"}'
    $credential = New-Object Management.Automation.PSCredential('fake-user', (ConvertTo-SecureString 'FAKE-PASSWORD-DEPLOY-1' -AsPlainText -Force))
    $credential | Export-Clixml -LiteralPath (Join-Path $tested 'rutracker-credential.xml')
    New-Object Management.Automation.PSCredential('rutracker-session', (ConvertTo-SecureString 'bb_session=0-FAKE-DEPLOY' -AsPlainText -Force)) | Export-Clixml -LiteralPath (Join-Path $tested 'rutracker-session.xml')
    return [pscustomobject]@{ prod = $prod; release = $release; tested = $tested; before = (Get-Tree $prod) }
}
$skipRelease = @('powershell ', '& "$src\10-RuTracker-check.cmd"')
$loginFiles = @('rutracker-proxy.txt', 'rutracker-credential.xml', 'rutracker-session.xml', 'rutracker-state.json')
function Assert-Updated($Env, [string]$Out, [string]$Case) {
    Assert ($Out -match 'Program files that differ: 0' -and $Out -match 'TLS component OK') "${Case}: update did not verify: $Out"
    $added = @([regex]::Matches($Out, '(?m)^data => (\S+)\s*$') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    Assert (($added -join ',') -eq 'rutracker-credential.xml,rutracker-proxy.txt,rutracker-session.xml,rutracker-state.json' -and $Out -notmatch 'data <=') "${Case}: data changed during the update: $Out"
    Assert ($Out -match '(?m)^\s*True\s*$' -and $Out -notmatch 'Найдено копий') "${Case}: release or tested copy not accepted: $Out"
    $backup = Get-Tree (Join-Path (Split-Path $Env.prod) 'backup-before-p0')
    Assert ($backup.Count -eq $Env.before.Count) "${Case}: backup incomplete ($($backup.Count) of $($Env.before.Count))"
    foreach ($key in $Env.before.Keys) { Assert ($backup[$key] -eq $Env.before[$key]) "${Case}: $key differs in the backup" }
}
function Assert-UpdatedState($Env, [string]$Case) {
    $now = Get-Tree $Env.prod
    $release = Get-Tree $Env.release
    foreach ($key in $release.Keys) { Assert ($now[$key] -eq $release[$key]) "${Case}: $key not deployed" }
    foreach ($key in $Env.before.Keys) {
        if ($data18.Contains($key.Replace('/', '\'))) { Assert ($now[$key] -eq $Env.before[$key]) "${Case}: data file $key changed" }
    }
}
function Assert-RolledBack($Env, [string]$Out, [string]$Case) {
    Assert ($Out -match 'autoload enabled: False' -and $Out -match '(?m)^\s*False\s*$') "${Case}: rollback output: $Out"
    $now = Get-Tree $Env.prod
    foreach ($name in $program18) { Assert ($now[$name] -eq $Env.before[$name]) "${Case}: $name not restored to 1.8" }
    foreach ($name in @('RuTracker.ps1', 'RuTrackerTls13.ps1', 'RuTrackerRoute.cs', 'RuTrackerTls13.cs', '9-RuTracker-login.cmd', 'lib/bouncycastle/2.7.0/SOURCE.txt')) {
        Assert (!$now.ContainsKey($name)) "${Case}: $name left in the 1.8 folder"
    }
    $aside = @(Get-ChildItem -LiteralPath (Split-Path $Env.prod) -Directory -Filter 'removed-*')
    Assert ($aside.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $aside[0].FullName 'RuTracker.ps1')) -and (Test-Path -LiteralPath (Join-Path $aside[0].FullName 'lib'))) "${Case}: new files not moved aside"
    $auto = Get-Content -LiteralPath (Join-Path $Env.prod 'autoload.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($auto.enabled -eq $false -and $auto.destination -eq 'D:\Фильмы' -and $auto.reserveGiB -eq 20) "${Case}: autoload not disabled or settings changed"
    foreach ($key in $Env.before.Keys) {
        if ($data18.Contains($key.Replace('/', '\')) -and $key -ne 'autoload.json') { Assert ($now[$key] -eq $Env.before[$key]) "${Case}: data file $key changed by rollback" }
    }
    foreach ($name in $loginFiles) { Assert ($now.ContainsKey($name)) "${Case}: $name removed by rollback" }
    $lock = [IO.File]::Open((Join-Path $Env.prod 'monitor.lock'), 'OpenOrCreate', 'ReadWrite', 'None'); $lock.Dispose()
}

$temp = New-TestDirectory
try {
    # --- A: update while a poll holds the lock, then rollback in a new window --------------------------------
    $rootA = Join-Path $temp 'a'
    $envA = New-Environment $rootA
    $lockPath = (Join-Path $envA.prod 'monitor.lock')
    if ($script:OnWindows) { $lockPath = $rootA + '\TorrentMonitor\monitor.lock' }
    $marker = Join-Path $rootA 'poll-started'
    $holder = Join-Path $rootA 'poll.ps1'
    [IO.File]::WriteAllText($holder, "`$l = [IO.File]::Open('$lockPath', 'OpenOrCreate', 'ReadWrite', 'None'); [IO.File]::WriteAllText('$marker', 'x'); Start-Sleep -Seconds 6; `$l.Dispose()")
    $start = @{ FilePath = $exe; ArgumentList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $holder); PassThru = $true }
    if ($script:OnWindows) { $start.WindowStyle = 'Hidden' }
    $poll = Start-Process @start
    for ($i = 0; $i -lt 100 -and !(Test-Path -LiteralPath $marker); $i++) { Start-Sleep -Milliseconds 100 }
    Assert (Test-Path -LiteralPath $marker) 'simulated poll did not start'
    $started = [DateTime]::UtcNow
    $out = Invoke-Commands ((Convert-Block $releaseBlock $rootA $skipRelease) + "`r`n" + (Convert-Block $updateBlock $rootA)) $rootA 'update'
    $poll.WaitForExit()
    Assert ($out -match 'Идёт опрос, жду' -and ([DateTime]::UtcNow - $started).TotalSeconds -ge 3) "update did not wait for the running poll: $out"
    Assert-Updated $envA $out 'A'
    Assert-UpdatedState $envA 'A'
    foreach ($name in $loginFiles) { Assert (Test-Path -LiteralPath (Join-Path $envA.prod $name)) "A: $name not copied from the tested copy" }
    $out = Invoke-Commands (Convert-Block $rollbackBlock $rootA) $rootA 'rollback'
    Assert-RolledBack $envA $out 'A'

    # --- B: something is wrong during the update: rollback in the same window, lock still held ----------------
    $rootB = Join-Path $temp 'b'
    $envB = New-Environment $rootB
    $update = (Convert-Block $updateBlock $rootB) -replace '(?m)^\$lock\.Dispose\(\)\s*$', ''
    $out = Invoke-Commands ((Convert-Block $releaseBlock $rootB $skipRelease) + "`r`n" + $update + "`r`n" + (Convert-Block $rollbackBlock $rootB)) $rootB 'abort'
    Assert-Updated $envB $out 'B'
    Assert-RolledBack $envB $out 'B'

    # --- C: rollback later in the same window as the finished update (released lock is taken again) ------------
    $rootC = Join-Path $temp 'c'
    $envC = New-Environment $rootC
    $out = Invoke-Commands ((Convert-Block $releaseBlock $rootC $skipRelease) + "`r`n" + (Convert-Block $updateBlock $rootC) + "`r`n" + (Convert-Block $rollbackBlock $rootC)) $rootC 'same-window'
    Assert-RolledBack $envC $out 'C'

    # --- D: no tested copy with a login: nothing is copied, the update would not get the login files ---------
    $rootD = Join-Path $temp 'd'
    $envD = New-Environment $rootD
    foreach ($name in $loginFiles) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath (Join-Path $envD.tested $name) }
    $out = Invoke-Commands (Convert-Block $releaseBlock $rootD $skipRelease) $rootD 'release-only'
    Assert ($out -match 'Найдено копий со входом: 0') "missing login not reported: $out"
    foreach ($name in $loginFiles) { Assert (!(Test-Path -LiteralPath (Join-Path $envD.release $name))) "$name copied without a tested login" }
    Assert ((Get-Tree $envD.prod).Count -eq $envD.before.Count) 'the working folder changed during the release step'
} finally { Remove-TestDirectory $temp }
"PASS Test-Deployment: $script:AssertCount assertions"
