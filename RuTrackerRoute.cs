using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text;

// Anonymous check of the network route to RuTracker, used before any request that carries a password or cookie
// (RuTracker.ps1) and by Test-RuTrackerConnection.ps1.
// Direct:     DNS -> TCP host:443 -> TLS -> GET <path>.
// HTTP proxy: TCP proxy -> "CONNECT host:443" -> TLS inside the tunnel -> GET <path>. The proxy resolves the name and
//             sees only "host:443"; the path and everything else travel inside TLS.
// Only the HTTP status line is read. No cookies, credentials or personal data are sent. The certificate is validated
// exactly like the default (the callback only records the errors it is given and accepts none); nothing is changed
// in Windows, DNS, routes or proxy settings.
public sealed class RuTrackerRouteResult {
    public bool Ok;
    public string Code = "";        // Ok, DnsFailed, ConnectFailed, ProxyUnreachable, ProxyAuthRequired, ProxyRefused,
                                    // Timeout, TlsFailed, TlsCertificateInvalid, HttpForbidden, HttpRateLimited, HttpUnexpected
    public string Stage = "";       // Dns, Connect, ProxyConnect, ProxyTunnel, Tls, Http
    public int ProxyStatus;         // status of the CONNECT answer
    public int HttpStatus;          // status of GET <path>
    public string TlsErrors = "";   // SslPolicyErrors names when the certificate was rejected
    public int Addresses;           // number of DNS addresses (direct only)
    public long ElapsedMs;
}

public static class RuTrackerRoute {
    public static RuTrackerRouteResult Check(string proxyHost, int proxyPort, string host, string path, int timeoutMs) {
        var result = new RuTrackerRouteResult();
        var watch = Stopwatch.StartNew();
        TcpClient client = null;
        SslStream ssl = null;
        try {
            Stream stream;
            if (string.IsNullOrEmpty(proxyHost)) {
                result.Stage = "Dns";
                IPAddress[] addresses;
                try {
                    IAsyncResult lookup = Dns.BeginGetHostAddresses(host, null, null);
                    if (!lookup.AsyncWaitHandle.WaitOne(timeoutMs)) return Done(result, "Timeout", watch);
                    addresses = Dns.EndGetHostAddresses(lookup);
                } catch (SocketException) { return Done(result, "DnsFailed", watch); }
                result.Addresses = addresses.Length;
                if (addresses.Length == 0) return Done(result, "DnsFailed", watch);
                result.Stage = "Connect";
                string failure = "";
                foreach (IPAddress address in addresses) {
                    failure = TryConnect(address.ToString(), 443, timeoutMs, out client);
                    if (client != null) break;
                }
                if (client == null) return Done(result, failure == "Timeout" ? "Timeout" : "ConnectFailed", watch);
                stream = Prepare(client, timeoutMs);
            } else {
                result.Stage = "ProxyConnect";
                string failure = TryConnect(proxyHost, proxyPort, timeoutMs, out client);
                if (client == null) return Done(result, failure == "Timeout" ? "Timeout" : "ProxyUnreachable", watch);
                stream = Prepare(client, timeoutMs);
                result.Stage = "ProxyTunnel";
                Send(stream, "CONNECT " + host + ":443 HTTP/1.1\r\nHost: " + host + ":443\r\nUser-Agent: TorrentControl-route-check\r\n\r\n");
                string head = ReadUntil(stream, "\r\n\r\n", 16384);
                result.ProxyStatus = StatusOf(head);
                if (result.ProxyStatus == 407) return Done(result, "ProxyAuthRequired", watch);
                if (result.ProxyStatus != 200) return Done(result, "ProxyRefused", watch);   // includes a closed connection (status 0)
            }
            result.Stage = "Tls";
            SslPolicyErrors seen = SslPolicyErrors.None;
            ssl = new SslStream(stream, false, (sender, certificate, chain, errors) => { seen = errors; return errors == SslPolicyErrors.None; });
            try {
                ssl.AuthenticateAsClient(host, null, SslProtocols.Tls12, false);
            } catch (AuthenticationException) {
                result.TlsErrors = seen == SslPolicyErrors.None ? "" : seen.ToString();
                return Done(result, TlsCode(seen), watch);
            }
            result.Stage = "Http";
            Send(ssl, "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\nUser-Agent: TorrentControl-route-check\r\nAccept: text/html\r\nConnection: close\r\n\r\n");
            result.HttpStatus = StatusOf(ReadUntil(ssl, "\r\n", 2048));
            if (result.HttpStatus >= 200 && result.HttpStatus < 400) { result.Ok = true; return Done(result, "Ok", watch); }
            if (result.HttpStatus == 403) return Done(result, "HttpForbidden", watch);
            if (result.HttpStatus == 429) return Done(result, "HttpRateLimited", watch);
            return Done(result, "HttpUnexpected", watch);
        } catch (Exception e) {
            if (IsTimeout(e)) return Done(result, "Timeout", watch);
            switch (result.Stage) {
                case "Dns": return Done(result, "DnsFailed", watch);
                case "Connect": return Done(result, "ConnectFailed", watch);
                case "ProxyConnect": return Done(result, "ProxyUnreachable", watch);
                case "ProxyTunnel": return Done(result, "ProxyRefused", watch);
                case "Tls": return Done(result, "TlsFailed", watch);
                default: return Done(result, "HttpUnexpected", watch);
            }
        } finally {
            if (ssl != null) ssl.Dispose();
            if (client != null) client.Close();
        }
    }

