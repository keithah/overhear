import Foundation

/// Represents a stored transcript with metadata
struct StoredTranscript: Codable, Identifiable {
    let id: String
    let meetingID: String
    let title: String
    let date: Date
    let transcript: String
    let duration: TimeInterval
    let audioFilePath: String?
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Manages storage and retrieval of transcripts
actor TranscriptStore {
    enum Error: LocalizedError {
        case storageDirectoryNotFound
        case encodingFailed(String)
        case decodingFailed(String)
        case notFound
        case deletionFailed(String)
        
        var errorDescription: String? {
            switch self {
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
            }
        }
    }
    
    private let storageDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    init(storageDirectory: URL? = nil) {
        if let provided = storageDirectory {
            self.storageDirectory = provided
        } else {
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                fatalError("Application support directory not found")
            }
            self.storageDirectory = appSupport.appendingPathComponent("com.overhear.app/Transcripts")
        }
        
        do {
            try FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
        } catch {
            print("Warning: Failed to create transcript storage directory: \(error)")
        }
    }
    
    /// Save a transcript
    func save(_ transcript: StoredTranscript) async throws {
        let fileURL = storageDirectory.appendingPathComponent("\(transcript.id).json")
        
        do {
            let data = try encoder.encode(transcript)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw Error.encodingFailed(error.localizedDescription)
        }
    }
    
    /// Retrieve a transcript by ID
    func retrieve(id: String) async throws -> StoredTranscript {
        let fileURL = storageDirectory.appendingPathComponent("\(id).json")
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw Error.notFound
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let transcript = try decoder.decode(StoredTranscript.self, from: data)
            return transcript
        } catch {
            throw Error.decodingFailed(error.localizedDescription)
        }
    }
    
    /// Get all stored transcripts
    func allTranscripts() async throws -> [StoredTranscript] {
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
                let transcript = try decoder.decode(StoredTranscript.self, from: data)
                transcripts.append(transcript)
            } catch {
                // Skip files that can't be decoded
                continue
            }
        }
        
        return transcripts.sorted { $0.date > $1.date }
    }
    
    /// Search transcripts by text content, with optional pagination
    func search(query: String, limit: Int = 50, offset: Int = 0) async throws -> [StoredTranscript] {
        let transcripts = try await allTranscripts()
        let lowerQuery = query.lowercased()
        
        let filtered = transcripts.filter { transcript in
            transcript.title.lowercased().contains(lowerQuery) ||
            transcript.transcript.lowercased().contains(lowerQuery)
        }
        
        let start = min(offset, filtered.count)
        let end = min(start + limit, filtered.count)
        
        if start >= end {
            return []
        }
        
        return Array(filtered[start..<end])
    }
    
    /// Delete a transcript
    func delete(id: String) async throws {
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
}
