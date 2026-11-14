param([string]$Proxy = '', [switch]$FindLocalProxy, [switch]$Save, [switch]$Interactive, [int]$TimeoutSec = 10, [switch]$NoOfficialProxy, [switch]$NoAddressProbe)
# Diagnosis of the network route from this computer to RuTracker for TorrentControl (15-RuTracker-connection.cmd).
# Read-only for the computer: no DNS, route, registry, VPN, browser or Windows proxy setting is changed, Hiddify is
# neither started nor configured. Every check is anonymous: no login, password, cookie or tracker address is used,
# only the status line of https://rutracker.org/forum/index.php is read (RuTrackerRoute.cs; TLS 1.3 with the site by
# RuTrackerTls13.cs, certificate validated by Windows for rutracker.org).
#   -Proxy http://127.0.0.1:PORT  check this proxy (http:// or https://, for example the proxy port of Hiddify);
#   (default)                     also check the official RuTracker proxy https://ps1.blockme.site:443 - the route the
#                                 official RuTracker extension of Firefox uses on this computer; -NoOfficialProxy skips it;
#   -FindLocalProxy               also check the loopback ports on which Hiddify / sing-box listen (other programs,
#                                 such as the uTorrent WebUI, are never probed);
#   -Save / -Interactive          write the first working proxy to rutracker-proxy.txt in this folder (only after a
#                                 successful check; -Interactive asks first) and, for a proxy name with several
#                                 addresses, what the check of every address found to rutracker-proxy-addresses.json
#                                 (the starting order of addresses for TorrentControl; no secrets);
#   (default for a proxy name)    every address of the name is also checked separately (certificate for the NAME);
#                                 -NoAddressProbe skips that.
# The report is shown and saved to rutracker-connection.txt (no secrets in it).
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\RuTracker.ps1"

$script:RouteTexts = @{
    Ok = 'РАБОТАЕТ'
    DnsFailed = 'имя rutracker.org не разрешается DNS этого компьютера (обычная блокировка у провайдера)'
    ConnectFailed = 'адрес найден, но соединение с rutracker.org:443 не устанавливается (блокировка по адресу)'
    ProxyUnreachable = 'на этом адресе и порту ничего не принимает соединения: прокси не запущен, порт другой или Hiddify в режиме «VPN» (в нём локальный порт закрыт)'
    ProxyTlsFailed = 'защищённое соединение с самим прокси оборвалось или не ответило (сетевая ошибка TLS; сертификат не отклонялся)'
    ProxyCertificateInvalid = 'сертификат прокси не прошёл проверку{3}: перебор адресов остановлен, ничего не отправлено'
    ProxyUnsupported = 'тип прокси не поддерживается (нужен http:// или https://)'
    ProxyAuthRequired = 'прокси требует пароль (HTTP 407); TorrentControl не хранит пароли прокси — нужен порт без авторизации'
    ProxyRefused = 'прокси не открыл туннель к rutracker.org:443 (ответ {0}); возможно, это не HTTP-прокси'
    Timeout = 'нет ответа за {1} с (этап: {2})'
    TlsFailed = 'защищённое соединение (TLS) с rutracker.org не установлено{3}: соединение оборвано или подменено'
    TlsCertificateInvalid = 'сертификат rutracker.org не прошёл проверку{3}; соединение прервано, ничего не отправлено'
    HttpForbidden = 'rutracker.org ответил 403 — доступ с этого адреса выхода запрещён'
    HttpRateLimited = 'rutracker.org ответил 429 — слишком много запросов, повторите позже'
    HttpUnexpected = 'неожиданный ответ rutracker.org (HTTP {4})'
}
$script:StageTexts = @{ Dns = 'DNS'; Connect = 'подключение к rutracker.org'; ProxyConnect = 'подключение к прокси'; ProxyTls = 'TLS с прокси'; ProxyTunnel = 'туннель CONNECT'; Tls = 'TLS'; Http = 'ответ сайта' }

