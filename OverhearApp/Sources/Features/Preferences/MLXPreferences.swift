import Foundation

struct MLXPreferences {
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
            return
        }
        UserDefaults.standard.set(cleaned, forKey: "overhear.mlx.modelID")
    }

    static func clearModelCache() {
        // Remove our own cache directory (legacy path).
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let dir = appSupport.appendingPathComponent("com.overhear.app/MLXModels")
        try? FileManager.default.removeItem(at: dir)

        // Also clear MLXLLM-local caches we own. Avoid deleting broader/shared caches
        // (e.g. Hugging Face) to prevent removing data used by other apps.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            home.appendingPathComponent("Library/Caches/MLXLLM"),
            home.appendingPathComponent(".cache/mlx")
        ]
        for url in candidates {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func sanitize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Restrict to common HF/MLX identifier characters.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.@/").inverted
        return trimmed.rangeOfCharacter(from: allowed) == nil ? trimmed : nil
    }
}
