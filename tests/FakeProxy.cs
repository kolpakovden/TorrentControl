using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

// Test-only HTTP proxy on 127.0.0.1 (random port). It never forwards anything to the network: it records what a
// client sends and answers according to the mode.
//   connect-garbage : "200 Connection established", records the first tunnel bytes, then answers with non-TLS bytes
//   connect-403     : refuses the tunnel with 403
//   connect-407     : asks for proxy authentication
//   silent          : accepts and never answers (timeout)
//   close           : accepts, reads the request and closes without an answer
//   tls-garbage     : records the first bytes (a TLS ClientHello for an https proxy) and answers with non-TLS bytes
//   respond         : plain HTTP server for the parser tests: records the request (head and body) and sends the
//                     scripted response given to the constructor
public sealed class FakeProxy : IDisposable {
    readonly TcpListener listener;
    readonly Thread worker;
    readonly string mode;
    volatile bool stopping;
    public readonly int Port;
    public readonly List<string> Requests = new List<string>();
    public readonly List<byte[]> TunnelBytes = new List<byte[]>();

    readonly string response;
    public FakeProxy(string mode) : this(mode, "") { }
    public FakeProxy(string mode, string response) {
        this.mode = mode;
        this.response = response;
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        worker = new Thread(Run);
        worker.IsBackground = true;
        worker.Start();
    }

    // A port on which nothing listens (refused connections).
    public static int ClosedPort() {
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        int port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        return port;
    }

    public string AllRequests() { lock (Requests) { return string.Join("\n----\n", Requests.ToArray()); } }

    void Run() {
        while (!stopping) {
            TcpClient client;
            try { client = listener.AcceptTcpClient(); } catch { return; }
            try { Handle(client); } catch { } finally { client.Close(); }
        }
    }

    void Handle(TcpClient client) {
        NetworkStream stream = client.GetStream();
        stream.ReadTimeout = 10000;
        if (mode == "tls-garbage") {
            var first = new byte[4096];
            int got = 0;
            try { got = stream.Read(first, 0, first.Length); } catch (IOException) { }
            var hello = new byte[got];
            Array.Copy(first, hello, got);
            lock (TunnelBytes) { TunnelBytes.Add(hello); }
            Send(stream, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\nthis is not TLS");
            Thread.Sleep(200);
            return;
        }
        string head = ReadHead(stream);
        lock (Requests) { Requests.Add(head); }
        switch (mode) {
            case "connect-garbage": {
                Send(stream, "HTTP/1.1 200 Connection established\r\n\r\n");
                var buffer = new byte[4096];
                int n = 0;
                try { n = stream.Read(buffer, 0, buffer.Length); } catch (IOException) { }
                var copy = new byte[n];
                Array.Copy(buffer, copy, n);
                lock (TunnelBytes) { TunnelBytes.Add(copy); }
                Send(stream, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\nthis is not TLS");
                Thread.Sleep(200);
                break;
            }
            case "respond": {
                int length = 0;
                foreach (string line in head.Split(new[] { "\r\n" }, StringSplitOptions.None))
                    if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = int.Parse(line.Substring(15).Trim());
                var body = new StringBuilder();
                for (int i = 0; i < length; i++) { int b = stream.ReadByte(); if (b < 0) break; body.Append((char)b); }
                lock (Requests) { Requests[Requests.Count - 1] = head + body.ToString(); }
                byte[] bytes = Encoding.GetEncoding(28591).GetBytes(response);
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush();
                Thread.Sleep(100);
                break;
            }
            case "connect-403": Send(stream, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"); break;
            case "connect-407": Send(stream, "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"x\"\r\nContent-Length: 0\r\n\r\n"); break;
            case "silent": for (int i = 0; i < 150 && !stopping; i++) Thread.Sleep(100); break;
            default: break;
        }
    }

    static string ReadHead(NetworkStream stream) {
        var text = new StringBuilder();
        try {
            while (text.Length < 65536) {
                int b = stream.ReadByte();
                if (b < 0) break;
                text.Append((char)b);
                if (text.Length >= 4 && text.ToString(text.Length - 4, 4) == "\r\n\r\n") break;
            }
        } catch (IOException) { }
        return text.ToString();
    }

    static void Send(NetworkStream stream, string text) {
        byte[] bytes = Encoding.ASCII.GetBytes(text);
        stream.Write(bytes, 0, bytes.Length);
        stream.Flush();
    }

    public void Dispose() {
        stopping = true;
        listener.Stop();
        worker.Join(3000);
    }
}
