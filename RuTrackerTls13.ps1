# Loads TorrentControl's only network transport to RuTracker: RuTrackerRoute.cs (routes, proxy, HTTP) compiled
# together with RuTrackerTls13.cs (TLS 1.3 with the site) and the pinned BouncyCastle.Cryptography 2.7.0 library from
# lib\bouncycastle (see lib\bouncycastle\2.7.0\SOURCE.txt). Nothing is installed or registered on the computer:
# the DLL is read once, its SHA-256 is compared with the pinned value and exactly those bytes are loaded into this
# PowerShell process (a replaced or damaged file stops with TlsLibraryInvalid, a missing one with TlsLibraryMissing).
$script:RuTrackerTls13Library = @{
    Desktop = @{ path = 'lib\bouncycastle\2.7.0\net461\BouncyCastle.Cryptography.dll'; sha256 = '4F96977E9C67334742C683410B3A361258219F0D3084A5E0BC10FBA96CF23A0D' }
    Core = @{ path = 'lib\bouncycastle\2.7.0\net6.0\BouncyCastle.Cryptography.dll'; sha256 = 'EF92FC661E8D7BA8EC4D39A7CDFCDBA41F14CB327F0D24FE79D0B5BB428899B5' }
}
$script:RuTrackerTransportSources = @('RuTrackerTls13.cs', 'RuTrackerRoute.cs')
function Get-RuTrackerTransportReferences {
    # Compile-time references (also used by tests\Test-RuTrackerTls.ps1 for its fake TLS servers). The library path is
    # only a compile-time reference; at run time the SHA-256-verified assembly loaded by Initialize-RuTrackerTransport
    # is used.
    $entry = $script:RuTrackerTls13Library[[string]$PSVersionTable.PSEdition]
    if ($null -eq $entry) { $entry = $script:RuTrackerTls13Library.Desktop }
    $references = @(Join-Path $PSScriptRoot $entry.path)
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # PowerShell 7 (tests): it drops its default references once any are given, and reports the harmless
        # CS1701 version-unification warning of the net6.0 library as an error (callers pass -IgnoreWarnings).
        $references += @('System.Runtime', 'System.Collections', 'System.Net.Primitives', 'System.Net.Sockets', 'System.Net.Security', 'System.Net.NameResolution',
            'System.Security.Cryptography', 'System.Security.Cryptography.X509Certificates', 'System.Runtime.Extensions', 'System.Private.CoreLib', 'System.Collections.NonGeneric',
            'Microsoft.Win32.Primitives', 'System.ComponentModel.Primitives', 'System.Text.Encoding.Extensions', 'System.Diagnostics.Process', 'System.Threading')
    }
    return ,$references
}
function Initialize-RuTrackerTransport {
    if (('RuTrackerTls13' -as [type]) -and ('RuTrackerRoute' -as [type])) { return }
    $entry = $script:RuTrackerTls13Library[[string]$PSVersionTable.PSEdition]
    if ($null -eq $entry) { $entry = $script:RuTrackerTls13Library.Desktop }
    $path = Join-Path $PSScriptRoot $entry.path
    if (![IO.File]::Exists($path)) { throw 'TlsLibraryMissing' }
    $bytes = [IO.File]::ReadAllBytes($path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '' } finally { $sha.Dispose() }
    if ($hash -ne $entry.sha256) { throw 'TlsLibraryInvalid' }
    $assembly = [Reflection.Assembly]::Load($bytes)
    $sources = @($script:RuTrackerTransportSources | ForEach-Object { Join-Path $PSScriptRoot $_ })
    $references = Get-RuTrackerTransportReferences
    if ($PSVersionTable.PSEdition -eq 'Core') { Add-Type -Path $sources -ReferencedAssemblies $references -IgnoreWarnings }
    else { Add-Type -Path $sources -ReferencedAssemblies $references }
    [RuTrackerTlsLibrary]::Register($assembly)
}
