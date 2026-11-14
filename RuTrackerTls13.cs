using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using Org.BouncyCastle.Security;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;

// TLS 1.3 client for TorrentControl's requests to RuTracker on Windows 10, whose Schannel has no TLS 1.3 client while
// the RuTracker site behind the official proxy accepts only TLS 1.3 (protocol_version alert to a TLS 1.2 ClientHello).
// The protocol is BouncyCastle.Cryptography 2.7.0 (lib\bouncycastle, SHA-256 pinned, loaded from verified bytes).
// The server certificate is accepted only if ALL hold:
//   - Windows/.NET X509Chain builds a chain to a trusted root of this computer with the serverAuth usage and valid
//     dates (no extra roots, no relaxed flags; revocation as SslStream's default: not checked);
//   - a subjectAltName dNSName of the leaf matches the expected host (exact, or a "*." wildcard for one label);
//   - BouncyCastle verified the server's handshake signature with the key of that certificate (TLS itself).
// Offered versions: TLS 1.3 and TLS 1.2 (downgrade protection of TLS 1.3 applies); ALPN http/1.1; SNI = host.
public static class RuTrackerTlsLibrary {
    static Assembly library;
    // The library is loaded by RuTrackerTls13.ps1 from bytes whose SHA-256 was checked; this makes the CLR use exactly
    // that assembly when this code needs BouncyCastle.Cryptography.
    public static void Register(Assembly assembly) {
        if (library != null) return;
        library = assembly;
        AppDomain.CurrentDomain.AssemblyResolve += Resolve;
    }
    static Assembly Resolve(object sender, ResolveEventArgs e) {
        return new AssemblyName(e.Name).Name == "BouncyCastle.Cryptography" ? library : null;
    }
}

public sealed class RuTrackerTls13Failure : Exception {
    public readonly string Code;     // TlsCertificateInvalid, TlsFailed, Timeout
    public readonly string Detail;   // fixed text: chain status names, alert name, exception type - no secrets
    public RuTrackerTls13Failure(string code, string detail) : base(code) { Code = code; Detail = detail; }
}

public sealed class RuTrackerTls13Session : IDisposable {
    public Stream Stream;
    public string Version = "";
    public string CipherSuite = "";
    public string Alpn = "";
    public string Subject = "";
    public string Issuer = "";
    public string NotAfter = "";
    internal Action Closer;
    public void Dispose() { try { if (Closer != null) Closer(); } catch { } Closer = null; }
}

public static class RuTrackerTls13 {
    // TLS over an established stream (a CONNECT tunnel or a direct connection). serverName goes into SNI;
    // expectedName is what the certificate must be issued for (the same in production; tests pass another one to
    // prove that a wrong name is rejected).
    public static RuTrackerTls13Session Connect(Stream inner, string serverName, string expectedName) {
        return Tls13Engine.Connect(inner, serverName, expectedName);
    }

    // RFC 6125 host name matching: exact (case-insensitive), or "*.<at least two labels>" for exactly one left label.
    public static bool NameMatches(string pattern, string host) {
        if (string.IsNullOrEmpty(pattern) || string.IsNullOrEmpty(host)) return false;
        pattern = pattern.TrimEnd('.').ToLowerInvariant();
        host = host.TrimEnd('.').ToLowerInvariant();
        if (pattern.IndexOf('*') < 0) return pattern == host;
        if (!pattern.StartsWith("*.") || pattern.IndexOf('*', 1) >= 0) return false;
        string suffix = pattern.Substring(1);                        // ".rutracker.org"
        if (suffix.Split('.').Length < 3) return false;              // never "*.org"
        if (!host.EndsWith(suffix, StringComparison.Ordinal)) return false;
        string label = host.Substring(0, host.Length - suffix.Length);
        return label.Length > 0 && label.IndexOf('.') < 0;
    }
}

static class Tls13Engine {
    public static RuTrackerTls13Session Connect(Stream inner, string serverName, string expectedName) {
        var crypto = new BcTlsCrypto(new SecureRandom());
        var client = new Tls13Client(crypto, serverName, expectedName);
        var protocol = new TlsClientProtocol(inner);
        try {
            protocol.Connect(client);
        } catch (Exception e) {
            try { protocol.Close(); } catch { }
            if (client.Rejected.Length > 0) throw new RuTrackerTls13Failure("TlsCertificateInvalid", client.Rejected);
            throw new RuTrackerTls13Failure(IsTimeout(e) ? "Timeout" : "TlsFailed", Describe(e));
        }
        var session = new RuTrackerTls13Session();
        session.Stream = protocol.Stream;
        session.Closer = delegate { protocol.Close(); };
        TlsClientContext context = client.ClientContext;
        session.Version = context.ServerVersion == null ? "" : context.ServerVersion.ToString();
        session.CipherSuite = "0x" + context.SecurityParameters.CipherSuite.ToString("X4");
        session.Alpn = context.SecurityParameters.ApplicationProtocol == null ? "" : context.SecurityParameters.ApplicationProtocol.GetUtf8Decoding();
        session.Subject = client.Subject;
        session.Issuer = client.Issuer;
        session.NotAfter = client.NotAfter;
        return session;
    }

