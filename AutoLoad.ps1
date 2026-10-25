function Save-AutoJson($Value, [string]$Path) {
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$Path.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$Path.tmp" -Destination $Path -Force
}
function Get-AutoErrorCode($Exception) {
    $allowed=@('UnknownIncompletePath','UnknownRemainingSize','UnsupportedRow','DestinationNotAllowed','DestinationReparseOrFile','WebUINotLocal','ExpectedOneLocalClient','InvalidAutoSettings','AutoBaselineMissing','InvalidAutoState','DriveDUnavailable','TokenMissing')
    if ($Exception.Message -in $allowed) {return $Exception.Message}
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
    if ($Paths.ContainsKey([string]$Row[0])) {return [string]$Paths[[string]$Row[0]]}
    return ''
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
function Stop-AutoOwnedTorrent($Config,$Credential,[string]$Hash) {
    if ($Hash -notmatch '^[A-Fa-f0-9]{40}$') {throw 'InvalidHash'}
    $session=New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $session.Credentials=$Credential.GetNetworkCredential()
    $base=([string]$Config.url).TrimEnd('/')
    $page=Invoke-WebRequest "$base/gui/token.html" -WebSession $session -UseBasicParsing -TimeoutSec 25
    $m=[regex]::Match($page.Content,'<div[^>]*id=["'']token["''][^>]*>([^<]+)</div>')
    if (!$m.Success) {throw 'TokenMissing'}
    $token=[uri]::EscapeDataString($m.Groups[1].Value)
    $null=Invoke-WebRequest "$base/gui/?token=$token&action=stop&hash=$Hash" -WebSession $session -UseBasicParsing -TimeoutSec 25
}
function Write-AutoReport($State,[string]$Directory) {
    $labels=@{WaitingMetadata='Ожидает метаданные';NoSpace='Ожидает место';Submitted='Передано клиенту — ждём подтверждение';Confirmed='Добавлено, путь подтверждён';Existing='Уже есть в клиенте';Rejected='Пропущено';NeedsAttention='Нужна проверка'}
    $rows=@($State.items | ForEach-Object {[pscustomobject]@{
        Статус=$labels[[string]$_.status];Название=$_.title;ГиБ=[math]::Round([double]$_.bytes/1GB,2);Путь=$_.path;Причина=$_.reason;Hash=$_.hash
    }})
    $intro='<h1>Автозагрузка фильмов</h1><p>Обновлено: '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'</p><p>Новые темы после включения; WEB-DL/WEB-DLRip/BDRip, Dub/MVO/DVO. Папка D:\Фильмы, запас 20 ГиБ, максимум одно добавление за опрос. Удаление отключено.</p>'
    $rows | ConvertTo-Html -Head '<meta charset="utf-8"><style>body{font:15px Segoe UI;margin:24px}td,th{border:1px solid #ddd;padding:8px}table{border-collapse:collapse}</style>' -PreContent $intro | Set-Content "$Directory\auto-downloads.html" -Encoding UTF8
}
function Invoke-AutoLoad($Entries,$Rows,$Paths,$Config,$Credential,[string]$Directory) {
    $settingsPath=Join-Path $Directory 'autoload.json'
    if (!(Test-Path $settingsPath)) {return 'Автозагрузка выключена.'}
    $settings=Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (!$settings.enabled) {return 'Автозагрузка выключена.'}
    if ($settings.destination -ne 'D:\Фильмы' -or [double]$settings.reserveGiB -lt 20) {throw 'InvalidAutoSettings'}
    $statePath=Join-Path $Directory 'auto-state.json'
    if (!(Test-Path $statePath)) {throw 'AutoBaselineMissing'}
    $state=Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
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
        $exe=Assert-AutoLocalClient $Config
        Assert-AutoDirectory $settings.destination
        # A submitted record is never automatically submitted again, even if the process died.
        foreach($item in @($state.items | Where-Object status -eq 'Submitted')) {
            $matches=@($Rows | Where-Object {$_[0] -eq $item.hash})
            if (!$matches.Count) {continue}
            $actual=Get-AutoPath $matches[0] $Paths
            if (!$actual) {continue}
            $expected=([IO.Path]::GetFullPath($item.path)).TrimEnd('\')
            $full=[IO.Path]::GetFullPath($actual).TrimEnd('\')
            if ($full -eq $expected -or $full.StartsWith($expected+'\',[StringComparison]::OrdinalIgnoreCase)) {
                $item.status='Confirmed';$item.reason=''
            } else {
                $item.status='NeedsAttention';$item.reason='UnexpectedClientPath'
                Save-AutoJson $state $statePath
                Stop-AutoOwnedTorrent $Config $Credential $item.hash
            }
        }
        if (@($state.items | Where-Object {$_.status -in @('Submitted','NeedsAttention')}).Count) {return 'Автозагрузка ждёт подтверждения предыдущего добавления; см. журнал автозагрузки.'}
        $examined=0
        foreach($item in @($state.items | Where-Object {$_.status -in @('WaitingMetadata','NoSpace')} | Sort-Object lastAttempt)) {
            if (++$examined -gt 3) {break}
            $item.lastAttempt=[DateTimeOffset]::UtcNow.ToString('o')
            if (@($Rows | Where-Object {$_[0] -eq $item.hash}).Count) {$item.status='Existing';continue}
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
            $Rows=$fresh.torrents
            if (@($Rows | Where-Object {$_[0] -eq $item.hash}).Count) {$item.status='Existing';continue}
            $Paths=Read-LocalPaths
            $budget=Get-AutoBudget $Rows $Paths (Get-AutoFreeBytes) ([double]$settings.reserveGiB*1GB)
            if ($size -gt $budget) {$item.status='NoSpace';$item.reason='ReservedForCurrentDownloads';continue}
            $target=Join-Path $settings.destination ('rt-'+$item.topic)
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
