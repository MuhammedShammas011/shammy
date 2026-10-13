// ScreenCaptureManager.swift
// MacLink – macOS Host
// Uses ScreenCaptureKit (macOS 12.3+) to continuously capture the main display
// and publish CMSampleBuffers at a configurable frame rate.

import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AudioToolbox
import Combine
import AppKit

// MARK: - Display info snapshot

struct DisplayInfo {
    let width: Int
    let height: Int
    let scaleFactor: Double
    let displayID: CGDirectDisplayID
}

// MARK: - ScreenCaptureManager

final class ScreenCaptureManager: NSObject, SCStreamDelegate, SCStreamOutput {

    // Publishers
    let framePublisher = PassthroughSubject<CMSampleBuffer, Never>()
    let fpsPublisher   = PassthroughSubject<Double, Never>()
    let audioPublisher = PassthroughSubject<Data, Never>()

    private(set) var currentDisplayInfo = DisplayInfo(width: 1280, height: 720,
                                                       scaleFactor: 1.0,
                                                       displayID: CGMainDisplayID())

    // Internal
    private(set) var isCapturing: Bool = false
    private var stream: SCStream?
    private var configuration = SCStreamConfiguration()
    private var targetFPS: Int = 30
    private var targetWidth: Int = 1280
    private var targetHeight: Int = 800

    // FPS tracking
    private var lastFrameTime: CFAbsoluteTime = 0
    private var frameCount: Int = 0
    private var fpsTimer: Timer?

    private let micCapture = MicrophoneCapture()
    private var cancellables = Set<AnyCancellable>()
    private let audioMixer = RealtimeAudioMixer()

    // MARK: - Start / Stop

    func start() async throws {
        guard !isCapturing else { return }
        // Refresh display info
        let mainDisplay = CGMainDisplayID()
        let w = CGDisplayPixelsWide(mainDisplay)
        let h = CGDisplayPixelsHigh(mainDisplay)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        currentDisplayInfo = DisplayInfo(width: w, height: h,
                                         scaleFactor: Double(scale),
                                         displayID: mainDisplay)

        if w > 0 && h > 0 {
            targetHeight = Int(round(Double(targetWidth) * Double(h) / Double(w)))
        }

        // Ask ScreenCaptureKit for the list of shareable content
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                            onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == mainDisplay })
                            ?? content.displays.first else {
            throw ScreenCaptureError.noDisplayAvailable
        }

        // Configure the stream
        configuration = SCStreamConfiguration()
        configuration.width  = targetWidth
        configuration.height = targetHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor  = true
        configuration.scalesToFit  = true
        configuration.capturesAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 1
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = true
        }
        configuration.queueDepth   = 3

        let filter = SCContentFilter(display: display, excludingWindows: [])

        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try? stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        var scMicActive = false
        if #available(macOS 15.0, *) {
            do {
                try stream?.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
                scMicActive = true
            } catch {
                print("[Capture] SCStream microphone not supported: \(error)")
            }
        }
        try await stream?.startCapture()

        startFPSTimer()
        isCapturing = true

        // Only start fallback AVCaptureSession if SCStream native microphone is not available
        if !scMicActive {
            micCapture.audioPublisher
                .sink { [weak self] pcm in
                    self?.audioPublisher.send(pcm)
                }
                .store(in: &cancellables)
            micCapture.start()
        }
    }

    func stop() {
        isCapturing = false
        fpsTimer?.invalidate()
        fpsTimer = nil
        micCapture.stop()
        cancellables.removeAll()
        Task {
            try? await stream?.stopCapture()
            stream = nil
        }
    }

    func updateSettings(fps: Int, width: Int, height: Int) {
        targetFPS    = max(1, min(60, fps))
        targetWidth  = max(320, width)
        targetHeight = max(240, height)

        guard let stream = stream else { return }
        let newConfig = SCStreamConfiguration()
        newConfig.width  = targetWidth
        newConfig.height = targetHeight
        newConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        newConfig.pixelFormat  = configuration.pixelFormat
        newConfig.showsCursor  = configuration.showsCursor
        newConfig.scalesToFit  = configuration.scalesToFit
        newConfig.queueDepth   = configuration.queueDepth
        Task { try? await stream.updateConfiguration(newConfig) }
    }

    // MARK: - SCStreamOutput

    private let captureQueue = DispatchQueue(label: "maclink.capture", qos: .userInteractive)
    private let audioQueue   = DispatchQueue(label: "maclink.capture.audio", qos: .userInteractive)

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        if type == .screen {
            // Track FPS
            frameCount += 1
            framePublisher.send(sampleBuffer)
        } else if type == .audio {
            if let samples = AudioPCMUtils.extractMonoFloat32(from: sampleBuffer) {
                audioMixer.pushSystemAudio(samples)
                for chunk in audioMixer.popMixedChunks() {
                    audioPublisher.send(chunk)
                }
            }
        } else if type.rawValue == 2 { // .microphone in macOS 15+
            if let samples = AudioPCMUtils.extractMonoFloat32(from: sampleBuffer) {
                audioMixer.pushMicrophoneAudio(samples)
                for chunk in audioMixer.popMixedChunks() {
                    audioPublisher.send(chunk)
                }
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[Capture] Stream stopped with error: \(error)")
    }

    // MARK: - FPS timer

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let fps = Double(self.frameCount)
            self.frameCount = 0
            self.fpsPublisher.send(fps)
        }
    }
}

