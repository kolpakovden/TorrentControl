param([string]$Proxy = 'https://ps1.blockme.site:443', [string]$Target = 'rutracker.org', [int]$TimeoutSec = 8, [int]$Repeat = 1,
    [string[]]$DirectAddress = @(), [switch]$ByName)
# Diagnostic only (no production code uses it): what the far end of the RuTracker proxy tunnel answers to different
# TLS ClientHello messages. Anonymous and read-only: no login, no cookie, nothing is sent after the first handshake
# message except one anonymous HEAD /forum/index.php when a Schannel handshake fully succeeds with normal certificate
# validation. Certificates are never accepted without validation: the hand-built ClientHello probes stop at the
# server's first answer and never complete a handshake. Nothing on this computer is changed (registry, DNS, proxy,
# VPN, Hiddify, Firefox, uTorrent); the report is written to rutracker-tls-probe.txt next to this script.
#   default         every IPv4 address of the proxy name is tested separately (TLS still validated for the proxy name)
#   -ByName         connect by name only (one address chosen by Windows, as Firefox/curl do)
#   -DirectAddress  also send the hand-built ClientHello directly to these addresses of the site (no proxy), with and
#                   without SNI, to see whether the direct path is filtered by SNI or closed altogether
$ErrorActionPreference = 'Stop'
$source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text;

public sealed class TlsProbeResult {
    public string Variant = "";
    public string Outcome = "";     // ServerHello, HelloRetryRequest, Alert, Closed, Timeout, NotTls, HandshakeOk, HandshakeFailed, ProxyFailed
    public string Detail = "";
    public string Proxy = "";       // outer TLS of the proxy and the CONNECT status
    public string Address = "";     // address actually connected to
    public long ElapsedMs;
}

public static class TlsProbe {
    static readonly string HrrRandom = "CF21AD74E59A6111BE1D8C021E65B891C2A211167ABB8C5E079E09E2C8A8339C";

