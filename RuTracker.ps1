# Personal (account-bound) .torrent files from RuTracker - on this computer only.
# Mechanism verified against two widely used open-source clients (Jackett RuTracker indexer,
# qBittorrent RuTracker plugin):
#   login:    POST https://rutracker.org/forum/login.php, windows-1251 form login_username, login_password, login=Вход;
#             success = cookie bb_session; CAPTCHA = image on static.rutracker.cc/captcha + fields cap_sid and cap_code_*.
#   download: GET https://rutracker.org/forum/dl.php?t=<topic id> with the session cookies.
# A CAPTCHA is never solved automatically: only Setup-RuTracker.ps1 shows it to the person.
# Nothing here talks to GitHub. The password and session cookies are stored with Windows DPAPI for the current
# Windows user (like credential.xml); personal .torrent files go to %LOCALAPPDATA%\TorrentControl\personal.
# Passwords, cookies and announce keys are never written to logs, reports or the autoload journal.
$script:RuTrackerForum = 'https://rutracker.org/forum/'
$script:PublicAnnounce = 'http://bt.t-ru.org/ann?magnet'
# RuTracker tracker servers: host bt, bt2, bt3, ... (number not fixed) on a confirmed domain, path exactly /ann.
#   t-ru.org      - bt.t-ru.org is the public announce of the GitHub metadata cache; bt..bt4.t-ru.org are RuTracker's
#                   tracker hosts;
#   rutracker.cx  - personal announce of a real .torrent downloaded from the user's account (bt2.rutracker.cx/ann?kk=);
#   rutracker.org - historical bt*.rutracker.org announces.
# A domain is added here only after it is seen in a real file from rutracker.org. Unknown servers fail closed.
$script:RuTrackerTrackerDomains = @('t-ru.org', 'rutracker.cx', 'rutracker.org')
# Keyless tracker RuTracker itself adds to its .torrent files (local ISP retracker); allowed next to the personal one.
$script:NeutralTrackerHosts = @('retracker.local')
$script:RuTrackerSecrets = New-Object Collections.Generic.List[string]
# At most one automatic login per this many minutes (repeated logins are what makes RuTracker ask for a CAPTCHA).
$script:RuTrackerLoginPauseMinutes = 30
$script:RuTrackerProxy = ''
$script:RuTrackerCodes = @('RuTrackerNotConfigured','RuTrackerCredentialUnreadable','RuTrackerProxyInvalid','PersonalTrackersUnexpected','RuTrackerLoginFailed','RuTrackerCaptchaRequired','RuTrackerAuthExpired',
    'RuTrackerUnavailable','RuTrackerTopicUnavailable','PersonalTorrentInvalid','PersonalHashMismatch','PersonalAnnounceMissing','LocalAppDataMissing')

function Add-RuTrackerSecret([string]$Value) { if ($Value -and $Value.Length -ge 4 -and !$script:RuTrackerSecrets.Contains($Value)) { $script:RuTrackerSecrets.Add($Value) } }
function Protect-SecretText([string]$Text) {
    # Defence in depth for any text that could reach a log or report: URL parameters, cookie and password
    # assignments and every secret seen in this process are masked.
    if (!$Text) { return $Text }
    $out = [regex]::Replace($Text, '(?i)([?&;][a-z0-9_.-]{1,32}=)[^&\s"''<>;]+', '$1***')
    $out = [regex]::Replace($out, '(?i)\b(bb_[a-z0-9_]+|cookie|password|login_password|passkey|cap_code_[a-z0-9]+)(\s*[=:]\s*)[^;\s"''&<>]+', '$1$2***')
    foreach ($secret in $script:RuTrackerSecrets) { $out = $out.Replace($secret, '***') }
    return $out
}
function Get-RuTrackerCode($Exception) {
    if ($Exception -and [string]$Exception.Message -in $script:RuTrackerCodes) { return [string]$Exception.Message }
    return 'RuTrackerUnavailable'
}
function Get-RuTrackerFiles([string]$Directory) {
    [pscustomobject]@{
        proxy = Join-Path $Directory 'rutracker-proxy.txt'
        credential = Join-Path $Directory 'rutracker-credential.xml'
        session = Join-Path $Directory 'rutracker-session.xml'
        state = Join-Path $Directory 'rutracker-state.json'
    }
}
function Get-PersonalTorrentDirectory {
    # Inside the Windows user profile, not next to the scripts: the files contain the personal announce key.
    if (!$env:LOCALAPPDATA) { throw 'LocalAppDataMissing' }
    return (Join-Path $env:LOCALAPPDATA 'TorrentControl\personal')
}

