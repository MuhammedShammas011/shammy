// ControlServer.cs
// MacLink – Windows Host
// TCP server that listens for one native client (iOS/Android), performs HMAC-SHA256
// auth handshake, then dispatches incoming control messages to the input injector.

using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using MacLink.Windows.Protocol;
using MacLink.Windows.Streaming;

namespace MacLink.Windows.Networking
{
    public enum ServerState { Idle, Listening, Connected, Disconnected }

    public class ClientConnectedEventArgs : EventArgs
    {
        public string DeviceName { get; init; } = "";
    }

    public class ControlServer : IDisposable
    {
        public event EventHandler<ControlMessage>? MessageReceived;
        public event EventHandler<ClientConnectedEventArgs>? ClientConnected;
        public event EventHandler? ClientDisconnected;

        public ServerState State { get; private set; } = ServerState.Idle;
        public string SharedSecret => _sharedSecret;

        private readonly VideoStreamer _streamer;
        private TcpListener? _listener;
        private TcpClient?   _client;
        private string _sharedSecret = "";
        private CancellationTokenSource? _cts;

        public ControlServer(VideoStreamer streamer) => _streamer = streamer;

        public async Task StartAsync(int port, CancellationToken ct = default)
        {
            _sharedSecret = LoadOrGenerateSecret();
            State = ServerState.Listening;

            _listener = new TcpListener(IPAddress.Any, port);
            _listener.Start();
            Console.WriteLine($"[Server] Listening on port {port}");

            // Accept loop – re-accept after each client disconnects
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    _client = await _listener.AcceptTcpClientAsync(ct);
                    _client.NoDelay = true;
                    Console.WriteLine($"[Server] Client connected: {_client.Client.RemoteEndPoint}");
                    await HandleClientAsync(_client, ct);
                }
                catch (OperationCanceledException) { break; }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[Server] Accept error: {ex.Message}");
                    await Task.Delay(1000, ct);
                }
            }
        }

        private async Task HandleClientAsync(TcpClient client, CancellationToken ct)
        {
            await using var stream = client.GetStream();
            try
            {
                string deviceName = await PerformHandshakeAsync(stream, client, ct);
                State = ServerState.Connected;
                ClientConnected?.Invoke(this, new ClientConnectedEventArgs { DeviceName = deviceName });

                // Start receive loop
                await ReceiveLoopAsync(stream, ct);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[Server] Client error: {ex.Message}");
            }
            finally
            {
                _streamer.NativeClient = null;
                client.Close();
                State = ServerState.Disconnected;
                ClientDisconnected?.Invoke(this, EventArgs.Empty);
                Console.WriteLine("[Server] Client disconnected.");
            }
        }

        private async Task<string> PerformHandshakeAsync(NetworkStream stream, TcpClient client, CancellationToken ct)
        {
            // 1. Receive HELLO
            var helloMsg = await ReceiveOneAsync(stream, ct);
            if (helloMsg.Type != "hello")
                throw new InvalidOperationException($"Expected hello, got {helloMsg.Type}");

            HelloPayload hello = JsonSerializer.Deserialize<HelloPayload>(helloMsg.Payload?.GetRawText() ?? "{}") ?? new();
            Console.WriteLine($"[Server] Hello from: {hello.DeviceName} ({hello.Platform})");

            // 2. Send HELLO ACK
            var ack = BuildMessage("helloAck", new HelloAckPayload
            {
                HostAppVersion = MacLinkConstants.AppVersion,
                MacOSVersion   = Environment.OSVersion.VersionString,
                HostPlatform   = "windows",
                DisplayCount   = 1,
                RequiresAuth   = true
            });
            await SendRawAsync(stream, ack, ct);

            // 3. Issue auth challenge
            string challenge = RandomHex(32);
            var challengeMsg = BuildMessage("authChallenge", new AuthChallengePayload { Challenge = challenge });
            await SendRawAsync(stream, challengeMsg, ct);

            // 4. Receive auth response
            var respMsg = await ReceiveOneAsync(stream, ct);
            if (respMsg.Type != "authResponse")
                throw new InvalidOperationException("Auth response not received.");

            AuthResponsePayload resp = JsonSerializer.Deserialize<AuthResponsePayload>(respMsg.Payload?.GetRawText() ?? "{}") ?? new();

            // 5. Verify HMAC
            bool ok = HmacEquals(_sharedSecret, challenge, resp.Response);
            var resultMsg = BuildMessage("authResult", new AuthResultPayload
            {
                Success = ok,
                Reason  = ok ? null : "Invalid auth token"
            });
            await SendRawAsync(stream, resultMsg, ct);
            if (!ok) throw new InvalidOperationException("Authentication failed.");

            // 6. Send session info
            int sw = GetSystemMetrics(SM_CXSCREEN);
            int sh = GetSystemMetrics(SM_CYSCREEN);
            var sessionMsg = BuildMessage("sessionStarted", new SessionInfoPayload
            {
                SessionID          = Guid.NewGuid().ToString(),
                VideoPort          = 0,
                ControlPort        = 0,
                DisplayWidth       = sw,
                DisplayHeight      = sh,
                DisplayScaleFactor = 1.0
            });
            await SendRawAsync(stream, sessionMsg, ct);

            // Hand the TCP connection to the video streamer
            _streamer.NativeClient = client;
            Console.WriteLine("[Server] Handshake complete. Session started.");
            return hello.DeviceName;
        }

        private async Task ReceiveLoopAsync(NetworkStream stream, CancellationToken ct)
        {
            byte[] buf = [];
            byte[] chunk = new byte[65536];

            while (!ct.IsCancellationRequested)
            {
                int n = await stream.ReadAsync(chunk, ct);
                if (n == 0) break;

                // Append to buffer
                var newBuf = new byte[buf.Length + n];
                buf.CopyTo(newBuf, 0);
                chunk.AsSpan(0, n).CopyTo(newBuf.AsSpan(buf.Length));
                buf = newBuf;

                foreach (var msg in MessageFramer.Decode(ref buf))
                    MessageReceived?.Invoke(this, msg);
            }
        }

        // ─── Helpers ─────────────────────────────────────────────────────────────

        public async Task SendAsync(ControlMessage msg, CancellationToken ct = default)
        {
            if (_streamer.NativeClient?.Connected != true) return;
            byte[] frame = MessageFramer.Encode(msg);
            await _streamer.NativeClient.GetStream().WriteAsync(frame, ct);
        }

        private static async Task<ControlMessage> ReceiveOneAsync(NetworkStream stream, CancellationToken ct)
        {
            byte[] buf = [];
            byte[] chunk = new byte[4096];
            while (true)
            {
                int n = await stream.ReadAsync(chunk, ct);
                if (n == 0) throw new EndOfStreamException("Connection closed.");
                var newBuf = new byte[buf.Length + n];
                buf.CopyTo(newBuf, 0);
                chunk.AsSpan(0, n).CopyTo(newBuf.AsSpan(buf.Length));
                buf = newBuf;
                var msgs = MessageFramer.Decode(ref buf);
                if (msgs.Count > 0) return msgs[0];
            }
        }

        private static byte[] BuildMessage<T>(string type, T payload)
        {
            var msg = new ControlMessage
            {
                Type    = type,
                Payload = JsonSerializer.Deserialize<JsonElement>(JsonSerializer.Serialize(payload))
            };
            return MessageFramer.Encode(msg);
        }

        private static async Task SendRawAsync(NetworkStream stream, byte[] data, CancellationToken ct)
            => await stream.WriteAsync(data, ct);

        private static bool HmacEquals(string secret, string message, string expectedHex)
        {
            var key = new HMACSHA256(Encoding.UTF8.GetBytes(secret));
            byte[] mac = key.ComputeHash(Encoding.UTF8.GetBytes(message));
            string actual = BitConverter.ToString(mac).Replace("-", "").ToLowerInvariant();
            return actual == expectedHex.ToLowerInvariant();
        }

        private static string RandomHex(int bytes)
        {
            byte[] buf = RandomNumberGenerator.GetBytes(bytes);
            return BitConverter.ToString(buf).Replace("-", "").ToLowerInvariant();
        }

        private static string LoadOrGenerateSecret()
        {
            string path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "MacLink", "secret.txt");
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (File.Exists(path)) return File.ReadAllText(path).Trim();
            string secret = RandomHex(32);
            File.WriteAllText(path, secret);
            return secret;
        }

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        static extern int GetSystemMetrics(int nIndex);
        const int SM_CXSCREEN = 0;
        const int SM_CYSCREEN = 1;

        public void Dispose()
        {
            _cts?.Cancel();
            _client?.Close();
            _listener?.Stop();
        }
    }
}
