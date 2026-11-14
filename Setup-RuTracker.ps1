param([switch]$Check)
# RuTracker login for personal .torrent files (see RuTracker.ps1). Run interactively by the person:
# a CAPTCHA, if RuTracker asks for one, is shown as a picture and typed in by the person - never solved by code.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Feed.ps1"
. "$PSScriptRoot\AutoLoad.ps1"
. "$PSScriptRoot\RuTracker.ps1"
$explain = @{
    SetupCancelled = 'Ввод отменён.'
    RuTrackerLoginFailed = 'RuTracker не принял логин или пароль. Проверьте их в браузере и повторите.'
    RuTrackerCaptchaRequired = 'RuTracker требует CAPTCHA, а код не подошёл. Повторите 9-RuTracker-login.cmd.'
    RuTrackerNotConfigured = 'Вход не настроен: запустите 9-RuTracker-login.cmd.'
    RuTrackerCredentialUnreadable = 'rutracker-credential.xml не читается этой учётной записью Windows. Повторите 9-RuTracker-login.cmd под тем пользователем, от имени которого работает монитор.'
    RuTrackerAuthExpired = 'Сессия не действует, а повторный вход не дал файл. Повторите 9-RuTracker-login.cmd.'
    RuTrackerUnavailable = 'rutracker.org недоступен с этого компьютера напрямую. Запустите 15-RuTracker-connection.cmd: он проверит маршрут официального расширения RuTracker (как в Firefox) и локальный прокси Hiddify и запишет рабочий в rutracker-proxy.txt.'
    RuTrackerProxyUnavailable = 'Прокси из rutracker-proxy.txt не отвечает или отказал. Запустите 15-RuTracker-connection.cmd, чтобы найти рабочий маршрут.'
    RuTrackerTlsFailed = 'Защищённое соединение с rutracker.org не установлено (сертификат или TLS). Пароль не отправлялся. Проверка сертификатов не отключается.'
    RuTrackerBlocked = 'rutracker.org ответил 403/429 (доступ запрещён или слишком много запросов). Повторите позже.'
    RuTrackerRedirectRefused = 'RuTracker перенаправил запрос на другой адрес; запрос не выполнен.'
    RuTrackerProxyInvalid = 'rutracker-proxy.txt должен содержать одну строку вида http://адрес:порт (без логина и пароля).'
    RuTrackerTopicUnavailable = 'Проверочная тема недоступна; повторите позже.'
    PersonalAnnounceMissing = 'Файл получен, но в нём нет персонального адреса подтверждённого сервера RuTracker (bt*.t-ru.org, bt*.rutracker.cx, bt*.rutracker.org).'
    PersonalImportInvalid = 'Сохранённый персональный .torrent для этой темы не прошёл повторную проверку; импортируйте его заново (16-Import-personal-torrent.cmd).'
    PersonalTopicMismatch = 'Файл относится к другой теме RuTracker.'
    PersonalTrackersUnexpected = 'В файле кроме персонального адреса есть публичный или посторонний трекер; такой файл не используется.'
    PersonalHashMismatch = 'Хеш полученного файла не совпал с лентой.'
    PersonalTorrentInvalid = 'Полученный файл повреждён.'
    LocalAppDataMissing = 'Не определена папка профиля Windows (LOCALAPPDATA).'
}
$lock = $null
try {
    $lock = [IO.File]::Open("$PSScriptRoot\monitor.lock", 'OpenOrCreate', 'ReadWrite', 'None')
    $files = Get-RuTrackerFiles $PSScriptRoot
    $script:RuTrackerProxy = Resolve-RuTrackerProxy $PSScriptRoot
    if ($script:RuTrackerProxy) { Write-Host ('Запросы к RuTracker идут через прокси ' + $script:RuTrackerProxy + ' (только для TorrentControl).') }
    else { Write-Host 'Запросы к RuTracker идут напрямую (rutracker-proxy.txt нет, прокси Windows не задан).' }
    # The route is checked anonymously before the password is asked for and sent.
    Assert-RuTrackerRoute
    Write-Host 'Соединение с rutracker.org проверено (TLS, сертификат действителен).'
    if (!$Check) {
        Write-Host 'Вход в RuTracker для персональных .torrent. Пароль хранится зашифрованным для этой учётной записи Windows (DPAPI)'
        Write-Host 'и отправляется только на rutracker.org. На GitHub не передаётся ничего из этих данных.'
        $credential = Get-Credential -Message 'RuTracker: логин и пароль'
        if (!$credential) { throw 'SetupCancelled' }
        $login = Invoke-RuTrackerLogin $credential
        for ($attempt = 0; !$login.ok -and $login.captcha -and $attempt -lt 3; $attempt++) {
            $extension = '.jpg'
            if ($login.captcha.image -match '\.(png|gif|jpe?g)$') { $extension = '.' + $Matches[1] }
            $folder = Split-Path (Get-PersonalTorrentDirectory)
            if (!(Test-Path -LiteralPath $folder)) { $null = New-Item -Path $folder -ItemType Directory -Force }
            $image = Join-Path $folder ('captcha' + $extension)
            $picture = Invoke-RuTrackerHttp 'Get' $login.captcha.image $login.session
            [IO.File]::WriteAllBytes($image, [byte[]]$picture.bytes)
            Start-Process -FilePath $image
            Write-Host 'RuTracker просит CAPTCHA: картинка открыта. Введите символы с неё.'
            $code = Read-Host 'Код с картинки'
            if (!$code) { throw 'SetupCancelled' }
            $login = Invoke-RuTrackerLogin $credential $login.captcha $code $login.session
        }
        if (!$login.ok) { if ($login.captcha) { throw 'RuTrackerCaptchaRequired' }; throw 'RuTrackerLoginFailed' }
        $credential | Export-Clixml -LiteralPath $files.credential
        Save-RuTrackerSessionText $PSScriptRoot (Get-SessionCookieText $login.session)
        Save-RuTrackerState $PSScriptRoot '' -LoginAttempt
        Write-Host 'Вход выполнен.'
    }
    # End-to-end check: the personal .torrent of a current topic from the public feed, infohash and announce verified.
    $snapshot = Read-MirrorText ($script:FeedMirrorBase + 'forum-252.json') 30 | ConvertFrom-Json
    $entries = @(Convert-FilmFeed ([string]$snapshot.xml) | Where-Object { $_.hash } | Select-Object -First 3)
    $personal = $null
    foreach ($entry in $entries) {
        try { $personal = Get-PersonalTorrent $PSScriptRoot $entry.topic $entry.hash; break }
        catch { if ((Get-RuTrackerCode $_.Exception) -ne 'PersonalHashMismatch') { throw } }
    }
    if ($null -eq $personal) { throw 'PersonalHashMismatch' }
    Save-RuTrackerState $PSScriptRoot '' $personal.host
    Write-Host ('ПРОВЕРКА ПРОЙДЕНА: персональный .torrent темы ' + $entry.topic + ' получен, infohash совпадает с лентой, сервер статистики: ' + $personal.host + ' (ключ не показывается).')
    Write-Host 'Это подтверждает получение файла. Начисление отдачи нужно проверить в профиле RuTracker (README, план проверки).'
} catch {
    $code = Get-RuTrackerCode $_.Exception
    if ([string]$_.Exception.Message -eq 'SetupCancelled') { $code = 'SetupCancelled' }
    Write-Host ('RuTracker: ' + $code + ' — ' + $explain[$code]) -ForegroundColor Red
    exit 1
} finally { if ($lock) { $lock.Dispose() } }
