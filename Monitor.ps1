param([switch]$Setup, [switch]$Once)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. "$root\Rules.ps1"
. "$root\LocalPaths.ps1"
. "$root\Feed.ps1"
function Save-Json($Value, $Path) {
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$Path.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$Path.tmp" -Destination $Path -Force
}
function Fetch-List($Config, $Credential) {
    $base = ([string]$Config.url).TrimEnd('/')
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $session.Credentials = $Credential.GetNetworkCredential()
    $tokenPage = Invoke-WebRequest "$base/gui/token.html" -WebSession $session -UseBasicParsing -TimeoutSec 30
    $match = [regex]::Match($tokenPage.Content, '<div[^>]*id=["'']token["''][^>]*>([^<]+)</div>')
    if (!$match.Success) { throw 'Token not found. Check WebUI login/password and port.' }
    $token = [uri]::EscapeDataString($match.Groups[1].Value)
    $response = Invoke-WebRequest "$base/gui/?token=$token&list=1" -WebSession $session -UseBasicParsing -TimeoutSec 30
    # Legacy WebUI can omit charset; Windows PowerShell then misdecodes UTF-8.
    $response.RawContentStream.Position = 0
    $reader = New-Object IO.StreamReader($response.RawContentStream, (New-Object Text.UTF8Encoding($false, $true)))
    try { $json = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $data = $json | ConvertFrom-Json
    if ($null -eq $data.torrents) { throw 'No torrent list in API response.' }
    return $data
}
function Collect {
    $config = Get-Content "$root\config.json" -Raw | ConvertFrom-Json
    $credential = Import-Clixml "$root\credential.xml"
    $data = Fetch-List $config $credential
    $feedMessage = 'Подборка фильмов не обновлена; подробности в monitor.log.'
    try {
        $feedCount = Collect-Films $data.torrents $root
        $feedMessage = "Подборка фильмов обновлена: $feedCount записей."
    } catch {
        $detail = Get-FeedErrorDetail $_.Exception
        $feedMessage = "Подборка фильмов не обновлена: $detail."
        Write-Host "Feed failed: $detail" -ForegroundColor Yellow
        Add-Content "$root\monitor.log" "$(Get-Date -Format s) FEED ERROR: $detail. Torrent monitoring continues." -Encoding UTF8
    }
    $localPaths = Read-LocalPaths
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $previous = @{}
    if (Test-Path "$root\state.json") {
        $saved = Get-Content "$root\state.json" -Raw | ConvertFrom-Json
        foreach ($item in $saved.items) { $previous[$item.hash] = $item }
    }
    $states = @(); $report = @(); $unknown = 0; $excluded = 0
    foreach ($row in $data.torrents) {
        if ($row.Count -lt 19) { throw 'Unsupported torrent row format; history was not updated.' }
        $path = ''
        if ($row.Count -gt 26) { $path = [string]$row[26] }
        if ($path -notmatch '^[A-Za-z]:\\' -and $localPaths.ContainsKey([string]$row[0])) {
            $path = [string]$localPaths[[string]$row[0]]
        }
        if ($path -notmatch '^[A-Za-z]:\\') { $unknown++; continue }
        if ($path -notmatch '^[DF]:\\') { $excluded++; continue }
        $hash = [string]$row[0]
        $old = $null
        if ($previous.ContainsKey($hash)) { $old = $previous[$hash] }
        $state = Update-History $row $path $old $now
        $states += $state
        $decision = Get-Decision $state $now
        $report += [pscustomobject]@{
            Решение = $decision; Название = [string]$row[2]; Путь = $path
            ГБ = [math]::Round(([double]$row[3] / 1GB), 2)
            Готово = ([double]$row[4] / 10)
            Дней_хранения = [math]::Round(($now - $state.firstSeen) / 86400, 1)
            Дней_без_спроса = [math]::Round(($now - $state.quietSince) / 86400, 1)
            Отдано_за_наблюдение_МБ = [math]::Round($state.observedUpload / 1MB, 2)
            Скачивающих = $row[13]; Сидов = $row[15]; Hash = $hash
        }
    }
    $report = @($report | Sort-Object Решение, Название)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $intro = "<h1>Монитор временных раздач</h1><p>Обновлено: $stamp · Только отчёт, удаление отключено.</p><p>Раздач D/F: $($states.Count). Другие диски: $excluded. Путь не определён: $unknown.</p><p>Кандидат: 30 дней наблюдаемого хранения и 14 дней без замеченного спроса. Перерыв в проверках более часа, остановка или ошибка сбрасывают период тишины. Сиды не влияют на решение.</p>"
    $style = '<meta charset="utf-8"><style>body{font:15px Segoe UI;margin:28px;background:#f5f7fa}table{border-collapse:collapse;background:white;width:100%}td,th{padding:9px;border:1px solid #ddd;text-align:left}th{background:#dfeafa}h1{color:#17365d}</style>'
    if ($unknown -gt 0) {
        $intro += '<p>Для части раздач путь неизвестен. Монитор читает resume.dat из профиля Windows и папки запущенного µTorrent. Если файл находится в другом месте, укажите его полный путь в resume-path.txt рядом с Monitor.ps1. Неизвестные пути исключены из отбора.</p>'
    }
    $intro += '<p>Отслеживаются все раздачи на D: и F:. Весь E: — постоянное хранение; C: — системный. Оба диска исключены.</p>'
    $intro += "<p>$feedMessage <a href='films.html'>Открыть публикации раздела 252</a></p>"
    $html = $report | ConvertTo-Html -Head $style -PreContent $intro
    $html | Set-Content "$root\report.html" -Encoding UTF8
    $report | Export-Csv "$root\report.csv" -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    Save-Json @{ version = 1; updated = $now; items = @($states) } "$root\state.json"
    Add-Content "$root\monitor.log" "$stamp OK: D/F=$($states.Count), unknown=$unknown, excluded=$excluded" -Encoding UTF8
    Write-Host "OK: $($states.Count) torrents on D/F. Report: $root\report.html"
}
try {
    if ($Setup) {
        Write-Host 'Setup on the torrent computer. No torrents or files will be changed.'
        $url = Read-Host 'WebUI URL [http://127.0.0.1:9090]'
        if (!$url) { $url = 'http://127.0.0.1:9090' }
        $parsed = [uri]$url
        if (!$parsed.IsAbsoluteUri -or $parsed.Scheme -notin @('http','https') -or $parsed.UserInfo -or $parsed.Query -or $parsed.AbsolutePath -ne '/') { throw 'Enter only http://HOST:PORT without login, password or /gui/.' }
        $credential = Get-Credential -UserName 'admin' -Message 'Enter uTorrent WebUI password (stored encrypted for this Windows user)'
        if (!$credential) { throw 'Setup cancelled.' }
        $null = Fetch-List ([pscustomobject]@{url=$url}) $credential
        $credential | Export-Clixml "$root\credential.xml"
        Save-Json @{url=$url} "$root\config.json"
        Collect
        $taskName = 'TorrentMonitor-DF'
        $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $action = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\Monitor.ps1`" -Once" -WorkingDirectory $root
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 15)
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host 'Scheduled every 15 minutes while this Windows user is signed in (locked/disconnected session is OK).'
        Start-Process "$root\report.html"
    } else {
        $lock = $null
        try {
            $lock = [IO.File]::Open("$root\monitor.lock", 'OpenOrCreate', 'ReadWrite', 'None')
            Collect
        } finally { if ($lock) { $lock.Dispose() } }
    }
} catch {
    # Avoid logging URLs containing a token or authentication details.
    $message = 'Connection/processing failed. Check uTorrent, URL, password and local file access. History not advanced. Error type: ' + $_.Exception.GetType().Name
    Add-Content "$root\monitor.log" "$(Get-Date -Format s) ERROR: $message" -Encoding UTF8
    Write-Host $message -ForegroundColor Red
    if ($Setup) { Write-Host 'If the report opened/was created but scheduling failed, run 2-Run-once.cmd manually or retry setup.' }
    exit 1
}
