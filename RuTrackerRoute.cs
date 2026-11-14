using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text;

// The only network transport of TorrentControl to RuTracker (RuTracker.ps1, Test-RuTrackerConnection.ps1).
// Routes:
//   direct       DNS -> TCP host:443 -> TLS
//   http proxy   TCP proxy -> "CONNECT host:443" -> TLS inside the tunnel
//   https proxy  TCP proxy -> TLS to the proxy -> "CONNECT host:443" -> TLS to the host inside it. This is what the
//                official RuTracker browser extension uses (HTTPS ps1.blockme.site:443); neither .NET Framework nor
//                PowerShell 5.1 can use such a proxy on their own.
// Every certificate (proxy and rutracker.org) is validated exactly like the default: the callback only records the
// errors it is given and accepts none. The proxy sees "host:443" only; paths, cookies and passwords travel inside the
// TLS session with the host. One request per connection, redirects are never followed here, sizes and times are
// bounded. Nothing is changed in Windows, DNS, routes or proxy settings.
public sealed class RuTrackerRouteResult {
    public bool Ok;
    public string Code = "";        // Ok, DnsFailed, ConnectFailed, ProxyUnreachable, ProxyTlsFailed, ProxyAuthRequired,
                                    // ProxyRefused, ProxyUnsupported, Timeout, TlsFailed, TlsCertificateInvalid,
                                    // HttpForbidden, HttpRateLimited, HttpUnexpected
    public string Stage = "";       // Dns, Connect, ProxyConnect, ProxyTls, ProxyTunnel, Tls, Http
    public int ProxyStatus;         // status of the CONNECT answer
    public int HttpStatus;          // status of GET <path>
    public string TlsErrors = "";   // SslPolicyErrors names when a certificate was rejected
    public int Addresses;           // number of DNS addresses (direct only)
    public long ElapsedMs;
}

public sealed class RuTrackerHttpResult {
    public int Status;              // 0 when the request failed (Error says why)
    public string ContentType = "";
    public string Location = "";
    public byte[] Body = new byte[0];
    public string Error = "";       // a route code (see above) or ResponseTooLarge / UnsupportedUrl
    public string Stage = "";
    public string TlsErrors = "";
    public int ProxyStatus;
}

public sealed class RuTrackerRouteFailure : Exception {
    public readonly string Code;
    public RuTrackerRouteFailure(string code) : base(code) { Code = code; }
}

public static class RuTrackerRoute {
    const int MaxHead = 65536;

    // Anonymous route check: only the status line of GET <path> is read; no cookie or credential is sent.
    public static RuTrackerRouteResult Check(string proxyHost, int proxyPort, string host, string path, int timeoutMs) {
        return Check(string.IsNullOrEmpty(proxyHost) ? "" : "http", proxyHost, proxyPort, host, path, timeoutMs);
    }
    public static RuTrackerRouteResult Check(string proxyScheme, string proxyHost, int proxyPort, string host, string path, int timeoutMs) {
        var result = new RuTrackerRouteResult();
        var watch = Stopwatch.StartNew();
        var connection = new Connection(timeoutMs);
        try {
            Stream stream = connection.Open(proxyScheme, proxyHost, proxyPort, host, 443, "TorrentControl-route-check");
            connection.Stage = "Http";
            Send(stream, "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\nUser-Agent: TorrentControl-route-check\r\nAccept: text/html\r\nConnection: close\r\n\r\n");
            result.HttpStatus = StatusOf(ReadUntil(stream, "\r\n", 2048));
            if (result.HttpStatus >= 200 && result.HttpStatus < 400) { result.Ok = true; result.Code = "Ok"; }
            else if (result.HttpStatus == 403) result.Code = "HttpForbidden";
            else if (result.HttpStatus == 429) result.Code = "HttpRateLimited";
            else result.Code = "HttpUnexpected";
        } catch (Exception e) {
            result.Code = connection.Classify(e);
        } finally {
            connection.Dispose();
            result.Stage = connection.Stage;
            result.ProxyStatus = connection.ProxyStatus;
            result.TlsErrors = connection.TlsErrors;
            result.Addresses = connection.Addresses;
            result.ElapsedMs = watch.ElapsedMilliseconds;
        }
        return result;
    }

