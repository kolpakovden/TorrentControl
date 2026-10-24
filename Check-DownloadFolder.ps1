param()
$ErrorActionPreference = 'Stop'
try {
    $config = Get-Content -LiteralPath "$PSScriptRoot\config.json" -Raw | ConvertFrom-Json
    $credential = Import-Clixml -LiteralPath "$PSScriptRoot\credential.xml"
    $base = ([string]$config.url).TrimEnd('/')
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $session.Credentials = $credential.GetNetworkCredential()
    $page = Invoke-WebRequest "$base/gui/token.html" -WebSession $session -UseBasicParsing -TimeoutSec 30
    $match = [regex]::Match($page.Content, '<div[^>]*id=["'']token["''][^>]*>([^<]+)</div>')
    if (!$match.Success) { throw 'TokenMissing' }
    $token = [uri]::EscapeDataString($match.Groups[1].Value)
    $response = Invoke-WebRequest "$base/gui/?token=$token&action=getsettings" -WebSession $session -UseBasicParsing -TimeoutSec 30
    $response.RawContentStream.Position = 0
    $reader = New-Object IO.StreamReader($response.RawContentStream, (New-Object Text.UTF8Encoding($false,$true)))
    try { $data = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    if ($null -eq $data.settings) { throw 'SettingsMissing' }
    Write-Host 'READ-ONLY CHECK: no settings or torrents changed.'
    Write-Host ('uTorrent build: ' + $data.build)
    # Deliberate allowlist: never print password, tokens, cookies or unrelated settings.
    $names = @('dir_active','dir_active_flag','dir_completed','dir_completed_flag','dir_add_label','dir_autoload','dir_autoload_flag','torrents_start_stopped')
    foreach ($name in $names) {
        $found = $false
        foreach ($setting in $data.settings) {
            if ($setting[0] -eq $name) { Write-Host ($name + ' = ' + [string]$setting[2]); $found=$true; break }
        }
        if (!$found) { Write-Host ($name + ' = <not exposed by this client>') }
    }
    $drive = New-Object IO.DriveInfo('D:\')
    if (!$drive.IsReady) { throw 'DriveDUnavailable' }
    Write-Host ('D: free GiB = ' + [math]::Round($drive.AvailableFreeSpace/1GB,2))
    Write-Host 'Planned target: D:\Фильмы; no per-torrent size limit.'
} catch {
    Write-Host ('CHECK FAILED: ' + $_.Exception.GetType().Name) -ForegroundColor Red
    exit 1
}
