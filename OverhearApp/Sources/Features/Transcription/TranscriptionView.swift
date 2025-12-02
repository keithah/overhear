import SwiftUI
import AppKit

/// View for displaying live transcription during a meeting
struct TranscriptionView: View {
    @ObservedObject var recordingManager: MeetingRecordingManager
    @State private var exportError: String?
    @State private var showExportError = false
    
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "text.bubble.fill")
                    .foregroundStyle(.blue)
                Text("Transcript")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                statusIndicator
            }
            .padding(.bottom, 4)
            
            // Transcript text area
            ScrollView {
                Text(recordingManager.transcript.isEmpty ? "Waiting for audio..." : recordingManager.transcript)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 100)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            
            // Action buttons
            HStack(spacing: 8) {
                Button(action: copyTranscript) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                }
                .disabled(recordingManager.transcript.isEmpty)
                
                Button(action: exportTranscript) {
                    Label("Export", systemImage: "arrow.up.doc")
                        .font(.system(size: 11, weight: .medium))
                }
                .disabled(recordingManager.transcript.isEmpty)
                
                Spacer()
                
                if case .failed(let error) = recordingManager.status {
                    Text("Error: \(error.localizedDescription)")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlColor))
        .cornerRadius(8)
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "Unknown error")
        }
    }
    
    @ViewBuilder
    private var statusIndicator: some View {
        switch recordingManager.status {
        case .idle:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.gray)
        case .capturing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Recording...")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.blue)
        case .transcribing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing...")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.orange)
        case .completed:
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .failed:
            Label("Error", systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        }
    }
    
    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recordingManager.transcript, forType: .string)
    }
    
    private func exportTranscript() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        let dateString = Self.iso8601Formatter.string(from: Date())
        savePanel.nameFieldStringValue = "transcript-\(dateString).txt"
        
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try recordingManager.transcript.write(to: url, atomically: true, encoding: String.Encoding.utf8)
            } catch {
                self.exportError = error.localizedDescription
                self.showExportError = true
            }
        }
    }
}
