using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text;
using System.Threading;

// The only network transport of TorrentControl to RuTracker (RuTracker.ps1, Test-RuTrackerConnection.ps1).
// Compiled together with RuTrackerTls13.cs by RuTrackerTls13.ps1 (Initialize-RuTrackerTransport).
// Routes:
//   direct       DNS -> TCP host:443 -> TLS with the host
//   http proxy   TCP proxy -> "CONNECT host:443" -> TLS with the host inside the tunnel
//   https proxy  TCP proxy -> TLS to the proxy -> "CONNECT host:443" -> TLS with the host inside it. This is what the
//                official RuTracker browser extension uses (HTTPS ps1.blockme.site:443); neither .NET Framework nor
//                PowerShell 5.1 can use such a proxy on their own.
// TLS to the proxy: SslStream (Windows Schannel, TLS 1.2), certificate validated for the proxy NAME exactly like the
//   default: the callback only records the errors it is given and accepts none.
// TLS with the host: RuTrackerTls13.cs only (BouncyCastle, TLS 1.3 or 1.2). Windows 10 Schannel has no TLS 1.3 client,
//   and rutracker.org behind the official proxy accepts only TLS 1.3. Its certificate must build a Windows X509Chain
//   to a root trusted on this computer, with the serverAuth usage, valid dates and the host name; nothing relaxes it.
// The proxy sees "host:443" only; paths, cookies and passwords travel inside the TLS session with the host.
// A proxy name with several addresses (ps1.blockme.site: 9, only some of them work at a time): DNS is asked every
// time; the caller (RuTracker.ps1) gives the order it learned - addresses that worked most recently first, then the
// unknown ones in DNS order, then those that failed recently. Only if DNS gives nothing are the remembered addresses
// used. Every address is tried while the time of the request allows (short handshake timeout per address), each
// attempt ends before any byte of the request is sent, and none follows a rejected certificate (of the proxy or of
// the site) or a proxy password request. The certificate of an https proxy is always checked for the proxy NAME,
// whichever address is used. One request per connection, redirects are never followed here, sizes are bounded, and
// a request (all addresses, handshakes and the answer) never runs longer than 3 timeouts: then its sockets are closed
// and it ends with Timeout. Nothing is changed in Windows, DNS, routes or proxy settings.
public sealed class RuTrackerRouteResult {
    public bool Ok;
    public string Code = "";        // Ok, DnsFailed, ConnectFailed, ProxyUnreachable, ProxyTlsFailed (network failure in the
                                    // handshake with the proxy), ProxyCertificateInvalid, ProxyAuthRequired,
                                    // ProxyRefused, ProxyUnsupported, Timeout, TlsFailed, TlsCertificateInvalid,
                                    // HttpForbidden, HttpRateLimited, HttpUnexpected
    public string Stage = "";       // Dns, Connect, ProxyConnect, ProxyTls, ProxyTunnel, Tls, Http
    public int ProxyStatus;         // status of the CONNECT answer
    public int HttpStatus;          // status of GET <path>
    public string TlsErrors = "";   // why a certificate or a handshake was refused (fixed texts: SslPolicyErrors names,
                                    // chain status names, alert names; never a URL, cookie or key)
    public int Addresses;           // DNS addresses of the host (direct) or of the proxy name
    public int Attempts;            // proxy addresses tried
    public string Endpoint = "";    // address:port of the last connection (the proxy, or the host when direct)
    public string TlsVersion = "";  // TLS version with the host ("TLS 1.3" / "TLS 1.2")
    public string AddressSource = "";                 // dns, cache (DNS gave nothing: remembered addresses), fixed
    public string[] DnsAddresses = new string[0];     // what DNS returned for the proxy name
    public string[] AttemptAddresses = new string[0]; // proxy addresses in the order tried
    public string[] AttemptCodes = new string[0];     // Ok or the failure code of each of them
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
    public string TlsVersion = "";
    public string Endpoint = "";
    public string AddressSource = "";
    public string[] DnsAddresses = new string[0];
    public string[] AttemptAddresses = new string[0];
    public string[] AttemptCodes = new string[0];
}

