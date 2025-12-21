import Foundation

struct MLXPreferences {
    static func modelID(default value: String = "mlx-community/SmolLM2-1.7B-Instruct-4bit") -> String {
        let env = ProcessInfo.processInfo.environment["OVERHEAR_MLX_MODEL_ID"]
        let stored = UserDefaults.standard.string(forKey: "overhear.mlx.modelID")
        let resolved = env ?? stored ?? value
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

        // Also clear common MLX/MLXLLM download locations.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            home.appendingPathComponent("Library/Caches/mlx"),
            home.appendingPathComponent("Library/Caches/MLXLLM"),
            home.appendingPathComponent("Library/Caches/huggingface/hub"),
            home.appendingPathComponent(".cache/mlx"),
            home.appendingPathComponent(".cache/huggingface/hub")
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
