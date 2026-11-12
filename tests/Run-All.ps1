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