    // Hand-built ClientHello. Variants: tls13-alpn, tls13-noalpn, tls12-only, tls13-nosni.
    public static byte[] BuildClientHello(string variant, string serverName) {
        bool tls13 = variant.StartsWith("tls13");
        bool sni = variant != "tls13-nosni";
        bool alpn = variant == "tls13-alpn" || variant == "tls13-nosni" || variant == "tls12-only";
        var random = new byte[32]; var session = new byte[32]; var share = new byte[32];
        var rng = System.Security.Cryptography.RandomNumberGenerator.Create();
        rng.GetBytes(random); rng.GetBytes(session); rng.GetBytes(share);
        var ciphers = new List<int>();
        if (tls13) { ciphers.Add(0x1301); ciphers.Add(0x1302); ciphers.Add(0x1303); }
        ciphers.AddRange(new[] { 0xC02B, 0xC02F, 0xC02C, 0xC030, 0xCCA9, 0xCCA8, 0xC013, 0xC014, 0x009C, 0x009D, 0x002F, 0x0035 });
        var ext = new MemoryStream();
        if (sni) {
            byte[] name = Encoding.ASCII.GetBytes(serverName);
            var list = new MemoryStream(); list.WriteByte(0); U16(list, name.Length); list.Write(name, 0, name.Length);
            Ext(ext, 0x0000, Vec16(list.ToArray()));
        }
        Ext(ext, 0x0017, new byte[0]);                                   // extended_master_secret
        Ext(ext, 0xFF01, new byte[] { 0 });                              // renegotiation_info
        Ext(ext, 0x000A, Vec16(new byte[] { 0x00, 0x1D, 0x00, 0x17, 0x00, 0x18 }));   // x25519, secp256r1, secp384r1
        Ext(ext, 0x000B, new byte[] { 1, 0 });                           // ec_point_formats
        Ext(ext, 0x0023, new byte[0]);                                   // session_ticket
        if (alpn) Ext(ext, 0x0010, Vec16(new byte[] { 2, (byte)'h', (byte)'2', 8, (byte)'h', (byte)'t', (byte)'t', (byte)'p', (byte)'/', (byte)'1', (byte)'.', (byte)'1' }));
        Ext(ext, 0x0005, new byte[] { 1, 0, 0, 0, 0 });                  // status_request
        Ext(ext, 0x000D, Vec16(new byte[] { 0x04, 0x03, 0x08, 0x04, 0x04, 0x01, 0x05, 0x03, 0x08, 0x05, 0x05, 0x01, 0x08, 0x06, 0x06, 0x01, 0x02, 0x01 }));
        if (tls13) {
            var ks = new MemoryStream(); U16(ks, 0x001D); U16(ks, 32); ks.Write(share, 0, 32);
            Ext(ext, 0x0033, Vec16(ks.ToArray()));                       // key_share x25519
            Ext(ext, 0x002B, new byte[] { 4, 0x03, 0x04, 0x03, 0x03 });  // supported_versions 1.3, 1.2
            Ext(ext, 0x002D, new byte[] { 1, 1 });                       // psk_key_exchange_modes
        }
        var body = new MemoryStream();
        body.WriteByte(3); body.WriteByte(3);
        body.Write(random, 0, 32);
        body.WriteByte(32); body.Write(session, 0, 32);
        U16(body, ciphers.Count * 2); foreach (int c in ciphers) U16(body, c);
        body.WriteByte(1); body.WriteByte(0);
        byte[] extensions = ext.ToArray(); U16(body, extensions.Length); body.Write(extensions, 0, extensions.Length);
        byte[] hello = body.ToArray();
        var handshake = new MemoryStream();
        handshake.WriteByte(1); handshake.WriteByte((byte)(hello.Length >> 16)); U16(handshake, hello.Length & 0xFFFF); handshake.Write(hello, 0, hello.Length);
        byte[] message = handshake.ToArray();
        var record = new MemoryStream();
        record.WriteByte(0x16); record.WriteByte(3); record.WriteByte(1); U16(record, message.Length); record.Write(message, 0, message.Length);
        return record.ToArray();
    }

    // The first TLS record of the server, described: ServerHello (version, cipher, ALPN when visible), HRR, alert.
    public static string[] Describe(byte[] header, byte[] body) {
        if (header.Length < 5) return new[] { "Closed", "no answer (connection closed)" };
        int type = header[0];
        if (type == 0x15 && body.Length >= 2) return new[] { "Alert", (body[0] == 2 ? "fatal " : "warning ") + AlertName(body[1]) + " (" + body[1] + ")" };
        if (type == 0x16 && body.Length >= 38 && body[0] == 2) {
            int p = 4;
            int legacy = (body[p] << 8) | body[p + 1]; p += 2;
            string random = BitConverter.ToString(body, p, 32).Replace("-", ""); p += 32;
            int sid = body[p]; p += 1 + sid;
            if (p + 3 > body.Length) return new[] { "ServerHello", "truncated" };
            int cipher = (body[p] << 8) | body[p + 1]; p += 3;
            int version = legacy; string alpn = "";
            if (p + 2 <= body.Length) {
                int end = Math.Min(body.Length, p + 2 + ((body[p] << 8) | body[p + 1])); p += 2;
                while (p + 4 <= end) {
                    int et = (body[p] << 8) | body[p + 1]; int el = (body[p + 2] << 8) | body[p + 3]; p += 4;
                    if (et == 0x002B && el == 2 && p + 2 <= end) version = (body[p] << 8) | body[p + 1];
                    if (et == 0x0010 && el > 3 && p + el <= end) alpn = Encoding.ASCII.GetString(body, p + 3, body[p + 2]);
                    p += el;
                }
            }
            string text = VersionName(version) + ", cipher 0x" + cipher.ToString("X4") + (alpn.Length > 0 ? ", ALPN " + alpn : "");
            return new[] { random == HrrRandom ? "HelloRetryRequest" : "ServerHello", text };
        }
        if (type >= 0x14 && type <= 0x17) return new[] { "TlsOther", "record type " + type + ", version 0x" + header[1].ToString("X2") + header[2].ToString("X2") };
        var all = new byte[header.Length + Math.Min(body.Length, 27)];
        Array.Copy(header, all, header.Length); Array.Copy(body, 0, all, header.Length, all.Length - header.Length);
        return new[] { "NotTls", Printable(all) };
    }