public sealed class RuTrackerRouteFailure : Exception {
    public readonly string Code;
    public RuTrackerRouteFailure(string code) : base(code) { Code = code; }
}

public static class RuTrackerRoute {
    const int MaxHead = 65536;

    // Tests only (tests\Test-RuTrackerTls.ps1): fixed addresses for names under the reserved ".test" domain (RFC 6761,
    // never resolvable by DNS), so that failover between proxy addresses can be tested on 127.0.0.x. No other name is
    // looked up here, and no production script fills it (tests\Test-Static.ps1).
    public static readonly Dictionary<string, IPAddress[]> TestAddresses = new Dictionary<string, IPAddress[]>(StringComparer.OrdinalIgnoreCase);

    // Anonymous route check: only the status line of GET <path> is read; no cookie or credential is sent.
    public static RuTrackerRouteResult Check(string proxyHost, int proxyPort, string host, string path, int timeoutMs) {
        return Check(string.IsNullOrEmpty(proxyHost) ? "" : "http", proxyHost, proxyPort, host, path, timeoutMs);
    }
    public static RuTrackerRouteResult Check(string proxyScheme, string proxyHost, int proxyPort, string host, string path, int timeoutMs) {
        return Check(proxyScheme, proxyHost, proxyPort, host, path, timeoutMs, null, null);
    }
    // preferred: proxy addresses to try first (best first); avoid: addresses to try last (both from RuTracker.ps1).
    public static RuTrackerRouteResult Check(string proxyScheme, string proxyHost, int proxyPort, string host, string path, int timeoutMs,
                                             string[] preferred, string[] avoid) {
        var connection = new Connection(timeoutMs);
        connection.Preferred = preferred;
        connection.Avoid = avoid;
        return Run(connection, proxyScheme, proxyHost, proxyPort, host, path);
    }
    // Diagnostics: the same check through every address of the proxy name separately (at most 16), so that the person
    // sees which addresses work. The certificate is checked for the proxy name for each of them.
    public static RuTrackerRouteResult[] CheckEach(string proxyScheme, string proxyHost, int proxyPort, string host, string path, int timeoutMs) {
        var probe = new Connection(timeoutMs);
        IPAddress[] addresses;
        try { addresses = probe.ResolveName(proxyHost); } catch (RuTrackerRouteFailure) { addresses = new IPAddress[0]; } finally { probe.Dispose(); }
        if (addresses.Length == 0) return new[] { Check(proxyScheme, proxyHost, proxyPort, host, path, timeoutMs) };
        var results = new List<RuTrackerRouteResult>();
        for (int i = 0; i < addresses.Length && i < Connection.MaxProxyAddresses; i++) {
            var connection = new Connection(timeoutMs);
            connection.Only = addresses[i];
            results.Add(Run(connection, proxyScheme, proxyHost, proxyPort, host, path));
        }
        return results.ToArray();
    }
    static RuTrackerRouteResult Run(Connection connection, string proxyScheme, string proxyHost, int proxyPort, string host, string path) {
        var result = new RuTrackerRouteResult();
        var watch = Stopwatch.StartNew();
        try {
            Stream stream = connection.Open(proxyScheme, proxyHost, proxyPort, host, 443, "TorrentControl-route-check");
            connection.Stage = "Http";
            Send(stream, "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\nUser-Agent: TorrentControl-route-check\r\nAccept: text/html\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n");
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
            result.Attempts = connection.Attempts;
            result.Endpoint = connection.Endpoint;
            result.TlsVersion = connection.TlsVersion;
            result.AddressSource = connection.AddressSource;
            result.DnsAddresses = connection.DnsAddresses;
            result.AttemptAddresses = connection.AttemptAddresses.ToArray();
            result.AttemptCodes = connection.AttemptCodes.ToArray();
            result.ElapsedMs = watch.ElapsedMilliseconds;
        }
        return result;
    }