function Format-RouteResult($Result, [int]$TimeoutSec) {
    $template = $script:RouteTexts[[string]$Result.Code]
    # No answer while connecting to the proxy has the same practical causes as a refused connection.
    if ($Result.Code -eq 'Timeout' -and $Result.Stage -eq 'ProxyConnect') { $template = $script:RouteTexts.ProxyUnreachable + ' (нет ответа за {1} с)' }
    if (!$template) { $template = 'ошибка ({0})' }
    # Fixed texts only (SslPolicyErrors, chain status and TLS alert names), never a URL, cookie or key.
    $tlsErrors = [string]$Result.TlsErrors
    if ($tlsErrors) { $tlsErrors = ' (' + $tlsErrors + ')' }
    $text = $template -f $Result.ProxyStatus, $TimeoutSec, $script:StageTexts[[string]$Result.Stage], $tlsErrors, $Result.HttpStatus
    if ($Result.Ok) { $text += ' (HTTP ' + $Result.HttpStatus + ', ' + $Result.TlsVersion + ', сертификат rutracker.org в порядке)' }
    if ([int]$Result.Attempts -gt 0) {
        $text += '; адрес прокси ' + $Result.Endpoint + ', попыток ' + $Result.Attempts + ' из ' + $Result.Addresses
        if ([string]$Result.AddressSource -eq 'cache') { $text += ' (DNS не ответил — запомненные адреса)' }
    }
    return ($text + ', ' + (Format-Seconds $Result.ElapsedMs))
}
function Format-Seconds([long]$Ms) { return ([math]::Round($Ms / 1000.0, 1).ToString([Globalization.CultureInfo]::InvariantCulture) + ' с') }
$script:AddressTexts = @{
    ProxyUnreachable = 'нет TCP-соединения'; ProxyTlsFailed = 'TLS с прокси оборвался или не ответил (сетевая ошибка)'
    ProxyCertificateInvalid = 'сертификат прокси отклонён'; ProxyRefused = 'туннель CONNECT не открыт'; ProxyAuthRequired = 'прокси требует пароль'
    TlsFailed = 'TLS с rutracker.org не установлен'; TlsCertificateInvalid = 'сертификат rutracker.org отклонён'
    HttpForbidden = 'rutracker.org ответил 403'; HttpRateLimited = 'rutracker.org ответил 429'; HttpUnexpected = 'неожиданный ответ rutracker.org'
}
function Format-AddressProbe($Result) {
    # One line per proxy address: what the person needs to see why some addresses do not work.
    $address = [string]$Result.Endpoint
    if ($Result.Ok) { return ($address + ': РАБОТАЕТ (' + $Result.TlsVersion + ', HTTP ' + $Result.HttpStatus + '), ' + (Format-Seconds $Result.ElapsedMs)) }
    $text = $script:AddressTexts[[string]$Result.Code]
    if ([string]$Result.Code -eq 'Timeout') { $text = 'нет ответа (этап: ' + $script:StageTexts[[string]$Result.Stage] + ')' }
    if (!$text) { $text = 'ошибка ' + [string]$Result.Code }
    if ([string]$Result.TlsErrors) { $text += ' (' + [string]$Result.TlsErrors + ')' }
    return ($address + ': ' + $text + ', ' + (Format-Seconds $Result.ElapsedMs))
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
function Invoke-RuTrackerDiagnostics([string]$Directory, [string]$Proxy = '', [switch]$FindLocalProxy, [int]$TimeoutSec = 10, [switch]$NoOfficialProxy, [switch]$NoAddressProbe) {
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
    if (!$NoOfficialProxy) {
        # The route of the official RuTracker extension (TLS to the proxy, then a tunnel to rutracker.org; the proxy sees
        # only rutracker.org:443). Checked anonymously, like Firefox does; written to rutracker-proxy.txt only on request.
        $candidates.Add([pscustomobject]@{ url = $script:RuTrackerOfficialProxy; source = 'официальный прокси RuTracker, тот же, что у расширения Firefox' })
    }
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
    $probes = @{}
    $checked = @{}
    foreach ($candidate in $candidates) {
        if ($checked.ContainsKey($candidate.url)) { continue }
        $checked[$candidate.url] = $true
        $result = Invoke-RuTrackerRouteCheck $candidate.url 'rutracker.org' ($timeout * 1000)
        $lines.Add('   ' + $candidate.url + ' (' + $candidate.source + '): ' + (Format-RouteResult $result $timeout))
        $ok = [bool]$result.Ok
        # A proxy name with several addresses: each address separately, so that a few broken ones are seen as such.
        $each = @()
        if (!$NoAddressProbe) { $each = @(Invoke-RuTrackerAddressProbe $candidate.url ($timeout * 1000)) }
        if ($each.Count -gt 1) {
            foreach ($probe in $each) { $lines.Add('      ' + (Format-AddressProbe $probe)) }
            $good = @($each | Where-Object { $_.Ok }).Count
            $lines.Add('      Рабочих адресов: ' + $good + ' из ' + $each.Count + '. TorrentControl начинает с последнего рабочего адреса и пропускает неотвечающие.')
            if ($good -gt 0) { $ok = $true; $probes[$candidate.url] = $each }
        }
        if ($ok -and !$working) { $working = $candidate.url }
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
        $lines.Add('Других внешних прокси, кроме официального прокси RuTracker из его расширения, TorrentControl не предлагает и не использует.')
    }
    $probe = $null
    if ($working -and $probes.ContainsKey($working)) { $probe = $probes[$working] }
    return [pscustomobject]@{ lines = $lines.ToArray(); working = $working; directOk = [bool]$direct.Ok; configured = $configured; probe = $probe }
}
function Save-RuTrackerProxy([string]$Directory, [string]$Url) {
    $value = ConvertTo-RuTrackerProxy $Url
    [IO.File]::WriteAllText((Get-RuTrackerFiles $Directory).proxy, $value + "`r`n", (New-Object Text.ASCIIEncoding))
    Reset-RuTrackerRoute
    return $value
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $report = Invoke-RuTrackerDiagnostics $PSScriptRoot $Proxy -FindLocalProxy:$FindLocalProxy $TimeoutSec -NoOfficialProxy:$NoOfficialProxy -NoAddressProbe:$NoAddressProbe
        foreach ($line in $report.lines) { Write-Host $line }
        [IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'rutracker-connection.txt'), [string[]]$report.lines, (New-Object Text.UTF8Encoding($true)))
        if ($report.working -and ($report.working -ne $report.configured -or $report.probe)) {
            $write = [bool]$Save
            if (!$write -and $Interactive) { $write = ((Read-Host ('Записать ' + $report.working + ' в rutracker-proxy.txt этой папки? Введите YES')).Trim() -eq 'YES') }
            if ($write -and $report.working -ne $report.configured) { $null = Save-RuTrackerProxy $PSScriptRoot $report.working; Write-Host ('Записано в rutracker-proxy.txt: ' + $report.working) }
            if ($write -and $report.probe) {
                Save-RuTrackerAddressProbe $PSScriptRoot $report.working $report.probe
                Write-Host ('Записан порядок адресов прокси (rutracker-proxy-addresses.json): рабочих ' + @($report.probe | Where-Object { $_.Ok }).Count + ' из ' + @($report.probe).Count + '.')
            }
        }
        if ($report.directOk -or $report.working) { exit 0 }
        exit 2
    } catch {
        $code = Get-RuTrackerCode $_.Exception
        $hint = ''
        if ($code -eq 'RuTrackerTlsComponentInvalid') { $hint = ' — нет папки lib\bouncycastle рядом со скриптами или её файл изменён (SHA-256 не совпал); скопируйте папку lib из той же версии' }
        Write-Host ('Проверка остановлена: ' + $code + $hint) -ForegroundColor Red
        exit 1
    }
}
