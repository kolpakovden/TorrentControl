function Save-AutoJson($Value, [string]$Path) {
    $full=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$full.tmp" -Encoding UTF8
    # File.Replace keeps the previous version as .bak and never leaves a moment without the file;
    # Move-Item -Force deletes the target first, so a crash there used to lose the journal/history.
    if ([IO.File]::Exists($full)) {[IO.File]::Replace("$full.tmp",$full,"$full.bak")}
    else {[IO.File]::Move("$full.tmp",$full)}
}
function Get-AutoErrorCode($Exception) {
    $allowed=@('UnknownIncompletePath','UnknownRemainingSize','UnsupportedRow','DestinationNotAllowed','DestinationReparseOrFile','WebUINotLocal','ExpectedOneLocalClient','InvalidAutoSettings','AutoBaselineMissing','AutoStateBackupPresent','ReviewCancelled','InvalidAutoState','DriveDUnavailable','TokenMissing','TorrentListMissing')
    if ($Exception.Message -in $allowed) {return $Exception.Message}
    if ($Exception.Message -match '^ClientDataInvalid:(Format|Hash|DuplicateHash|Status|Size|Progress|Downloaded|Uploaded|UploadSpeed|PeersConnected|Remaining)$') {return $Exception.Message}
    return 'SeeClientAndConfiguration'
}
function Get-AutoRemoteJson([string]$Uri) {
    $tls=[Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol=$tls -bor [Net.SecurityProtocolType]::Tls12
        $response=Invoke-WebRequest $Uri -UseBasicParsing -TimeoutSec 25
        if ($response.RawContentStream.Length -gt 6MB) {throw 'ResponseTooLarge'}
        $response.RawContentStream.Position=0
        $reader=New-Object IO.StreamReader($response.RawContentStream,(New-Object Text.UTF8Encoding($false,$true)))
        try {return ($reader.ReadToEnd() | ConvertFrom-Json)} finally {$reader.Dispose()}
    } finally {[Net.ServicePointManager]::SecurityProtocol=$tls}
}
function Test-AutoTitle([string]$Title) {
    return ($Title -match '(?i)\b(WEB[- .]?DL(?:Rip)?|BDRip)\b' -and
        $Title -match '(?i)\b(Dub|MVO|DVO)\b|дубляж|многоголос' -and
        $Title -notmatch '(?i)\b(CAM(?:Rip)?|HDCAM|HDTS|TS|TC)\b')
}
function Assert-AutoDirectory([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -ne 'D:\Фильмы' -and $full -notmatch '^D:\\Фильмы\\rt-[0-9]+$') {throw 'DestinationNotAllowed'}
    $cursor=$full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item=Get-Item -LiteralPath $cursor -Force
            if (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'DestinationReparseOrFile'}
        }
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) {break}
        $cursor=$parent
    }
}
function Get-AutoPath($Row, $Paths) {
    if ($Row.Count -gt 26 -and [string]$Row[26] -match '^[A-Za-z]:\\') {return [string]$Row[26]}
    if ($Paths -and $Paths.ContainsKey([string]$Row[0])) {return [string]$Paths[[string]$Row[0]]}
    return ''
}
function Find-AutoRow($Rows, [string]$Hash) {
    foreach ($row in @($Rows)) {if ($null -ne $row -and [string]$row[0] -eq $Hash) {return ,$row}}
    return $null
}
function Get-AutoPresence($Rows, $Paths, [string]$Hash) {
    # resume.dat also lists torrents the WebUI list may have missed (startup, partial response).
    if ($null -ne (Find-AutoRow $Rows $Hash)) {return 'Client'}
    if ($Paths -and $Paths.ContainsKey($Hash)) {return 'ResumeDat'}
    return ''
}
function Test-AutoListShrank($Before, $After) {
    $present=@{}
    foreach ($row in @($After)) {if ($null -ne $row) {$present[[string]$row[0]]=$true}}
    foreach ($row in @($Before)) {if ($null -ne $row -and !$present.ContainsKey([string]$row[0])) {return $true}}
    return $false
}
function ConvertTo-AutoTime($Value) {
    if ($Value -is [DateTimeOffset]) {return $Value}
    if ($Value -is [DateTime]) {return [DateTimeOffset]$Value.ToUniversalTime()}
    $parsed=[DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$parsed)) {return $parsed}
    return $null
}
function Get-AutoBudget($Rows, $Paths, [double]$FreeBytes, [double]$ReserveBytes) {
    $remaining=0.0
    foreach ($row in $Rows) {
        if ($row.Count -lt 19) {throw 'UnsupportedRow'}
        if ([double]$row[4] -ge 1000) {continue}
        $path=Get-AutoPath $row $Paths
        if (!$path) {throw 'UnknownIncompletePath'}
        if ($path -notmatch '^D:\\') {continue}
        if ([double]$row[3] -le 0 -or [double]$row[5] -lt 0 -or [double]$row[18] -lt 0) {throw 'UnknownRemainingSize'}
        $remaining += [math]::Max([double]$row[18], [math]::Max(0.0,[double]$row[3]-[double]$row[5]))
    }
    return [math]::Max(0.0,$FreeBytes-$ReserveBytes-$remaining)
}
function Get-AutoFreeBytes {
    $drive=New-Object IO.DriveInfo('D:\')
    if (!$drive.IsReady) {throw 'DriveDUnavailable'}
    return $drive.AvailableFreeSpace
}
function Assert-AutoLocalClient($Config) {
    $hostName=([uri]$Config.url).DnsSafeHost
    $addresses=@([Net.IPAddress]::Loopback.ToString(),[Net.IPAddress]::IPv6Loopback.ToString())
    foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        foreach ($ip in $nic.GetIPProperties().UnicastAddresses) {$addresses += $ip.Address.ToString()}
    }
    $resolved=@([Net.Dns]::GetHostAddresses($hostName) | ForEach-Object {$_.ToString()})
    if (!$resolved.Count -or @($resolved | Where-Object {$_ -notin $addresses}).Count) {throw 'WebUINotLocal'}
    $clients=@(Get-Process -Name utorrent -ErrorAction Stop)
    if ($clients.Count -ne 1 -or !$clients[0].Path) {throw 'ExpectedOneLocalClient'}
    return $clients[0].Path
}
function Set-AutoReviewed($State) {
    # Explicit user action: unblocks the queue, keeps the record so the hash is never sent again.
    $count=0
    foreach($item in @($State.items | Where-Object status -eq 'NeedsAttention')) {
        $item.status='Reviewed'
        $item | Add-Member -NotePropertyName reviewedAt -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force
        $count++
    }
    return $count
}
function Write-AutoReport($State,[string]$Directory) {
    $labels=@{WaitingMetadata='Ожидает метаданные';NoSpace='Ожидает место';Submitted='Передано клиенту — ждём подтверждение';Confirmed='Добавлено, путь подтверждён';Existing='Уже есть в клиенте';Rejected='Пропущено';NeedsAttention='Нужна проверка';Reviewed='Проверено пользователем'}
    $reasons=@{
        UnexpectedClientPath='Путь в µTorrent не совпал с папкой автозагрузки. Раздача НЕ остановлена: принадлежность не доказана — проверьте её вручную.'
        NotSeenInClient='µTorrent не показал раздачу в течение 2 часов после передачи. Повторная передача не выполняется.'
        PathNotConfirmed='Путь не подтверждён в течение 24 часов. Повторная передача не выполняется.'
        LaunchFailed='Не удалось запустить µTorrent для передачи. Повторная передача не выполняется.'
        FoundInResumeDat='Найдено в resume.dat µTorrent'
        ClientListUnstable='Список µTorrent изменился во время проверки; повтор при следующем опросе'
        ClientDataInvalid='µTorrent вернул некорректные данные; отправка отложена до корректного списка'
    }
    $rows=@($State.items | ForEach-Object {
        $reason=[string]$_.reason
        if ($reasons.ContainsKey($reason)) {$reason=$reasons[$reason]}
        [pscustomobject]@{Статус=$labels[[string]$_.status];Название=$_.title;ГиБ=[math]::Round([double]$_.bytes/1GB,2);Путь=$_.path;Причина=$reason;Hash=$_.hash}
    })
    $intro='<h1>Автозагрузка фильмов</h1><p>Обновлено: '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'</p><p>Новые темы после включения; WEB-DL/WEB-DLRip/BDRip, Dub/MVO/DVO. Папка D:\Фильмы, запас 20 ГиБ, максимум одно добавление за опрос. Удаление отключено. Автозагрузка никогда не останавливает и не удаляет раздачи.</p><p>«Нужна проверка» блокирует следующие добавления. После проверки в µTorrent запустите 8-Review-autoload.cmd.</p>'
    $rows | ConvertTo-Html -Head '<meta charset="utf-8"><style>body{font:15px Segoe UI;margin:24px}td,th{border:1px solid #ddd;padding:8px}table{border-collapse:collapse}</style>' -PreContent $intro | Set-Content "$Directory\auto-downloads.html" -Encoding UTF8
}
function Invoke-AutoLoad($Entries,$Rows,$Paths,$Config,$Credential,[string]$Directory) {
    # Requires Rules.ps1 (Get-TorrentListProblem); Monitor.ps1 loads it first.
    $settingsPath=Join-Path $Directory 'autoload.json'
    if (!(Test-Path -LiteralPath $settingsPath)) {return 'Автозагрузка выключена.'}
    $settings=Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (!$settings.enabled) {return 'Автозагрузка выключена.'}
    if ($settings.destination -ne 'D:\Фильмы' -or [double]$settings.reserveGiB -lt 20) {throw 'InvalidAutoSettings'}
    $statePath=Join-Path $Directory 'auto-state.json'
    if (!(Test-Path -LiteralPath $statePath)) {
        if ((Test-Path -LiteralPath "$statePath.bak") -or (Test-Path -LiteralPath "$statePath.tmp")) {throw 'AutoStateBackupPresent'}
        throw 'AutoBaselineMissing'
    }
    $state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.version -ne 1 -or !$state.enabledAt) {throw 'InvalidAutoState'}
    $known=@{}; foreach($topic in $state.knownTopics) {$known[[string]$topic]=$true}
    foreach($entry in $Entries) {
        if ($known.ContainsKey([string]$entry.topic)) {continue}
        $known[[string]$entry.topic]=$true
        if ($entry.topic -notmatch '^\d+$' -or $entry.hash -notmatch '^[A-F0-9]{40}$' -or !(Test-AutoTitle $entry.title)) {continue}
        if (@($state.items | Where-Object hash -eq $entry.hash).Count) {continue}
        $state.items=@($state.items)+[pscustomobject]@{topic=$entry.topic;hash=$entry.hash;title=$entry.title;status='WaitingMetadata';bytes=0;path='';reason='';submittedAt='';lastAttempt=''}
    }
    $state.knownTopics=@($known.Keys)
    Save-AutoJson $state $statePath
    try {
        # Nothing is confirmed or submitted from a response with corrupted values.
        $problem=Get-TorrentListProblem $Rows
        if ($problem) {throw "ClientDataInvalid:$problem"}
        $exe=Assert-AutoLocalClient $Config
        Assert-AutoDirectory $settings.destination
        $now=[DateTimeOffset]::UtcNow
        # A submitted record is never automatically submitted again, even if the process died.
        foreach($item in @($state.items | Where-Object status -eq 'Submitted')) {
            $sent=ConvertTo-AutoTime $item.submittedAt
            $row=Find-AutoRow $Rows $item.hash
            $actual=''
            if ($null -ne $row) {$actual=Get-AutoPath $row $Paths}
            if (!$actual) {
                # Only the label changes after a timeout; the record keeps blocking and is never resent.
                if ($null -ne $sent -and $null -eq $row -and @($Rows).Count -and ($now-$sent).TotalHours -ge 2) {$item.status='NeedsAttention';$item.reason='NotSeenInClient'}
                elseif ($null -ne $sent -and $null -ne $row -and ($now-$sent).TotalHours -ge 24) {$item.status='NeedsAttention';$item.reason='PathNotConfirmed'}
                continue
            }
            $expected=([IO.Path]::GetFullPath($item.path)).TrimEnd('\')
            $full=[IO.Path]::GetFullPath($actual).TrimEnd('\')
            if ($full -eq $expected -or $full.StartsWith($expected+'\',[StringComparison]::OrdinalIgnoreCase)) {
                $item.status='Confirmed';$item.reason=''
            } else {
                # The same hash outside our new folder may be a manual or pre-existing torrent:
                # ownership cannot be proven, so the torrent is left untouched and only autoload stops.
                $item.status='NeedsAttention';$item.reason='UnexpectedClientPath'
            }
        }
        if (@($state.items | Where-Object {$_.status -in @('Submitted','NeedsAttention')}).Count) {return 'Автозагрузка ждёт подтверждения предыдущего добавления или проверки пользователем; см. журнал автозагрузки.'}
        if (!@($Rows).Count) {return 'Автозагрузка ждёт: µTorrent вернул пустой список раздач.'}
        $examined=0
        foreach($item in @($state.items | Where-Object {$_.status -in @('WaitingMetadata','NoSpace')} | Sort-Object lastAttempt)) {
            if (++$examined -gt 3) {break}
            $item.lastAttempt=[DateTimeOffset]::UtcNow.ToString('o')
            $presence=Get-AutoPresence $Rows $Paths $item.hash
            if ($presence) {$item.status='Existing';$item.reason=$(if($presence -eq 'ResumeDat'){'FoundInResumeDat'}else{''});continue}
            try {$meta=Get-AutoRemoteJson ('https://raw.githubusercontent.com/kolpakovden/TorrentControl/main/data/metadata/'+$item.hash+'.json')}
            catch {$item.status='WaitingMetadata';$item.reason='CacheNotAvailable';continue}
            if ($meta.status -ne 'success') {$item.status='WaitingMetadata';$item.reason='PeersNotAvailable';continue}
            $cache=Join-Path $Directory 'metadata-cache'
            $null=New-Item $cache -ItemType Directory -Force
            $torrent=Join-Path $cache ($item.hash+'.torrent')
            try {
                if ($meta.schema -ne 1 -or $meta.hash -ne $item.hash -or ([string]$meta.torrent_base64).Length -gt 5500000) {throw 'MetadataInvalid'}
                [IO.File]::WriteAllBytes($torrent,[Convert]::FromBase64String($meta.torrent_base64))
                if (!('TorrentMetadata' -as [type])) {Add-Type -Path "$PSScriptRoot\TorrentMetadata.cs"}
                $size=[TorrentMetadata]::Verify($torrent,$item.hash)
                if ($size -le 0 -or $size -ne [long]$meta.total_bytes) {throw 'MetadataSizeMismatch'}
                [TorrentMetadata]::Sanitize($torrent,$item.hash)
                $item.bytes=$size
            } catch {$item.status='Rejected';$item.reason='MetadataOrPathValidationFailed';continue}
            # Refresh before mutation: includes any manual additions since the monitor started.
            $fresh=Fetch-List $Config $Credential
            $freshRows=@($fresh.torrents)
            $problem=Get-TorrentListProblem $freshRows
            if ($problem) {$item.reason='ClientDataInvalid';throw "ClientDataInvalid:$problem"}
            $Paths=Read-LocalPaths
            $presence=Get-AutoPresence $freshRows $Paths $item.hash
            if ($presence) {$item.status='Existing';$item.reason=$(if($presence -eq 'ResumeDat'){'FoundInResumeDat'}else{''});continue}
            # An empty list or one that lost torrents seen moments ago cannot prove absence.
            if (!$freshRows.Count -or (Test-AutoListShrank $Rows $freshRows)) {
                $item.reason='ClientListUnstable'
                return 'Автозагрузка отложена: список µTorrent изменился во время проверки.'
            }
            $Rows=$freshRows
            $budget=Get-AutoBudget $Rows $Paths (Get-AutoFreeBytes) ([double]$settings.reserveGiB*1GB)
            if ($size -gt $budget) {$item.status='NoSpace';$item.reason='ReservedForCurrentDownloads';continue}
            # Plain concatenation: the destination is fixed and validated; Join-Path would require drive D: to be mounted in PowerShell.
            $target=$settings.destination+'\rt-'+$item.topic
            Assert-AutoDirectory $target
            if (Test-Path -LiteralPath $target) {$item.status='Rejected';$item.reason='DestinationAlreadyExists';continue}
            $null=New-Item $target -ItemType Directory
            Assert-AutoDirectory $target
            $item.path=$target;$item.status='Submitted';$item.reason='';$item.submittedAt=[DateTimeOffset]::UtcNow.ToString('o')
            # Persist BEFORE process launch. A crash cannot cause automatic duplicate submission.
            Save-AutoJson $state $statePath
            try {Start-Process -FilePath $exe -ArgumentList ('/DIRECTORY "{0}" "{1}"' -f $target,$torrent) -WindowStyle Hidden -ErrorAction Stop}
            catch {$item.status='NeedsAttention';$item.reason='LaunchFailed';throw}
            return 'Раздача передана в µTorrent; путь будет проверен при следующем опросе.'
        }
        return 'Автозагрузка включена; очередь проверена.'
    } finally {Save-AutoJson $state $statePath;Write-AutoReport $state $Directory}
}
