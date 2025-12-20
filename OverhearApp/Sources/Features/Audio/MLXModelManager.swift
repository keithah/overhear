import Foundation
import os.log

/// Handles on-disk MLX model caching/versioning and download.
actor MLXModelManager {
    struct ModelInfo: Equatable {
        let version: String
        let path: URL?
    }

    enum State: Equatable {
        case idle
        case downloading(Double) // 0...1
        case ready(ModelInfo)
        case unavailable(String)
    }

    private let logger = Logger(subsystem: "com.overhear.app", category: "MLXModelManager")
    private let modelVersion: String
    private let downloadURL: URL?
    private let baseDirectory: URL
    private(set) var state: State = .idle

    init(
        modelVersion: String = ProcessInfo.processInfo.environment["OVERHEAR_MLX_MODEL_VERSION"]
            ?? "smol2-1.7b-instruct-4bit",
        downloadURL: URL? = {
            if let env = ProcessInfo.processInfo.environment["OVERHEAR_MLX_MODEL_URL"], let url = URL(string: env) {
                return url
            }
            // Default to a small instruction-tuned model packaged for MLX.
            return URL(string: "https://huggingface.co/mlx-community/SmolLM2-1.7B-Instruct-4bit-mlx/resolve/main/model.safetensors")
        }(),
        baseDirectory: URL? = nil
    ) {
        self.modelVersion = modelVersion
        self.downloadURL = downloadURL
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseDirectory = appSupport.appendingPathComponent("com.overhear.app/MLXModels")
        }
    }

    func ensureModel() async -> ModelInfo? {
        if case .ready(let info) = state {
            return info
        }

        let target = baseDirectory.appendingPathComponent(modelVersion, isDirectory: true)
        let marker = target.appendingPathComponent(".ready")

        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            state = .unavailable("Failed to create model dir: \(error.localizedDescription)")
            return nil
        }

        if FileManager.default.fileExists(atPath: marker.path) {
            let info = ModelInfo(version: modelVersion, path: target)
            state = .ready(info)
            return info
        }

        guard let downloadURL else {
            state = .unavailable("No model URL configured")
            return nil
        }

        state = .downloading(0)
        do {
            let (bytes, response) = try await URLSession.shared.bytes(from: downloadURL)
            let expectedLength = response.expectedContentLength
            let destination = target.appendingPathComponent(downloadURL.lastPathComponent)
            // Remove any existing file to avoid conflicts.
            try? FileManager.default.removeItem(at: destination)

            let stream = OutputStream(url: destination, append: false)!
            stream.open()
            defer { stream.close() }

            var received: Int64 = 0
            for try await byte in bytes {
                var value = byte
                let wrote = withUnsafeBytes(of: &value) { ptr -> Int in
                    guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return stream.write(base, maxLength: 1)
                }
                if wrote < 0 {
                    throw stream.streamError ?? URLError(.cannotWriteToFile)
                }
                received += 1
                if expectedLength > 0 {
                    let progress = min(1.0, Double(received) / Double(expectedLength))
                    state = .downloading(progress)
                }
            }

            try Data().write(to: marker)
            let info = ModelInfo(version: modelVersion, path: target)
            state = .ready(info)
            logger.info("MLX model ready at \(destination.path, privacy: .public)")
            return info
        } catch {
            state = .unavailable("Download failed: \(error.localizedDescription)")
            logger.error("MLX model download failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
