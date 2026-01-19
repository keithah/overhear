import SwiftUI

struct AISectionView: View {
    let summary: MeetingSummary?
    let liveTranscriptIsEmpty: Bool
    let llmState: LocalLLMPipeline.State
    let llmIsReady: Bool
    let isWarmingLLM: Bool
    let isRegenerating: Bool
    let llmStateDescription: String
    let warmLLM: () async -> Void
    let regenerateSummary: (PromptTemplate?) async -> Void
    let copySummary: () -> Void
    let exportSummary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            status
            if let summary {
                summaryView(summary)
            } else {
                Text("AI will summarize once the meeting ends.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("AI-enhanced bullets")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if summary != nil {
                Text("Ready")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.green)
            } else {
                Text("Generates after recording")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            MenuBarContentView.makeLLMStatusChip(for: llmState)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(llmStateDescription)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            if llmIsReady {
                readyRow
            } else {
                HStack(spacing: 8) {
                    Button {
                        Task { await warmLLM() }
                    } label: {
                        Text(isWarmingLLM ? "Warming…" : "Warm up LLM")
                    }
                    .disabled(isWarmingLLM)
                    .controlSize(.mini)
                    regenerateMenu
                    copyButtons
                }
            }
        }
    }

    private var readyRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("LLM ready")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.green)
            }
            regenerateMenu
            copyButtons
        }
    }

    private var regenerateMenu: some View {
        Menu {
            Button("Regenerate (default prompt)") {
                Task { await regenerateSummary(PromptTemplate.defaultTemplate) }
            }
            Divider()
            ForEach(PromptTemplate.allTemplates.filter { $0.id != PromptTemplate.defaultTemplate.id }, id: \.id) { template in
                Button("Regenerate with \(template.title)") {
                    Task { await regenerateSummary(template) }
                }
            }
        } label: {
            Image(systemName: "arrow.clockwise")
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .disabled(isRegenerating || liveTranscriptIsEmpty)
    }

    private var copyButtons: some View {
        HStack(spacing: 8) {
            Button {
                copySummary()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy AI bullets")
            Button {
                exportSummary()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Export summary/notes")
        }
    }

    private func summaryView(_ summary: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !summary.summary.isEmpty {
                Text(summary.summary)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !summary.highlights.isEmpty {
                Divider()
                Text("Highlights")
                    .font(.system(size: 11, weight: .semibold))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(summary.highlights, id: \.self) { highlight in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(Color.secondary.opacity(0.5))
                                .frame(width: 4, height: 4)
                                .padding(.top, 5)
                            Text(highlight)
                                .font(.system(size: 11))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            if !summary.actionItems.isEmpty {
                Divider()
                Text("Action items")
                    .font(.system(size: 11, weight: .semibold))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(summary.actionItems, id: \.self) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "checkmark.circle")
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.description)
                                    .font(.system(size: 11))
                                if let owner = item.owner, !owner.isEmpty {
                                    Text("Owner: \(owner)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                if let due = item.dueDate {
                                    Text("Due: \(Self.relativeDateFormatter.localizedString(for: due, relativeTo: Date()))")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
