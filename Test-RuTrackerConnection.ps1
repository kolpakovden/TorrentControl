param([string]$Proxy = '', [switch]$FindLocalProxy, [switch]$Save, [switch]$Interactive, [int]$TimeoutSec = 10)
# Diagnosis of the network route from this computer to RuTracker for TorrentControl (15-RuTracker-connection.cmd).
# Read-only for the computer: no DNS, route, registry, VPN, browser or Windows proxy setting is changed, Hiddify is
# neither started nor configured. Every check is anonymous: no login, password, cookie or tracker address is used,
# only the status line of https://rutracker.org/forum/index.php is read (RuTrackerRoute.cs, certificate validated).
#   -Proxy http://127.0.0.1:PORT  check this HTTP proxy (for example the proxy port of Hiddify);
#   -FindLocalProxy               also check the loopback ports on which Hiddify / sing-box listen (other programs,
#                                 such as the uTorrent WebUI, are never probed);
#   -Save / -Interactive          write the first working proxy to rutracker-proxy.txt in this folder (only after a
#                                 successful check; -Interactive asks first).
# The report is shown and saved to rutracker-connection.txt (no secrets in it).
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\RuTracker.ps1"

$script:RouteTexts = @{
    Ok = 'РАБОТАЕТ'
    DnsFailed = 'имя rutracker.org не разрешается DNS этого компьютера (обычная блокировка у провайдера)'
    ConnectFailed = 'адрес найден, но соединение с rutracker.org:443 не устанавливается (блокировка по адресу)'
    ProxyUnreachable = 'на этом адресе и порту ничего не принимает соединения: прокси не запущен, порт другой или Hiddify в режиме «VPN» (в нём локальный порт закрыт)'
    ProxyAuthRequired = 'прокси требует пароль (HTTP 407); TorrentControl не хранит пароли прокси — нужен порт без авторизации'
    ProxyRefused = 'прокси не открыл туннель к rutracker.org:443 (ответ {0}); возможно, это не HTTP-прокси'
    Timeout = 'нет ответа за {1} с (этап: {2})'
    TlsFailed = 'защищённое соединение (TLS) не установлено: соединение оборвано или подменено'
    TlsCertificateInvalid = 'сертификат rutracker.org не прошёл проверку ({3}); соединение прервано, ничего не отправлено'
    HttpForbidden = 'rutracker.org ответил 403 — доступ с этого адреса выхода запрещён'
    HttpRateLimited = 'rutracker.org ответил 429 — слишком много запросов, повторите позже'
    HttpUnexpected = 'неожиданный ответ rutracker.org (HTTP {4})'
}
$script:StageTexts = @{ Dns = 'DNS'; Connect = 'подключение к rutracker.org'; ProxyConnect = 'подключение к прокси'; ProxyTunnel = 'туннель CONNECT'; Tls = 'TLS'; Http = 'ответ сайта' }

