# Loads the TLS 1.3 component (RuTrackerTls13.cs) with the pinned BouncyCastle.Cryptography 2.7.0 library from
# lib\bouncycastle (see lib\bouncycastle\2.7.0\SOURCE.txt). Nothing is installed or registered on the computer:
# the DLL is read once, its SHA-256 is compared with the pinned value and exactly those bytes are loaded into this
# PowerShell process (a replaced or damaged file stops with TlsLibraryInvalid, a missing one with TlsLibraryMissing).
$script:RuTrackerTls13Library = @{
    Desktop = @{ path = 'lib\bouncycastle\2.7.0\net461\BouncyCastle.Cryptography.dll'; sha256 = '4F96977E9C67334742C683410B3A361258219F0D3084A5E0BC10FBA96CF23A0D' }
    Core = @{ path = 'lib\bouncycastle\2.7.0\net6.0\BouncyCastle.Cryptography.dll'; sha256 = 'EF92FC661E8D7BA8EC4D39A7CDFCDBA41F14CB327F0D24FE79D0B5BB428899B5' }
}
function Initialize-RuTrackerTls13 {
    if ('RuTrackerTls13' -as [type]) { return }
    $entry = $script:RuTrackerTls13Library[[string]$PSVersionTable.PSEdition]
    if ($null -eq $entry) { $entry = $script:RuTrackerTls13Library.Desktop }
    $path = Join-Path $PSScriptRoot $entry.path
    if (![IO.File]::Exists($path)) { throw 'TlsLibraryMissing' }
    $bytes = [IO.File]::ReadAllBytes($path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '' } finally { $sha.Dispose() }
    if ($hash -ne $entry.sha256) { throw 'TlsLibraryInvalid' }
    $assembly = [Reflection.Assembly]::Load($bytes)
    # The path is only a compile-time reference; at run time the verified assembly above is used.
    $references = @($path)
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # PowerShell 7 (tests): it drops its default references once any are given, and reports the harmless
        # CS1701 version-unification warning of the net6.0 library as an error.
        $references += @('System.Runtime', 'System.Collections', 'System.Net.Primitives', 'System.Net.Sockets', 'System.Security.Cryptography',
            'System.Security.Cryptography.X509Certificates', 'System.Runtime.Extensions', 'System.Private.CoreLib', 'System.Collections.NonGeneric', 'Microsoft.Win32.Primitives', 'System.ComponentModel.Primitives')
        Add-Type -Path (Join-Path $PSScriptRoot 'RuTrackerTls13.cs') -ReferencedAssemblies $references -IgnoreWarnings
    } else {
        Add-Type -Path (Join-Path $PSScriptRoot 'RuTrackerTls13.cs') -ReferencedAssemblies $references
    }
    [RuTrackerTlsLibrary]::Register($assembly)
}
