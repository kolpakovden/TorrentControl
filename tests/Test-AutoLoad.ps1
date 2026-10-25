$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\AutoLoad.ps1"
function Assert($value,$why) {if(!$value){throw $why}}
Assert (Test-AutoTitle 'Film WEB-DLRip Dub') 'good title'
Assert (!(Test-AutoTitle 'Film TS Dub')) 'TS accepted'
Assert (!(Test-AutoTitle 'Film WEB-DL Original Eng + Sub Rus')) 'subtitles accepted as voice'
function Row($hash,$path,$size,$done,$progress) {
    $row=New-Object object[] 27;for($i=0;$i -lt 27;$i++){$row[$i]=0}
    $row[0]=$hash;$row[3]=$size;$row[5]=$done;$row[4]=$progress;$row[18]=$size-$done;$row[26]=$path
    return ,$row
}
$rows=@((Row 'A' 'D:\old' 100GB 40GB 400),(Row 'B' 'F:\old' 100GB 0 0))
Assert ((Get-AutoBudget $rows @{} 340GB 20GB) -eq 260GB) 'unfinished D reservation'
$failed=$false;try{$null=Get-AutoBudget @(,(Row 'A' '' 1GB 0 0)) @{} 10GB 0}catch{$failed=$true}
Assert $failed 'unknown path did not block'
$failed=$false;try{Assert-AutoDirectory 'E:\Archive'}catch{$failed=$true};Assert $failed 'E allowed'
$temp=Join-Path $PSScriptRoot ('autoload-test-'+[guid]::NewGuid().ToString('N'));$null=New-Item $temp -ItemType Directory
$fixture=Join-Path $temp 'fixture.torrent'
[IO.File]::WriteAllBytes($fixture,[Convert]::FromBase64String('ZDQ6aW5mb2Q2Omxlbmd0aGk1OGU0Om5hbWUyODpUb3JyZW50Q29udHJvbC1wYXRoLXRlc3QudHh0MTI6cGllY2UgbGVuZ3RoaTE2Mzg0ZTY6cGllY2VzMjA6fif7fCP8oPWUPlhooe+04CEImto3OnByaXZhdGVpMWVlZQ=='))
$script:stateFile="$temp\auto-state.json"
Save-AutoJson @{enabled=$true;destination='D:\Фильмы';reserveGiB=20} "$temp\autoload.json"
Save-AutoJson @{version=1;enabledAt='2026-10-24T00:00:00Z';knownTopics=@('1');items=@()} $script:stateFile
$hash='51CE70C03EC2FBF311F03C4B6570951C3CF28F3A'
$script:meta=[pscustomobject]@{schema=1;hash=$hash;status='success';total_bytes=58;torrent_base64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture))}
$script:free=100GB;$script:launches=0;$script:clientRows=@();$script:stops=0
function Assert-AutoLocalClient {return 'fake.exe'}
function Assert-AutoDirectory {}
function Get-AutoFreeBytes {return $script:free}
function Get-AutoRemoteJson {return $script:meta}
function Read-LocalPaths {return @{}}
function Fetch-List {return [pscustomobject]@{torrents=$script:clientRows}}
function Stop-AutoOwnedTorrent {$script:stops++}
function Test-Path {param([string]$LiteralPath,[string]$Path) if(($LiteralPath+$Path) -like 'D:*'){return $false};if($LiteralPath){return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath};return Microsoft.PowerShell.Management\Test-Path $Path}
function New-Item {param([string]$Path,[string]$ItemType,[switch]$Force) if($Path -like 'D:*'){return};Microsoft.PowerShell.Management\New-Item -Path $Path -ItemType $ItemType -Force:$Force}
function Start-Process {
    param($FilePath,$ArgumentList,$WindowStyle,$ErrorAction)
    $saved=Get-Content $script:stateFile -Raw -Encoding UTF8|ConvertFrom-Json
    Assert (@($saved.items|Where-Object status -eq 'Submitted').Count -eq 1) 'not saved before launch'
    Assert ($ArgumentList -like '/DIRECTORY "D:\Фильмы\rt-2" *') 'wrong CLI path'
    if ($script:failLaunch) {throw 'Simulated launch failure'}
    $script:launches++
}
$baseline=[pscustomobject]@{topic='1';hash=$hash;title='Old WEB-DLRip Dub'}
$new=[pscustomobject]@{topic='2';hash=$hash;title='New WEB-DLRip Dub'}
$null=Invoke-AutoLoad @($baseline) @() @{} @{} $null $temp
Assert ($script:launches -eq 0) 'baseline downloaded'
$script:free=20GB
$null=Invoke-AutoLoad @($new) @() @{} @{} $null $temp
$s=Get-Content $script:stateFile -Raw -Encoding UTF8|ConvertFrom-Json
Assert ($s.items[0].status -eq 'NoSpace') 'low space not deferred'
$script:free=100GB
$null=Invoke-AutoLoad @($new) @() @{} @{} $null $temp
Assert ($script:launches -eq 1) 'missing first submission'
$null=Invoke-AutoLoad @($new) @() @{} @{} $null $temp
Assert ($script:launches -eq 1) 'repeated pending submission'
$script:clientRows=@(,(Row $hash 'D:\Фильмы\rt-2\TorrentControl-path-test.txt' 58 58 1000))
$null=Invoke-AutoLoad @($new) $script:clientRows @{} @{} $null $temp
$s=Get-Content $script:stateFile -Raw -Encoding UTF8|ConvertFrom-Json
Assert ($s.items[0].status -eq 'Confirmed') 'path not confirmed'
$null=Invoke-AutoLoad @($new) @() @{} @{} $null $temp
Assert ($script:launches -eq 1) 'removed confirmed torrent readded'
$s.items[0].status='Submitted';Save-AutoJson $s $script:stateFile
$script:clientRows=@(,(Row $hash 'E:\wrong' 58 0 0))
$null=Invoke-AutoLoad @($new) $script:clientRows @{} @{} $null $temp
$s=Get-Content $script:stateFile -Raw -Encoding UTF8|ConvertFrom-Json
Assert ($s.items[0].status -eq 'NeedsAttention' -and $script:stops -eq 1) 'wrong destination not stopped'
'PASS: filters, incomplete reservations, baseline, low space, persist before submit, no duplicate retry, path confirmation, removed torrent, wrong-path stop'

# Existing hash on any disk is never submitted or stopped.
Save-AutoJson @{version=1;enabledAt='2026-10-24T00:00:00Z';knownTopics=@('1');items=@()} $script:stateFile
$before=$script:launches
$null=Invoke-AutoLoad @($new) $script:clientRows @{} @{} $null $temp
Assert ($script:launches -eq $before) 'existing hash launched'
$s=Get-Content $script:stateFile -Raw -Encoding UTF8|ConvertFrom-Json
Assert ($s.items[0].status -eq 'Existing') 'existing hash not recorded'
# Launch errors retain an attention record and cannot silently retry.
Save-AutoJson @{version=1;enabledAt='2026-10-24T00:00:00Z';knownTopics=@('1');items=@()} $script:stateFile
$script:clientRows=@();$script:failLaunch=$true
try {$null=Invoke-AutoLoad @($new) @() @{} @{} $null $temp} catch {}
$s=Get-Content $script:stateFile -Raw -Encoding UTF8|ConvertFrom-Json
Assert ($s.items[0].status -eq 'NeedsAttention') 'launch failure not retained'
$script:failLaunch=$false
$null=Invoke-AutoLoad @($new) @() @{} @{} $null $temp
Assert ($script:launches -eq $before) 'failed launch retried'
'PASS: existing hashes on E and interrupted-launch recovery'