    // One HTTPS request to url through the route. Cookies come from and go to the container (RFC rules of
    // CookieContainer: a cookie of rutracker.org is never sent to another host).
    public static RuTrackerHttpResult Send(string proxyScheme, string proxyHost, int proxyPort, string method, string url, CookieContainer cookies,
                                           string contentType, byte[] body, string userAgent, int timeoutMs, int maxBody) {
        var result = new RuTrackerHttpResult();
        Uri uri;
        if (!Uri.TryCreate(url, UriKind.Absolute, out uri) || uri.Scheme != "https" || uri.UserInfo.Length > 0) { result.Error = "UnsupportedUrl"; return result; }
        var connection = new Connection(timeoutMs);
        try {
            Stream stream = connection.Open(proxyScheme, proxyHost, proxyPort, uri.Host, uri.Port, userAgent);
            connection.Stage = "Http";
            RuTrackerHttpResult answer = Exchange(stream, method, uri, cookies, contentType, body, userAgent, maxBody);
            answer.Stage = connection.Stage;
            answer.ProxyStatus = connection.ProxyStatus;
            return answer;
        } catch (Exception e) {
            result.Error = connection.Classify(e);
            result.Stage = connection.Stage;
            result.ProxyStatus = connection.ProxyStatus;
            result.TlsErrors = connection.TlsErrors;
            return result;
        } finally {
            connection.Dispose();
        }
    }

    // HTTP/1.1 exchange over an already established stream (always the validated TLS stream in production; tests use
    // it over plain sockets to check the parser). One request, "Connection: close", no compression, no redirects.
    public static RuTrackerHttpResult Exchange(Stream stream, string method, Uri uri, CookieContainer cookies, string contentType, byte[] body,
                                               string userAgent, int maxBody) {
        var request = new StringBuilder();
        request.Append(method).Append(' ').Append(uri.PathAndQuery).Append(" HTTP/1.1\r\n");
        request.Append("Host: ").Append(uri.IsDefaultPort ? uri.Host : uri.Host + ":" + uri.Port).Append("\r\n");
        request.Append("User-Agent: ").Append(userAgent).Append("\r\n");
        request.Append("Accept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n");
        string cookie = cookies == null ? "" : cookies.GetCookieHeader(uri);
        if (cookie.Length > 0) request.Append("Cookie: ").Append(cookie).Append("\r\n");
        if (body != null) request.Append("Content-Type: ").Append(contentType).Append("\r\nContent-Length: ").Append(body.Length).Append("\r\n");
        request.Append("\r\n");
        byte[] head = Encoding.ASCII.GetBytes(request.ToString());
        stream.Write(head, 0, head.Length);
        if (body != null && body.Length > 0) stream.Write(body, 0, body.Length);
        stream.Flush();

        string answer = ReadUntil(stream, "\r\n\r\n", MaxHead);
        if (!answer.EndsWith("\r\n\r\n", StringComparison.Ordinal)) throw new RuTrackerRouteFailure("HttpUnexpected");
        var result = new RuTrackerHttpResult();
        result.Status = StatusOf(answer);
        if (result.Status < 100) throw new RuTrackerRouteFailure("HttpUnexpected");
        long length = -1;
        bool chunked = false;
        string[] lines = answer.Split(new[] { "\r\n" }, StringSplitOptions.None);
        for (int i = 1; i < lines.Length; i++) {
            int colon = lines[i].IndexOf(':');
            if (colon <= 0) continue;
            string name = lines[i].Substring(0, colon).Trim();
            string value = lines[i].Substring(colon + 1).Trim();
            if (name.Equals("Set-Cookie", StringComparison.OrdinalIgnoreCase)) {
                if (cookies != null) { try { cookies.SetCookies(uri, value); } catch (CookieException) { } }
            } else if (name.Equals("Content-Type", StringComparison.OrdinalIgnoreCase)) {
                result.ContentType = value;
            } else if (name.Equals("Location", StringComparison.OrdinalIgnoreCase)) {
                result.Location = value;
            } else if (name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) {
                long parsed;
                if (!long.TryParse(value, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out parsed)) throw new RuTrackerRouteFailure("HttpUnexpected");
                length = parsed;
            } else if (name.Equals("Transfer-Encoding", StringComparison.OrdinalIgnoreCase)) {
                chunked = value.ToLowerInvariant().Contains("chunked");
            }
        }
        if (method == "HEAD" || result.Status < 200 || result.Status == 204 || result.Status == 304) return result;
        if (chunked) result.Body = ReadChunked(stream, maxBody);
        else if (length >= 0) {
            if (length > maxBody) throw new RuTrackerRouteFailure("ResponseTooLarge");
            result.Body = ReadExact(stream, (int)length);
        } else result.Body = ReadToEnd(stream, maxBody);
        return result;
    }

