// AudioPCMUtils.swift
// MacLink – macOS Host
// Utility to extract/convert any CMSampleBuffer (Float32/Int16, Mono/Stereo, Interleaved/Non-Interleaved)
// into standardized Linear PCM 16-bit Signed Integer 48kHz Mono Data.

import Foundation
import CoreMedia
import AudioToolbox

enum AudioPCMUtils {
    static let targetSampleRate: Float64 = 48000.0

    static func extractMonoFloat32(from sampleBuffer: CMSampleBuffer) -> [Float32]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGet:StreamBasicDescription(formatDesc)?.pointee else {
            return nil
        }

        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let inSampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : targetSampleRate

        let maxBuffers = isNonInterleaved ? channels : 1
        let bufferListPtr = AudioBufferList.allocate(maximumBuffers: maxBuffers)
        defer { free(UnsafeMutableRawPointer(bufferListPtr.unsafeMutablePointer)) }

        var blockBuffer: CMBlockBuffer?
        let bufferListSize = AudioBufferList.sizeInBytes(maximumBuffers: maxBuffers)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferListPtr.unsafeMutablePointer,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return nil }

        var monoSamples: [Float32] = []

        if isFloat && bitsPerChannel == 32 {
            if isNonInterleaved {
                guard let buf0 = bufferListPtr[0].mData else { return nil }
                let frames = Int(bufferListPtr[0].mDataByteSize) / MemoryLayout<Float32>.size
                guard frames > 0 else { return nil }
                monoSamples = [Float32](repeating: 0, count: frames)
                let leftPtr = buf0.bindMemory(to: Float32.self, capacity: frames)

                if channels >= 2 && bufferListPtr.count >= 2, let buf1 = bufferListPtr[1].mData {
                    let rightPtr = buf1.bindMemory(to: Float32.self, capacity: frames)
                    for i in 0..<frames {
                        monoSamples[i] = (leftPtr[i] + rightPtr[i]) * 0.5
                    }
                } else {
                    for i in 0..<frames {
                        monoSamples[i] = leftPtr[i]
                    }
                }
            } else {
                guard let buf0 = bufferListPtr[0].mData else { return nil }
                let totalFloats = Int(bufferListPtr[0].mDataByteSize) / MemoryLayout<Float32>.size
                let frames = totalFloats / channels
                guard frames > 0 else { return nil }
                monoSamples = [Float32](repeating: 0, count: frames)
                let inPtr = buf0.bindMemory(to: Float32.self, capacity: totalFloats)

                if channels >= 2 {
                    for i in 0..<frames {
                        monoSamples[i] = (inPtr[i * channels] + inPtr[i * channels + 1]) * 0.5
                    }
                } else {
                    for i in 0..<frames {
                        monoSamples[i] = inPtr[i]
                    }
                }
            }
        } else if bitsPerChannel == 16 {
            if isNonInterleaved {
                guard let buf0 = bufferListPtr[0].mData else { return nil }
                let frames = Int(bufferListPtr[0].mDataByteSize) / MemoryLayout<Int16>.size
                guard frames > 0 else { return nil }
                monoSamples = [Float32](repeating: 0, count: frames)
                let leftPtr = buf0.bindMemory(to: Int16.self, capacity: frames)

                if channels >= 2 && bufferListPtr.count >= 2, let buf1 = bufferListPtr[1].mData {
                    let rightPtr = buf1.bindMemory(to: Int16.self, capacity: frames)
                    for i in 0..<frames {
                        let l = Float32(leftPtr[i]) / 32768.0
                        let r = Float32(rightPtr[i]) / 32768.0
                        monoSamples[i] = (l + r) * 0.5
                    }
                } else {
                    for i in 0..<frames {
                        monoSamples[i] = Float32(leftPtr[i]) / 32768.0
                    }
                }
            } else {
                guard let buf0 = bufferListPtr[0].mData else { return nil }
                let totalInt16 = Int(bufferListPtr[0].mDataByteSize) / MemoryLayout<Int16>.size
                let frames = totalInt16 / channels
                guard frames > 0 else { return nil }
                monoSamples = [Float32](repeating: 0, count: frames)
                let inPtr = buf0.bindMemory(to: Int16.self, capacity: totalInt16)

                if channels >= 2 {
                    for i in 0..<frames {
                        let l = Float32(inPtr[i * channels]) / 32768.0
                        let r = Float32(inPtr[i * channels + 1]) / 32768.0
                        monoSamples[i] = (l + r) * 0.5
                    }
                } else {
                    for i in 0..<frames {
                        monoSamples[i] = Float32(inPtr[i]) / 32768.0
                    }
                }
            }
        } else {
            return nil
        }

        guard !monoSamples.isEmpty else { return nil }

        // Resample to targetSampleRate (48000 Hz) if incoming rate differs
        if abs(inSampleRate - targetSampleRate) > 10.0 && monoSamples.count > 1 {
            let inCount = monoSamples.count
            let outCount = Int(round(Double(inCount) * targetSampleRate / inSampleRate))
            guard outCount > 0 else { return monoSamples }
            var resampled = [Float32](repeating: 0, count: outCount)
            let ratio = Double(inCount - 1) / Double(max(1, outCount - 1))
            for i in 0..<outCount {
                let srcPos = Double(i) * ratio
                let idx0 = Int(srcPos)
                let idx1 = min(inCount - 1, idx0 + 1)
                let frac = Float32(srcPos - Double(idx0))
                resampled[i] = monoSamples[idx0] * (1.0 - frac) + monoSamples[idx1] * frac
            }
            return resampled
        }

        return monoSamples
    }

    static func floatToPCM16(_ samples: [Float32]) -> Data {
        var outData = Data(count: samples.count * MemoryLayout<Int16>.size)
        outData.withUnsafeMutableBytes { raw in
            let outPtr = raw.bindMemory(to: Int16.self)
            for i in 0..<samples.count {
                let s = max(-1.0, min(1.0, samples[i]))
                outPtr[i] = Int16(s < 0 ? s * 32768.0 : s * 32767.0)
            }
        }
        return outData
    }

    static func extractPCM16(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let floatSamples = extractMonoFloat32(from: sampleBuffer) else { return nil }
        return floatToPCM16(floatSamples)
    }
}