    // Hand-built ClientHello sent directly to host:port (no proxy, no CONNECT): ALPN/TLS of a proxy, or the direct path.
    public static TlsProbeResult RawDirect(string address, int port, string serverName, string variant, int timeoutMs) {
        var result = new TlsProbeResult(); result.Variant = "direct " + variant + (serverName.Length > 0 ? " SNI " + serverName : "");
        var watch = Stopwatch.StartNew(); var owned = new List<IDisposable>();
        try {
            var client = new TcpClient(); owned.Add(client);
            IAsyncResult connect = client.BeginConnect(address, port, null, null);
            if (!connect.AsyncWaitHandle.WaitOne(timeoutMs)) { result.Outcome = "Timeout"; result.Detail = "no TCP connection"; return result; }
            client.EndConnect(connect);
            result.Address = client.Client.RemoteEndPoint.ToString();
            NetworkStream s = client.GetStream(); s.ReadTimeout = timeoutMs; s.WriteTimeout = timeoutMs;
            byte[] hello = BuildClientHello(serverName.Length > 0 ? variant : "tls13-nosni", serverName);
            s.Write(hello, 0, hello.Length); s.Flush();
            byte[] header = ReadUpTo(s, 5);
            byte[] body = new byte[0];
            if (header.Length == 5) body = ReadUpTo(s, Math.Min(16384, (header[3] << 8) | header[4]));
            string[] d = Describe(header, body);
            result.Outcome = d[0]; result.Detail = d[1];
        } catch (Exception e) {
            result.Outcome = IsTimeout(e) ? "Timeout" : "Closed"; result.Detail = Code(e);
        } finally { Close(owned); result.ElapsedMs = watch.ElapsedMilliseconds; }
        return result;
    }

    public static TlsProbeResult RawHello(string proxyHost, string proxyAddress, int proxyPort, bool proxyTls, string target, string variant, int timeoutMs) {
        var result = new TlsProbeResult(); result.Variant = "raw " + variant;
        var watch = Stopwatch.StartNew(); var owned = new List<IDisposable>();
        try {
            Stream tunnel = Tunnel(proxyHost, proxyAddress, proxyPort, proxyTls, target, timeoutMs, owned, result);
            if (tunnel == null) return result;
            byte[] hello = BuildClientHello(variant, target);
            tunnel.Write(hello, 0, hello.Length); tunnel.Flush();
            byte[] header = ReadUpTo(tunnel, 5);
            byte[] body = new byte[0];
            if (header.Length == 5) body = ReadUpTo(tunnel, Math.Min(16384, (header[3] << 8) | header[4]));
            string[] d = Describe(header, body);
            result.Outcome = d[0]; result.Detail = d[1];
        } catch (Exception e) {
            result.Outcome = IsTimeout(e) ? "Timeout" : "Closed"; result.Detail = Code(e);
        } finally { Close(owned); result.ElapsedMs = watch.ElapsedMilliseconds; }
        return result;
    }

