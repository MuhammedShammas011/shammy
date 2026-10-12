// AudioOutputEngine.swift
// MacLink – macOS Host
// Receives 16-bit 48kHz mono PCM audio chunks from mobile web client (phone microphone)
// and plays them in real-time through the Mac's audio output using AudioQueue.

import Foundation
import AudioToolbox

final class AudioOutputEngine {
    private var queue: AudioQueueRef?
    private let sampleRate: Float64 = 48000.0
    private let channels: UInt32 = 1
    private let lock = NSLock()
    private(set) var isRunning: Bool = false

    init() {
        setupQueue()
    }

    deinit {
        stop()
    }

    func setupQueue() {
        lock.lock()
        defer { lock.unlock() }

        guard queue == nil else { return }

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        let status = AudioQueueNewOutput(&format, { (userData, queue, buffer) in
            AudioQueueFreeBuffer(queue, buffer)
        }, nil, nil, nil, 0, &queue)

        if status == noErr, let q = queue {
            AudioQueueStart(q, nil)
            isRunning = true
            print("[AudioOutputEngine] Initialized audio playback queue at \(Int(sampleRate)) Hz")
        } else {
            print("[AudioOutputEngine] Failed to create AudioQueue: \(status)")
        }
    }

    func playAudioChunk(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        guard let q = queue, !data.isEmpty else { return }

        var buffer: AudioQueueBufferRef?
        let byteCount = UInt32(data.count)
        let status = AudioQueueAllocateBuffer(q, byteCount, &buffer)

        guard status == noErr, let buf = buffer else { return }

        data.withUnsafeBytes { rawPtr in
            guard let baseAddr = rawPtr.baseAddress else { return }
            memcpy(buf.pointee.mAudioData, baseAddr, Int(byteCount))
        }
        buf.pointee.mAudioDataByteSize = byteCount

        AudioQueueEnqueueBuffer(q, buf, 0, nil)
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        if let q = queue {
            AudioQueueStop(q, true)
            AudioQueueDispose(q, true)
            queue = nil
        }
        isRunning = false
    }
}
