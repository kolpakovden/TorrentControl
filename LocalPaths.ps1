function Read-LocalPaths {
    if (!('ResumePaths' -as [type])) { Add-Type -Path "$PSScriptRoot\ResumePaths.cs" }
    $candidates = @()
    if (Test-Path "$PSScriptRoot\resume-path.txt") {
        $candidates = @((Get-Content "$PSScriptRoot\resume-path.txt" -Raw).Trim().Trim('"'))
    } else {
        $candidates += (Join-Path $env:APPDATA 'uTorrent\resume.dat')
        foreach ($process in @(Get-Process -Name 'utorrent' -ErrorAction SilentlyContinue)) {
            try { if ($process.Path) { $candidates += Join-Path (Split-Path $process.Path) 'resume.dat' } } catch { }
        }
    }
    $map = @{}; $conflicts = @{}; $readCount = 0; $failed = 0
    foreach ($file in @($candidates | Select-Object -Unique)) {
        if (!(Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        try {
            $entries = [ResumePaths]::Load($file)
            $readCount++
            foreach ($entry in $entries.GetEnumerator()) {
                if ($conflicts.ContainsKey($entry.Key)) { continue }
                if ($map.ContainsKey($entry.Key) -and $map[$entry.Key] -ne $entry.Value) {
                    $map.Remove($entry.Key); $conflicts[$entry.Key] = $true
                } else { $map[$entry.Key] = $entry.Value }
            }
        } catch { $failed++ }
    }
    Add-Content "$PSScriptRoot\monitor.log" "$(Get-Date -Format s) PATHS: resumeFiles=$readCount, readErrors=$failed, paths=$($map.Count), conflicts=$($conflicts.Count)" -Encoding UTF8
    return $map
}
