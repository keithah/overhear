import Foundation
import OSLog

struct MLXPreferences {
    static let modelChangedNotification = Notification.Name("MLXPreferencesModelChanged")

    static func modelID(default value: String = "mlx-community/Llama-3.2-1B-Instruct-4bit") -> String {
        let env = ProcessInfo.processInfo.environment["OVERHEAR_MLX_MODEL_ID"]
        let stored = UserDefaults.standard.string(forKey: "overhear.mlx.modelID")
        // Migrate older defaults to the new lighter default.
        var migrated: String? = stored
        let alreadyMigrated = UserDefaults.standard.bool(forKey: "overhear.mlx.migratedTo1BDefault")
        if !alreadyMigrated, let stored, stored == "mlx-community/SmolLM2-1.7B-Instruct" {
            migrated = value
            // Persist the migration so we don't keep warming the old model.
            UserDefaults.standard.set(value, forKey: "overhear.mlx.modelID")
            UserDefaults.standard.set(true, forKey: "overhear.mlx.migratedTo1BDefault")
        }

        let resolved = env ?? migrated ?? value
        return sanitize(resolved) ?? value
    }

    static func setModelID(_ id: String) {
        guard let cleaned = sanitize(id) else {
            UserDefaults.standard.removeObject(forKey: "overhear.mlx.modelID")
            NotificationCenter.default.post(name: modelChangedNotification, object: nil)
            return
        }
        UserDefaults.standard.set(cleaned, forKey: "overhear.mlx.modelID")
        NotificationCenter.default.post(name: modelChangedNotification, object: nil)
    }

    static func clearModelCache() {
        // Remove our own cache directory (legacy path).
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let scopedCaches: [URL] = [
                appSupport.appendingPathComponent("com.overhear.app/MLXModels"),
                home.appendingPathComponent("Library/Caches/com.overhear.app/MLXLLM")
            ]

            for url in scopedCaches {
            let standardized = url.standardizedFileURL
            let path = standardized.path
            if path.contains("/../") || path.contains("/./") || !path.hasPrefix(home.path) {
                FileLogger.log(category: "MLXPreferences", message: "Skipped clearing suspicious MLX cache path: \(path)")
                continue
            }
            do {
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(at: standardized)
                    FileLogger.log(category: "MLXPreferences", message: "Cleared MLX cache at \(path)")
                }
            } catch {
                FileLogger.log(category: "MLXPreferences", message: "Failed to clear MLX cache at \(path): \(error.localizedDescription)")
            }
        }
    }
    }

    static func sanitize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Restrict to common HF/MLX identifier characters.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.@/").inverted
        return trimmed.rangeOfCharacter(from: allowed) == nil ? trimmed : nil
    }
}
