import Foundation
@preconcurrency import CryptoKit
import Security

/// Represents a stored transcript with metadata
struct StoredTranscript: Codable, Identifiable {
    let id: String
    let meetingID: String
    let title: String
    let date: Date
    let transcript: String
    let duration: TimeInterval
    let audioFilePath: String?
    let segments: [SpeakerSegment]
    let summary: MeetingSummary?
    let notes: String?
    
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    
    var formattedDate: String {
        Self.dateFormatter.string(from: date)
    }
}

/// Manages storage and retrieval of transcripts
actor TranscriptStore {
    enum Error: LocalizedError {
        case storageDisabled
        case storageDirectoryNotFound
        case storageDirectoryCreationFailed(String)
        case encodingFailed(String)
        case decodingFailed(String)
        case notFound
        case deletionFailed(String)
        case encryptionFailed(String)
        case decryptionFailed(String)
        case keyManagementFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .storageDisabled:
                return "Transcript storage is disabled by configuration"
            case .storageDirectoryNotFound:
                return "Transcript storage directory not found"
            case .storageDirectoryCreationFailed(let message):
                return "Failed to create transcript storage directory: \(message)"
            case .encodingFailed(let message):
                return "Failed to encode transcript: \(message)"
            case .decodingFailed(let message):
                return "Failed to decode transcript: \(message)"
            case .notFound:
                return "Transcript not found"
            case .deletionFailed(let message):
                return "Failed to delete transcript: \(message)"
            case .encryptionFailed(let message):
                return "Failed to encrypt transcript: \(message)"
            case .decryptionFailed(let message):
                return "Failed to decrypt transcript: \(message)"
            case .keyManagementFailed(let message):
                return "Failed to manage encryption key: \(message)"
            }
        }
    }
    
    private let storageDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let encryptionKey: SymmetricKey
    private let persistenceEnabled: Bool

    private static let meetingIDDelimiter = "__"
    
    init(storageDirectory: URL? = nil) throws {
        guard Self.isStorageEnabled else {
            throw Error.storageDisabled
        }
        self.persistenceEnabled = true
        if let provided = storageDirectory {
            self.storageDirectory = provided
        } else {
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw Error.storageDirectoryNotFound
            }
            self.storageDirectory = appSupport.appendingPathComponent("com.overhear.app/Transcripts")
        }
        
        // Ensure storage directory exists (create if missing) and is not shadowed by a file
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: self.storageDirectory.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                throw Error.storageDirectoryNotFound
            }
        } else {
            do {
                try FileManager.default.createDirectory(at: self.storageDirectory,
                                                        withIntermediateDirectories: true,
                                                        attributes: nil)
            } catch {
                throw Error.storageDirectoryCreationFailed(error.localizedDescription)
            }
        }
        
        // Initialize encryption key from Keychain
        do {
            self.encryptionKey = try Self.getOrCreateEncryptionKey()
        } catch {
            throw Error.keyManagementFailed(error.localizedDescription)
        }
    }

    private static var isStorageEnabled: Bool {
        ProcessInfo.processInfo.environment["OVERHEAR_DISABLE_TRANSCRIPT_STORAGE"] != "1"
    }
    
    /// Save a transcript (encrypted)
    func save(_ transcript: StoredTranscript) async throws {
        guard persistenceEnabled else { throw Error.storageDisabled }
        let fileURL = storageDirectory.appendingPathComponent(Self.fileName(for: transcript))
        
        do {
            FileLogger.log(
                category: "TranscriptStore",
                message: "save() writing \(fileURL.lastPathComponent) summaryChars=\(transcript.summary?.summary.count ?? 0) highlights=\(transcript.summary?.highlights.count ?? 0) actions=\(transcript.summary?.actionItems.count ?? 0)"
            )
            let data = try encoder.encode(transcript)
            let encrypted = try Self.encryptData(data, using: encryptionKey)
            try encrypted.write(to: fileURL, options: [.atomic])
        } catch let Error.encryptionFailed(message) {
            throw Error.encryptionFailed(message)
        } catch {
            throw Error.encodingFailed(error.localizedDescription)
        }
    }
    
    /// Retrieve a transcript by ID (decrypted)
    func retrieve(id: String) async throws -> StoredTranscript {
        guard persistenceEnabled else { throw Error.storageDisabled }
        guard let fileURL = try fileURLForTranscript(id: id) else {
            throw Error.notFound
        }
        FileLogger.log(
            category: "TranscriptStore",
            message: "retrieve() reading \(fileURL.lastPathComponent)"
        )
        
        let data = try Data(contentsOf: fileURL)
        return try Self.decryptOrDecode(data: data, using: encryptionKey, decoder: decoder)
    }

    /// Update an existing transcript by applying a transform; persists the updated record.
    func update(id: String, transform: @Sendable (StoredTranscript) -> StoredTranscript) async throws {
        var transcript = try await retrieve(id: id)
        transcript = transform(transcript)
        try await save(transcript)
    }
    
    /// Get all stored transcripts (decrypted)
    func allTranscripts() async throws -> [StoredTranscript] {
        guard persistenceEnabled else { return [] }
        guard FileManager.default.fileExists(atPath: storageDirectory.path) else {
            return []
        }
        
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        
        var transcripts: [StoredTranscript] = []
        
        for fileURL in fileURLs {
            do {
                let data = try Data(contentsOf: fileURL)
                let transcript = try Self.decryptOrDecode(data: data, using: encryptionKey, decoder: decoder)
                transcripts.append(transcript)
            } catch {
                FileLogger.log(
                    category: "TranscriptStore",
                    message: "Skipped corrupt or unreadable transcript at \(fileURL.lastPathComponent): \(error.localizedDescription)"
                )
                continue
            }
        }
        
        return transcripts.sorted { $0.date > $1.date }
    }
    
    /// Search transcripts by text content, with optional pagination
    /// For large transcript collections, this uses streaming search to avoid loading all transcripts into memory
    func search(query: String, limit: Int = 50, offset: Int = 0) async throws -> [StoredTranscript] {
        guard persistenceEnabled else { return [] }
        guard FileManager.default.fileExists(atPath: storageDirectory.path) else {
            return []
        }
        
        let lowerQuery = query.lowercased()
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        
        var results: [StoredTranscript] = []
        var processedCount = 0
        var skippedCount = 0
        
        // Sort file URLs to ensure consistent ordering
        let sortedFileURLs = fileURLs.sorted { $0.path < $1.path }
        
        for fileURL in sortedFileURLs {
            // Early exit if we have enough results
            if results.count >= limit {
                break
            }
            
            do {
                let data = try Data(contentsOf: fileURL)
                let transcript = try Self.decryptOrDecode(data: data, using: encryptionKey, decoder: decoder)
                
                if transcript.title.lowercased().contains(lowerQuery) ||
                   transcript.transcript.lowercased().contains(lowerQuery) {
                    processedCount += 1
                    
                    // Handle offset by skipping results
                    if processedCount > offset {
                        results.append(transcript)
                    } else {
                        skippedCount += 1
                    }
                }
            } catch {
                // Skip files that can't be decoded
                continue
            }
        }
        
        // Sort results by date (most recent first)
        return results.sorted { $0.date > $1.date }
    }
    
    /// Decrypts data if possible; falls back to plaintext decoding for legacy files.
    private static func decryptOrDecode(data: Data, using key: SymmetricKey, decoder: JSONDecoder) throws -> StoredTranscript {
        // Try encrypted path first
        if let decrypted = try? decryptData(data, using: key),
           let transcript = try? decoder.decode(StoredTranscript.self, from: decrypted) {
            return transcript
        }
        
        // Fallback to plaintext legacy JSON
        if let transcript = try? decoder.decode(StoredTranscript.self, from: data) {
            return transcript
        }
        
        throw Error.decodingFailed("Unable to decode transcript data (encrypted or plaintext)")
    }
    
    /// Delete a transcript
    func delete(id: String) async throws {
        guard persistenceEnabled else { throw Error.storageDisabled }
        guard let fileURL = try fileURLForTranscript(id: id) else {
            throw Error.notFound
        }
        
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw Error.deletionFailed(error.localizedDescription)
        }
    }
    
    /// Get transcripts for a specific meeting
    func transcriptsForMeeting(_ meetingID: String) async throws -> [StoredTranscript] {
        return try await transcripts(forMeetingID: meetingID)
    }

    func transcripts(forMeetingID meetingID: String) async throws -> [StoredTranscript] {
        guard persistenceEnabled else { return [] }
        guard FileManager.default.fileExists(atPath: storageDirectory.path) else { return [] }

        let safeMeetingID = Self.fileSafeMeetingID(meetingID)
        let meetingPrefix = safeMeetingID + Self.meetingIDDelimiter

        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        let meetingFiles = fileURLs.filter { $0.lastPathComponent.hasPrefix(meetingPrefix) }
        if !meetingFiles.isEmpty {
            let transcripts = meetingFiles.compactMap { fileURL in
                do {
                    let data = try Data(contentsOf: fileURL)
                    return try Self.decryptOrDecode(data: data, using: encryptionKey, decoder: decoder)
                } catch {
                    return nil
                }
            }
            return transcripts.sorted { $0.date > $1.date }
        }

        // Legacy fallback: prior versions stored transcripts as `id.json`, requiring scanning to filter by meetingID.
        let transcripts = try await allTranscripts()
        return transcripts.filter { $0.meetingID == meetingID }
    }

    private static func fileName(for transcript: StoredTranscript) -> String {
        let safeMeetingID = fileSafeMeetingID(transcript.meetingID)
        return "\(safeMeetingID)\(meetingIDDelimiter)\(transcript.id).json"
    }

    private static func fileSafeMeetingID(_ meetingID: String) -> String {
        meetingID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? meetingID
    }

    private func fileURLForTranscript(id: String) throws -> URL? {
        let legacyURL = storageDirectory.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            return legacyURL
        }

        guard FileManager.default.fileExists(atPath: storageDirectory.path) else { return nil }

        let suffix = "\(Self.meetingIDDelimiter)\(id).json"
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter { $0.lastPathComponent.hasSuffix(suffix) }

        if fileURLs.count > 1 {
            FileLogger.log(
                category: "TranscriptStore",
                message: "Multiple transcripts share id=\(id); selecting most recently modified"
            )
        }

        return fileURLs
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
            .first
    }
    
    /// Determine if we should bypass the Keychain (explicit env override only).
    nonisolated private static var isKeychainBypassed: Bool {
        let env = ProcessInfo.processInfo.environment
        let truthy: Set<String> = ["1", "true", "TRUE", "True"]
        let bypass = env["OVERHEAR_INSECURE_NO_KEYCHAIN"] ?? ""
        return truthy.contains(bypass)
    }

    nonisolated private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    nonisolated private static var keychainBypassReason: String? {
        let env = ProcessInfo.processInfo.environment
        let truthy: Set<String> = ["1", "true", "TRUE", "True"]
        if let bypass = env["OVERHEAR_INSECURE_NO_KEYCHAIN"], truthy.contains(bypass) {
            return "OVERHEAR_INSECURE_NO_KEYCHAIN"
        }
        if isRunningTests {
            return "XCTestConfigurationFilePath"
        }
        return nil
    }
    
    // MARK: - Encryption

    private struct EphemeralKeyBox: @unchecked Sendable {
        let key: SymmetricKey
    }

    private enum KeyStorage {
        static let ephemeralKeyBox = EphemeralKeyBox(key: SymmetricKey(size: .bits256))
        nonisolated(unsafe) private static var didLogBypass = false
        private static let logLock = NSLock()

        static func shouldLogBypass() -> Bool {
            logLock.lock()
            defer { logLock.unlock() }
            if didLogBypass { return false }
            didLogBypass = true
            return true
        }
    }
    
    /// Return or create the encryption key for transcript persistence.
    /// In CI/debug bypass scenarios the Keychain is unavailable, so we use a process-scoped
    /// ephemeral key instead. In production this persists to the Keychain.
    nonisolated private static func getOrCreateEncryptionKey() throws -> SymmetricKey {
#if !DEBUG
        // Never allow bypass in release builds, even if tests/env are spoofed.
        if isKeychainBypassed || isRunningTests {
            FileLogger.log(
                category: "TranscriptStore",
                message: "CRITICAL: Keychain bypass attempted in release build"
            )
            fatalError("Keychain bypass is only allowed in debug builds")
        }
#endif

        // In CI/test environments, avoid Keychain dependencies by using a per-process in-memory key.
        if isKeychainBypassed || isRunningTests {
            let ephemeralKey = KeyStorage.ephemeralKeyBox.key
            let reasonSuffix = keychainBypassReason.map { ": \($0)" } ?? ""
            if KeyStorage.shouldLogBypass() {
                FileLogger.log(
                    category: "TranscriptStore",
                    message: "Using ephemeral in-memory encryption key (Keychain bypass active\(reasonSuffix))"
                )
            }
            return ephemeralKey
        }

        let keyTag = "com.overhear.app.transcripts.key"
        
        // Try to retrieve existing key from Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        // Key already exists in Keychain
        if status == errSecSuccess, let data = result as? Data {
            if data.count == 32 {
                return SymmetricKey(data: data)
            } else {
                FileLogger.log(category: "TranscriptStore", message: "Encryption key invalid size (\(data.count)); keeping old key for recovery and generating new one")
                // Keep old key for potential recovery; store under a legacy tag.
                let legacyTag = "\(keyTag).legacy.\(UUID().uuidString)"
                let addLegacy: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrAccount as String: legacyTag,
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                ]
                _ = SecItemAdd(addLegacy as CFDictionary, nil)
                // Fall through to create new key
            }
        }
        
        // Create new encryption key
        if status == errSecItemNotFound || status != errSecSuccess {
            let newKey = SymmetricKey(size: .bits256)
            let keyData = newKey.withUnsafeBytes { Data($0) }
            
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: keyTag,
                kSecValueData as String: keyData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                return newKey
            } else {
                // CI runners often have an inaccessible Keychain; fall back to ephemeral only for expected access-denied cases.
                if addStatus == errSecInteractionNotAllowed || addStatus == errSecNotAvailable || isRunningTests {
                    let reasonSuffix = keychainBypassReason.map { ": \($0)" } ?? ""
                    FileLogger.log(
                        category: "TranscriptStore",
                        message: "Keychain unavailable (status \(addStatus)); falling back to ephemeral key\(reasonSuffix)"
                    )
                    return KeyStorage.ephemeralKeyBox.key
                }

                throw Error.keyManagementFailed("Failed to store encryption key in Keychain: status \(addStatus)")
            }
        }
        
        throw Error.keyManagementFailed("Unexpected Keychain error: \(status)")
    }
    
    nonisolated private static func encryptData(_ data: Data, using key: SymmetricKey) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            guard let combined = sealedBox.combined else {
                throw Error.encryptionFailed("Failed to combine sealed box")
            }
            return combined
        } catch {
            throw Error.encryptionFailed(error.localizedDescription)
        }
    }
    
    nonisolated private static func decryptData(_ encryptedData: Data, using key: SymmetricKey) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw Error.decryptionFailed(error.localizedDescription)
        }
    }
}