    // Schannel (SslStream) inside the tunnel with normal certificate validation (no callback).
    public static TlsProbeResult Schannel(string proxyHost, string proxyAddress, int proxyPort, bool proxyTls, string target, SslProtocols protocols, string variant, int timeoutMs) {
        var result = new TlsProbeResult(); result.Variant = variant;
        var watch = Stopwatch.StartNew(); var owned = new List<IDisposable>();
        try {
            Stream tunnel = Tunnel(proxyHost, proxyAddress, proxyPort, proxyTls, target, timeoutMs, owned, result);
            if (tunnel == null) return result;
            var inner = new SslStream(tunnel, false); owned.Add(inner);
            try { inner.AuthenticateAsClient(target, null, protocols, false); }
            catch (Exception e) { result.Outcome = IsTimeout(e) ? "Timeout" : "HandshakeFailed"; result.Detail = Code(e); return result; }
            result.Outcome = "HandshakeOk";
            // Only the protocol: the cipher properties are obsolete (a compile error) in newer .NET.
            result.Detail = inner.SslProtocol + ", certificate " + (inner.RemoteCertificate == null ? "?" : inner.RemoteCertificate.Subject);
            byte[] request = Encoding.ASCII.GetBytes("HEAD /forum/index.php HTTP/1.1\r\nHost: " + target + "\r\nUser-Agent: TorrentControl-tls-probe\r\nConnection: close\r\n\r\n");
            inner.Write(request, 0, request.Length); inner.Flush();
            string line = ReadLine(inner);
            result.Detail += "; HEAD /forum/index.php -> " + (line.Length > 0 ? line : "no answer");
        } catch (Exception e) {
            if (result.Outcome.Length == 0) { result.Outcome = IsTimeout(e) ? "Timeout" : "Closed"; result.Detail = Code(e); }
        } finally { Close(owned); result.ElapsedMs = watch.ElapsedMilliseconds; }
        return result;
    }

    // TCP to one address of the proxy (or its name), TLS validated for the proxy NAME, CONNECT target:443.
    static Stream Tunnel(string proxyHost, string proxyAddress, int proxyPort, bool proxyTls, string target, int timeoutMs, List<IDisposable> owned, TlsProbeResult result) {
        var client = new TcpClient(); owned.Add(client);
        IAsyncResult connect = client.BeginConnect(proxyAddress.Length > 0 ? proxyAddress : proxyHost, proxyPort, null, null);
        if (!connect.AsyncWaitHandle.WaitOne(timeoutMs)) { result.Outcome = "ProxyFailed"; result.Detail = "no TCP connection to the proxy"; return null; }
        try { client.EndConnect(connect); }
        catch (Exception e) { result.Outcome = "ProxyFailed"; result.Detail = "TCP to the proxy: " + Code(e); return null; }
        result.Address = client.Client.RemoteEndPoint.ToString();
        client.ReceiveTimeout = timeoutMs; client.SendTimeout = timeoutMs;
        NetworkStream network = client.GetStream(); network.ReadTimeout = timeoutMs; network.WriteTimeout = timeoutMs;
        Stream stream = network;
        if (proxyTls) {
            var outer = new SslStream(network, false); owned.Add(outer);   // normal certificate validation of the proxy
            try { outer.AuthenticateAsClient(proxyHost); }
            catch (Exception e) { result.Outcome = "ProxyFailed"; result.Detail = "TLS to the proxy: " + Code(e); return null; }
            result.Proxy = "TLS to proxy " + outer.SslProtocol;
            stream = outer;
        }
        byte[] ask = Encoding.ASCII.GetBytes("CONNECT " + target + ":443 HTTP/1.1\r\nHost: " + target + ":443\r\nUser-Agent: TorrentControl-tls-probe\r\n\r\n");
        stream.Write(ask, 0, ask.Length); stream.Flush();
        var head = new StringBuilder();
        while (head.Length < 16384) {
            int b = stream.ReadByte(); if (b < 0) break;
            head.Append((char)b);
            if (head.Length >= 4 && head.ToString(head.Length - 4, 4) == "\r\n\r\n") break;
        }
        string status = head.Length > 12 ? head.ToString(9, 3) : "none";
        result.Proxy += (result.Proxy.Length > 0 ? ", " : "") + "CONNECT " + status;
        if (status != "200") { result.Outcome = "ProxyFailed"; result.Detail = "CONNECT answer " + status; return null; }
        return stream;
    }

