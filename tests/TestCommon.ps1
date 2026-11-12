# Shared helpers. Tests never use real uTorrent, WebUI, GitHub or the D:/F: drives:
# every such call is replaced by a stub, and temporary files live only in tests\autoload-test-<guid>.
$ErrorActionPreference = 'Stop'
$script:AssertCount = 0
$script:OnWindows = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
function Assert($Value, [string]$Why) {
    $script:AssertCount++
    if (!$Value) { throw "ASSERT FAILED: $Why" }
}
function Assert-Throws([scriptblock]$Block, [string]$Expected, [string]$Why) {
    $message = $null
    try { $null = & $Block } catch { $message = $_.Exception.Message }
    $script:AssertCount++
    if ($null -eq $message) { throw "ASSERT FAILED (nothing thrown): $Why" }
    if ($Expected -and $message -ne $Expected) { throw "ASSERT FAILED (got '$message', expected '$Expected'): $Why" }
}
function New-TestHash([string]$Character) { return ($Character * 40).ToUpperInvariant() }
function New-TestRow {
    # Builds a WebUI list=1 row by field name, following the official index order.
    param([string]$Hash, [string]$Path = '', [long]$Size = 1GB, [int]$Progress = 1000, [long]$Downloaded = -1,
        [long]$Uploaded = 0, [long]$UpSpeed = 0, [long]$Status = 201, [int]$PeersConnected = 0, [int]$PeersSwarm = 0,
        [int]$SeedsConnected = 0, [int]$SeedsSwarm = 0, [long]$Remaining = -1, [int]$Fields = 27, [string]$Name = 'Test film')
    if ($Downloaded -lt 0) { $Downloaded = [long]($Size * $Progress / 1000) }
    if ($Remaining -lt 0) { $Remaining = [math]::Max(0L, $Size - $Downloaded) }
    $row = New-Object object[] $Fields
    for ($i = 0; $i -lt $Fields; $i++) { $row[$i] = 0 }
    $row[0] = $Hash; $row[1] = $Status; $row[2] = $Name; $row[3] = $Size; $row[4] = $Progress; $row[5] = $Downloaded
    $row[6] = $Uploaded; $row[7] = 0; $row[8] = $UpSpeed; $row[9] = 0; $row[10] = 0; $row[11] = ''
    $row[12] = $PeersConnected; $row[13] = $PeersSwarm; $row[14] = $SeedsConnected; $row[15] = $SeedsSwarm
    $row[16] = 65536; $row[17] = -1; $row[18] = $Remaining
    if ($Fields -gt 26) { $row[26] = $Path }
    return ,$row
}
function ConvertTo-WebUIList($Rows) {
    # Round-trip through JSON so value types match what ConvertFrom-Json gives for a real response.
    # Rows are copied into plain arrays: Windows PowerShell 5.1 serializes pipeline-wrapped arrays as {value,Count}.
    $plain = New-Object Collections.ArrayList
    foreach ($row in @($Rows)) {
        $copy = New-Object object[] $row.Count
        for ($i = 0; $i -lt $row.Count; $i++) { $copy[$i] = $row[$i] }
        [void]$plain.Add($copy)
    }
    $json = @{ build = 25534; label = @(); torrents = $plain.ToArray(); torrentc = '1' } | ConvertTo-Json -Depth 6
    return ($json | ConvertFrom-Json)
}
function New-TestDirectory {
    $path = Join-Path $PSScriptRoot ('autoload-test-' + [guid]::NewGuid().ToString('N'))
    $null = Microsoft.PowerShell.Management\New-Item -Path $path -ItemType Directory
    return $path
}
function Remove-TestDirectory([string]$Path) {
    # Removes only a directory created by New-TestDirectory.
    if ($Path -and (Split-Path $Path -Leaf) -match '^autoload-test-[0-9a-f]{32}$' -and
        (Split-Path $Path -Parent) -eq $PSScriptRoot -and (Microsoft.PowerShell.Management\Test-Path -LiteralPath $Path)) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $Path -Recurse -Force
    }
}
function Get-FileText([string]$Path) { return [IO.File]::ReadAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)) }
