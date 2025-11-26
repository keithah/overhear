import AVFoundation
import AudioToolbox
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
        configuration.width = 1
        configuration.height = 1
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        self.mixer = try AudioMixer(outputURL: outputURL)
        self.stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(mixer, type: .audio, sampleHandlerQueue: outputQueue)
    }

    func start() async throws {
        try mixer.start()
        try await stream.startCapture()

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
    private let systemAudioPlayer = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var tapInstalled = false
    private let writingQueue = DispatchQueue(label: "com.overhear.audiospike.writer")

    private let outputURL: URL

    init(outputURL: URL) throws {
        self.outputURL = outputURL
        super.init()
    }

    func start() throws {
        let mainMixer = engine.mainMixerNode
        let mixerFormat = AudioMixer.mixerFormat(for: mainMixer)
        self.file = try AVAudioFile(forWriting: outputURL,
                                    settings: mixerFormat.settings)
        engine.attach(systemAudioPlayer)

        // Connect microphone (input) and system audio player into the main mixer.
        let micInput = engine.inputNode
        engine.connect(micInput, to: mainMixer, format: micInput.inputFormat(forBus: 0))
        engine.connect(systemAudioPlayer, to: mainMixer, format: mainMixer.outputFormat(forBus: 0))

        if !tapInstalled {
            mainMixer.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                guard let self, let file = self.file else { return }
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
        systemAudioPlayer.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("Stream stopped with error: \(error)\n", stderr)
    }

    private static func mixerFormat(for mixer: AVAudioMixerNode) -> AVAudioFormat {
        mixer.outputFormat(forBus: 0)
    }
}

enum CaptureError: Error {
    case noDisplayFound
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
