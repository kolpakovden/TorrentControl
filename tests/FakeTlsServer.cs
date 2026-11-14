using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using Org.BouncyCastle.Asn1.Sec;
using Org.BouncyCastle.Asn1.X509;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Operators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Math;
using Org.BouncyCastle.Pkcs;
using Org.BouncyCastle.Security;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;
using Org.BouncyCastle.X509;
using Org.BouncyCastle.X509.Extension;

// Test-only PKI and TLS servers for tests\Test-RuTrackerTls.ps1, on the same pinned BouncyCastle library as the client.
// Keys and certificates exist in memory only (for the trusted run on Linux a throwaway CA is also written to a temp
// folder); nothing is added to any certificate store. The servers listen on 127.0.0.x and never forward anything:
// the "proxy" answers CONNECT itself and plays rutracker.org inside the tunnel.
public sealed class TestPki {
    static readonly SecureRandom Random = new SecureRandom();
    public readonly AsymmetricKeyParameter Key;
    public readonly Org.BouncyCastle.X509.X509Certificate Cert;
    TestPki(AsymmetricKeyParameter key, Org.BouncyCastle.X509.X509Certificate cert) { Key = key; Cert = cert; }

    static AsymmetricCipherKeyPair NewKey() {
        var generator = new ECKeyPairGenerator();
        generator.Init(new ECKeyGenerationParameters(SecObjectIdentifiers.SecP256r1, Random));
        return generator.GenerateKeyPair();
    }

    public static TestPki CreateAuthority(string name) {
        AsymmetricCipherKeyPair pair = NewKey();
        var subject = new X509Name("CN=" + name);
        var generator = new X509V3CertificateGenerator();
        generator.SetSerialNumber(BigInteger.ProbablePrime(64, Random));
        generator.SetIssuerDN(subject);
        generator.SetSubjectDN(subject);
        generator.SetNotBefore(DateTime.UtcNow.AddDays(-1));
        generator.SetNotAfter(DateTime.UtcNow.AddDays(7));
        generator.SetPublicKey(pair.Public);
        generator.AddExtension(X509Extensions.BasicConstraints, true, new BasicConstraints(true));
        generator.AddExtension(X509Extensions.KeyUsage, true, new KeyUsage(KeyUsage.KeyCertSign | KeyUsage.CrlSign));
        generator.AddExtension(X509Extensions.SubjectKeyIdentifier, false, X509ExtensionUtilities.CreateSubjectKeyIdentifier(pair.Public));
        return new TestPki(pair.Private, generator.Generate(new Asn1SignatureFactory("SHA256WITHECDSA", pair.Private, Random)));
    }

    public static TestPki Load(byte[] certificate, byte[] key) {
        return new TestPki(PrivateKeyFactory.CreateKey(key), new X509CertificateParser().ReadCertificate(certificate));
    }

    public byte[] CertificateDer { get { return Cert.GetEncoded(); } }
    public byte[] KeyDer { get { return PrivateKeyInfoFactory.CreatePrivateKeyInfo(Key).GetEncoded(); } }
    public string CertificatePem {
        get {
            string body = Convert.ToBase64String(Cert.GetEncoded());
            var text = new StringBuilder("-----BEGIN CERTIFICATE-----\n");
            for (int i = 0; i < body.Length; i += 64) text.Append(body.Substring(i, Math.Min(64, body.Length - i))).Append('\n');
            return text.Append("-----END CERTIFICATE-----\n").ToString();
        }
    }

