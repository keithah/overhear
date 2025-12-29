import Foundation

/// Helper for writing human-readable debug lines into the app log directory.
struct FileLogger {
    private static let logURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/com.overhear.app", isDirectory: true)
        let directory = base ?? URL(fileURLWithPath: "/tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("overhear.log")
    }()
    private static let maxLogBytes: Int = 5 * 1024 * 1024
    private static let maxLogFiles: Int = 3
    private static let queue = DispatchQueue(label: "com.overhear.filelogger", qos: .utility)

    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["OVERHEAR_FILE_LOGS"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "overhear.enableFileLogs")
    }

    static func log(category: String, message: String) {
        guard isEnabled else { return }
        let timestamp = Date()
        let line = "[\(category)] \(timestamp): \(message)\n"
        append(line)
    }

    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            rotateIfNeeded()
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                do {
                    try data.write(to: logURL, options: .atomic)
                    let attributes = [FileAttributeKey.posixPermissions: NSNumber(value: Int16(0o600))]
                    try? FileManager.default.setAttributes(attributes, ofItemAtPath: logURL.path)
                } catch {
                    // Ignore file logging errors in release builds
                }
            }
        }
    }
}

private extension FileLogger {
    static func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue > maxLogBytes else {
            return
        }
        for index in stride(from: maxLogFiles - 1, through: 1, by: -1) {
            let src = logURL.deletingPathExtension().appendingPathExtension("log.\(index)")
            let dst = logURL.deletingPathExtension().appendingPathExtension("log.\(index + 1)")
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.moveItem(at: src, to: dst)
            }
        }
        let rotated = logURL.deletingPathExtension().appendingPathExtension("log.1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: logURL, to: rotated)
        try? Data().write(to: logURL, options: .atomic)
        let attributesReset = [FileAttributeKey.posixPermissions: NSNumber(value: Int16(0o600))]
        try? FileManager.default.setAttributes(attributesReset, ofItemAtPath: logURL.path)
    }
}
