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
        if #available(macOS 15.0, *) {
            try? stream?.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        }
        try await stream?.startCapture()

        startFPSTimer()
        isCapturing = true
    }

    func stop() {
        isCapturing = false
        fpsTimer?.invalidate()
        fpsTimer = nil
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
        } else if type == .audio || type.rawValue == 2 {
            if let pcm = extractPCM16(from: sampleBuffer) {
                audioPublisher.send(pcm)
            }
        }
    }

    private func extractPCM16(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return nil
        }

        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        var bufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let mData = bufferList.mBuffers.mData else { return nil }
        let byteSize = Int(bufferList.mBuffers.mDataByteSize)
        guard byteSize > 0 else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let channels = Int(asbd.mChannelsPerFrame)
        let is16Bit = asbd.mBitsPerChannel == 16
        let is32Bit = asbd.mBitsPerChannel == 32

        if isFloat && is32Bit {
            let totalFloatSamples = byteSize / MemoryLayout<Float32>.size
            let floatPtr = mData.bindMemory(to: Float32.self, capacity: totalFloatSamples)

            if channels <= 1 {
                var outData = Data(count: totalFloatSamples * MemoryLayout<Int16>.size)
                outData.withUnsafeMutableBytes { outRaw in
                    let outPtr = outRaw.bindMemory(to: Int16.self)
                    for i in 0..<totalFloatSamples {
                        let s = max(-1.0, min(1.0, floatPtr[i]))
                        outPtr[i] = Int16(s < 0 ? s * 32768.0 : s * 32767.0)
                    }
                }
                return outData
            } else {
                let frames = totalFloatSamples / channels
                var outData = Data(count: frames * MemoryLayout<Int16>.size)
                outData.withUnsafeMutableBytes { outRaw in
                    let outPtr = outRaw.bindMemory(to: Int16.self)
                    for frame in 0..<frames {
                        let left = floatPtr[frame * channels]
                        let right = floatPtr[frame * channels + 1]
                        let mixed = (left + right) * 0.5
                        let s = max(-1.0, min(1.0, mixed))
                        outPtr[frame] = Int16(s < 0 ? s * 32768.0 : s * 32767.0)
                    }
                }
                return outData
            }
        } else if is16Bit {
            if channels <= 1 {
                return Data(bytes: mData, count: byteSize)
            } else {
                let totalInt16 = byteSize / MemoryLayout<Int16>.size
                let inPtr = mData.bindMemory(to: Int16.self, capacity: totalInt16)
                let frames = totalInt16 / channels
                var outData = Data(count: frames * MemoryLayout<Int16>.size)
                outData.withUnsafeMutableBytes { outRaw in
                    let outPtr = outRaw.bindMemory(to: Int16.self)
                    for frame in 0..<frames {
                        let left = Int32(inPtr[frame * channels])
                        let right = Int32(inPtr[frame * channels + 1])
                        outPtr[frame] = Int16((left + right) / 2)
                    }
                }
                return outData
            }
        }

        return nil
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
