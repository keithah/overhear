import Foundation
@preconcurrency import CryptoKit
import Security
import os

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

/// Thread-safe cache for search results to avoid re-decoding transcripts across queries.
actor TranscriptSearchCache {
    private let maxEntries: Int = 200
    private var cache: [URL: StoredTranscript] = [:]
    private var order: [URL] = []

    func get(_ url: URL) -> StoredTranscript? {
        if let value = cache[url] {
            // Move to back for LRU behavior.
            if order.last != url {
                order.removeAll(where: { $0 == url })
                order.append(url)
            }
            return value
        }
        return cache[url]
    }

    func set(_ url: URL, value: StoredTranscript) {
        cache[url] = value
        if order.last != url {
            order.removeAll(where: { $0 == url })
            order.append(url)
        }
        if order.count > maxEntries, let evict = order.first {
            order.removeFirst()
            cache.removeValue(forKey: evict)
        }
    }

    func clear() {
        cache.removeAll()
        order.removeAll()
    }

#if DEBUG
    func _testActiveCount() -> Int {
        cache.count
    }
#endif
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
    private static let logger = Logger(subsystem: "com.overhear.app", category: "TranscriptStore")
    private static let keychainBypassDecision: (enabled: Bool, reason: String?, requested: Bool, validContext: Bool) = evaluateBypass(environment: ProcessInfo.processInfo.environment)
    private let searchCache = TranscriptSearchCache()
    // Optional FTS index; disabled by default to avoid unexpected disk writes. Enable via OVERHEAR_ENABLE_FTS=1 or UserDefaults overhear.enableFTS.
    private let searchIndex: TranscriptSearchIndex?

    private static var shouldEnableFTS: Bool {
        let env = ProcessInfo.processInfo.environment["OVERHEAR_ENABLE_FTS"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if env == "1" || env?.lowercased() == "true" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "overhear.enableFTS")
    }

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
        KeyStorage.markEphemeralRiskFlag(false)
        
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
        
        #if canImport(SQLite3)
        if Self.shouldEnableFTS {
            self.searchIndex = try? TranscriptSearchIndex(baseDirectory: self.storageDirectory)
        } else {
            self.searchIndex = nil
        }
        #else
        self.searchIndex = nil
        #endif

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
        await searchCache.clear()
        let fileURL = storageDirectory.appendingPathComponent(Self.fileName(for: transcript))
        
        do {
            FileLogger.log(
                category: "TranscriptStore",
                message: "save() writing \(fileURL.lastPathComponent) summaryChars=\(transcript.summary?.summary.count ?? 0) highlights=\(transcript.summary?.highlights.count ?? 0) actions=\(transcript.summary?.actionItems.count ?? 0)"
            )
            let data = try encoder.encode(transcript)
            let encrypted = try Self.encryptData(data, using: encryptionKey)
            try await Task.detached(priority: .utility) {
                try encrypted.write(to: fileURL, options: [.atomic])
            }.value
#if canImport(SQLite3)
            try searchIndex?.index(transcript: transcript, fileURL: fileURL)
#endif
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
        let data = try await Task.detached(priority: .utility) {
            try Data(contentsOf: fileURL)
        }.value
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
            includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter { $0.pathExtension == "json" }
        
        var transcripts: [StoredTranscript] = []
        
        for fileURL in fileURLs {
            do {
                let data = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: fileURL)
                }.value
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
        var fileURLs: [URL] = []
        var offsetAlreadyApplied = false
        #if canImport(SQLite3)
        if let urls = try? searchIndex?.search(query: lowerQuery, limit: limit, offset: offset) {
            fileURLs = urls
            offsetAlreadyApplied = true
        }
        #endif
        if fileURLs.isEmpty {
            let all = try FileManager.default.contentsOfDirectory(
                at: storageDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
            // Sort newest-first so we can satisfy limit+offset quickly without scanning all files.
            fileURLs = all.sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
        }

        // Process in parallel with a small concurrency cap to improve throughput on large collections.
        let maxConcurrent = 4
        var results: [StoredTranscript] = []
        var queued = 0
        let currentKey = encryptionKey
        let decoder = decoder
        let cache = searchCache
        try await withThrowingTaskGroup(of: StoredTranscript?.self) { group in
            var iterator = fileURLs.makeIterator()

            func enqueueNext() {
                guard let url = iterator.next(), queued < offset + limit else { return }
                queued += 1
                group.addTask {
                    if let cached = await cache.get(url) {
                        if cached.title.lowercased().contains(lowerQuery) ||
                            cached.transcript.lowercased().contains(lowerQuery) {
                            return cached
                        }
                        return nil
                    }
                    do {
                        let data = try await Task.detached(priority: .utility) {
                            try Data(contentsOf: url)
                        }.value
                        let transcript = try Self.decryptOrDecode(data: data, using: currentKey, decoder: decoder)
                        await cache.set(url, value: transcript)
                        if transcript.title.lowercased().contains(lowerQuery) ||
                            transcript.transcript.lowercased().contains(lowerQuery) {
                            return transcript
                        }
                        return nil
                    } catch {
                        return nil
                    }
                }
            }

            for _ in 0..<maxConcurrent { enqueueNext() }

            while let result = try await group.next() {
                enqueueNext()
                if let transcript = result {
                    results.append(transcript)
                    if results.count >= offset + limit { group.cancelAll() }
                }
            }
        }

        let sortedResults = results.sorted { $0.date > $1.date }
        let effectiveOffset = offsetAlreadyApplied ? 0 : offset
        return Array(sortedResults.dropFirst(effectiveOffset).prefix(limit))
    }
    
    /// Decrypts data if possible; falls back to plaintext decoding for legacy files.
    private static func decryptOrDecode(data: Data, using key: SymmetricKey, decoder: JSONDecoder) throws -> StoredTranscript {
        // Try encrypted path first
        if let decrypted = try? decryptData(data, using: key),
           let transcript = try? decoder.decode(StoredTranscript.self, from: decrypted) {
            return transcript
        }
        FileLogger.log(
            category: "TranscriptStore",
            message: "Decrypting transcript failed; attempting plaintext fallback"
        )
        // Fallback to plaintext legacy JSON
        if let transcript = try? decoder.decode(StoredTranscript.self, from: data) {
            let count = KeyStorage.recordPlaintextFallback()
            FileLogger.log(
                category: "TranscriptStore",
                message: "Loaded plaintext transcript fallback (legacy/unencrypted data); count=\(count)"
            )
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
        await searchCache.clear()
        
        do {
            try FileManager.default.removeItem(at: fileURL)
#if canImport(SQLite3)
            try searchIndex?.delete(id: id)
#endif
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
        keychainBypassDecision.enabled
    }

    nonisolated private static var keychainBypassReason: String? {
        keychainBypassDecision.reason
    }

    nonisolated internal static func isKeychainBypassEnabled(environment: [String: String]) -> Bool {
        evaluateBypass(environment: environment).enabled
    }

    nonisolated internal static func keychainBypassReason(environment: [String: String]) -> String? {
        let decision = evaluateBypass(environment: environment)
        guard decision.enabled else { return nil }
        if decision.validContext {
            return decision.reason
        }
        return nil
    }

    private static func evaluateBypass(environment: [String: String]) -> (enabled: Bool, reason: String?, requested: Bool, validContext: Bool) {
        let truthy: Set<String> = ["1", "true", "TRUE", "True"]
        let allowBypass = truthy.contains(
            environment["OVERHEAR_ALLOW_INSECURE_BYPASS"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
        let requested = truthy.contains(
            environment["OVERHEAR_INSECURE_NO_KEYCHAIN"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
        let validContext = isCIEnvironment(environment) || isTestEnvironment(environment)
        #if !DEBUG
            return (false, "bypass not allowed in release", requested, validContext)
        #else
            guard allowBypass && requested else { return (false, nil, requested, validContext) }
            if !validContext {
                logger.critical("Keychain bypass requested outside CI/test; ignoring request")
                return (false, "invalid context", requested, validContext)
            }
            let reason: String? = {
                if isTestEnvironment(environment) { return "XCTestConfigurationFilePath" }
                if isCIEnvironment(environment) { return "CI/GitHubActions" }
                return "OVERHEAR_INSECURE_NO_KEYCHAIN"
            }()
            return (true, reason, requested, validContext)
        #endif
    }

    // Global lock protects process-scoped bypass logging flags that may be touched from many call sites.
    private static let bypassWarningLock = OSAllocatedUnfairLock(initialState: false)

    nonisolated private static func logInvalidBypassIfNeeded(environment: [String: String]) {
        guard environment["OVERHEAR_INSECURE_NO_KEYCHAIN"] != nil else { return }
        guard !isKeychainBypassEnabled(environment: environment) else { return }
        bypassWarningLock.withLock { didLogInvalidBypass in
            guard !didLogInvalidBypass else { return }
            didLogInvalidBypass = true
            FileLogger.log(
                category: "TranscriptStore",
                message: "Ignoring OVERHEAR_INSECURE_NO_KEYCHAIN outside trusted CI/test context; Keychain remains required"
            )
        }
    }

    nonisolated private static func isCIEnvironment(_ environment: [String: String]) -> Bool {
        (environment["CI"] == "true") && (environment["GITHUB_ACTIONS"] == "true") && environment["GITHUB_RUNNER_NAME"] != nil
    }

    nonisolated private static func isTestEnvironment(_ environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    // Testing helpers
    nonisolated internal static func logInvalidBypassIfNeededForTests(environment: [String: String]) {
        logInvalidBypassIfNeeded(environment: environment)
    }

    // CI/test telemetry hook; only active when a valid bypass is requested.
    nonisolated internal static func logBypassUsageIfNeeded(environment: [String: String]) {
        let decision = evaluateBypass(environment: environment)
        guard decision.enabled, decision.validContext else { return }
        FileLogger.log(
            category: "TranscriptStore",
            message: "Keychain bypass in CI/test: reason=\(decision.reason ?? "unknown")"
        )
    }

    // Document bypass expectations for CI/test usage.
    nonisolated internal static var bypassUsageHint: String {
        """
        Keychain bypass is only honored in DEBUG + CI/test contexts with BOTH OVERHEAR_ALLOW_INSECURE_BYPASS=1 and OVERHEAR_INSECURE_NO_KEYCHAIN=1 set.
        Release builds always reject bypass. CI/test transcripts use process-scoped ephemeral keys and are not encrypted at rest.
        """
    }

    nonisolated internal static func resetBypassLogStateForTests() {
        bypassWarningLock.withLock { $0 = false }
        KeyStorage.resetLogsForTests()
    }

    nonisolated internal static func didLogInvalidBypassForTests() -> Bool {
        bypassWarningLock.withLock { $0 }
    }

    nonisolated internal static func didLogEphemeralFallbackForTests() -> Bool {
        KeyStorage.didLogEphemeralFallbackForTests()
    }

    nonisolated internal static func markEphemeralFallbackLoggedForTests() -> Bool {
        KeyStorage.shouldLogEphemeralFallback()
    }
    
    // MARK: - Encryption

    private enum KeyStorage {
        private struct LogFlags {
            var didLogBypass = false
            var didLogEphemeralFallback = false
            var isUsingEphemeralKey = false
            var didCleanLegacyInsecureKey = false
            var didLogPlaintextFallback = false
            var plaintextFallbackCount = 0
        }
        private struct InsecureKeyBox { var key: SymmetricKey? }
        private struct EphemeralFallbackBox { var keyData: Data? }
        // Lightweight global locks to guard shared logging flags and insecure bypass key.
        private static let logLock = OSAllocatedUnfairLock(initialState: LogFlags())
        private static let insecureKeyLock = OSAllocatedUnfairLock(initialState: InsecureKeyBox(key: nil))
        private static let ephemeralFallbackLock = OSAllocatedUnfairLock(initialState: EphemeralFallbackBox(keyData: nil))

        static func shouldLogBypass() -> Bool {
            logLock.withLock { flags in
                if flags.didLogBypass { return false }
                flags.didLogBypass = true
                return true
            }
        }

        static func shouldLogEphemeralFallback() -> Bool {
            logLock.withLock { flags in
                if flags.didLogEphemeralFallback { return false }
                flags.didLogEphemeralFallback = true
                return true
            }
        }

        static func markEphemeralInUse() {
            logLock.withLock { flags in
                flags.isUsingEphemeralKey = true
            }
        }

        static func isEphemeralInUse() -> Bool {
            logLock.withLock { $0.isUsingEphemeralKey }
        }

        // Testing helpers
        static func resetLogsForTests() {
            logLock.withLock { flags in
                flags.didLogBypass = false
                flags.didLogEphemeralFallback = false
                flags.didLogPlaintextFallback = false
                flags.plaintextFallbackCount = 0
                flags.isUsingEphemeralKey = false
                flags.didCleanLegacyInsecureKey = false
            }
            insecureKeyLock.withLock { box in
                box.key = nil
            }
            ephemeralFallbackLock.withLock { box in
                box.keyData = nil
            }
        }

        static func didLogBypassForTests() -> Bool {
            logLock.withLock { $0.didLogBypass }
        }

        static func didLogEphemeralFallbackForTests() -> Bool {
            logLock.withLock { $0.didLogEphemeralFallback }
        }
        static func recordPlaintextFallback() -> Int {
            logLock.withLock { flags in
                flags.didLogPlaintextFallback = true
                flags.plaintextFallbackCount &+= 1
                return flags.plaintextFallbackCount
            }
        }

        /// Returns a process-scoped insecure key when bypassing secure storage (CI/tests).
        /// This key is in-memory only and intentionally not persisted.
        static func insecureBypassKey() throws -> SymmetricKey {
            guard isKeychainBypassed else {
                TranscriptStore.logger.critical("Attempted insecure key access without valid bypass")
                FileLogger.log(
                    category: "TranscriptStore",
                    message: "CRITICAL: Insecure key storage requested without Keychain bypass"
                )
                throw Error.keyManagementFailed("Keychain bypass required before using insecure key storage")
            }
            return insecureKeyLock.withLock { box in
                if let key = box.key { return key }
                let key = SymmetricKey(size: .bits256)
                box.key = key
                return key
            }
        }

        static func ephemeralFallbackKey() -> SymmetricKey {
            ephemeralFallbackLock.withLock { box in
                if let data = box.keyData {
                    return SymmetricKey(data: data)
                }
                let key = SymmetricKey(size: .bits256)
                box.keyData = key.withUnsafeBytes { Data($0) }
                return key
            }
        }

        static func markEphemeralRiskFlag(_ isActive: Bool) {
            let defaults = UserDefaults.standard
            if isActive {
                defaults.set(true, forKey: "overhear.ephemeralKeyWarning")
            } else {
                defaults.removeObject(forKey: "overhear.ephemeralKeyWarning")
            }
        }

        static func cleanupLegacyPersistedKeyIfNeeded() {
            logLock.withLock { flags in
                guard !flags.didCleanLegacyInsecureKey else { return }
                flags.didCleanLegacyInsecureKey = true
                let defaults = UserDefaults.standard
                let key = "overhear.insecureTranscriptKey"
                if defaults.object(forKey: key) != nil {
                    defaults.removeObject(forKey: key)
                    FileLogger.log(
                        category: "TranscriptStore",
                        message: "Removed legacy insecure persisted key after bypass disabled"
                    )
                }
            }
        }
    }
    
    /// Return or create the encryption key for transcript persistence.
    /// In CI/debug bypass scenarios the Keychain is unavailable, so we use a process-scoped
    /// ephemeral key instead. In production this persists to the Keychain.
    nonisolated private static func getOrCreateEncryptionKey() throws -> SymmetricKey {
        // Cache bypass decision at process start to avoid TOCTOU based on later env changes.
        let decision = keychainBypassDecision
        if decision.requested && !decision.validContext {
            throw Error.keyManagementFailed("Keychain bypass is only allowed in CI or test environments")
        }
#if !DEBUG
        if decision.requested || decision.enabled {
            throw Error.keyManagementFailed("Keychain bypass is not allowed in production builds")
        }
#endif
        let bypassEnabled = decision.enabled
        let bypassReason = decision.reason

        // In CI/test environments, avoid Keychain dependencies by using a per-process in-memory key.
        if bypassEnabled {
            let insecureKey = try KeyStorage.insecureBypassKey()
            let reasonSuffix = bypassReason.map { ": \($0)" } ?? ""
            if KeyStorage.shouldLogBypass() {
                FileLogger.log(
                    category: "TranscriptStore",
                    message: "Using insecure in-memory encryption key (Keychain bypass active\(reasonSuffix)); transcripts are NOT encrypted at rest and may be lost on restart"
                )
                logger.error("Using insecure in-memory encryption key (Keychain bypass active\(reasonSuffix)); transcripts are NOT encrypted at rest and may be lost on restart")
            }
            FileLogger.log(
                category: "TranscriptStore",
                message: "Ephemeral encryption key in use; transcripts may be unreadable after crash/restart"
            )
            KeyStorage.markEphemeralRiskFlag(true)
            return insecureKey
        }
        KeyStorage.markEphemeralRiskFlag(false)
        KeyStorage.cleanupLegacyPersistedKeyIfNeeded()

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
                SecItemDelete(query as CFDictionary)
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
            
            var addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                return newKey
            } else {
                if addStatus == errSecDuplicateItem {
                    var existing: AnyObject?
                    let status = SecItemCopyMatching(query as CFDictionary, &existing)
                    if status == errSecSuccess, let data = existing as? Data, data.count == 32 {
                        return SymmetricKey(data: data)
                    } else {
                        SecItemDelete(query as CFDictionary)
                        let retryStatus = SecItemAdd(addQuery as CFDictionary, nil)
                        if retryStatus == errSecSuccess {
                            return newKey
                        }
                        addStatus = retryStatus
                    }
                }
                if addStatus == errSecInteractionNotAllowed || addStatus == errSecNotAvailable || addStatus == errSecAuthFailed || addStatus == errSecDuplicateItem {
#if DEBUG
                    let env = ProcessInfo.processInfo.environment
                    let runningTests = isTestEnvironment(env)
                    let allowEphemeralFallback = bypassEnabled || runningTests
                    guard allowEphemeralFallback else {
                        throw Error.keyManagementFailed("Keychain unavailable (status \(addStatus)); set OVERHEAR_INSECURE_NO_KEYCHAIN=1 when running in CI/test without Keychain access")
                    }
                    if KeyStorage.shouldLogEphemeralFallback() {
                        let reasonSuffix: String
                        if bypassEnabled {
                            reasonSuffix = bypassReason.map { ": \($0)" } ?? ""
                        } else if runningTests {
                            reasonSuffix = ": XCTest"
                        } else {
                            reasonSuffix = ""
                        }
                        FileLogger.log(
                            category: "TranscriptStore",
                            message: "Keychain unavailable (status \(addStatus)); falling back to ephemeral key\(reasonSuffix). Transcripts may be unreadable after restart"
                        )
                    }
                    KeyStorage.markEphemeralInUse()
                    logger.fault("Using ephemeral transcript key due to Keychain failure (status \(addStatus, privacy: .public)); data will be unreadable after restart")
                    return KeyStorage.ephemeralFallbackKey()
#else
                    throw Error.keyManagementFailed("Keychain unavailable (status \(addStatus)) and bypass is not permitted in production")
#endif
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
            FileLogger.log(
                category: "TranscriptStore",
                message: "Decryption failed; attempting plaintext decode as fallback"
            )
            throw Error.decryptionFailed(error.localizedDescription)
        }
    }
}