    // usage: "server" = serverAuth (what a web site has), "client" = clientAuth only (must be refused for a site).
    public TestLeaf Issue(string[] names, DateTime notBefore, DateTime notAfter, string usage) {
        AsymmetricCipherKeyPair pair = NewKey();
        var generator = new X509V3CertificateGenerator();
        generator.SetSerialNumber(BigInteger.ProbablePrime(64, Random));
        generator.SetIssuerDN(Cert.SubjectDN);
        generator.SetSubjectDN(new X509Name("CN=" + names[0]));
        generator.SetNotBefore(notBefore);
        generator.SetNotAfter(notAfter);
        generator.SetPublicKey(pair.Public);
        generator.AddExtension(X509Extensions.BasicConstraints, true, new BasicConstraints(false));
        generator.AddExtension(X509Extensions.KeyUsage, true, new KeyUsage(KeyUsage.DigitalSignature));
        generator.AddExtension(X509Extensions.ExtendedKeyUsage, false, new ExtendedKeyUsage(usage == "client" ? KeyPurposeID.id_kp_clientAuth : KeyPurposeID.id_kp_serverAuth));
        var alternative = new GeneralName[names.Length];
        for (int i = 0; i < names.Length; i++) alternative[i] = new GeneralName(GeneralName.DnsName, names[i]);
        generator.AddExtension(X509Extensions.SubjectAlternativeName, false, new GeneralNames(alternative));
        generator.AddExtension(X509Extensions.SubjectKeyIdentifier, false, X509ExtensionUtilities.CreateSubjectKeyIdentifier(pair.Public));
        generator.AddExtension(X509Extensions.AuthorityKeyIdentifier, false, X509ExtensionUtilities.CreateAuthorityKeyIdentifier(Cert));
        var leaf = generator.Generate(new Asn1SignatureFactory("SHA256WITHECDSA", Key, Random));
        return new TestLeaf(pair.Private, new[] { leaf.GetEncoded(), Cert.GetEncoded() });
    }
    public TestLeaf IssueServer(string name) { return Issue(new[] { name }, DateTime.UtcNow.AddHours(-1), DateTime.UtcNow.AddDays(2), "server"); }
}

public sealed class TestLeaf {
    public readonly AsymmetricKeyParameter Key;
    public readonly byte[][] Chain;   // leaf first, then the authority
    public TestLeaf(AsymmetricKeyParameter key, byte[][] chain) { Key = key; Chain = chain; }
}

sealed class TestTlsServer : DefaultTlsServer {
    readonly TestLeaf leaf;
    readonly ProtocolVersion[] versions;
    public TestTlsServer(BcTlsCrypto crypto, TestLeaf leaf, ProtocolVersion[] versions) : base(crypto) { this.leaf = leaf; this.versions = versions; }
    protected override ProtocolVersion[] GetSupportedVersions() { return versions; }
    protected override int[] GetSupportedCipherSuites() {
        return TlsUtilities.GetSupportedCipherSuites(Crypto, new int[] {
            CipherSuite.TLS_AES_128_GCM_SHA256, CipherSuite.TLS_AES_256_GCM_SHA384, CipherSuite.TLS_CHACHA20_POLY1305_SHA256,
            CipherSuite.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256, CipherSuite.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 });
    }
    public override TlsCredentials GetCredentials() {
        var crypto = (BcTlsCrypto)Crypto;
        Certificate certificate;
        if (TlsUtilities.IsTlsV13(m_context)) {
            var entries = new CertificateEntry[leaf.Chain.Length];
            for (int i = 0; i < entries.Length; i++) entries[i] = new CertificateEntry(crypto.CreateCertificate(leaf.Chain[i]), null);
            certificate = new Certificate(TlsUtilities.EmptyBytes, entries);
        } else {
            var list = new TlsCertificate[leaf.Chain.Length];
            for (int i = 0; i < list.Length; i++) list[i] = crypto.CreateCertificate(leaf.Chain[i]);
            certificate = new Certificate(list);
        }
        return new BcDefaultTlsCredentialedSigner(new TlsCryptoParameters(m_context), crypto, leaf.Key, certificate,
            SignatureAndHashAlgorithm.GetInstance(HashAlgorithm.sha256, SignatureAlgorithm.ecdsa));
    }
}

