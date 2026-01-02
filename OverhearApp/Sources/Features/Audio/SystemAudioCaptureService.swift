import AVFoundation
import CoreGraphics
import os.log

/// Captures system/output audio using an AVCaptureScreenInput audio tap (requires Screen Recording permission).
/// Best-effort: if permission is denied or the API is unavailable, callers should fall back to mic-only capture.
final class SystemAudioCaptureService: NSObject {
    enum CaptureError: LocalizedError {
        case unavailable
        case permissionDenied(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "System audio capture is unavailable on this macOS version."
            case .permissionDenied(let message):
                return "System audio capture permission denied: \(message)"
            case .failed(let message):
                return "System audio capture failed: \(message)"
            }
        }
    }

    private let logger = Logger(subsystem: "com.overhear.app", category: "SystemAudioCapture")
    private let session = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let outputQueue = DispatchQueue(label: "com.overhear.app.systemaudiocapture.output", qos: .userInitiated)
    private var observers: [UUID: (AVAudioPCMBuffer) -> Void] = [:]
    private var isRunning = false

    func start() throws {
        guard !isRunning else { return }
        guard #available(macOS 14.0, *) else {
            throw CaptureError.unavailable
        }

        let displayID = CGMainDisplayID()
        guard let screenInput = AVCaptureScreenInput(displayID: displayID) else {
            throw CaptureError.failed("Could not create screen input for display \(displayID)")
        }
        screenInput.capturesAudio = true

        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(screenInput) {
            session.addInput(screenInput)
        } else {
            session.commitConfiguration()
            throw CaptureError.failed("Cannot add screen input")
        }

        if session.canAddOutput(audioOutput) {
            audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
            session.addOutput(audioOutput)
        } else {
            session.commitConfiguration()
            throw CaptureError.failed("Cannot add audio output")
        }

        session.commitConfiguration()

        session.startRunning()
        isRunning = true
        log("System audio capture session started")
    }

    func stop() {
        guard isRunning else { return }
        session.stopRunning()
        isRunning = false
        log("System audio capture session stopped")
    }

    func registerBufferObserver(_ observer: @escaping (AVAudioPCMBuffer) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        log("Registered system audio observer id=\(id) (total \(observers.count))")
        return id
    }

    func unregisterBufferObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
        log("Unregistered system audio observer id=\(id) (total \(observers.count))")
    }

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        FileLogger.log(category: "SystemAudioCapture", message: message)
    }
}

// MARK: - Sample buffer handling
extension SystemAudioCaptureService: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pcm = Self.makePCMBuffer(from: sampleBuffer) else { return }
        // Deliver to observers on the capture queue.
        for observer in observers.values {
            observer(pcm)
        }
    }
}

// MARK: - PCM conversion
private extension SystemAudioCaptureService {
    static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              let format = AVAudioFormat(streamDescription: asbd)
        else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcmBuffer.frameLength = frameCount

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 0,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        )
        let ablSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.stride * Int(format.channelCount)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            nil,
            &audioBufferList,
            ablSize,
            nil,
            nil,
            0,
            &blockBuffer
        )
        guard status == noErr else { return nil }

        let srcList = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        let dstList = pcmBuffer.mutableAudioBufferList
        let count = min(srcList.count, Int(dstList.pointee.mNumberBuffers))
        for i in 0..<count {
            let src = srcList[i]
            let dst = dstList[i]
            let bytes = min(Int(src.mDataByteSize), Int(dst.mDataByteSize))
            if let srcData = src.mData, let dstData = dst.mData, bytes > 0 {
                memcpy(dstData, srcData, bytes)
                dstList[i].mDataByteSize = UInt32(bytes)
            }
        }
        return pcmBuffer
    }
}