    // A rejected certificate is reported as such; any other handshake failure is a TLS failure. Never accepted.
    public static string TlsCode(SslPolicyErrors errors) {
        return errors == SslPolicyErrors.None ? "TlsFailed" : "TlsCertificateInvalid";
    }

    sealed class Connection : IDisposable {
        readonly int timeoutMs;
        readonly List<IDisposable> owned = new List<IDisposable>();
        public string Stage = "";
        public int ProxyStatus;
        public string TlsErrors = "";
        public int Addresses;
        public Connection(int timeoutMs) { this.timeoutMs = timeoutMs; }

        public Stream Open(string proxyScheme, string proxyHost, int proxyPort, string host, int port, string agent) {
            Stream stream;
            if (string.IsNullOrEmpty(proxyScheme)) {
                Stage = "Dns";
                IPAddress[] addresses;
                try {
                    IAsyncResult lookup = Dns.BeginGetHostAddresses(host, null, null);
                    if (!lookup.AsyncWaitHandle.WaitOne(timeoutMs)) throw new RuTrackerRouteFailure("Timeout");
                    addresses = Dns.EndGetHostAddresses(lookup);
                } catch (SocketException) { throw new RuTrackerRouteFailure("DnsFailed"); }
                Addresses = addresses.Length;
                if (addresses.Length == 0) throw new RuTrackerRouteFailure("DnsFailed");
                Stage = "Connect";
                TcpClient client = null;
                string failure = "";
                foreach (IPAddress address in addresses) {
                    failure = TryConnect(address.ToString(), port, out client);
                    if (client != null) break;
                }
                if (client == null) throw new RuTrackerRouteFailure(failure == "Timeout" ? "Timeout" : "ConnectFailed");
                stream = Prepare(client);
            } else {
                if (proxyScheme != "http" && proxyScheme != "https") throw new RuTrackerRouteFailure("ProxyUnsupported");
                Stage = "ProxyConnect";
                TcpClient client;
                string failure = TryConnect(proxyHost, proxyPort, out client);
                if (client == null) throw new RuTrackerRouteFailure(failure == "Timeout" ? "Timeout" : "ProxyUnreachable");
                stream = Prepare(client);
                if (proxyScheme == "https") {
                    Stage = "ProxyTls";
                    stream = Authenticate(stream, proxyHost, true);
                }
                Stage = "ProxyTunnel";
                Send(stream, "CONNECT " + host + ":" + port + " HTTP/1.1\r\nHost: " + host + ":" + port + "\r\nUser-Agent: " + agent + "\r\n\r\n");
                ProxyStatus = StatusOf(ReadUntil(stream, "\r\n\r\n", 16384));
                if (ProxyStatus == 407) throw new RuTrackerRouteFailure("ProxyAuthRequired");
                if (ProxyStatus != 200) throw new RuTrackerRouteFailure("ProxyRefused");   // includes a closed connection (0)
            }
            Stage = "Tls";
            return Authenticate(stream, host, false);
        }

        SslStream Authenticate(Stream inner, string name, bool proxy) {
            SslPolicyErrors seen = SslPolicyErrors.None;
            var ssl = new SslStream(inner, false, (sender, certificate, chain, errors) => { seen = errors; return errors == SslPolicyErrors.None; });
            owned.Add(ssl);
            try {
                ssl.AuthenticateAsClient(name, null, SslProtocols.Tls12, false);
            } catch (AuthenticationException) {
                TlsErrors = seen == SslPolicyErrors.None ? "" : seen.ToString();
                throw new RuTrackerRouteFailure(proxy ? "ProxyTlsFailed" : TlsCode(seen));
            }
            return ssl;
        }

