# Runs every tests\Test-*.ps1 in its own process with the same PowerShell (stubs cannot leak between files).
# Afterwards checks that no local data next to the scripts changed and that nothing was created under D:\Фильмы.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exe = (Get-Process -Id $PID).Path
Write-Host ("PowerShell {0} ({1}) on {2}" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, [Environment]::OSVersion.VersionString)
function Get-LocalSnapshot {
    $snapshot = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $repo -File -Force | Where-Object { $_.Extension -notin @('.tmp', '.lock') })) {
        $snapshot[$file.Name] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $snapshot
}
$before = Get-LocalSnapshot
# Personal RuTracker files of this Windows user: tests redirect LOCALAPPDATA and must never touch the real folder.
function Get-ProfileSnapshot {
    $folder = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'TorrentControl' } else { '' }
    if (!$folder -or !(Test-Path -LiteralPath $folder)) { return '' }
    return (@(Get-ChildItem -LiteralPath $folder -Recurse -File -Force | ForEach-Object { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks }) -join "`n")
}
$profileBefore = Get-ProfileSnapshot
# Windows proxy settings of this user: tests (fake proxies on 127.0.0.1 only) must never change them.
function Get-ProxySettingsSnapshot {
    $parts = @(foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'ALL_PROXY')) { $name + '=' + [Environment]::GetEnvironmentVariable($name, 'User') })
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        $parts += @(foreach ($name in @('ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL', 'AutoDetect')) { $name + '=' + [string]$settings.$name })
    }
    return ($parts -join "`n")
}
$proxyBefore = Get-ProxySettingsSnapshot
# The working installation (if this is the user's PC) must never be touched by the tests.
$working = 'C:\TorrentMonitor'
function Get-WorkingSnapshot {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or !(Test-Path -LiteralPath $working)) { return '' }
    return (@(Get-ChildItem -LiteralPath $working -File -Force | Where-Object { $_.Name -notin @('monitor.lock') } | ForEach-Object { $_.Name + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks }) -join "`n")
}
$workingBefore = Get-WorkingSnapshot
$probe = 'D:\Фильмы'
$probeBefore = @()
if (Test-Path -LiteralPath $probe) { $probeBefore = @(Get-ChildItem -LiteralPath $probe -Directory -Filter 'rt-9000000*' | ForEach-Object Name) }
$failed = @()
foreach ($test in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*.ps1' | Sort-Object Name)) {
    Write-Host "--- $($test.Name)"
    & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $test.FullName
    if ($LASTEXITCODE -ne 0) { $failed += $test.Name; Write-Host "FAIL: $($test.Name) (exit $LASTEXITCODE)" -ForegroundColor Red }
}
$after = Get-LocalSnapshot
if ((Get-WorkingSnapshot) -ne $workingBefore) { $failed += 'working-folder-guard'; Write-Host "FAIL: files in $working changed during the run (if the scheduled monitor ran meanwhile, repeat the tests)." -ForegroundColor Red }
if ((Get-ProxySettingsSnapshot) -ne $proxyBefore) { $failed += 'proxy-settings-guard'; Write-Host 'FAIL: Windows proxy settings changed during the run.' -ForegroundColor Red }
if ((Get-ProfileSnapshot) -ne $profileBefore) { $failed += 'profile-guard'; Write-Host 'FAIL: files under %LOCALAPPDATA%\TorrentControl changed during the run.' -ForegroundColor Red }
$changed = @(@($before.Keys) + @($after.Keys) | Select-Object -Unique | Where-Object { $before[$_] -ne $after[$_] })
if ($changed.Count) {
    $failed += 'local-files-guard'
    Write-Host ("FAIL: files next to the scripts changed during the run: {0}. If the scheduled monitor ran at the same time, repeat the tests." -f ($changed -join ', ')) -ForegroundColor Red
}
if (Test-Path -LiteralPath $probe) {
    $created = @(Get-ChildItem -LiteralPath $probe -Directory -Filter 'rt-9000000*' | ForEach-Object Name | Where-Object { $_ -notin $probeBefore })
    if ($created.Count) { $failed += 'destination-guard'; Write-Host "FAIL: test folders were created under ${probe}: $($created -join ', ')" -ForegroundColor Red }
}
$leftovers = @(Get-ChildItem -LiteralPath $PSScriptRoot -Directory -Filter 'autoload-test-*')
if ($leftovers.Count) { Write-Host "WARNING: temporary test folders left in tests: $($leftovers.Count)" -ForegroundColor Yellow }
if ($failed.Count) { Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host 'ALL TESTS PASSED' -ForegroundColor Green
exit 0
