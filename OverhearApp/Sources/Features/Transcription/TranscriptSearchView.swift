import SwiftUI
import Combine
import AppKit
import Foundation

/// View for searching and browsing stored transcripts
struct TranscriptSearchView: View {
    @StateObject private var viewModel = TranscriptSearchViewModel()
    @State private var selectedTranscript: StoredTranscript?
    @State private var showingDetailView = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.gray)
                    TextField("Search transcripts...", text: $viewModel.searchQuery)
                        .textFieldStyle(.roundedBorder)
                    if !viewModel.searchQuery.isEmpty {
                        Button(action: { viewModel.searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.gray)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .border(Color(nsColor: .separatorColor), width: 1)
                
                if viewModel.isLoading {
                    VStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let errorMessage = viewModel.errorMessage {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)
                        Text("Error")
                            .font(.system(size: 14, weight: .semibold))
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                        Button("Retry") {
                            Task { await viewModel.loadTranscripts() }
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.transcripts.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "doc.text.image")
                            .font(.system(size: 48))
                            .foregroundStyle(.gray)
                        Text(viewModel.searchQuery.isEmpty ? "No transcripts yet" : "No results found")
                            .font(.system(size: 14, weight: .semibold))
                        Text(viewModel.searchQuery.isEmpty ? "Transcripts from meetings will appear here" : "Try different search terms")
                            .font(.system(size: 12))
                            .foregroundStyle(.gray)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(viewModel.transcripts) { transcript in
                        TranscriptRow(transcript: transcript)
                            .onTapGesture {
                                selectedTranscript = transcript
                                showingDetailView = true
                            }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Transcripts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { Task { await viewModel.refresh() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .navigationViewStyle(.automatic)
        .sheet(isPresented: $showingDetailView) {
            if let transcript = selectedTranscript {
                TranscriptDetailView(transcript: transcript)
            }
        }
        .onAppear {
            Task { await viewModel.loadTranscripts() }
        }
    }
}

/// Row view for a single transcript
struct TranscriptRow: View {
    let transcript: StoredTranscript
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(transcript.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(transcript.formattedDate)
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
            }
            Text(transcript.transcript.count > 100 ? String(transcript.transcript.prefix(100)) + "..." : transcript.transcript)
                .font(.system(size: 11))
                .lineLimit(2)
                .foregroundStyle(.gray)
        }
        .padding(.vertical, 8)
    }
}

/// Detail view for a single transcript
struct TranscriptDetailView: View {
    let transcript: StoredTranscript
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(transcript.title)
                        .font(.system(size: 16, weight: .bold))
                    Text(transcript.formattedDate)
                        .font(.system(size: 12))
                        .foregroundStyle(.gray)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.gray)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlColor))
            .border(Color(nsColor: .separatorColor), width: 1)
            
            // Transcript content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(transcript.transcript)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            
            // Footer with actions
            HStack(spacing: 12) {
                Button(action: copyTranscript) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                }
                
                Button(action: exportTranscript) {
                    Label("Export", systemImage: "arrow.up.doc")
                        .font(.system(size: 11, weight: .medium))
                }
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Text("Done")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .border(Color(nsColor: .separatorColor), width: 1)
        }
    }
    
    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.transcript, forType: .string)
    }
    
    private func exportTranscript() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        let fileName = transcript.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        savePanel.nameFieldStringValue = "\(fileName)-\(Int(transcript.date.timeIntervalSince1970)).txt"
        
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try transcript.transcript.write(to: url, atomically: true, encoding: String.Encoding.utf8)
            } catch {
                print("Failed to export transcript: \(error)")
            }
        }
    }
}

/// ViewModel for transcript search
@MainActor
final class TranscriptSearchViewModel: ObservableObject {
    @Published var searchQuery = ""
    @Published var transcripts: [StoredTranscript] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let store = TranscriptStore()
    private var searchTask: Task<Void, Never>?
    
    init() {
        $searchQuery
            .debounce(for: 0.3, scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.performSearch()
            }
            .store(in: &cancellables)
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    func loadTranscripts() async {
        isLoading = true
        errorMessage = nil
        do {
            let allTranscripts = try await store.allTranscripts()
            self.transcripts = allTranscripts
        } catch {
            self.errorMessage = "Failed to load transcripts: \(error.localizedDescription)"
            print("Failed to load transcripts: \(error)")
        }
        isLoading = false
    }
    
    func refresh() async {
        await loadTranscripts()
    }
    
    private func performSearch() {
        searchTask?.cancel()
        searchTask = Task {
            isLoading = true
            errorMessage = nil
            
            do {
                if searchQuery.isEmpty {
                    let allTranscripts = try await store.allTranscripts()
                    self.transcripts = allTranscripts
                } else {
                    let results = try await store.search(query: searchQuery)
                    self.transcripts = results
                }
            } catch {
                self.errorMessage = "Search failed: \(error.localizedDescription)"
                print("Search failed: \(error)")
                self.transcripts = []
            }
            
            isLoading = false
        }
    }
}

#Preview {
    TranscriptSearchView()
}
