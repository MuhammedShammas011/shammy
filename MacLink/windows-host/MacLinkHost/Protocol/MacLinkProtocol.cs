// MacLinkProtocol.cs
// MacLink – Windows Host
// C# port of the shared MacLink protocol (MacLinkProtocol.swift).
// Wire format: 4-byte big-endian length prefix + UTF-8 JSON payload.
// Video frames: 1 type byte (0x01=JPEG) + 8-byte index + 4-byte length + data.

using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MacLink.Windows.Protocol
{
    // ─── Message types ───────────────────────────────────────────────────────────

    public enum ControlMessageType
    {
        hello, helloAck, authChallenge, authResponse, authResult,
        startSession, sessionStarted, stopSession, sessionStopped,
        mouseMove, mouseDown, mouseUp, mouseScroll,
        keyDown, keyUp, textInput,
        displayInfo, displayChanged,
        qualityRequest, qualityAck,
        ping, pong, error
    }

    // ─── Envelope ────────────────────────────────────────────────────────────────

    public class ControlMessage
    {
        [JsonPropertyName("type")]
        public string Type { get; set; } = "";

        [JsonPropertyName("id")]
        public string Id { get; set; } = Guid.NewGuid().ToString();

        [JsonPropertyName("timestamp")]
        public double Timestamp { get; set; } = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

        [JsonPropertyName("payload")]
        public JsonElement? Payload { get; set; }
    }

    // ─── Payload structs ─────────────────────────────────────────────────────────

    public class HelloPayload
    {
        [JsonPropertyName("appVersion")]  public string AppVersion { get; set; } = "1.0.0";
        [JsonPropertyName("platform")]    public string Platform { get; set; } = "ios";
        [JsonPropertyName("deviceName")] public string DeviceName { get; set; } = "Device";
        [JsonPropertyName("supportedFeatures")] public string[] SupportedFeatures { get; set; } = ["video", "input", "keyboard"];
    }

    public class HelloAckPayload
    {
        [JsonPropertyName("hostAppVersion")] public string HostAppVersion { get; set; } = "1.0.0";
        [JsonPropertyName("macOSVersion")]   public string MacOSVersion { get; set; } = "";
        [JsonPropertyName("hostPlatform")]   public string HostPlatform { get; set; } = "windows";
        [JsonPropertyName("displayCount")]   public int DisplayCount { get; set; } = 1;
        [JsonPropertyName("requiresAuth")]   public bool RequiresAuth { get; set; } = true;
        [JsonPropertyName("serverTimestamp")] public double ServerTimestamp { get; set; }
            = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
    }

    public class AuthChallengePayload
    {
        [JsonPropertyName("challenge")] public string Challenge { get; set; } = "";
    }

    public class AuthResponsePayload
    {
        [JsonPropertyName("response")] public string Response { get; set; } = "";
    }

    public class AuthResultPayload
    {
        [JsonPropertyName("success")] public bool Success { get; set; }
        [JsonPropertyName("reason")]  public string? Reason { get; set; }
    }

    public class SessionInfoPayload
    {
        [JsonPropertyName("sessionID")]          public string SessionID { get; set; } = "";
        [JsonPropertyName("videoPort")]          public int VideoPort { get; set; }
        [JsonPropertyName("controlPort")]        public int ControlPort { get; set; }
        [JsonPropertyName("displayWidth")]       public int DisplayWidth { get; set; }
        [JsonPropertyName("displayHeight")]      public int DisplayHeight { get; set; }
        [JsonPropertyName("displayScaleFactor")] public double DisplayScaleFactor { get; set; } = 1.0;
    }

    public class DisplayInfoPayload
    {
        [JsonPropertyName("width")]       public int Width { get; set; }
        [JsonPropertyName("height")]      public int Height { get; set; }
        [JsonPropertyName("scaleFactor")] public double ScaleFactor { get; set; } = 1.0;
        [JsonPropertyName("displayIndex")] public int DisplayIndex { get; set; }
    }

    public class MouseMovePayload
    {
        [JsonPropertyName("normX")] public double NormX { get; set; }
        [JsonPropertyName("normY")] public double NormY { get; set; }
    }

    public class MouseButtonPayload
    {
        [JsonPropertyName("button")]     public string Button { get; set; } = "left";
        [JsonPropertyName("pressed")]    public bool Pressed { get; set; }
        [JsonPropertyName("normX")]      public double NormX { get; set; }
        [JsonPropertyName("normY")]      public double NormY { get; set; }
        [JsonPropertyName("clickCount")] public int ClickCount { get; set; } = 1;
    }

    public class MouseScrollPayload
    {
        [JsonPropertyName("deltaX")] public double DeltaX { get; set; }
        [JsonPropertyName("deltaY")] public double DeltaY { get; set; }
        [JsonPropertyName("normX")]  public double NormX { get; set; }
        [JsonPropertyName("normY")]  public double NormY { get; set; }
    }

    public class KeyEventPayload
    {
        [JsonPropertyName("keyCode")]    public ushort KeyCode { get; set; }    // macOS VKC
        [JsonPropertyName("pressed")]    public bool Pressed { get; set; }
        [JsonPropertyName("modifiers")]  public uint Modifiers { get; set; }
        [JsonPropertyName("characters")] public string? Characters { get; set; }
    }

    public class TextInputPayload
    {
        [JsonPropertyName("text")] public string Text { get; set; } = "";
    }

    public class QualityRequestPayload
    {
        [JsonPropertyName("targetFPS")]    public int TargetFPS { get; set; } = 30;
        [JsonPropertyName("targetWidth")]  public int TargetWidth { get; set; } = 1280;
        [JsonPropertyName("targetHeight")] public int TargetHeight { get; set; } = 800;
        [JsonPropertyName("bitrateKbps")] public int? BitrateKbps { get; set; }
    }

    public class PingPayload
    {
        [JsonPropertyName("sentAt")] public double SentAt { get; set; }
            = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
    }

    public class PongPayload
    {
        [JsonPropertyName("receivedAt")] public double ReceivedAt { get; set; }
        [JsonPropertyName("echoedAt")]   public double EchoedAt { get; set; }
            = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
    }

    public class ErrorPayload
    {
        [JsonPropertyName("code")]    public string Code { get; set; } = "";
        [JsonPropertyName("message")] public string Message { get; set; } = "";
    }

    // ─── Framing ─────────────────────────────────────────────────────────────────

    public static class MessageFramer
    {
        private const int MaxFrameSize = 4 * 1024 * 1024; // 4 MB

        public static byte[] Encode(ControlMessage message)
        {
            var json = JsonSerializer.SerializeToUtf8Bytes(message);
            if (json.Length > MaxFrameSize)
                throw new InvalidOperationException($"Message too large: {json.Length}");

            var frame = new byte[4 + json.Length];
            BinaryPrimitives.WriteUInt32BigEndian(frame, (uint)json.Length);
            json.CopyTo(frame, 4);
            return frame;
        }

        /// <summary>
        /// Decode all complete messages from buffer. Consumed bytes are removed.
        /// </summary>
        public static List<ControlMessage> Decode(ref byte[] buffer)
        {
            var messages = new List<ControlMessage>();
            int pos = 0;

            while (pos + 4 <= buffer.Length)
            {
                var length = BinaryPrimitives.ReadUInt32BigEndian(buffer.AsSpan(pos, 4));
                if (length > MaxFrameSize) throw new InvalidOperationException($"Frame length {length} exceeds max");
                int total = (int)length + 4;
                if (pos + total > buffer.Length) break;

                var json = buffer.AsSpan(pos + 4, (int)length);
                var msg = JsonSerializer.Deserialize<ControlMessage>(json);
                if (msg != null) messages.Add(msg);
                pos += total;
            }

            if (pos > 0)
            {
                var remaining = new byte[buffer.Length - pos];
                buffer.AsSpan(pos).CopyTo(remaining);
                buffer = remaining;
            }
            return messages;
        }

        /// <summary>
        /// Build a video frame packet: 1 type byte + 8-byte index + 4-byte length + data.
        /// typeCode: 0x01 = JPEG
        /// </summary>
        public static byte[] MakeVideoFrame(byte typeCode, ulong index, byte[] data)
        {
            var packet = new byte[1 + 8 + 4 + data.Length];
            packet[0] = typeCode;
            BinaryPrimitives.WriteUInt64BigEndian(packet.AsSpan(1, 8), index);
            BinaryPrimitives.WriteUInt32BigEndian(packet.AsSpan(9, 4), (uint)data.Length);
            data.CopyTo(packet, 13);
            return packet;
        }
    }

    // ─── Constants ───────────────────────────────────────────────────────────────

    public static class MacLinkConstants
    {
        public const int DefaultControlPort = 55_101;
        public const int DefaultWebPort     = 55_100;
        public const string ProtocolVersion = "1.0";
        public const string AppVersion      = "1.0.0";
        public const double PingInterval    = 5.0;
        public const double ConnectionTimeout = 10.0;
        public const double ReconnectDelay  = 2.0;
        public const int MaxReconnectAttempts = 5;
    }

    // ─── macOS VK → Windows VK mapping ──────────────────────────────────────────

    /// <summary>
    /// Maps macOS virtual key codes (from KeyEventPayload.keyCode) to Windows
    /// virtual key codes for SendInput. 
    /// Reference: https://boredzo.org/x-keycodes/
    /// </summary>
    public static class KeyCodeMap
    {
        private static readonly Dictionary<ushort, ushort> MacToWin = new()
        {
            // Letters
            [0]  = 0x41, // A
            [1]  = 0x53, // S
            [2]  = 0x44, // D
            [3]  = 0x46, // F
            [4]  = 0x48, // H
            [5]  = 0x47, // G
            [6]  = 0x5A, // Z
            [7]  = 0x58, // X
            [8]  = 0x43, // C
            [9]  = 0x56, // V
            [11] = 0x42, // B
            [12] = 0x51, // Q
            [13] = 0x57, // W
            [14] = 0x45, // E
            [15] = 0x52, // R
            [16] = 0x59, // Y
            [17] = 0x54, // T
            [32] = 0x55, // U
            [34] = 0x49, // I
            [31] = 0x4F, // O
            [35] = 0x50, // P
            [37] = 0x4C, // L
            [38] = 0x4A, // J
            [40] = 0x4B, // K
            [45] = 0x4E, // N
            [46] = 0x4D, // M
            // Numbers
            [18] = 0x31, // 1
            [19] = 0x32, // 2
            [20] = 0x33, // 3
            [21] = 0x34, // 4
            [22] = 0x36, // 6
            [23] = 0x35, // 5
            [24] = 0xBB, // = (VK_OEM_PLUS)
            [25] = 0x39, // 9
            [26] = 0x37, // 7
            [27] = 0xBD, // - (VK_OEM_MINUS)
            [28] = 0x38, // 8
            [29] = 0x30, // 0
            // Special
            [36] = 0x0D, // Return/Enter
            [48] = 0x09, // Tab
            [49] = 0x20, // Space
            [51] = 0x08, // Delete/Backspace
            [53] = 0x1B, // Escape
            [117]= 0x2E, // Forward Delete
            [115]= 0x24, // Home
            [119]= 0x23, // End
            [116]= 0x21, // Page Up
            [121]= 0x22, // Page Down
            // Arrows
            [123]= 0x25, // Left
            [124]= 0x27, // Right
            [125]= 0x28, // Down
            [126]= 0x26, // Up
            // Function keys
            [122]= 0x70, [120]= 0x71, [99] = 0x72, [118]= 0x73,
            [96] = 0x74, [97] = 0x75, [98] = 0x76, [100]= 0x77,
            [101]= 0x78, [109]= 0x79, [103]= 0x7A, [111]= 0x7B,
            // Symbols
            [33] = 0xDB, // [ 
            [30] = 0xDD, // ]
            [39] = 0xDE, // '
            [41] = 0xBA, // ;
            [42] = 0xDC, // backslash
            [43] = 0xBC, // ,
            [47] = 0xBE, // .
            [44] = 0xBF, // /
            [50] = 0xC0, // `
        };

        /// <summary>Returns Windows VK code for a macOS VKC, or 0 if unmapped.</summary>
        public static ushort ToWindows(ushort macVKC)
            => MacToWin.TryGetValue(macVKC, out var wvk) ? wvk : (ushort)0;

        // macOS modifier flags → Windows modifier keys
        public const uint MacShift   = 0x0002_0000;
        public const uint MacControl = 0x0004_0000;
        public const uint MacOption  = 0x0008_0000;
        public const uint MacCommand = 0x0010_0000;
    }
}
