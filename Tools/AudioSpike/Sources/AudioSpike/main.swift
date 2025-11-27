import AVFoundation
import AudioToolbox
import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

@main
struct AudioSpikeCLI {
    static func main() async {
        guard #available(macOS 13.0, *) else {
            fputs("AudioSpike requires macOS 13 or newer.\n", stderr)
            exit(1)
        }

        do {
            let arguments = CommandLine.arguments.dropFirst()
            let duration = AudioSpikeCLI.parseDuration(arguments) ?? 20.0
            let outputURL = AudioSpikeCLI.parseOutput(arguments) ?? defaultOutputURL()

            print("Recording ~\(Int(duration))s of mixed system + mic audio to \(outputURL.path)")
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                fputs("Microphone access denied. Grant permission in System Settings > Privacy.\n", stderr)
                exit(1)
            }
            let hasScreenPermission = CGPreflightScreenCaptureAccess()
            print("Screen Recording permission: \(hasScreenPermission ? "granted" : "not granted")")
            try AudioSpikeCLI.ensureScreenRecordingPermission()
            AudioSpikeCLI.playStartBeep()

            let coordinator = try await AudioCaptureCoordinator(outputURL: outputURL, duration: duration)
            try await coordinator.start()
            print("Finished. WAV saved at \(outputURL.path)")
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func parseDuration(_ args: ArraySlice<String>) -> TimeInterval? {
        guard let durationArgIndex = args.firstIndex(of: "--duration").flatMap({ args.index(after: $0) }),
              durationArgIndex < args.endIndex,
              let value = Double(args[durationArgIndex]) else {
            return nil
        }
        return value
    }

    private static func parseOutput(_ args: ArraySlice<String>) -> URL? {
        guard let outputArgIndex = args.firstIndex(of: "--output").flatMap({ args.index(after: $0) }),
              outputArgIndex < args.endIndex else { return nil }
        let path = NSString(string: args[outputArgIndex]).expandingTildeInPath
        return URL(fileURLWithPath: path)
    }

    private static func defaultOutputURL() -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        return (desktop ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .appendingPathComponent("overhear-spike.wav")
    }

    private static func playStartBeep() {
        // Use the system alert sound so the user hears a start cue.
        NSSound.beep()
        AudioServicesPlayAlertSound(SystemSoundID(kSystemSoundID_UserPreferredAlert))
    }

    private static func ensureScreenRecordingPermission() throws {
        guard !CGPreflightScreenCaptureAccess() else { return }
        print("Requesting Screen Recording permission...")
        if CGRequestScreenCaptureAccess() {
            print("Screen Recording permission granted. Re-run the command to start capture.")
            exit(0)
        } else {
            throw CaptureError.screenRecordingPermissionDenied
        }
    }
}

@available(macOS 13.0, *)
final class AudioCaptureCoordinator {
    private let outputURL: URL
    private let duration: TimeInterval
    private let mixer: AudioMixer
    private let stream: SCStream
    private let outputQueue = DispatchQueue(label: "com.overhear.audiospike.stream")

    init(outputURL: URL, duration: TimeInterval) async throws {
        self.outputURL = outputURL
        self.duration = duration

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw CaptureError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.width = display.width
        configuration.height = display.height
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        self.mixer = try AudioMixer(outputURL: outputURL)
        self.stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(mixer, type: .audio, sampleHandlerQueue: outputQueue)
    }

    func start() async throws {
        try mixer.start()
        do {
            try await stream.startCapture()
        } catch {
            let nsError = error as NSError
            fputs("startCapture failed: domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)\n", stderr)
            throw error
        }

        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

        try await stop()
    }

    private func stop() async throws {
        try await stream.stopCapture()
        mixer.stop()
    }
}

@available(macOS 13.0, *)
final class AudioMixer: NSObject, SCStreamOutput {
    private let engine = AVAudioEngine()
    private let recordingMixer = AVAudioMixerNode()
    private let systemAudioPlayer = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var tapInstalled = false
    private let writingQueue = DispatchQueue(label: "com.overhear.audiospike.writer")
    private let monitorVolume: Float = 0.0
    private var loggedMicRMS = false
    private var loggedStreamRMS = false

    private let outputURL: URL

    init(outputURL: URL) throws {
        self.outputURL = outputURL
        super.init()
    }

    func start() throws {
        let mainMixer = engine.mainMixerNode
        engine.attach(recordingMixer)
        engine.attach(systemAudioPlayer)

        let micInput = engine.inputNode
        let recordingFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        // Route mic + system audio into a dedicated recording mixer.
        engine.connect(micInput, to: recordingMixer, format: micInput.inputFormat(forBus: 0))
        engine.connect(systemAudioPlayer, to: recordingMixer, format: recordingFormat)

        self.file = try AVAudioFile(forWriting: outputURL,
                                    settings: recordingFormat.settings)

        // Feed the recording mixer into the main mixer just for hardware output (muted).
        engine.connect(recordingMixer, to: mainMixer, format: recordingFormat)
        mainMixer.outputVolume = monitorVolume // mute monitor while leaving tap intact

        if !tapInstalled {
            recordingMixer.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
                guard let self, let file = self.file else { return }
                if !self.loggedMicRMS {
                    print(String(format: "mic+mix tap rms=%.5f", buffer.rms()))
                    self.loggedMicRMS = true
                }
                self.writingQueue.async {
                    do {
                        try file.write(from: buffer)
                    } catch {
                        fputs("Write error: \(error)\n", stderr)
                    }
                }
            }
            tapInstalled = true
        }

        try engine.start()
        systemAudioPlayer.play()
    }

    func stop() {
        engine.mainMixerNode.removeTap(onBus: 0)
        tapInstalled = false
        systemAudioPlayer.stop()
        engine.stop()
        file = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pcmBuffer = sampleBuffer.makePCMBuffer() else {
            return
        }
        if !loggedStreamRMS {
            print(String(format: "system stream rms=%.5f", pcmBuffer.rms()))
            loggedStreamRMS = true
        }
        systemAudioPlayer.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("Stream stopped with error: \(error)\n", stderr)
    }
}

enum CaptureError: Error {
    case noDisplayFound
    case screenRecordingPermissionDenied
}

extension CaptureError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display found to capture."
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission denied. Allow Terminal in System Settings > Privacy & Security > Screen Recording, then rerun."
        }
    }
}

private extension CMSampleBuffer {
    func makePCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = formatDescription else { return nil }
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let sampleCount = CMSampleBufferGetNumSamples(self)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            return nil
        }
        buffer.frameLength = buffer.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(self,
                                                                  at: 0,
                                                                  frameCount: Int32(sampleCount),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

private extension AVAudioPCMBuffer {
    func rms() -> Float {
        guard let floatChannelData = floatChannelData else { return 0 }
        let channelCount = Int(format.channelCount)
        let frameLength = Int(frameLength)
        var total: Float = 0
        var sampleCount: Int = 0
        for channel in 0..<channelCount {
            let samples = floatChannelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                total += sample * sample
                sampleCount += 1
            }
        }
        return sampleCount > 0 ? sqrtf(total / Float(sampleCount)) : 0
    }
}