// MARK: - Errors

enum ScreenCaptureError: LocalizedError {
    case noDisplayAvailable
    case permissionDenied
    case streamFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable: return "No display found to capture."
        case .permissionDenied:   return "Screen Recording permission denied."
        case .streamFailed(let e): return "Stream failed: \(e.localizedDescription)"
        }
    }
}

// MARK: - Realtime Audio Mixer

final class RealtimeAudioMixer {
    private var systemQueue = [Float32]()
    private var micQueue = [Float32]()
    private let lock = NSLock()
    private let chunkSize = 960 // 20ms at 48000 Hz

    func pushSystemAudio(_ samples: [Float32]) {
        lock.lock()
        defer { lock.unlock() }
        systemQueue.append(contentsOf: samples)
        // Cap queue to 4800 samples (100ms) to prevent latency buildup
        if systemQueue.count > 4800 {
            systemQueue.removeFirst(systemQueue.count - 4800)
        }
    }

    func pushMicrophoneAudio(_ samples: [Float32]) {
        lock.lock()
        defer { lock.unlock() }
        micQueue.append(contentsOf: samples)
        if micQueue.count > 4800 {
            micQueue.removeFirst(micQueue.count - 4800)
        }
    }

    func popMixedChunks() -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        var results = [Data]()

        while true {
            let hasSys = systemQueue.count >= chunkSize
            let hasMic = micQueue.count >= chunkSize

            if hasSys && hasMic {
                var chunk = [Float32](repeating: 0, count: chunkSize)
                for i in 0..<chunkSize {
                    // Clean vocal mix with headroom
                    chunk[i] = systemQueue[i] + micQueue[i] * 0.95
                }
                systemQueue.removeFirst(chunkSize)
                micQueue.removeFirst(chunkSize)
                results.append(AudioPCMUtils.floatToPCM16(chunk))
            } else if hasSys && micQueue.isEmpty {
                let chunk = Array(systemQueue.prefix(chunkSize))
                systemQueue.removeFirst(chunkSize)
                results.append(AudioPCMUtils.floatToPCM16(chunk))
            } else if hasMic && systemQueue.isEmpty {
                var chunk = Array(micQueue.prefix(chunkSize))
                micQueue.removeFirst(chunkSize)
                for i in 0..<chunk.count {
                    chunk[i] *= 1.15 // Gentle boost for room speech
                }
                results.append(AudioPCMUtils.floatToPCM16(chunk))
            } else {
                break
            }
        }

        return results
    }
}