    static byte[] ReadUpTo(Stream s, int count) {
        var buffer = new byte[count]; int done = 0;
        while (done < count) { int n = s.Read(buffer, done, count - done); if (n <= 0) break; done += n; }
        if (done == count) return buffer;
        var part = new byte[done]; Array.Copy(buffer, part, done); return part;
    }
    static string ReadLine(Stream s) {
        var line = new StringBuilder();
        while (line.Length < 200) { int b = s.ReadByte(); if (b < 0 || b == '\n') break; if (b != '\r') line.Append((char)b); }
        return line.ToString();
    }
    static void Close(List<IDisposable> owned) { for (int i = owned.Count - 1; i >= 0; i--) { try { owned[i].Dispose(); } catch { } } }
    static bool IsTimeout(Exception e) {
        for (Exception x = e; x != null; x = x.InnerException) {
            var socket = x as SocketException;
            if (socket != null && socket.SocketErrorCode == SocketError.TimedOut) return true;
            if (x is TimeoutException) return true;
        }
        return false;
    }
    // A fixed description: exception type, SEC_E_/socket code. Never the message text.
    static string Code(Exception e) {
        var parts = new List<string>();
        for (Exception x = e; x != null; x = x.InnerException) {
            var win32 = x as Win32Exception;
            var socket = x as SocketException;
            if (socket != null) parts.Add("socket " + socket.SocketErrorCode);
            else if (win32 != null) parts.Add(x.GetType().Name + " 0x" + win32.NativeErrorCode.ToString("X8"));
            else parts.Add(x.GetType().Name + " 0x" + x.HResult.ToString("X8"));
        }
        return string.Join(" <- ", parts.ToArray());
    }
    static string AlertName(int code) {
        switch (code) {
            case 0: return "close_notify"; case 10: return "unexpected_message"; case 20: return "bad_record_mac"; case 40: return "handshake_failure";
            case 42: return "bad_certificate"; case 47: return "illegal_parameter"; case 50: return "decode_error"; case 70: return "protocol_version";
            case 71: return "insufficient_security"; case 80: return "internal_error"; case 86: return "inappropriate_fallback"; case 109: return "missing_extension";
            case 112: return "unrecognized_name"; case 120: return "no_application_protocol"; default: return "alert";
        }
    }
    static string VersionName(int v) {
        switch (v) { case 0x0304: return "TLS 1.3"; case 0x0303: return "TLS 1.2"; case 0x0302: return "TLS 1.1"; case 0x0301: return "TLS 1.0"; default: return "0x" + v.ToString("X4"); }
    }
    static string Printable(byte[] bytes) {
        var text = new StringBuilder();
        foreach (byte b in bytes) text.Append(b >= 32 && b < 127 ? ((char)b).ToString() : "\\x" + b.ToString("X2"));
        return text.ToString();
    }
    static void U16(Stream s, int v) { s.WriteByte((byte)(v >> 8)); s.WriteByte((byte)v); }
    static byte[] Vec16(byte[] data) { var m = new MemoryStream(); U16(m, data.Length); m.Write(data, 0, data.Length); return m.ToArray(); }
    static void Ext(Stream s, int type, byte[] data) { U16(s, type); U16(s, data.Length); s.Write(data, 0, data.Length); }
}
'@
if (!('TlsProbe' -as [type])) { Add-Type -TypeDefinition $source }

function Get-ProbeEnvironment {
    $lines = New-Object Collections.Generic.List[string]
    $os = [Environment]::OSVersion
    $lines.Add('Windows: ' + $os.VersionString + ' (build ' + $os.Version.Build + '); PowerShell ' + $PSVersionTable.PSVersion + ' ' + $PSVersionTable.PSEdition)
    if ($os.Platform -eq [PlatformID]::Win32NT) {
        $release = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
        $lines.Add('.NET Framework 4 release: ' + $release + '; Schannel TLS 1.3 client is built into Windows 11 / Server 2022 (build 20348+), not into Windows 10.')
        foreach ($version in @('TLS 1.2', 'TLS 1.3')) {
            $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\' + $version + '\Client'
            $values = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
            if ($values) { $lines.Add('Schannel ' + $version + ' client (registry): Enabled=' + $values.Enabled + ' DisabledByDefault=' + $values.DisabledByDefault) }
            else { $lines.Add('Schannel ' + $version + ' client (registry): no explicit setting (Windows default)') }
        }
    }
    return $lines.ToArray()
}

