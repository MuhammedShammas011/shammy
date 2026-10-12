// MicrophoneCapture.swift
// MacLink – macOS Host
// Captures the Mac's built-in microphone using AVFoundation
// and publishes PCM audio chunks so the phone can hear room and laptop microphone audio during calls.

import Foundation
import AVFoundation
import AudioToolbox
import Combine

final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "shammy.mic.capture", qos: .userInteractive)
    let audioPublisher = PassthroughSubject<Data, Never>()
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        guard let mic = AVCaptureDevice.default(for: .audio) else {
            print("[MicrophoneCapture] No default audio input device found")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: mic)
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: queue)

            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()

            Task.detached(priority: .userInitiated) { [weak self] in
                self?.session.startRunning()
            }
            isRunning = true
            print("[MicrophoneCapture] Started recording from \(mic.localizedName)")
        } catch {
            print("[MicrophoneCapture] Failed to start: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        session.stopRunning()
        isRunning = false
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        if let pcm = AudioPCMUtils.extractPCM16(from: sampleBuffer) {
            audioPublisher.send(pcm)
        }
    }
}