    // One HTTPS request to url through the route. Cookies come from and go to the container (RFC rules of
    // CookieContainer: a cookie of rutracker.org is never sent to another host).
    // The request (and a POST body) is sent once, on the first address whose route is fully established; after that no
    // other address is tried, whatever happens to the answer.
    public static RuTrackerHttpResult Send(string proxyScheme, string proxyHost, int proxyPort, string method, string url, CookieContainer cookies,
                                           string contentType, byte[] body, string userAgent, int timeoutMs, int maxBody) {
        return Send(proxyScheme, proxyHost, proxyPort, method, url, cookies, contentType, body, userAgent, timeoutMs, maxBody, null, null);
    }
    public static RuTrackerHttpResult Send(string proxyScheme, string proxyHost, int proxyPort, string method, string url, CookieContainer cookies,
                                           string contentType, byte[] body, string userAgent, int timeoutMs, int maxBody, string[] preferred, string[] avoid) {
        var result = new RuTrackerHttpResult();
        Uri uri;
        if (!Uri.TryCreate(url, UriKind.Absolute, out uri) || uri.Scheme != "https" || uri.UserInfo.Length > 0) { result.Error = "UnsupportedUrl"; return result; }
        var connection = new Connection(timeoutMs);
        connection.Preferred = preferred;
        connection.Avoid = avoid;
        try {
            Stream stream = connection.Open(proxyScheme, proxyHost, proxyPort, uri.Host, uri.Port, userAgent);
            connection.Stage = "Http";
            result = Exchange(stream, method, uri, cookies, contentType, body, userAgent, maxBody);
        } catch (Exception e) {
            result.Error = connection.Classify(e);
            result.TlsErrors = connection.TlsErrors;
        } finally {
            connection.Dispose();
            result.Stage = connection.Stage;
            result.ProxyStatus = connection.ProxyStatus;
            result.TlsVersion = connection.TlsVersion;
            result.Endpoint = connection.Endpoint;
            result.AddressSource = connection.AddressSource;
            result.DnsAddresses = connection.DnsAddresses;
            result.AttemptAddresses = connection.AttemptAddresses.ToArray();
            result.AttemptCodes = connection.AttemptCodes.ToArray();
        }
        return result;
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

    sealed class Connection : IDisposable {
        public const int MaxProxyAddresses = 16;
        // A TCP connection to a working server takes well under a second; an address that does not answer must not
        // use up the whole request timeout before the next address is tried.
        const int MaxConnectMs = 10000;
        // Handshakes through one proxy address (TCP, TLS to the proxy, CONNECT, TLS with the site): every read waits at
        // most this long. Working addresses of the official proxy needed 1.3-4.5 s for the WHOLE check on the PC (all
        // round trips together), so one read never needs 5 s; with a 15 s route check up to six addresses that do not
        // answer fit in before a working one, even without a learned order.
        const int MaxAttemptMs = 5000;
        readonly int timeoutMs;
        readonly Stopwatch watch = Stopwatch.StartNew();
        readonly List<IDisposable> owned = new List<IDisposable>();
        readonly object gate = new object();
        readonly List<TcpClient> sockets = new List<TcpClient>();
        readonly Timer guard;
        volatile bool expired;
        NetworkStream current;
        public string[] Preferred;
        public string[] Avoid;
        public IPAddress Only;
        public string AddressSource = "";
        public string[] DnsAddresses = new string[0];
        public readonly List<string> AttemptAddresses = new List<string>();
        public readonly List<string> AttemptCodes = new List<string>();
        public string Stage = "";
        public int ProxyStatus;
        public string TlsErrors = "";
        public int Addresses;
        public int Attempts;
        public string Endpoint = "";
        public string TlsVersion = "";
        public Connection(int timeoutMs) {
            this.timeoutMs = timeoutMs;
            // Hard limit of the whole request: per-read timeouts alone do not stop a server that keeps answering
            // slowly. The caller's time budget (RuTracker.ps1) relies on this bound.
            guard = new Timer(Expire, null, 3L * timeoutMs, System.Threading.Timeout.Infinite);
        }

        void Expire(object unused) {
            lock (gate) {
                expired = true;
                foreach (TcpClient socket in sockets) { try { socket.Close(); } catch { } }
            }
        }

        public Stream Open(string proxyScheme, string proxyHost, int proxyPort, string host, int port, string agent) {
            if (string.IsNullOrEmpty(proxyScheme)) {
                Stage = "Dns";
                IPAddress[] addresses = Resolve(host);
                Addresses = addresses.Length;
                if (addresses.Length == 0) throw new RuTrackerRouteFailure("DnsFailed");
                Stage = "Connect";
                TcpClient client = null;
                string failure = "";
                foreach (IPAddress address in addresses) {
                    Endpoint = Format(address, port);
                    failure = TryConnect(address, port, out client);
                    if (client != null) break;
                }
                if (client == null) throw new RuTrackerRouteFailure(failure == "Timeout" ? "Timeout" : "ConnectFailed");
                return Secure(Prepare(client, timeoutMs), host);
            }
            if (proxyScheme != "http" && proxyScheme != "https") throw new RuTrackerRouteFailure("ProxyUnsupported");
            Stage = "ProxyConnect";
            List<IPAddress> order = Order(proxyHost);
            if (order.Count == 0) throw new RuTrackerRouteFailure("ProxyUnreachable");
            int attemptMs = Math.Min(timeoutMs, MaxAttemptMs);
            long totalMs = 3L * timeoutMs;   // the hard limit of the guard
            string lastCode = "ProxyUnreachable";
            for (int i = 0; i < order.Count; i++) {
                if (expired) throw new RuTrackerRouteFailure("Timeout");
                // Another address only if its handshakes can end with one timeout left for the request and its answer.
                if (i > 0 && watch.ElapsedMilliseconds + attemptMs > totalMs - timeoutMs) break;
                Attempts = i + 1;
                AttemptAddresses.Add(order[i].ToString());
                try {
                    Stream stream = ThroughProxy(proxyScheme == "https", proxyHost, order[i], proxyPort, host, port, agent, attemptMs);
                    AttemptCodes.Add("Ok");
                    SetTimeouts(timeoutMs);   // the request and its answer get the normal timeout
                    return stream;
                } catch (Exception e) {
                    string code = Classify(e);
                    AttemptCodes.Add(code);
                    if (!MayTryAnotherAddress(code)) throw new RuTrackerRouteFailure(code);
                    lastCode = code;
                    Release();
                }
            }
            throw new RuTrackerRouteFailure(lastCode);
        }

        public IPAddress[] ResolveName(string name) { return Resolve(name); }

        // Addresses to try: DNS answer ordered by the caller's experience; remembered addresses only without DNS.
        List<IPAddress> Order(string name) {
            var result = new List<IPAddress>();
            if (Only != null) { AddressSource = "fixed"; result.Add(Only); return result; }
            IPAddress[] dns;
            try { dns = Resolve(name); } catch (RuTrackerRouteFailure) { dns = new IPAddress[0]; }
            if (expired) throw new RuTrackerRouteFailure("Timeout");
            Addresses = dns.Length;
            var names = new List<string>();
            foreach (IPAddress address in dns) names.Add(address.ToString());
            DnsAddresses = names.ToArray();
            string[] preferred = Preferred ?? new string[0];
            string[] avoid = Avoid ?? new string[0];
            if (dns.Length > 0) {
                AddressSource = "dns";
                foreach (string text in preferred) AddFrom(dns, text, result);
                foreach (IPAddress address in dns) if (!result.Contains(address) && Array.IndexOf(avoid, address.ToString()) < 0) result.Add(address);
                foreach (string text in avoid) AddFrom(dns, text, result);
                foreach (IPAddress address in dns) if (!result.Contains(address)) result.Add(address);
            } else {
                AddressSource = "cache";
                foreach (string text in preferred) AddParsed(text, result);
                foreach (string text in avoid) AddParsed(text, result);
            }
            if (result.Count > MaxProxyAddresses) result.RemoveRange(MaxProxyAddresses, result.Count - MaxProxyAddresses);
            return result;
        }
        static void AddFrom(IPAddress[] dns, string text, List<IPAddress> result) {
            foreach (IPAddress address in dns) if (address.ToString() == text && !result.Contains(address)) result.Add(address);
        }
        static void AddParsed(string text, List<IPAddress> result) {
            IPAddress address;
            if (IPAddress.TryParse(text, out address) && !result.Contains(address)) result.Add(address);
        }

        // One proxy address: nothing of the request is sent here, only CONNECT host:port and the TLS handshakes.
        Stream ThroughProxy(bool proxyTls, string proxyHost, IPAddress address, int proxyPort, string host, int port, string agent, int attemptMs) {
            Stage = "ProxyConnect";
            ProxyStatus = 0;
            TlsErrors = "";
            TlsVersion = "";
            Endpoint = Format(address, proxyPort);
            TcpClient client;
            string failure = TryConnect(address, proxyPort, out client, attemptMs);
            if (client == null) throw new RuTrackerRouteFailure(failure == "Timeout" ? "Timeout" : "ProxyUnreachable");
            Stream stream = Prepare(client, attemptMs);
            if (proxyTls) {
                Stage = "ProxyTls";
                stream = AuthenticateProxy(stream, proxyHost);
            }
            Stage = "ProxyTunnel";
            Send(stream, "CONNECT " + host + ":" + port + " HTTP/1.1\r\nHost: " + host + ":" + port + "\r\nUser-Agent: " + agent + "\r\n\r\n");
            ProxyStatus = StatusOf(ReadUntil(stream, "\r\n\r\n", 16384));
            if (ProxyStatus == 407) throw new RuTrackerRouteFailure("ProxyAuthRequired");
            if (ProxyStatus != 200) throw new RuTrackerRouteFailure("ProxyRefused");   // includes a closed connection (0)
            return Secure(stream, host);
        }

        // Another address of the same proxy is tried only for network failures of that address (no connection, no or a
        // broken answer, a refused tunnel, a TLS handshake that broke off); never after a certificate was rejected
        // (ProxyCertificateInvalid, TlsCertificateInvalid) or the proxy asked for a password.
        static bool MayTryAnotherAddress(string code) {
            switch (code) {
                case "ProxyUnreachable":
                case "Timeout":
                case "ProxyRefused":
                case "ProxyTlsFailed":
                case "TlsFailed":
                    return true;
                default:
                    return false;
            }
        }

        // TLS with the host: RuTrackerTls13 (TLS 1.3 / 1.2, Windows chain + host name). The only TLS path to the site.
        Stream Secure(Stream inner, string host) {
            Stage = "Tls";
            RuTrackerTls13Session session;
            try {
                session = RuTrackerTls13.Connect(inner, host, host);
            } catch (RuTrackerTls13Failure e) {
                TlsErrors = e.Detail;
                throw new RuTrackerRouteFailure(e.Code);
            }
            owned.Add(session);
            TlsVersion = session.Version;
            return session.Stream;
        }

        Stream AuthenticateProxy(Stream inner, string name) {
            SslPolicyErrors seen = SslPolicyErrors.None;
            var ssl = new SslStream(inner, false, (sender, certificate, chain, errors) => { seen = errors; return errors == SslPolicyErrors.None; });
            owned.Add(ssl);
            try {
                ssl.AuthenticateAsClient(name, null, SslProtocols.Tls12, false);
            } catch (AuthenticationException) {
                // A certificate the callback refused is a certificate failure: the search for another address stops.
                // Anything else in the handshake (closed, broken, no answer) is a network failure of this address.
                if (seen != SslPolicyErrors.None) { TlsErrors = seen.ToString(); throw new RuTrackerRouteFailure("ProxyCertificateInvalid"); }
                throw new RuTrackerRouteFailure("ProxyTlsFailed");
            }
            return ssl;
        }

        // IPv4 first (then IPv6), DNS order within each family. A literal address is used as it is.
        IPAddress[] Resolve(string name) {
            IPAddress literal;
            if (IPAddress.TryParse(name, out literal)) return new[] { literal };
            if (name.EndsWith(".test", StringComparison.OrdinalIgnoreCase)) {
                IPAddress[] assigned;
                lock (TestAddresses) { if (TestAddresses.TryGetValue(name, out assigned)) return (IPAddress[])assigned.Clone(); }
                return new IPAddress[0];
            }
            IPAddress[] found;
            IAsyncResult lookup = Dns.BeginGetHostAddresses(name, null, null);
            if (!lookup.AsyncWaitHandle.WaitOne(timeoutMs)) throw new RuTrackerRouteFailure("Timeout");
            try { found = Dns.EndGetHostAddresses(lookup); } catch (SocketException) { return new IPAddress[0]; }
            var ordered = new List<IPAddress>();
            foreach (IPAddress address in found) if (address.AddressFamily == AddressFamily.InterNetwork) ordered.Add(address);
            foreach (IPAddress address in found) if (address.AddressFamily == AddressFamily.InterNetworkV6) ordered.Add(address);
            return ordered.ToArray();
        }

        static string Format(IPAddress address, int port) {
            return address.AddressFamily == AddressFamily.InterNetworkV6 ? "[" + address + "]:" + port : address + ":" + port;
        }

        string TryConnect(IPAddress address, int port, out TcpClient client) { return TryConnect(address, port, out client, MaxConnectMs); }
        string TryConnect(IPAddress address, int port, out TcpClient client, int limitMs) {
            client = null;
            TcpClient candidate = null;
            try {
                candidate = new TcpClient(address.AddressFamily);   // throws where IPv6 is off: that address is skipped
                IAsyncResult connect = candidate.BeginConnect(address, port, null, null);
                if (!connect.AsyncWaitHandle.WaitOne(Math.Min(timeoutMs, Math.Min(limitMs, MaxConnectMs)))) { candidate.Close(); return "Timeout"; }
                candidate.EndConnect(connect);
                lock (gate) {
                    if (expired) { candidate.Close(); return "Timeout"; }
                    sockets.Add(candidate);
                }
                owned.Add(candidate);
                client = candidate;
                return "";
            } catch (Exception e) {
                if (candidate != null) candidate.Close();
                return IsTimeout(e) ? "Timeout" : "Refused";
            }
        }

        Stream Prepare(TcpClient client, int readMs) {
            client.ReceiveTimeout = readMs;
            client.SendTimeout = readMs;
            current = client.GetStream();
            current.ReadTimeout = readMs;
            current.WriteTimeout = readMs;
            return current;
        }

        // TLS streams on top read through this socket: a new timeout applies to all following reads and writes.
        void SetTimeouts(int readMs) {
            if (current == null) return;
            current.ReadTimeout = readMs;
            current.WriteTimeout = readMs;
        }

        public string Classify(Exception e) {
            if (expired) return "Timeout";   // the guard closed the sockets: whatever broke after that is the time limit
            var failure = e as RuTrackerRouteFailure;
            if (failure != null) return failure.Code;
            if (IsTimeout(e)) return "Timeout";
            switch (Stage) {
                case "Dns": return "DnsFailed";
                case "Connect": return "ConnectFailed";
                case "ProxyConnect": return "ProxyUnreachable";
                case "ProxyTls": return "ProxyTlsFailed";   // network failure during the handshake (no certificate refused)
                case "ProxyTunnel": return "ProxyRefused";
                case "Tls": return "TlsFailed";
                default: return "HttpUnexpected";
            }
        }

        // Closes in reverse order: TLS with the host (close_notify), TLS with the proxy, then the socket.
        void Release() {
            for (int i = owned.Count - 1; i >= 0; i--) { try { owned[i].Dispose(); } catch { } }
            owned.Clear();
            lock (gate) { sockets.Clear(); }
        }

        public void Dispose() { guard.Dispose(); Release(); }
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

    // A body without Content-Length or chunks ends with the connection ("Connection: close"). A server that closes the
    // TLS session without close_notify ends it as well (BouncyCastle reports EndOfStreamException); a cut .torrent
    // then fails the bencode and infohash checks of RuTracker.ps1, a cut page cannot carry the session cookie.
    static byte[] ReadToEnd(Stream stream, int maxBody) {
        var memory = new MemoryStream();
        var buffer = new byte[65536];
        while (true) {
            int read;
            try { read = stream.Read(buffer, 0, buffer.Length); } catch (EndOfStreamException) { break; }
            if (read <= 0) break;
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
                    string trailer;
                    try { trailer = ReadUntil(stream, "\r\n", 1024); } catch (EndOfStreamException) { break; }
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