# --- Announce analysis -----------------------------------------------------------------------------------
# Personal = RuTracker server (see RuTrackerTrackerDomains) + path /ann + only name=value parameters with non-empty
# values. Parameter names (kk, pk, ...) and key length are not fixed. A query on any other host never makes a URL
# personal: https://example.com/announce?id=123 is a foreign tracker.
function Get-AnnounceInfo([string]$Url) {
    $none = [pscustomobject]@{ valid = $false; host = ''; rutracker = $false; personal = $false; public = $false; neutral = $false; keys = @() }
    $uri = $null
    if (![Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo -or
        $uri.Fragment -or $uri.Host -notmatch '^[A-Za-z0-9.-]{1,253}$' -or $Url -match '[\s\\]') { return $none }
    $hostName = $uri.Host.ToLowerInvariant()
    $query = ''
    if ($Url.Contains('?')) { $query = $Url.Substring($Url.IndexOf('?') + 1) }
    $pairs = @(); if ($query) { $pairs = @($query.Split('&')) }
    # Values of every name=value pair are treated as secrets (masked in any text), whatever the host.
    $keys = @(foreach ($pair in $pairs) { if ($pair -match '^[^=]*=(.+)$') { $Matches[1] } })
    $domains = @($script:RuTrackerTrackerDomains | ForEach-Object { [regex]::Escape($_) }) -join '|'
    # Checked on the text itself: no port, no other path, no lookalike suffix such as bt2.rutracker.cx.example.com.
    $rutracker = ($Url -match ('^https?://bt[0-9]{0,2}\.(' + $domains + ')/ann(\?.*)?$'))
    $personal = $false
    if ($rutracker -and $pairs.Count) {
        $personal = $true
        foreach ($pair in $pairs) { if ($pair -notmatch '^[A-Za-z][A-Za-z0-9_]{0,31}=[^&=#"''<>]{1,512}$') { $personal = $false } }
    }
    [pscustomobject]@{ valid = $true; host = $hostName; rutracker = $rutracker; personal = $personal
        public = ($rutracker -and $query -eq 'magnet'); neutral = ($hostName -in $script:NeutralTrackerHosts -and !$query); keys = $keys }
}
function Get-TrackerSetInfo($Urls) {
    # Counts: personal RuTracker, public RuTracker, neutral (retracker.local), other (foreign, unknown or malformed).
    $set = [ordered]@{ personal = 0; public = 0; neutral = 0; other = 0; host = '' }
    foreach ($url in @($Urls)) {
        $info = Get-AnnounceInfo ([string]$url)
        foreach ($key in @($info.keys)) { Add-RuTrackerSecret $key }
        if ($info.personal) { $set.personal++; if (!$set.host) { $set.host = $info.host } }
        elseif ($info.public) { $set.public++ }
        elseif ($info.neutral) { $set.neutral++ }
        else { $set.other++ }
    }
    return [pscustomobject]$set
}
function Get-TorrentTrackerInfo([string]$Path) {
    if (!('TorrentMetadata' -as [type])) { Add-Type -Path "$PSScriptRoot\TorrentMetadata.cs" }
    $tiers = @([TorrentMetadata]::ReadTrackers($Path))
    $set = Get-TrackerSetInfo @(foreach ($tier in $tiers) { foreach ($url in @($tier)) { [string]$url } })
    [pscustomobject]@{ tiers = $tiers; host = $set.host; personal = $set.personal; public = $set.public; other = $set.other }
}
function Test-PersonalTorrent([string]$Path, [string]$ExpectedHash) {
    # Same infohash as the feed, valid file list, at least one personal RuTracker announce, and nothing else
    # except the neutral retracker: a public RuTracker or a foreign tracker in the file stops (fail-closed).
    if (!('TorrentMetadata' -as [type])) { Add-Type -Path "$PSScriptRoot\TorrentMetadata.cs" }
    $size = 0L
    try { $size = [TorrentMetadata]::Verify($Path, $ExpectedHash) }
    catch {
        if ([string]$_.Exception.InnerException.Message -eq 'Infohash mismatch' -or [string]$_.Exception.Message -match 'Infohash mismatch') { throw 'PersonalHashMismatch' }
        throw 'PersonalTorrentInvalid'
    }
    $trackers = $null
    try { $trackers = Get-TorrentTrackerInfo $Path } catch { throw 'PersonalTorrentInvalid' }
    if ($trackers.personal -lt 1) { throw 'PersonalAnnounceMissing' }
    if ($trackers.public -or $trackers.other) { throw 'PersonalTrackersUnexpected' }
    [pscustomobject]@{ size = $size; host = $trackers.host; tiers = $trackers.tiers }
}

# --- HTTP (one function, replaced by stubs in tests) ---------------------------------------------------
function Read-RuTrackerProxy([string]$Directory) {
    # Optional rutracker-proxy.txt: one line http://host:port, used only for requests to RuTracker (no system settings
    # change). Without the file Windows' own proxy settings apply. Proxy passwords are not supported (no secrets in files).
    $path = (Get-RuTrackerFiles $Directory).proxy
    if (!(Test-Path -LiteralPath $path)) { return '' }
    $text = "$(Get-Content -LiteralPath $path -Raw)".Trim()
    $uri = $null
    if (![Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'http' -or $uri.UserInfo -or
        $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment -or $uri.Host -notmatch '^[A-Za-z0-9.-]{1,253}$') { throw 'RuTrackerProxyInvalid' }
    return $uri.GetLeftPart([UriPartial]::Authority)
}
function Get-RuTrackerEncoding {
    try { return [Text.Encoding]::GetEncoding(1251) }
    catch { [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance); return [Text.Encoding]::GetEncoding(1251) }
}
function ConvertTo-FormValue([string]$Value) {
    $out = New-Object Text.StringBuilder
    foreach ($b in (Get-RuTrackerEncoding).GetBytes($Value)) {
        $c = [char]$b
        if (($b -ge 48 -and $b -le 57) -or ($b -ge 65 -and $b -le 90) -or ($b -ge 97 -and $b -le 122) -or $c -in @('-', '_', '.', '~')) { [void]$out.Append($c) }
        else { [void]$out.Append('%' + $b.ToString('X2')) }
    }
    return $out.ToString()
}
function Invoke-RuTrackerHttp([string]$Method, [string]$Url, $Session, [string]$Form = '') {
    $tls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $tls -bor [Net.SecurityProtocolType]::Tls12
        $params = @{ Uri = $Url; Method = $Method; WebSession = $Session; UseBasicParsing = $true; TimeoutSec = 30 }
        if ($script:RuTrackerProxy) { $params.Proxy = $script:RuTrackerProxy }
        if ($Form) { $params.Body = [Text.Encoding]::ASCII.GetBytes($Form); $params.ContentType = 'application/x-www-form-urlencoded' }
        $response = Invoke-WebRequest @params
        $response.RawContentStream.Position = 0
        $bytes = $response.RawContentStream.ToArray()
        return [pscustomobject]@{ status = [int]$response.StatusCode; contentType = [string]$response.Headers['Content-Type']; bytes = $bytes }
    } catch {
        # WebException (5.1) or HttpResponseException (7): keep only the status code, never the message.
        $status = 0
        try { if ($null -ne $_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { $status = 0 }
        return [pscustomobject]@{ status = $status; contentType = ''; bytes = [byte[]]@() }
    } finally { [Net.ServicePointManager]::SecurityProtocol = $tls }
}
function Get-SessionCookieText($Session) {
    $pairs = foreach ($cookie in $Session.Cookies.GetCookies([Uri]$script:RuTrackerForum)) { $cookie.Name + '=' + $cookie.Value }
    return (@($pairs) -join '; ')
}
function New-RuTrackerSession([string]$CookieText = '') {
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    foreach ($pair in $CookieText.Split(';')) {
        if ($pair.Trim() -match '^([A-Za-z0-9_]{1,64})=([^;\s]{1,4096})$') {
            $session.Cookies.Add([Uri]$script:RuTrackerForum, (New-Object Net.Cookie($Matches[1], $Matches[2])))
            Add-RuTrackerSecret $Matches[2]
        }
    }
    return $session
}
function Test-RuTrackerLoggedIn($Session) {
    foreach ($cookie in $Session.Cookies.GetCookies([Uri]$script:RuTrackerForum)) { if ($cookie.Name -eq 'bb_session' -and $cookie.Value) { return $true } }
    return $false
}

# --- Login (CAPTCHA only through a person) -------------------------------------------------------------
function Get-RuTrackerCaptcha([string]$Html) {
    $image = [regex]::Match($Html, '(?i)<img[^>]+src="(https://static\.rutracker\.cc/captcha/[^"<>\s]+)"')
    $sid = [regex]::Match($Html, '(?i)<input[^>]*name="cap_sid"[^>]*value="([^"<>\s]+)"|<input[^>]*value="([^"<>\s]+)"[^>]*name="cap_sid"')
    $field = [regex]::Match($Html, '(?i)name="(cap_code_[A-Za-z0-9]{1,64})"')
    if (!$image.Success -or !$sid.Success -or !$field.Success) { return $null }
    $sidValue = $sid.Groups[1].Value; if (!$sidValue) { $sidValue = $sid.Groups[2].Value }
    [pscustomobject]@{ image = $image.Groups[1].Value; sid = $sidValue; field = $field.Groups[1].Value }
}
function Invoke-RuTrackerLogin($Credential, $Captcha = $null, [string]$CaptchaCode = '', $Session = $null) {
    # Returns { ok; session; captcha }; never retries on its own.
    if ($null -eq $Session) { $Session = New-RuTrackerSession }
    $network = $Credential.GetNetworkCredential()
    Add-RuTrackerSecret $network.Password
    $form = 'login_username=' + (ConvertTo-FormValue $network.UserName) + '&login_password=' + (ConvertTo-FormValue $network.Password) + '&login=' + (ConvertTo-FormValue 'Вход')
    if ($Captcha -and $CaptchaCode) { $form += '&cap_sid=' + (ConvertTo-FormValue $Captcha.sid) + '&' + $Captcha.field + '=' + (ConvertTo-FormValue $CaptchaCode) }
    $response = Invoke-RuTrackerHttp 'Post' ($script:RuTrackerForum + 'login.php') $Session $form
    if ($response.status -eq 0) { throw 'RuTrackerUnavailable' }
    if (Test-RuTrackerLoggedIn $Session) {
        foreach ($cookie in $Session.Cookies.GetCookies([Uri]$script:RuTrackerForum)) { Add-RuTrackerSecret $cookie.Value }
        return [pscustomobject]@{ ok = $true; session = $Session; captcha = $null }
    }
    $html = (Get-RuTrackerEncoding).GetString([byte[]]$response.bytes)
    return [pscustomobject]@{ ok = $false; session = $Session; captcha = (Get-RuTrackerCaptcha $html) }
}

# --- Stored credential, session and state (DPAPI for this Windows user) ----------------------------------
function Read-RuTrackerState([string]$Directory) {
    $path = (Get-RuTrackerFiles $Directory).state
    if (!(Test-Path -LiteralPath $path)) { return [pscustomobject]@{ blocked = ''; checkedAt = ''; loginAt = 0L; host = '' } }
    # A damaged state file blocks automatic logins until Setup-RuTracker.ps1 (fail-closed).
    try { $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json; $loginAt = [long]$state.loginAt }
    catch { return [pscustomobject]@{ blocked = 'RuTrackerLoginFailed'; checkedAt = ''; loginAt = 0L; host = '' } }
    [pscustomobject]@{ blocked = [string]$state.blocked; checkedAt = [string]$state.checkedAt; loginAt = $loginAt; host = [string]$state.host }
}
function Save-RuTrackerState([string]$Directory, [string]$Blocked, [string]$HostName = '', [switch]$LoginAttempt) {
    # No secrets here: a fixed code, times and the tracker host name.
    $old = Read-RuTrackerState $Directory
    $loginAt = [long]$old.loginAt
    if ($LoginAttempt) { $loginAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    if (!$HostName) { $HostName = $old.host }
    Save-AutoJson ([ordered]@{ version = 1; blocked = $Blocked; checkedAt = [DateTimeOffset]::UtcNow.ToString('o'); loginAt = $loginAt; host = $HostName }) (Get-RuTrackerFiles $Directory).state
}
function Read-RuTrackerCredential([string]$Directory) {
    $path = (Get-RuTrackerFiles $Directory).credential
    if (!(Test-Path -LiteralPath $path)) { return $null }
    # DPAPI: only the Windows user who ran 9-RuTracker-login.cmd can decrypt it (the scheduled task runs as that user).
    try { $credential = Import-Clixml -LiteralPath $path; $null = $credential.GetNetworkCredential().Password } catch { throw 'RuTrackerCredentialUnreadable' }
    if ($credential -isnot [Management.Automation.PSCredential]) { throw 'RuTrackerCredentialUnreadable' }
    return $credential
}
function Read-RuTrackerSessionText([string]$Directory) {
    $path = (Get-RuTrackerFiles $Directory).session
    if (!(Test-Path -LiteralPath $path)) { return '' }
    try { return (Import-Clixml -LiteralPath $path).GetNetworkCredential().Password } catch { return '' }
}
function Save-RuTrackerSessionText([string]$Directory, [string]$CookieText) {
    $secure = ConvertTo-SecureString -String $CookieText -AsPlainText -Force
    New-Object Management.Automation.PSCredential('rutracker-session', $secure) | Export-Clixml -LiteralPath (Get-RuTrackerFiles $Directory).session
}

# --- Personal .torrent for a topic (used by autoload and migration) ------------------------------------
function Get-RuTrackerTorrentBytes($Session, [string]$Topic) {
    if ($Topic -notmatch '^\d{1,12}$') { throw 'RuTrackerTopicUnavailable' }
    $response = Invoke-RuTrackerHttp 'Get' ($script:RuTrackerForum + 'dl.php?t=' + $Topic) $Session
    if ($response.status -eq 0) { throw 'RuTrackerUnavailable' }
    if ($response.status -in @(404, 410)) { throw 'RuTrackerTopicUnavailable' }
    $bytes = [byte[]]$response.bytes
    # A .torrent is a bencoded dictionary; an HTML page (login form) means the session is not valid.
    if ($bytes.Length -lt 2 -or $bytes.Length -gt 4000000 -or $bytes[0] -ne 100 -or $response.contentType -match 'text/html') { throw 'RuTrackerAuthExpired' }
    return ,$bytes
}
function Get-PersonalTorrent([string]$Directory, [string]$Topic, [string]$Hash) {
    # Fail-closed: any problem is a fixed code; a public version is never returned instead.
    $script:RuTrackerProxy = Read-RuTrackerProxy $Directory
    $state = Read-RuTrackerState $Directory
    if ($state.blocked) { throw $state.blocked }
    $credential = Read-RuTrackerCredential $Directory
    if ($null -eq $credential) { throw 'RuTrackerNotConfigured' }
    $session = New-RuTrackerSession (Read-RuTrackerSessionText $Directory)
    $bytes = $null
    if (Test-RuTrackerLoggedIn $session) {
        try { $bytes = Get-RuTrackerTorrentBytes $session $Topic } catch { if ([string]$_.Exception.Message -ne 'RuTrackerAuthExpired') { throw } }
    }
    if ($null -eq $bytes) {
        # One automatic login with the stored credential, not more often than every RuTrackerLoginPauseMinutes;
        # a CAPTCHA or a refusal stops automatic logins until Setup-RuTracker.ps1.
        $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$state.loginAt
        if ($age -ge 0 -and $age -lt $script:RuTrackerLoginPauseMinutes * 60) { throw 'RuTrackerAuthExpired' }
        Save-RuTrackerState $Directory '' -LoginAttempt
        $login = Invoke-RuTrackerLogin $credential
        if (!$login.ok) {
            $code = 'RuTrackerLoginFailed'
            if ($login.captcha) { $code = 'RuTrackerCaptchaRequired' }
            Save-RuTrackerState $Directory $code
            throw $code
        }
        Save-RuTrackerSessionText $Directory (Get-SessionCookieText $login.session)
        $bytes = Get-RuTrackerTorrentBytes $login.session $Topic
    }
    $folder = Get-PersonalTorrentDirectory
    if (!(Test-Path -LiteralPath $folder)) { $null = New-Item -Path $folder -ItemType Directory -Force }
    $path = Join-Path $folder ($Hash.ToUpperInvariant() + '.torrent')
    [IO.File]::WriteAllBytes($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path), $bytes)
    $checked = Test-PersonalTorrent $path $Hash
    [pscustomobject]@{ path = $path; host = $checked.host; tiers = $checked.tiers; size = $checked.size }
}
