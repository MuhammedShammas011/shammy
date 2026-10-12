// AudioPCMUtils.swift
// MacLink – macOS Host
// Utility to extract/convert any CMSampleBuffer (Float32/Int16, Mono/Stereo)
// into standardized Linear PCM 16-bit Signed Integer 48kHz Mono Data.

import Foundation
import CoreMedia
import AudioToolbox

enum AudioPCMUtils {
    static func extractPCM16(from sampleBuffer: CMSampleBuffer) -> Data? {
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
}