if ($MyInvocation.InvocationName -ne '.') {
    $uri = [Uri]$Proxy
    if ($uri.Scheme -notin @('http', 'https') -or $uri.UserInfo) { Write-Host 'Proxy must be http://host:port or https://host:port without a password.'; exit 1 }
    $timeout = [math]::Max(2, $TimeoutSec) * 1000
    $report = New-Object Collections.Generic.List[string]
    $report.Add('TorrentControl TLS probe ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' - proxy ' + $uri.Host + ':' + $uri.Port + ' (' + $uri.Scheme + '), target ' + $Target + ':443')
    $report.Add('Anonymous: no login, no cookie. Hand-built ClientHello probes stop at the first answer; Schannel probes validate certificates normally.')
    foreach ($line in (Get-ProbeEnvironment)) { $report.Add($line) }
    foreach ($name in @($Target, $uri.Host)) {
        try { $report.Add('DNS ' + $name + ': ' + (@([Net.Dns]::GetHostAddresses($name) | ForEach-Object { $_.ToString() }) -join ', ')) }
        catch { $report.Add('DNS ' + $name + ': not resolved') }
    }
    $proxyTls = $uri.Scheme -eq 'https'
    $addresses = @('')
    if (!$ByName) {
        try { $addresses = @([Net.Dns]::GetHostAddresses($uri.Host) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.ToString() } | Select-Object -First 12) } catch { $addresses = @('') }
        if (!$addresses.Count) { $addresses = @('') }
    }
    $results = New-Object Collections.Generic.List[object]
    foreach ($address in $addresses) {
        for ($round = 1; $round -le [math]::Max(1, $Repeat); $round++) {
            if ($proxyTls) { $results.Add([TlsProbe]::RawDirect($(if ($address) { $address } else { $uri.Host }), $uri.Port, $uri.Host, 'tls12-only', $timeout)) }
            $results.Add([TlsProbe]::Schannel($uri.Host, $address, $uri.Port, $proxyTls, $Target, [Security.Authentication.SslProtocols]::None, 'schannel system-default', $timeout))
            $results.Add([TlsProbe]::Schannel($uri.Host, $address, $uri.Port, $proxyTls, $Target, [Security.Authentication.SslProtocols]::Tls12, 'schannel TLS 1.2 only (as 72e4ca3)', $timeout))
            foreach ($variant in @('tls13-alpn', 'tls12-only', 'tls13-nosni')) {
                $results.Add([TlsProbe]::RawHello($uri.Host, $address, $uri.Port, $proxyTls, $Target, $variant, $timeout))
            }
        }
    }
    foreach ($address in $DirectAddress) {
        $results.Add([TlsProbe]::RawDirect($address, 443, $Target, 'tls13-alpn', $timeout))
        $results.Add([TlsProbe]::RawDirect($address, 443, '', 'tls13-nosni', $timeout))
    }
    foreach ($r in $results) { $report.Add(('{0,-22} {1,-48} {2,-17} {3} [{4}; {5} ms]' -f $r.Address, $r.Variant, $r.Outcome, $r.Detail, $r.Proxy, $r.ElapsedMs)) }
    foreach ($line in $report) { Write-Host $line }
    [IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'rutracker-tls-probe.txt'), [string[]]$report, (New-Object Text.UTF8Encoding($true)))
    Write-Host ('Saved: ' + (Join-Path $PSScriptRoot 'rutracker-tls-probe.txt'))
}