    static string Describe(Exception e) {
        var parts = new List<string>();
        for (Exception x = e; x != null; x = x.InnerException) {
            var received = x as TlsFatalAlertReceived;
            var fatal = x as TlsFatalAlert;
            var socket = x as SocketException;
            if (received != null) parts.Add("alert received " + AlertDescription.GetText(received.AlertDescription));
            else if (fatal != null) parts.Add("alert sent " + AlertDescription.GetText(fatal.AlertDescription));
            else if (socket != null) parts.Add("socket " + socket.SocketErrorCode);
            else parts.Add(x.GetType().Name);
        }
        return string.Join(" <- ", parts.ToArray());
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

sealed class Tls13Client : DefaultTlsClient {
    readonly string serverName;
    public readonly string ExpectedName;
    public string Rejected = "";
    public string Subject = "";
    public string Issuer = "";
    public string NotAfter = "";
    public Tls13Client(TlsCrypto crypto, string serverName, string expectedName) : base(crypto) {
        this.serverName = serverName;
        ExpectedName = expectedName;
    }
    public TlsClientContext ClientContext { get { return m_context; } }
    protected override ProtocolVersion[] GetSupportedVersions() { return ProtocolVersion.TLSv13.DownTo(ProtocolVersion.TLSv12); }
    protected override IList<ServerName> GetSniServerNames() {
        return new List<ServerName> { new ServerName(NameType.host_name, Encoding.ASCII.GetBytes(serverName)) };
    }
    protected override IList<ProtocolName> GetProtocolNames() { return new List<ProtocolName> { ProtocolName.Http_1_1 }; }
    public override TlsAuthentication GetAuthentication() { return new Tls13Authentication(this); }
}

sealed class Tls13Authentication : TlsAuthentication {
    readonly Tls13Client owner;
    public Tls13Authentication(Tls13Client owner) { this.owner = owner; }
    public void NotifyServerCertificate(TlsServerCertificate serverCertificate) {
        string problem = CertificateCheck.Validate(serverCertificate == null ? null : serverCertificate.Certificate, owner);
        if (problem.Length > 0) {
            owner.Rejected = problem;
            throw new TlsFatalAlert(AlertDescription.bad_certificate);
        }
    }
    public TlsCredentials GetClientCredentials(Org.BouncyCastle.Tls.CertificateRequest certificateRequest) { return null; }
}

static class CertificateCheck {
    public static string Validate(Certificate chain, Tls13Client owner) {
        if (chain == null || chain.IsEmpty) return "no certificate";
        byte[] leafBytes = chain.GetCertificateAt(0).GetEncoded();
        var leaf = new X509Certificate2(leafBytes);
        owner.Subject = leaf.Subject;
        owner.Issuer = leaf.Issuer;
        owner.NotAfter = leaf.NotAfter.ToUniversalTime().ToString("yyyy-MM-dd");
        var x509 = new X509Chain();
        try {
            x509.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            x509.ChainPolicy.VerificationFlags = X509VerificationFlags.NoFlag;
            x509.ChainPolicy.ApplicationPolicy.Add(new Oid("1.3.6.1.5.5.7.3.1"));
            for (int i = 1; i < chain.Length; i++) x509.ChainPolicy.ExtraStore.Add(new X509Certificate2(chain.GetCertificateAt(i).GetEncoded()));
            if (!x509.Build(leaf)) {
                var flags = new List<string>();
                foreach (X509ChainStatus status in x509.ChainStatus) flags.Add(status.Status.ToString());
                return "chain not trusted: " + string.Join(",", flags.ToArray());
            }
        } finally {
            x509.Reset();
        }
        if (!NameInCertificate(leafBytes, owner.ExpectedName)) return "certificate is not issued for " + owner.ExpectedName;
        return "";
    }

    static bool NameInCertificate(byte[] der, string host) {
        var parsed = new Org.BouncyCastle.X509.X509CertificateParser().ReadCertificate(der);
        var names = parsed.GetSubjectAlternativeNames() as IEnumerable;
        if (names == null) return false;
        foreach (object item in names) {
            var entry = item as IList;
            if (entry == null || entry.Count < 2) continue;
            if (Convert.ToInt32(entry[0]) == 2 && RuTrackerTls13.NameMatches(Convert.ToString(entry[1]), host)) return true;
        }
        return false;
    }
}
