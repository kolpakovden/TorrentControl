param([switch]$Apply, [switch]$Batch, [switch]$MarkVerified, [string]$Hash = '')
# Re-binding of TorrentControl torrents to the personal RuTracker tracker (TrackerMigration.ps1).
# Without switches: Dry Run (nothing changes). -Apply: one torrent, typed confirmation. -MarkVerified: after checking
# the RuTracker profile. -Batch: only after at least one verified torrent.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Monitor.ps1"
. "$PSScriptRoot\TrackerMigration.ps1"
$lock = $null
try {
    $lock = [IO.File]::Open("$PSScriptRoot\monitor.lock", 'OpenOrCreate', 'ReadWrite', 'None')
    $mode = 'DryRun'
    if ($Apply) { $mode = 'Apply' } elseif ($MarkVerified) { $mode = 'Verify' } elseif ($Batch) { $mode = 'Batch' }
    if ($mode -in @('Apply', 'Verify') -and !$Hash) { $Hash = Read-Host 'Hash раздачи (40 символов, из tracker-migration.html)' }
    $config = Get-Content "$PSScriptRoot\config.json" -Raw | ConvertFrom-Json
    $credential = Import-Clixml "$PSScriptRoot\credential.xml"
    $null = Assert-AutoLocalClient $config
    $summary = Invoke-TrackerMigration -Directory $PSScriptRoot -Mode $mode -Hash $Hash -Config $config -Credential $credential -Confirm { param($text) Read-Host $text }
    Write-Host ($summary | Format-List | Out-String)
    Write-Host "Отчёт: $PSScriptRoot\tracker-migration.html"
} catch {
    $code = [string]$_.Exception.Message
    if ($code -notmatch '^[A-Za-z]+(:[A-Za-z]+)?$') { $code = $_.Exception.GetType().Name }
    Write-Host ('Перепривязка остановлена: ' + $code) -ForegroundColor Red
    exit 1
} finally { if ($lock) { $lock.Dispose() } }
