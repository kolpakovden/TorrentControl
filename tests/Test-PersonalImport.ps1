. "$PSScriptRoot\TestCommon.ps1"
. "$PSScriptRoot\..\Test-PersonalMigration.ps1"
. "$PSScriptRoot\..\Import-PersonalTorrent.ps1"
if (!('TorrentMetadata' -as [type])) { Add-Type -Path "$PSScriptRoot\..\TorrentMetadata.cs" }
# Import of personal .torrent files downloaded in Firefox and the read-only Dry Run for one old torrent.
# Offline: no RuTracker request is allowed at all, uTorrent is a fake WebUI, keys are fake.
$temp = New-TestDirectory
$savedLocal = $env:LOCALAPPDATA
try {
    $env:LOCALAPPDATA = Join-Path $temp 'LocalAppData'
    $downloads = Join-Path $temp 'Downloads'
    $tm = Join-Path $temp 'TorrentMonitor'            # stands for C:\TorrentMonitor: must stay untouched
    $app = Join-Path $temp 'app'
    foreach ($d in @($downloads, $tm, $app)) { $null = Microsoft.PowerShell.Management\New-Item -Path $d -ItemType Directory }
    function Resolve-Local([string]$Path) { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    function Read-Bytes([string]$Path) { return ,[IO.File]::ReadAllBytes((Resolve-Local $Path)) }

    # --- No network, no credential, no cookie: any such call fails the test --------------------------------
    $script:forbidden = New-Object Collections.ArrayList
    function Invoke-RuTrackerHttp { [void]$script:forbidden.Add('http'); throw 'NETWORK' }
    function Invoke-RuTrackerRouteCheck { [void]$script:forbidden.Add('route'); throw 'NETWORK' }
    function Read-RuTrackerCredential([string]$Directory) { [void]$script:forbidden.Add('credential'); return $null }
    function Read-RuTrackerSessionText([string]$Directory) { [void]$script:forbidden.Add('session'); return '' }
    function Get-SystemRuTrackerProxy { return '' }
    function Read-LocalPaths { return $script:resumePaths }
    $script:resumePaths = @{}

    # --- Records of TorrentControl (auto-state.json in the "working" folder) -------------------------------
    $infos = @{}; $h = @{}
    foreach ($k in @('A', 'B', 'C', 'D', 'E', 'F', 'G', 'M', 'X')) { $infos[$k] = New-TestInfo ('Film ' + $k + '.mkv') 58 $k; $h[$k] = Get-TestSha1 (ConvertTo-TestBencode $infos[$k]) }
    $topics = @{ A = '6612345'; B = '6612346'; C = '7000001'; D = '7000002'; E = '6612347'; F = '6612348'; G = '6612349' }
    function Item($k, $status, $path) { [pscustomobject]@{ topic = $topics[$k]; hash = $h[$k]; title = 'Film ' + $k; status = $status; bytes = 58; path = $path; reason = ''; submittedAt = ''; lastAttempt = '' } }
    $items = @(
        (Item 'A' 'Confirmed' 'D:\Фильмы\rt-6612345'), (Item 'B' 'Confirmed' 'D:\Фильмы\rt-6612346'), (Item 'C' 'WaitingAuth' ''),
        (Item 'D' 'Existing' ''), (Item 'E' 'Confirmed' 'D:\Фильмы\rt-9999999'), (Item 'F' 'Confirmed' 'D:\Фильмы\rt-6612348'),
        (Item 'G' 'Confirmed' 'D:\Фильмы\rt-6612349'))
    Save-AutoJson ([ordered]@{ version = 1; enabledAt = '2026-01-01T00:00:00Z'; items = $items }) (Join-Path $tm 'auto-state.json')
    [IO.File]::WriteAllText((Resolve-Local (Join-Path $tm 'config.json')), '{"url":"http://127.0.0.1:8080"}')
    foreach ($name in @('credential.xml', 'state.json', 'monitor.log', 'feed-state.json')) { [IO.File]::WriteAllText((Resolve-Local (Join-Path $tm $name)), "working file $name") }
    function Get-FolderSnapshot([string]$Folder) {
        return (@(Get-ChildItem -LiteralPath $Folder -Force | Sort-Object Name | ForEach-Object { $_.Name + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks + '|' + (Get-TestSha1 (Read-Bytes $_.FullName)) }) -join "`n")
    }
    $tmBefore = Get-FolderSnapshot $tm

    # --- Files "downloaded in Firefox" ---------------------------------------------------------------------
    $personalA = 'http://bt2.rutracker.cx/ann?kk=FAKE-IMPORT-KEY-A'
    $retracker = 'http://retracker.local/announce'
    $public = 'http://bt.t-ru.org/ann?magnet'
    function New-Download([string]$Name, $Info, [string]$Announce, $Tiers = $null, [string]$CommentTopic = '') {
        $top = [ordered]@{}
        if ($Announce) { $top['announce'] = $Announce }
        if ($null -ne $Tiers) { $top['announce-list'] = @(foreach ($tier in $Tiers) { ,@($tier) }) }
        if ($CommentTopic) { $top['comment'] = 'https://rutracker.org/forum/viewtopic.php?t=' + $CommentTopic }
        $top['info'] = $Info
        $path = Join-Path $downloads $Name
        [IO.File]::WriteAllBytes((Resolve-Local $path), (ConvertTo-TestBencode $top))
        return $path
    }
    # The name claims topic 7000001; the content is topic 6612345: the name is never trusted.
    $goodA = New-Download '[rutracker.org].t7000001.torrent' $infos.A $personalA @(@($personalA), @($retracker)) '6612345'
    $sourceBefore = Get-TestSha1 (Read-Bytes $goodA)
    $stored = Join-Path $env:LOCALAPPDATA ('TorrentControl\personal\' + $h.A + '.torrent')

    # --- Refusals: nothing is stored --------------------------------------------------------------------------
    $cut = Join-Path $downloads 'cut.torrent'
    $bytes = Read-Bytes $goodA
    [IO.File]::WriteAllBytes((Resolve-Local $cut), [byte[]]$bytes[0..($bytes.Length - 12)])
    $refusals = @(
        @((Join-Path $downloads 'missing.torrent'), '', 'ImportFileMissing'),
        @($cut, '', 'PersonalTorrentInvalid'),
        @((New-Download 'other.torrent' $infos.X $personalA $null '6612345'), '', 'ImportNotInAutoState'),
        @($goodA, '7000001', 'ImportTopicMismatch'),
        @($goodA, 'abc', 'InvalidTopic'),
        @((New-Download 'comment.torrent' $infos.A $personalA $null '7000001'), '', 'PersonalTopicMismatch'),
        @((New-Download 'public.torrent' $infos.A $public @(,@($public)) '6612345'), '', 'PersonalAnnounceMissing'),
        @((New-Download 'foreign.torrent' $infos.A 'https://example.com/announce?id=123' $null '6612345'), '', 'PersonalAnnounceMissing'),
        @((New-Download 'lookalike.torrent' $infos.A 'http://bt2.rutracker.cx.example.com/ann?kk=FAKE-IMPORT-KEY-L' $null '6612345'), '', 'PersonalAnnounceMissing'),
        @((New-Download 'mixed-public.torrent' $infos.A $personalA @(@($personalA), @($public)) '6612345'), '', 'PersonalTrackersUnexpected'),
        @((New-Download 'mixed-foreign.torrent' $infos.A $personalA @(@($personalA), @('https://example.com/announce?id=123')) '6612345'), '', 'PersonalTrackersUnexpected'),
        @((New-Download 'existing.torrent' $infos.D 'http://bt2.rutracker.cx/ann?kk=FAKE-IMPORT-KEY-D' $null '7000002'), '', 'ImportStatusNotAllowed'),
        @((New-Download 'wrongfolder.torrent' $infos.E 'http://bt2.rutracker.cx/ann?kk=FAKE-IMPORT-KEY-E' $null '6612347'), '', 'ImportStatusNotAllowed'))
    foreach ($case in $refusals) {
        Assert-Throws { Import-PersonalTorrentFile $case[0] $tm $case[1] } $case[2] "import of $(Split-Path $case[0] -Leaf) not refused with $($case[2])"
    }
    Assert (![IO.File]::Exists((Resolve-Local $stored))) 'a refused file was stored'
    $leftovers = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'TorrentControl\personal') -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 })
    Assert ($leftovers.Count -eq 0) "refused files left content behind: $($leftovers.Name -join ', ')"

    # --- Import: original bytes, found by infohash, verified -----------------------------------------------------
    $result = Import-PersonalTorrentFile $goodA $tm ''
    Assert ($result.status -eq 'Imported' -and $result.topic -eq '6612345' -and $result.hash -eq $h.A -and $result.host -eq 'bt2.rutracker.cx' -and $result.record -eq 'Confirmed') "import result: $($result | Out-String)"
    Assert ((Resolve-Local $result.path) -eq (Resolve-Local $stored) -and (Get-TestSha1 (Read-Bytes $stored)) -eq $sourceBefore) 'stored file differs from the downloaded one'
    Assert ((Get-TestSha1 (Read-Bytes $goodA)) -eq $sourceBefore) 'the downloaded file was changed'
    Assert ((Import-PersonalTorrentFile $goodA $tm '6612345').status -eq 'AlreadyImported') 'repeated import not recognised'
    $secondA = New-Download 'second-A.torrent' $infos.A 'http://bt2.rutracker.cx/ann?kk=FAKE-IMPORT-KEY-A2' $null '6612345'
    Assert ((Import-PersonalTorrentFile $secondA $tm '').status -eq 'Replaced' -and (Get-TestSha1 (Read-Bytes $stored)) -eq (Get-TestSha1 (Read-Bytes $secondA))) 'newer valid file not stored'
    # A bad file never replaces a stored good one.
    Assert-Throws { Import-PersonalTorrentFile (Join-Path $downloads 'mixed-public.torrent') $tm '' } 'PersonalTrackersUnexpected' 'bad replacement accepted'
    Assert ((Get-TestSha1 (Read-Bytes $stored)) -eq (Get-TestSha1 (Read-Bytes $secondA))) 'stored file replaced by a refused one'
    $null = Import-PersonalTorrentFile $goodA $tm ''
    if ($script:OnWindows) {
        $acl = Get-Acl -LiteralPath (Join-Path $env:LOCALAPPDATA 'TorrentControl\personal')
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        Assert ($acl.AreAccessRulesProtected -and $rules.Count -eq 1 -and $rules[0].IdentityReference -eq [Security.Principal.WindowsIdentity]::GetCurrent().User) 'personal folder is not limited to the current user'
    }

    # --- Use: Get-PersonalTorrent takes the verified local file, without network or credential -------------------
    $c = New-Download 'c.torrent' $infos.C 'http://bt3.t-ru.org/ann?pk=FAKE-IMPORT-KEY-C' @(@('http://bt3.t-ru.org/ann?pk=FAKE-IMPORT-KEY-C'), @($retracker)) '7000001'
    $null = Import-PersonalTorrentFile $c $tm '7000001'
    $local = Get-PersonalTorrent $app '7000001' $h.C
    Assert ($local.source -eq 'Local' -and $local.host -eq 'bt3.t-ru.org' -and $script:forbidden.Count -eq 0) "imported file not used offline: $($script:forbidden -join ',')"
    Assert-Throws { Get-PersonalTorrent $app '7000099' $h.C } 'PersonalImportInvalid' 'stored file used for another topic'
    # Without an imported file the previous behaviour stays: waiting for authorization, no public fallback.
    Assert-Throws { Get-PersonalTorrent $app '6612346' $h.B } 'RuTrackerNotConfigured' 'missing import did not fall back to the RuTracker login path'
    Assert ((@($script:forbidden) -join ',') -eq 'credential') "unexpected access without import: $($script:forbidden -join ',')"
    $script:forbidden.Clear()
    # Tampering after the import: another torrent or an unconfirmed tracker under the same name is never used.
    $storedC = Join-Path $env:LOCALAPPDATA ('TorrentControl\personal\' + $h.C + '.torrent')
    $goodC = Read-Bytes $storedC
    foreach ($fake in @((Read-Bytes (Join-Path $downloads 'other.torrent')), (Read-Bytes (New-Download 'c-public.torrent' $infos.C $public $null '7000001')),
        (Read-Bytes (New-Download 'c-foreign.torrent' $infos.C 'https://example.com/announce?id=7' $null '7000001')), [byte[]]@(100, 101))) {
        [IO.File]::WriteAllBytes((Resolve-Local $storedC), [byte[]]$fake)
        Assert-Throws { Get-PersonalTorrent $app '7000001' $h.C } 'PersonalImportInvalid' 'tampered file used'
    }
    Assert ($script:forbidden.Count -eq 0) 'a tampered file caused a network or credential access'
    [IO.File]::WriteAllBytes((Resolve-Local $storedC), [byte[]]$goodC)

    # --- Dry Run for one old torrent (uTorrent only read) -----------------------------------------------------------
    $script:requests = New-Object Collections.ArrayList
    $script:clientRows = [ordered]@{}
    $script:webuiDown = $false
    function Add-Client([string]$Key, [string]$Path, [string]$Trackers) { $script:clientRows[$h[$Key]] = @{ row = (New-TestRow $h[$Key] $Path -Size 58); trackers = $Trackers } }
    function Invoke-WebRequest {
        param([Parameter(Position = 0)][string]$Uri, $WebSession, [switch]$UseBasicParsing, $TimeoutSec)
        [void]$script:requests.Add($Uri)
        if ($script:webuiDown) { throw ('WebUI failed for ' + $Uri + ' FAKE-IMPORT-KEY-A') }
        $stream = { param($text) [pscustomobject]@{ Content = $text; RawContentStream = (New-Object IO.MemoryStream(, [Text.Encoding]::UTF8.GetBytes($text))) } }
        if ($Uri -like '*/gui/token.html') { return [pscustomobject]@{ Content = '<html><div id="token" style="display:none;">FAKE-TOKEN</div></html>' } }
        $query = @{}
        foreach ($pair in ($Uri -replace '^[^?]*\?', '').Split('&')) { $kv = $pair.Split('=', 2); $query[$kv[0]] = [uri]::UnescapeDataString($kv[1]) }
        if ($query.list -eq '1') {
            $plain = New-Object Collections.ArrayList
            foreach ($t in $script:clientRows.Values) { $copy = New-Object object[] $t.row.Count; for ($i = 0; $i -lt $t.row.Count; $i++) { $copy[$i] = $t.row[$i] }; [void]$plain.Add($copy) }
            return (& $stream (@{ build = 25534; label = @(); torrents = $plain.ToArray(); torrentc = '1' } | ConvertTo-Json -Depth 6))
        }
        if ($query.action -eq 'getprops') { return (& $stream (@{ build = 25534; props = @(@{ hash = $query.hash; trackers = $script:clientRows[$query.hash].trackers }) } | ConvertTo-Json -Depth 4)) }
        throw "forbidden WebUI request: $Uri"
    }
    Add-Client 'A' 'D:\Фильмы\rt-6612345\Film A' ($public + "`r`n")
    Add-Client 'B' 'D:\Фильмы\rt-6612346\Film B' ($public + "`r`n")
    Add-Client 'E' 'D:\Фильмы\rt-9999999' ($public + "`r`n")
    Add-Client 'F' 'D:\Фильмы\rt-6612348' ('http://bt2.rutracker.cx/ann?kk=FAKE-IMPORT-KEY-F' + "`r`n`r`n" + $retracker + "`r`n")
    Add-Client 'G' 'F:\Moved\Film G' ($public + "`r`n")
    Add-Client 'M' 'D:\Manual\Film M' ($public + "`r`n")        # manual torrent, not in auto-state.json
    $trackersBefore = @{}; foreach ($key in @($script:clientRows.Keys)) { $trackersBefore[$key] = $script:clientRows[$key].trackers }
    foreach ($k in @('F', 'G')) { $null = Import-PersonalTorrentFile (New-Download "$k.torrent" $infos[$k] "http://bt2.rutracker.cx/ann?kk=FAKE-IMPORT-KEY-$k" $null $topics[$k]) $tm '' }
    $config = [pscustomobject]@{ url = 'http://127.0.0.1:8080' }
    $credential = New-Object Management.Automation.PSCredential('admin', (ConvertTo-SecureString 'fake-webui' -AsPlainText -Force))
    function Check([string]$Topic = '', [string]$Hash = '', [switch]$Offline) { return (Invoke-PersonalMigrationCheck $tm $Hash $Topic $config $credential -NoWebUI:$Offline) }
    $ready = Check '6612345'
    Assert ($ready.verdict -eq 'ReadyToRebind' -and $ready.current -eq 'Public' -and $ready.planned -eq 'bt2.rutracker.cx' -and $ready.clientPath -eq 'D:\Фильмы\rt-6612345\Film A') "ready check: $($ready.verdict)/$($ready.reason)"
    $expect = @(@('6612346', 'NotImported'), @('6612348', 'AlreadyPersonal'), @('6612349', 'PathMismatch'), @('6612347', 'NotOwnedByTorrentControl'), @('7000001', 'NotOwnedByTorrentControl'))
    foreach ($case in $expect) {
        $r = Check $case[0]
        Assert ($r.verdict -eq 'NotReady' -and $r.reason -eq $case[1]) "topic $($case[0]): $($r.verdict)/$($r.reason), expected $($case[1])"
    }
    $count = $script:requests.Count
    $null = Check '6612347'
    Assert ($script:requests.Count -eq $count) 'a torrent that is not TorrentControl''s was read from uTorrent'
    Assert-Throws { Check -Hash $h.M } 'NotInAutoState' 'manual torrent checked'
    Assert-Throws { Check '1234' } 'NotInAutoState' 'unknown topic checked'
    Assert-Throws { Check } 'HashOrTopicRequired' 'check without a torrent'
    Assert-Throws { Check '6612345' $h.B } 'ImportTopicMismatch' 'hash and topic of different torrents accepted'
    $offline = Check '6612345' -Offline
    Assert ($offline.verdict -eq 'OfflineOnly' -and $offline.reason -eq 'OfflineOnly') 'offline check claimed readiness'
    $script:webuiDown = $true
    $down = Check '6612345'
    Assert ($down.verdict -eq 'NotReady' -and $down.reason -eq 'ClientUnavailable') "WebUI failure: $($down.reason)"
    $script:webuiDown = $false
    [IO.File]::WriteAllBytes((Resolve-Local $stored), (Read-Bytes (Join-Path $downloads 'public.torrent')))
    $tampered = Check '6612345'
    Assert ($tampered.verdict -eq 'NotReady' -and $tampered.reason -eq 'PersonalImportInvalid') "tampered import in the check: $($tampered.reason)"
    $null = Import-PersonalTorrentFile $goodA $tm ''
    # uTorrent: only token.html, list=1 and getprops; trackers unchanged; the changing functions are disabled.
    $bad = @($script:requests | Where-Object { $_ -notmatch '/gui/token\.html$' -and $_ -notmatch '[?&]list=1$' -and $_ -notmatch '&action=getprops&hash=[0-9A-F]{40}$' })
    Assert ($bad.Count -eq 0) "WebUI request other than reading: $($bad -join ' | ')"
    foreach ($key in @($script:clientRows.Keys)) { Assert ($script:clientRows[$key].trackers -eq $trackersBefore[$key]) "trackers of $key changed" }
    Assert-Throws { Set-WebUITrackers $null $h.A 'x' } 'ReadOnlyViolation' 'tracker change possible in the check'
    Assert-Throws { Invoke-TrackerMigration -Directory $tm -Mode Apply } 'ReadOnlyViolation' 'migration possible in the check'
    Assert ($script:forbidden.Count -eq 0) "RuTracker network or credential used: $($script:forbidden -join ',')"

    # --- Reports and list: links for Firefox, no key anywhere ---------------------------------------------------
    $entries = @(Get-PersonalMigrationList $tm)
    Assert ((@($entries | ForEach-Object { $_.topic }) -join ',') -eq '6612345,6612346,6612348,6612349') "list: $(@($entries | ForEach-Object { $_.topic }) -join ',')"
    $rowA = @($entries | Where-Object { $_.topic -eq '6612345' })[0]
    Assert ($rowA.imported -eq 'да (bt2.rutracker.cx)' -and $rowA.topicUrl -eq 'https://rutracker.org/forum/viewtopic.php?t=6612345' -and $rowA.downloadUrl -eq 'https://rutracker.org/forum/dl.php?t=6612345') 'list row A'
    Assert (@($entries | Where-Object { $_.topic -eq '6612346' })[0].imported -eq 'нет') 'list row B'
    $reports = Join-Path $temp 'reports'
    $null = Microsoft.PowerShell.Management\New-Item -Path $reports -ItemType Directory
    $html = Get-FileText (Write-PersonalMigrationList $entries $reports)
    Assert ($html -match 'href="https://rutracker\.org/forum/dl\.php\?t=6612345"' -and $html -match 'Раздачи TorrentControl') 'list HTML'
    $texts = @($html, ((Format-PersonalCheck $ready) -join "`n"), ((Format-PersonalCheck $down) -join "`n"), ((Format-PersonalCheck (Check '6612346')) -join "`n"),
        ((Format-ImportResult (Import-PersonalTorrentFile $goodA $tm '')) -join "`n"))
    Assert ($texts[1] -match 'ГОТОВО К ПЕРЕПРИВЯЗКЕ' -and $texts[1] -match 'В µTorrent ничего не изменялось' -and $texts[3] -match 'не импортирован') 'check report text'
    foreach ($text in $texts) { Assert ($text -notmatch 'FAKE-IMPORT-KEY|kk=|pk=') 'a personal key reached a report' }
    foreach ($code in @($script:PersonalImportCodes)) { Assert ($script:PersonalTexts.ContainsKey($code)) "no explanation for $code" }

    # --- The working TorrentControl folder was only read ------------------------------------------------------
    Assert ((Get-FolderSnapshot $tm) -eq $tmBefore) 'the working TorrentControl folder changed'
} finally { $env:LOCALAPPDATA = $savedLocal; Remove-TestDirectory $temp }
"PASS Test-PersonalImport: $script:AssertCount assertions"