        string TryConnect(string host, int port, out TcpClient client) {
            client = null;
            var candidate = new TcpClient();
            try {
                IAsyncResult connect = candidate.BeginConnect(host, port, null, null);
                if (!connect.AsyncWaitHandle.WaitOne(timeoutMs)) { candidate.Close(); return "Timeout"; }
                candidate.EndConnect(connect);
                owned.Add(candidate);
                client = candidate;
                return "";
            } catch (Exception e) {
                candidate.Close();
                return IsTimeout(e) ? "Timeout" : "Refused";
            }
        }

        Stream Prepare(TcpClient client) {
            client.ReceiveTimeout = timeoutMs;
            client.SendTimeout = timeoutMs;
            NetworkStream stream = client.GetStream();
            stream.ReadTimeout = timeoutMs;
            stream.WriteTimeout = timeoutMs;
            return stream;
        }

        public string Classify(Exception e) {
            var failure = e as RuTrackerRouteFailure;
            if (failure != null) return failure.Code;
            if (IsTimeout(e)) return "Timeout";
            switch (Stage) {
                case "Dns": return "DnsFailed";
                case "Connect": return "ConnectFailed";
                case "ProxyConnect": return "ProxyUnreachable";
                case "ProxyTls": return "ProxyTlsFailed";
                case "ProxyTunnel": return "ProxyRefused";
                case "Tls": return "TlsFailed";
                default: return "HttpUnexpected";
            }
        }

        public void Dispose() {
            for (int i = owned.Count - 1; i >= 0; i--) { try { owned[i].Dispose(); } catch { } }
            owned.Clear();
        }
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

    static byte[] ReadExact(Stream stream, int count) {
        var buffer = new byte[count];
        int done = 0;
        while (done < count) {
            int read = stream.Read(buffer, done, count - done);
            if (read <= 0) throw new RuTrackerRouteFailure("HttpUnexpected");
            done += read;
        }
        return buffer;
    }

    static byte[] ReadToEnd(Stream stream, int maxBody) {
        var memory = new MemoryStream();
        var buffer = new byte[65536];
        int read;
        while ((read = stream.Read(buffer, 0, buffer.Length)) > 0) {
            memory.Write(buffer, 0, read);
            if (memory.Length > maxBody) throw new RuTrackerRouteFailure("ResponseTooLarge");
        }
        return memory.ToArray();
    }

    static byte[] ReadChunked(Stream stream, int maxBody) {
        var memory = new MemoryStream();
        while (true) {
            string line = ReadUntil(stream, "\r\n", 1024);
            if (!line.EndsWith("\r\n", StringComparison.Ordinal)) throw new RuTrackerRouteFailure("HttpUnexpected");
            string sizeText = line.Substring(0, line.Length - 2);
            int semicolon = sizeText.IndexOf(';');
            if (semicolon >= 0) sizeText = sizeText.Substring(0, semicolon);
            int size;
            if (!int.TryParse(sizeText.Trim(), System.Globalization.NumberStyles.AllowHexSpecifier, System.Globalization.CultureInfo.InvariantCulture, out size) || size < 0)
                throw new RuTrackerRouteFailure("HttpUnexpected");
            if (size == 0) {
                for (int trailers = 0; trailers < 64; trailers++) {   // trailer lines up to the empty one (or the end)
                    string trailer = ReadUntil(stream, "\r\n", 1024);
                    if (trailer == "\r\n" || !trailer.EndsWith("\r\n", StringComparison.Ordinal)) break;
                }
                return memory.ToArray();
            }
            if (memory.Length + size > maxBody) throw new RuTrackerRouteFailure("ResponseTooLarge");
            byte[] chunk = ReadExact(stream, size);
            memory.Write(chunk, 0, chunk.Length);
            if (ReadUntil(stream, "\r\n", 2) != "\r\n") throw new RuTrackerRouteFailure("HttpUnexpected");
        }
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
