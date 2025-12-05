import Foundation
import CryptoKit
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
    private static let storageEnabled: Bool = {
        ProcessInfo.processInfo.environment["OVERHEAR_DISABLE_TRANSCRIPT_STORAGE"] != "1"
    }()
    
    init(storageDirectory: URL? = nil) throws {
        guard Self.storageEnabled else {
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
        
        // Ensure storage directory exists with proper error handling
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: self.storageDirectory.path)
            // Directory exists, verify it's actually a directory
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw Error.storageDirectoryNotFound
            }
        } catch CocoaError.fileNoSuchFile {
            // Directory doesn't exist, create it
            do {
                try FileManager.default.createDirectory(
                    at: self.storageDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                throw Error.storageDirectoryNotFound
            }
        } catch {
            // Other file system errors
            throw Error.storageDirectoryNotFound
        }
        
        // Initialize encryption key from Keychain
        do {
            self.encryptionKey = try Self.getOrCreateEncryptionKey()
        } catch {
            throw Error.keyManagementFailed(error.localizedDescription)
        }
    }
    
    /// Save a transcript (encrypted)
    func save(_ transcript: StoredTranscript) async throws {
        guard persistenceEnabled else { throw Error.storageDisabled }
        let fileURL = storageDirectory.appendingPathComponent("\(transcript.id).json")
        
        do {
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
        let fileURL = storageDirectory.appendingPathComponent("\(id).json")
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw Error.notFound
        }
        
        let data = try Data(contentsOf: fileURL)
        return try Self.decryptOrDecode(data: data, using: encryptionKey, decoder: decoder)
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
                // Skip files that can't be decoded
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
        let fileURL = storageDirectory.appendingPathComponent("\(id).json")
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
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
        let transcripts = try await allTranscripts()
        return transcripts.filter { $0.meetingID == meetingID }
    }
    
    // MARK: - Encryption
    
    nonisolated private static func getOrCreateEncryptionKey() throws -> SymmetricKey {
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
                // Corrupted key size - delete and recreate
                print("Warning: Encryption key has invalid size (\(data.count) bytes). Previously encrypted transcripts may become unrecoverable.")
                let deleteQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrAccount as String: keyTag
                ]
                SecItemDelete(deleteQuery as CFDictionary)
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
            guard addStatus == errSecSuccess else {
                throw Error.keyManagementFailed("Failed to store encryption key in Keychain: status \(addStatus)")
            }
            
            return newKey
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