// A proxy on one address. proxyLeaf == null: plain HTTP proxy; otherwise TLS 1.2 to the proxy with that certificate
// (like ps1.blockme.site). Behaviour:
//   ok           CONNECT 200, then rutracker.org inside the tunnel (TLS 1.3 only, or 1.2 only with siteTls "1.2")
//   close        accepts the connection and closes it at once
//   refuse-403   answers CONNECT with 403        auth-407   answers CONNECT with 407
//   site-garbage CONNECT 200, then plain bytes instead of the TLS server of the site
// The site: GET /forum/index.php -> 200; POST /forum/login.php with login_password=<Password> -> 302 + bb_session
// cookie (any other password -> the login page); GET /forum/dl.php?t=<n> with that cookie -> Torrent (no
// Content-Length: the body ends with close_notify), without it -> the login page (text/html).
public sealed class FakeTlsProxy : IDisposable {
    readonly TcpListener listener;
    readonly Thread worker;
    readonly string behaviour;
    readonly TestLeaf proxyLeaf;
    readonly TestLeaf siteLeaf;
    readonly ProtocolVersion[] siteVersions;
    volatile bool stopping;
    public readonly int Port;
    public readonly List<string> ProxyRequests = new List<string>();   // what the proxy saw in clear (CONNECT heads)
    public readonly List<string> SiteRequests = new List<string>();    // what reached the site inside TLS
    public readonly List<string> Failures = new List<string>();        // handshake failures on the server side
    public int Connections;
    public string Password = "";
    public string SessionCookie = "0-FAKE-SESSION-TLS-7";
    public byte[] Torrent = new byte[0];
    public bool NoCloseNotify;   // end the answer by closing the socket without the TLS close_notify alert

    public FakeTlsProxy(string address, int port, string behaviour, TestLeaf proxyLeaf, TestLeaf siteLeaf, string siteTls) {
        this.behaviour = behaviour;
        this.proxyLeaf = proxyLeaf;
        this.siteLeaf = siteLeaf;
        siteVersions = siteTls == "1.2" ? ProtocolVersion.TLSv12.Only() : ProtocolVersion.TLSv13.Only();
        listener = new TcpListener(IPAddress.Parse(address), port);
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        worker = new Thread(Run);
        worker.IsBackground = true;
        worker.Start();
    }

    public string AllProxyRequests() { lock (ProxyRequests) { return string.Join("\n----\n", ProxyRequests.ToArray()); } }
    public string AllSiteRequests() { lock (SiteRequests) { return string.Join("\n----\n", SiteRequests.ToArray()); } }

    void Run() {
        while (!stopping) {
            TcpClient client;
            try { client = listener.AcceptTcpClient(); } catch { return; }
            var connection = new Thread(delegate () { try { Handle(client); } catch (Exception e) { Note(e); } finally { client.Close(); } });
            connection.IsBackground = true;
            connection.Start();
        }
    }

    void Note(Exception e) {
        var parts = new List<string>();
        for (Exception x = e; x != null; x = x.InnerException) {
            var alert = x as TlsFatalAlertReceived;
            parts.Add(alert != null ? "alert received " + AlertDescription.GetText(alert.AlertDescription) : x.GetType().Name);
        }
        lock (Failures) { Failures.Add(string.Join(" <- ", parts.ToArray())); }
    }

