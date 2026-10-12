// VideoStreamer.swift
// MacLink – macOS Host
// Accepts CMSampleBuffers from ScreenCaptureManager, encodes them with VideoToolbox
// (H.264 Baseline), and writes the resulting NAL units to the connected client's
// video UDP socket as simple RTP-like packets.
//
// Transport choice rationale:
//   - We use a direct TCP connection (same socket as the control channel) for video
//     in the first milestone to keep the architecture minimal.  The client receives
//     video frames as length-prefixed raw JPEG to maximise compatibility before
//     VideoToolbox H.264 is wired end-to-end.
//
//   - A VideoToolbox H.264 path is provided for the optimised milestone.
//     Switch VideoStreamer.mode to .h264 to enable it.

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import CoreImage
import AppKit
import ImageIO
import Network
import Combine

// MARK: - Streaming mode

enum StreamingMode {
    case jpeg       // simple JPEG over TCP (milestone 1-2)
    case h264       // H.264 NAL units over TCP (milestone 3+)
}

// MARK: - VideoStreamer

final class VideoStreamer {

    var mode: StreamingMode = .jpeg
    var jpegQuality: CGFloat = 0.5
    var connection: NWConnection?   // set by ControlServer once client connects
    let onJPEGFrame = PassthroughSubject<Data, Never>()

    private let encodeQueue = DispatchQueue(label: "maclink.encode", qos: .userInteractive)
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .priorityRequestLow: false
    ])
    private var compressionSession: VTCompressionSession?
    private var frameIndex: UInt64 = 0

    // MARK: - Enqueue frame

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        encodeQueue.async { [weak self] in
            guard let self else { return }
            switch self.mode {
            case .jpeg:  self.encodeJPEG(sampleBuffer)
            case .h264:  self.encodeH264(sampleBuffer)
            }
        }
    }

    func stop() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }

    // MARK: - JPEG path

    private func encodeJPEG(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        let jpegData = data as Data

        onJPEGFrame.send(jpegData)

        // Frame packet: 1 byte type (0x01 = JPEG frame) + 8 bytes frame index + 4 bytes length + data
        var packet = Data()
        packet.append(0x01)                 // type: JPEG
        var idx = frameIndex.bigEndian
        packet.append(contentsOf: withUnsafeBytes(of: &idx) { Array($0) })
        var len = UInt32(jpegData.count).bigEndian
        packet.append(contentsOf: withUnsafeBytes(of: &len) { Array($0) })
        packet.append(jpegData)

        frameIndex += 1
        sendVideoPacket(packet)
    }

    // MARK: - H.264 path

    private func encodeH264(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if compressionSession == nil {
            setupCompressionSession(width: CVPixelBufferGetWidth(pixelBuffer),
                                     height: CVPixelBufferGetHeight(pixelBuffer))
        }
        guard let session = compressionSession else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
                                         presentationTimeStamp: pts,
                                         duration: .invalid,
                                         frameProperties: nil,
                                         infoFlagsOut: nil,
                                         outputHandler: { [weak self] status, _, buffer in
            guard status == noErr, let buffer else { return }
            self?.handleEncodedFrame(buffer)
        })
    }

    private func setupCompressionSession(width: Int, height: Int) {
        var session: VTCompressionSession?
        VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard let s = session else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,
                              value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,
                              value: NSNumber(value: 2_000_000))  // 2 Mbps
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                              value: NSNumber(value: 60))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering,
                              value: kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(s)
        compressionSession = s
    }

    private func handleEncodedFrame(_ buffer: CMSampleBuffer) {
        // Extract all NAL units from the sample buffer
        guard let dataBuffer = buffer.dataBuffer else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPointer) == noErr,
              let ptr = dataPointer else { return }

        let isKeyFrame = buffer.sampleAttachments[0][.dependsOnOthers] as? Bool == false

        // Prepend SPS/PPS before key frames
        var payload = Data()
        if isKeyFrame, let formatDesc = buffer.formatDescription {
            payload.append(annexBSPSPPS(from: formatDesc))
        }

        // Convert from AVCC (4-byte length) to Annex B (0x00 0x00 0x00 0x01)
        var offset = 0
        while offset < totalLength {
            let naluLength = Int(UInt32(bigEndian: (ptr + offset)
                .withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }))
            offset += 4
            payload.append(contentsOf: [0, 0, 0, 1])   // start code
            payload.append(Data(bytes: ptr + offset, count: naluLength))
            offset += naluLength
        }

        var packet = Data()
        packet.append(0x02)     // type: H264 Annex-B
        var idx = frameIndex.bigEndian
        packet.append(contentsOf: withUnsafeBytes(of: &idx) { Array($0) })
        var len = UInt32(payload.count).bigEndian
        packet.append(contentsOf: withUnsafeBytes(of: &len) { Array($0) })
        packet.append(payload)

        frameIndex += 1
        sendVideoPacket(packet)
    }

    private func annexBSPSPPS(from format: CMFormatDescription) -> Data {
        var data = Data()
        var count: Int = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                                                            parameterSetPointerOut: nil,
                                                            parameterSetSizeOut: nil,
                                                            parameterSetCountOut: &count,
                                                            nalUnitHeaderLengthOut: nil)
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i,
                                                                parameterSetPointerOut: &ptr,
                                                                parameterSetSizeOut: &size,
                                                                parameterSetCountOut: nil,
                                                                nalUnitHeaderLengthOut: nil)
            if let p = ptr {
                data.append(contentsOf: [0, 0, 0, 1])
                data.append(Data(bytes: p, count: size))
            }
        }
        return data
    }

    // MARK: - Network send

    private func sendVideoPacket(_ data: Data) {
        connection?.send(content: data, completion: .idempotent)
    }
}