    // A rejected certificate is reported as such; any other handshake failure is a TLS failure. Never accepted.
    public static string TlsCode(SslPolicyErrors errors) {
        return errors == SslPolicyErrors.None ? "TlsFailed" : "TlsCertificateInvalid";
    }

    static RuTrackerRouteResult Done(RuTrackerRouteResult result, string code, Stopwatch watch) {
        result.Code = code;
        result.ElapsedMs = watch.ElapsedMilliseconds;
        return result;
    }

    static string TryConnect(string host, int port, int timeoutMs, out TcpClient client) {
        client = null;
        var candidate = new TcpClient();
        try {
            IAsyncResult connect = candidate.BeginConnect(host, port, null, null);
            if (!connect.AsyncWaitHandle.WaitOne(timeoutMs)) { candidate.Close(); return "Timeout"; }
            candidate.EndConnect(connect);
            client = candidate;
            return "";
        } catch (Exception e) {
            candidate.Close();
            return IsTimeout(e) ? "Timeout" : "Refused";
        }
    }

    static Stream Prepare(TcpClient client, int timeoutMs) {
        client.ReceiveTimeout = timeoutMs;
        client.SendTimeout = timeoutMs;
        NetworkStream stream = client.GetStream();
        stream.ReadTimeout = timeoutMs;
        stream.WriteTimeout = timeoutMs;
        return stream;
    }

    static void Send(Stream stream, string text) {
        byte[] bytes = Encoding.ASCII.GetBytes(text);
        stream.Write(bytes, 0, bytes.Length);
        stream.Flush();
    }

    static string ReadUntil(Stream stream, string end, int max) {
        var text = new StringBuilder();
        while (text.Length < max) {
            int b = stream.ReadByte();
            if (b < 0) break;
            text.Append((char)b);
            if (text.Length >= end.Length && text.ToString(text.Length - end.Length, end.Length) == end) break;
        }
        return text.ToString();
    }

    static int StatusOf(string head) {
        if (!head.StartsWith("HTTP/", StringComparison.Ordinal)) return 0;
        int space = head.IndexOf(' ');
        int code;
        if (space < 0 || head.Length < space + 4 || !int.TryParse(head.Substring(space + 1, 3), out code)) return 0;
        return code;
    }

    static bool IsTimeout(Exception e) {
        for (Exception x = e; x != null; x = x.InnerException) {
            var socket = x as SocketException;
            if (socket != null && socket.SocketErrorCode == SocketError.TimedOut) return true;
            if (x is TimeoutException) return true;
        }
        return false;
    }
}
