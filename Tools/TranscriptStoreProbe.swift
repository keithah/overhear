import Foundation

// Import the app's transcript store implementation directly.
@main
struct TranscriptStoreProbe {
    static func main() async {
        do {
            // Include the TranscriptStore definitions directly
            // swiftc command should compile this file together with TranscriptStore.swift
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = try TranscriptStore(storageDirectory: tempDir)
            let transcript = StoredTranscript(
                id: UUID().uuidString,
                meetingID: "probe-meeting",
                title: "Probe",
                date: Date(),
                transcript: "Hello Probe",
                duration: 5,
                audioFilePath: nil
            )
            try await store.save(transcript)
            let loaded = try await store.retrieve(id: transcript.id)
            assert(loaded.transcript == transcript.transcript)
            print("✔︎ Encryption round-trip passed")
        } catch {
            print("Probe failed: \(error)")
            exit(1)
        }

        // Disable flag path
        setenv("OVERHEAR_DISABLE_TRANSCRIPT_STORAGE", "1", 1)
        do {
            _ = try TranscriptStore()
            print("Probe failed: storage disable flag did not throw")
            exit(1)
        } catch let error as TranscriptStore.Error {
            if case .storageDisabled = error {
                print("✔︎ Storage disable flag honored")
                exit(0)
            }
            print("Probe failed with unexpected TranscriptStore error: \(error)")
            exit(1)
        } catch {
            print("Probe failed with unexpected error: \(error)")
            exit(1)
        }
    }
}