    void Handle(TcpClient client) {
        Interlocked.Increment(ref Connections);
        NetworkStream network = client.GetStream();
        network.ReadTimeout = 10000;
        network.WriteTimeout = 10000;
        if (behaviour == "close") return;
        Stream stream = network;
        TlsServerProtocol outer = null;
        if (proxyLeaf != null) {
            outer = new TlsServerProtocol(network);
            outer.Accept(new TestTlsServer(new BcTlsCrypto(new SecureRandom()), proxyLeaf, ProtocolVersion.TLSv12.Only()));
            stream = outer.Stream;
        }
        string head = ReadHead(stream);
        lock (ProxyRequests) { ProxyRequests.Add(head); }
        if (behaviour == "refuse-403") { Send(stream, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"); Close(outer); return; }
        if (behaviour == "auth-407") { Send(stream, "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"x\"\r\nContent-Length: 0\r\n\r\n"); Close(outer); return; }
        Send(stream, "HTTP/1.1 200 Connection established\r\n\r\n");
        if (behaviour == "site-garbage") { Send(stream, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\nthis is not TLS"); Thread.Sleep(200); Close(outer); return; }
        var site = new TlsServerProtocol(stream);
        site.Accept(new TestTlsServer(new BcTlsCrypto(new SecureRandom()), siteLeaf, siteVersions));
        Stream tls = site.Stream;
        string request = ReadHead(tls);
        int length = 0;
        foreach (string line in request.Split(new[] { "\r\n" }, StringSplitOptions.None))
            if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = int.Parse(line.Substring(15).Trim());
        var body = new StringBuilder();
        for (int i = 0; i < length; i++) { int b = tls.ReadByte(); if (b < 0) break; body.Append((char)b); }
        lock (SiteRequests) { SiteRequests.Add(request + body.ToString()); }
        byte[] answer = Respond(request, body.ToString());
        tls.Write(answer, 0, answer.Length);
        tls.Flush();
        if (NoCloseNotify) return;   // the socket is closed by Run(): no close_notify
        site.Close();   // close_notify, then the tunnel (and the TLS to the proxy) is closed as well
    }

    byte[] Respond(string request, string body) {
        string first = request.Split(new[] { "\r\n" }, StringSplitOptions.None)[0];
        const string loginPage = "<html><form action=\"login.php\"><input name=\"login_username\"><input name=\"login_password\"></form></html>";
        if (first.StartsWith("GET /forum/index.php ")) return Page("200 OK", "text/html", "<html>RuTracker test index</html>", "");
        if (first.StartsWith("POST /forum/login.php ")) {
            if (Password.Length > 0 && ("&" + body + "&").Contains("&login_password=" + Password + "&"))
                return Page("302 Found", "text/html", "", "Location: https://rutracker.org/forum/index.php\r\nSet-Cookie: bb_session=" + SessionCookie + "; path=/forum/; domain=.rutracker.org; HttpOnly\r\n");
            return Page("200 OK", "text/html; charset=windows-1251", loginPage, "");
        }
        if (first.StartsWith("GET /forum/dl.php?t=")) {
            if (request.Contains("bb_session=" + SessionCookie)) {
                byte[] head = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/x-bittorrent\r\nConnection: close\r\n\r\n");
                var all = new byte[head.Length + Torrent.Length];
                Buffer.BlockCopy(head, 0, all, 0, head.Length);
                Buffer.BlockCopy(Torrent, 0, all, head.Length, Torrent.Length);
                return all;
            }
            return Page("200 OK", "text/html; charset=windows-1251", loginPage, "");
        }
        return Page("404 Not Found", "text/html", "<html>not found</html>", "");
    }

    static byte[] Page(string status, string type, string html, string extra) {
        byte[] body = Encoding.ASCII.GetBytes(html);
        string head = "HTTP/1.1 " + status + "\r\nContent-Type: " + type + "\r\n" + extra + "Content-Length: " + body.Length + "\r\nConnection: close\r\n\r\n";
        byte[] bytes = Encoding.ASCII.GetBytes(head);
        var all = new byte[bytes.Length + body.Length];
        Buffer.BlockCopy(bytes, 0, all, 0, bytes.Length);
        Buffer.BlockCopy(body, 0, all, bytes.Length, body.Length);
        return all;
    }

    static void Close(TlsServerProtocol outer) { if (outer != null) { try { outer.Close(); } catch { } } }

    static void Send(Stream stream, string text) {
        byte[] bytes = Encoding.ASCII.GetBytes(text);
        stream.Write(bytes, 0, bytes.Length);
        stream.Flush();
    }

    static string ReadHead(Stream stream) {
        var text = new StringBuilder();
        while (text.Length < 65536) {
            int b = stream.ReadByte();
            if (b < 0) break;
            text.Append((char)b);
            if (text.Length >= 4 && text.ToString(text.Length - 4, 4) == "\r\n\r\n") break;
        }
        return text.ToString();
    }

    public void Dispose() {
        stopping = true;
        try { listener.Stop(); } catch { }
    }
}