function Format-RouteResult($Result, [int]$TimeoutSec) {
    $template = $script:RouteTexts[[string]$Result.Code]
    # No answer while connecting to the proxy has the same practical causes as a refused connection.
    if ($Result.Code -eq 'Timeout' -and $Result.Stage -eq 'ProxyConnect') { $template = $script:RouteTexts.ProxyUnreachable + ' (нет ответа за {1} с)' }
    if (!$template) { $template = 'ошибка ({0})' }
    $text = $template -f $Result.ProxyStatus, $TimeoutSec, $script:StageTexts[[string]$Result.Stage], $Result.TlsErrors, $Result.HttpStatus
    if ($Result.Ok) { $text += ' (HTTP ' + $Result.HttpStatus + ', TLS и сертификат в порядке)' }
    return ($text + ', ' + [math]::Round($Result.ElapsedMs / 1000.0, 1).ToString([Globalization.CultureInfo]::InvariantCulture) + ' с')
}
function Get-ListeningSockets {
    # Read-only list of listening TCP ports with the owning process (Windows NetTCPIP module); $null if unavailable.
    $rows = $null
    try { $rows = @(Get-NetTCPConnection -State Listen -ErrorAction Stop) } catch { return $null }
    $names = @{}
    $list = New-Object Collections.Generic.List[object]
    foreach ($row in $rows) {
        $id = [int]$row.OwningProcess
        if (!$names.ContainsKey($id)) {
            $process = Get-Process -Id $id -ErrorAction SilentlyContinue
            $names[$id] = ''
            if ($process) { $names[$id] = [string]$process.ProcessName }
        }
        $list.Add([pscustomobject]@{ Address = [string]$row.LocalAddress; Port = [int]$row.LocalPort; Process = $names[$id] })
    }
    return ,$list.ToArray()
}
function Get-LocalProxyCandidates($Sockets) {
    # Only ports of Hiddify / sing-box on this computer, reachable at 127.0.0.1. Nothing else is probed.
    $seen = @{}
    $list = New-Object Collections.Generic.List[object]
    foreach ($socket in @($Sockets | Sort-Object Port)) {
        if ([string]$socket.Process -notmatch '(?i)hiddify|sing-?box') { continue }
        if ([string]$socket.Address -notin @('127.0.0.1', '0.0.0.0')) { continue }
        if ($seen.ContainsKey([int]$socket.Port)) { continue }
        $seen[[int]$socket.Port] = $true
        $list.Add([pscustomobject]@{ url = 'http://127.0.0.1:' + [int]$socket.Port; source = 'процесс ' + $socket.Process })
    }
    return $list.ToArray()   # callers wrap the result in @()
}
function Invoke-RuTrackerDiagnostics([string]$Directory, [string]$Proxy = '', [switch]$FindLocalProxy, [int]$TimeoutSec = 10) {
    $timeout = [math]::Max(1, $TimeoutSec)
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('Проверка доступа TorrentControl к RuTracker — ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $lines.Add('Без входа на сайт: логин, пароль, cookie и адреса трекеров не используются. Настройки Windows, DNS, VPN, прокси и Hiddify не меняются.')
    $direct = Invoke-RuTrackerRouteCheck '' 'rutracker.org' ($timeout * 1000)
    if ($direct.Stage -eq 'Dns') { $lines.Add('1. DNS rutracker.org на этом компьютере: ' + (Format-RouteResult $direct $timeout)); $lines.Add('2. HTTPS напрямую: не проверялось — нет адреса.') }
    else {
        $lines.Add('1. DNS rutracker.org на этом компьютере: разрешается (адресов: ' + $direct.Addresses + ').')
        $lines.Add('2. HTTPS напрямую: ' + (Format-RouteResult $direct $timeout))
    }
    $candidates = New-Object Collections.Generic.List[object]
    if ($Proxy) { $candidates.Add([pscustomobject]@{ url = (ConvertTo-RuTrackerProxy $Proxy); source = 'указан в команде' }) }
    $configured = ''
    try {
        $configured = Read-RuTrackerProxy $Directory
        if ($configured) { $lines.Add('3. rutracker-proxy.txt: ' + $configured); $candidates.Add([pscustomobject]@{ url = $configured; source = 'rutracker-proxy.txt' }) }
        else { $lines.Add('3. rutracker-proxy.txt: нет файла.') }
    } catch { $lines.Add('3. rutracker-proxy.txt: неверный формат (нужна одна строка http://адрес:порт).') }
    $system = Get-SystemRuTrackerProxy
    if ($system) { $lines.Add('4. Прокси Windows для rutracker.org: ' + $system); $candidates.Add([pscustomobject]@{ url = $system; source = 'прокси Windows' }) }
    else { $lines.Add('4. Прокси Windows для rutracker.org: не задан.') }
    if ($FindLocalProxy) {
        $sockets = Get-ListeningSockets
        if ($null -eq $sockets) { $lines.Add('5. Локальные порты Hiddify / sing-box: список портов недоступен; укажите порт явно: -Proxy http://127.0.0.1:<порт>.') }
        else {
            $found = @(Get-LocalProxyCandidates $sockets)
            if ($found.Count) { $lines.Add('5. Локальные порты Hiddify / sing-box: ' + (@($found | ForEach-Object { $_.url + ' (' + $_.source + ')' }) -join ', ')) }
            else { $lines.Add('5. Локальные порты Hiddify / sing-box: не найдены (Hiddify не запущен, не подключён или работает в режиме «VPN»).') }
            foreach ($item in $found) { $candidates.Add($item) }
        }
    }
    $working = ''
    $checked = @{}
    foreach ($candidate in $candidates) {
        if ($checked.ContainsKey($candidate.url)) { continue }
        $checked[$candidate.url] = $true
        $result = Invoke-RuTrackerRouteCheck $candidate.url 'rutracker.org' ($timeout * 1000)
        $lines.Add('   ' + $candidate.url + ' (' + $candidate.source + '): ' + (Format-RouteResult $result $timeout))
        if ($result.Ok -and !$working) { $working = $candidate.url }
    }
    if ($direct.Ok) { $lines.Add('ИТОГ: rutracker.org доступен напрямую; прокси не нужен.') }
    elseif ($working) { $lines.Add('ИТОГ: рабочий маршрут через ' + $working + '. Для TorrentControl в rutracker-proxy.txt должна быть строка: ' + $working) }
    else {
        $lines.Add('ИТОГ: рабочего маршрута к rutracker.org нет. Персональные .torrent не будут скачиваться; публичная версия не добавляется.')
        $lines.Add('Что сделать в Hiddify (настройки не меняются автоматически):')
        $lines.Add(' 1. Подключитесь к своему профилю.')
        $lines.Add(' 2. В настройках выберите «Режим службы» → «Только прокси». В режиме «VPN» локальный порт закрыт, а «Установить системный прокси» меняет прокси всей Windows.')
        $lines.Add(' 3. Там же посмотрите «Порт прокси (SOCKS5/4, HTTP)».')
        $lines.Add(' 4. Повторите проверку: Test-RuTrackerConnection.ps1 -Proxy http://127.0.0.1:<этот порт>')
        $lines.Add('Внешние прокси из интернета автоматически не предлагаются и не используются.')
    }
    return [pscustomobject]@{ lines = $lines.ToArray(); working = $working; directOk = [bool]$direct.Ok; configured = $configured }
}
function Save-RuTrackerProxy([string]$Directory, [string]$Url) {
    $value = ConvertTo-RuTrackerProxy $Url
    [IO.File]::WriteAllText((Get-RuTrackerFiles $Directory).proxy, $value + "`r`n", (New-Object Text.ASCIIEncoding))
    Reset-RuTrackerRoute
    return $value
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $report = Invoke-RuTrackerDiagnostics $PSScriptRoot $Proxy -FindLocalProxy:$FindLocalProxy $TimeoutSec
        foreach ($line in $report.lines) { Write-Host $line }
        [IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'rutracker-connection.txt'), [string[]]$report.lines, (New-Object Text.UTF8Encoding($true)))
        if ($report.working -and $report.working -ne $report.configured) {
            $write = [bool]$Save
            if (!$write -and $Interactive) { $write = ((Read-Host ('Записать ' + $report.working + ' в rutracker-proxy.txt этой папки? Введите YES')).Trim() -eq 'YES') }
            if ($write) { $null = Save-RuTrackerProxy $PSScriptRoot $report.working; Write-Host ('Записано в rutracker-proxy.txt: ' + $report.working) }
        }
        if ($report.directOk -or $report.working) { exit 0 }
        exit 2
    } catch {
        Write-Host ('Проверка остановлена: ' + (Get-RuTrackerCode $_.Exception)) -ForegroundColor Red
        exit 1
    }
}
