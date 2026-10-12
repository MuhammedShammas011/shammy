// VideoStreamer.cs
// MacLink – Windows Host
// Accepts raw BGRA frames, encodes them as JPEG using SkiaSharp,
// and broadcasts to all connected web stream clients (MJPEG) and native TCP clients.

using System;
using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using MacLink.Windows.Capture;
using SkiaSharp;

namespace MacLink.Windows.Streaming
{
    public class VideoStreamer : IDisposable
    {
        public float JpegQuality { get; set; } = 0.5f;  // 0.0-1.0

        // Published JPEG frame bytes (for web MJPEG clients)
        public event EventHandler<byte[]>? JpegFrameReady;

        // Native TCP client connection (for iOS/Android native client)
        public TcpClient? NativeClient { get; set; }

        private ulong _frameIndex;
        private bool _disposed;

        /// <summary>
        /// Encode a BGRA frame to JPEG and publish to all clients.
        /// Call this from the ScreenCapture.FrameReady handler.
        /// </summary>
        public void EnqueueFrame(FrameEventArgs frame)
        {
            if (_disposed) return;
            Task.Run(() => EncodeAndSend(frame));
        }

        private void EncodeAndSend(FrameEventArgs frame)
        {
            try
            {
                byte[]? jpeg = EncodeJpeg(frame);
                if (jpeg == null) return;

                ulong idx = Interlocked.Increment(ref _frameIndex);

                // Notify MJPEG web clients
                JpegFrameReady?.Invoke(this, jpeg);

                // Send to native TCP client
                if (NativeClient?.Connected == true)
                {
                    try
                    {
                        byte[] packet = MakeNativeVideoPacket(0x01, idx, jpeg);
                        NativeClient.GetStream().Write(packet, 0, packet.Length);
                    }
                    catch
                    {
                        NativeClient = null;
                    }
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[Streamer] Encode error: {ex.Message}");
            }
        }

        private byte[]? EncodeJpeg(FrameEventArgs frame)
        {
            int quality = (int)(JpegQuality * 100);
            quality = Math.Clamp(quality, 10, 95);

            using var bm = new SKBitmap(frame.Width, frame.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
            unsafe
            {
                fixed (byte* ptr = frame.Bgra)
                {
                    var srcInfo = new SKImageInfo(frame.Width, frame.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
                    bm.InstallPixels(srcInfo, (IntPtr)ptr, frame.Width * 4);
                }
            }
            using var img  = SKImage.FromBitmap(bm);
            using var data = img.Encode(SKEncodedImageFormat.Jpeg, quality);
            return data?.ToArray();
        }

        /// <summary>
        /// Video frame packet: 1 type byte + 8-byte big-endian index + 4-byte length + data.
        /// Matches the MacLink wire protocol expected by iOS/Android native clients.
        /// </summary>
        private static byte[] MakeNativeVideoPacket(byte typeCode, ulong index, byte[] data)
        {
            var packet = new byte[13 + data.Length];
            packet[0] = typeCode;
            BinaryPrimitives.WriteUInt64BigEndian(packet.AsSpan(1, 8), index);
            BinaryPrimitives.WriteUInt32BigEndian(packet.AsSpan(9, 4), (uint)data.Length);
            data.CopyTo(packet, 13);
            return packet;
        }

        public void Dispose()
        {
            _disposed = true;
        }
    }
}
