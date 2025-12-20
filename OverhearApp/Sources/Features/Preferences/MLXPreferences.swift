import Foundation

struct MLXPreferences {
    static func modelID(default value: String = "mlx-community/SmolLM2-1.7B-Instruct-4bit") -> String {
        let env = ProcessInfo.processInfo.environment["OVERHEAR_MLX_MODEL_ID"]
        let stored = UserDefaults.standard.string(forKey: "overhear.mlx.modelID")
        return env ?? stored ?? value
    }

    static func setModelID(_ id: String) {
        UserDefaults.standard.set(id, forKey: "overhear.mlx.modelID")
    }

    static func clearModelCache() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.overhear.app/MLXModels")
        try? FileManager.default.removeItem(at: dir)
    }
}
