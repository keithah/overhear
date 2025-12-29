import Foundation

/// Helper for writing human-readable debug lines into `/tmp/overhear.log`.
struct FileLogger {
    private static let logURL = URL(fileURLWithPath: "/tmp/overhear.log")
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
