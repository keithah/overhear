import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

extension NSNotification.Name {
    static let scrollToToday = NSNotification.Name("ScrollToToday")
    static let closeMenuPopover = NSNotification.Name("CloseMenuPopover")
}

struct MenuBarContentView: View {
     @ObservedObject var viewModel: MeetingListViewModel
     @ObservedObject var preferences: PreferencesService
     @ObservedObject var recordingCoordinator: MeetingRecordingCoordinator
    @ObservedObject var autoRecordingCoordinator: AutoRecordingCoordinator
    var openPreferences: () -> Void
    var onToggleRecording: () -> Void
    @State private var didAutoShowLiveNotes = false
    @State private var groupedCacheKey: Int = 0
    @State private var groupedCache: [(date: Date, meetings: [Meeting])] = []

     var body: some View {
        VStack(spacing: 0) {
            if autoRecordingCoordinator.isRecording, let title = autoRecordingCoordinator.currentRecordingTitle() {
                RecordingStateIndicator(title: title) {
                    Task { @MainActor in
                        await autoRecordingCoordinator.stopRecording()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            if recordingCoordinator.isRecording {
                RecordingBannerView(
                    recordingCoordinator: recordingCoordinator,
                    openLiveNotes: {
                        LiveNotesWindowController.shared.show(with: recordingCoordinator)
                    },
                    stopRecording: {
                        Task { await recordingCoordinator.stopRecording() }
                    },
                )
            }
            // Meetings list
            ScrollViewReader { proxy in
             ScrollView(.vertical) {
                     VStack(alignment: .leading, spacing: 0) {
if viewModel.isLoading {
                              HStack { 
                                  Spacer()
                                  VStack(spacing: 8) {
                                      ProgressView()
                                      Text("Loading meetings...").font(.system(size: 11))
                                  }
                                  Spacer() 
                              }
                              .frame(height: 32)
                          } else if allMeetings.isEmpty {
                             Text("No meetings")
                                 .font(.system(size: 11))
                                 .foregroundColor(.secondary)
                                 .frame(maxWidth: .infinity, alignment: .center)
                                 .frame(height: 32)
                         } else {
                             ForEach(groupedMeetings, id: \.date) { group in
                                 // Date header
                                 Text(formattedDate(group.date))
                                     .font(.system(size: 11, weight: .semibold))
                                     .foregroundColor(isDateInPast(group.date) ? .gray : .secondary)
                                     .opacity(isDateInPast(group.date) ? 0.6 : 1.0)
                                     .padding(.top, 4)
                                     .padding(.horizontal, 10)
                                     .padding(.bottom, 4)
                                     .id(dateIdentifier(group.date))  // Anchor for scroll
                                     .frame(maxWidth: .infinity, alignment: .leading)
                                 
                                 // Meetings for this date
                                 ForEach(group.meetings) { meeting in
                                     if preferences.viewMode == .minimalist {
                                        MinimalistMeetingRowView(
                                            meeting: meeting,
                                            use24HourClock: preferences.use24HourClock,
                                            recorded: viewModel.isRecorded(meeting),
                                            manualRecordingStatus: viewModel.manualRecordingStatus(for: meeting),
                                            onJoin: { meeting in
                                                Task { await viewModel.joinAndRecord(meeting: meeting) }
                                            },
                                            onShowRecordings: viewModel.showRecordings
                                        )
                                    } else {
                                        MeetingRowView(
                                            meeting: meeting,
                                            use24HourClock: preferences.use24HourClock,
                                            recorded: viewModel.isRecorded(meeting),
                                            manualRecordingStatus: viewModel.manualRecordingStatus(for: meeting),
                                            onJoin: { meeting in
                                                Task { await viewModel.joinAndRecord(meeting: meeting) }
                                            },
                                            onShowRecordings: viewModel.showRecordings
                                        )
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                    }
                                }
                            }
                        }
                    }
                     .padding(.vertical, 4)
                  }
.onAppear {
                       // Scroll to today (or nearest upcoming/past) when view appears
                       withAnimation {
                           if let target = scrollTargetDate() {
                               proxy.scrollTo(dateIdentifier(target), anchor: .top)
                           }
                       }
                   }
                   .onReceive(NotificationCenter.default.publisher(for: .scrollToToday)) { _ in
                       DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                           if let target = scrollTargetDate() {
                               withAnimation {
                                   proxy.scrollTo(dateIdentifier(target), anchor: .top)
                               }
                           }
                       }
                   }
              }
              .scrollIndicators(.hidden)
              .scrollDismissesKeyboard(.interactively)
             
             Divider()
            
            // Footer
             HStack(spacing: 10) {
                 VStack(alignment: .leading, spacing: 3) {
                     HStack(spacing: 6) {
                         Button(action: scrollToToday) {
                             Text("Today")
                                 .font(.system(size: 11))
                         }
                         Button(action: onToggleRecording) {
                             Label(
                                 recordingCoordinator.isRecording ? "Stop" : "Record",
                                 systemImage: recordingCoordinator.isRecording ? "stop.fill" : "record.circle"
                             )
                             .font(.system(size: 11, weight: .medium))
                         }
                         .buttonStyle(.borderless)
                         .controlSize(.small)
                     }
                     if recordingCoordinator.isRecording, let meeting = recordingCoordinator.activeMeeting {
                         Text("Recording \(meeting.title)")
                             .font(.system(size: 10))
                             .foregroundColor(.green)
                             .lineLimit(1)
                             .truncationMode(.tail)
                     }
                 }
                 
                 Spacer()
                 
                 // Gear icon menu on right
                 Menu {
                     Button(action: openPreferences) {
                         Text("Preferences…")
                     }
                     .keyboardShortcut("p")
                     
                     Button(action: { NSApp.terminate(nil) }) {
                         Text("Quit")
                     }
                     .keyboardShortcut("q")
                 } label: {
                     Image(systemName: "gear")
                         .font(.system(size: 12))
                         .foregroundColor(.secondary)
                 }
                 .menuStyle(.borderlessButton)
             }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: preferences.viewMode == .minimalist ? 360 : 360, height: calculateHeight())
        .onChange(of: recordingCoordinator.isRecording) { _, newValue in
            if newValue && preferences.autoShowLiveNotes && !didAutoShowLiveNotes {
                LiveNotesWindowController.shared.show(with: recordingCoordinator)
                didAutoShowLiveNotes = true
            }
            if !newValue {
                didAutoShowLiveNotes = false
            }
        }
    }
    
    private var allMeetings: [Meeting] {
        (viewModel.pastSections + viewModel.upcomingSections)
            .flatMap { $0.meetings }
    }
    
    private var groupedMeetings: [(date: Date, meetings: [Meeting])] {
        let key = meetingsHash(allMeetings)
        if key != groupedCacheKey {
            groupedCacheKey = key
            groupedCache = computeGroupedMeetings(allMeetings)
        }
        return groupedCache
    }
    
    private var todayDate: Date {
        Calendar.current.startOfDay(for: Date())
    }
    
    private func isDateInPast(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return date < today
    }
    
private let dateIdentifierFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func computeGroupedMeetings(_ meetings: [Meeting]) -> [(date: Date, meetings: [Meeting])] {
        let grouped = Dictionary(grouping: meetings) { meeting -> Date in
            Calendar.current.startOfDay(for: meeting.startDate)
        }
        let sorted = grouped.sorted { $0.key < $1.key }
        let mapped = sorted.map { (date: $0.key, meetings: $0.value.sorted { $0.startDate < $1.startDate }) }

        let today = todayDate
        let past = mapped.filter { $0.date < today }
        let todayAndFuture = mapped.filter { $0.date >= today }
        return past + todayAndFuture
    }

    private func meetingsHash(_ meetings: [Meeting]) -> Int {
        var hasher = Hasher()
        hasher.combine(meetings.count)
        for meeting in meetings {
            hasher.combine(meeting.id)
            hasher.combine(meeting.startDate.timeIntervalSince1970)
        }
        return hasher.finalize()
    }
    
    private let formattedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter
    }()
    
    private func dateIdentifier(_ date: Date) -> String {
        return dateIdentifierFormatter.string(from: date)
    }

    private func formattedDate(_ date: Date) -> String {
        return formattedDateFormatter.string(from: date)
    }

    /// Returns today if present; otherwise the next upcoming date; otherwise the last available date.
    private func scrollTargetDate() -> Date? {
        let today = todayDate
        if let exact = groupedMeetings.first(where: { Calendar.current.isDate($0.date, inSameDayAs: today) }) {
            return exact.date
        }
        if let upcoming = groupedMeetings.first(where: { $0.date > today }) {
            return upcoming.date
        }
        return groupedMeetings.last?.date
    }
    
    private func scrollToToday() {
        // Scroll to today's position
        NotificationCenter.default.post(name: .scrollToToday, object: nil)
    }
    
    private func calculateHeight() -> CGFloat {
        if allMeetings.isEmpty {
            return 150
        }
        
        let daysToShow = preferences.menubarDaysToShow
        let dayGroups = groupedMeetings.prefix(daysToShow)
        
        var totalHeight: CGFloat = 0
        
        if preferences.viewMode == .minimalist {
            // Minimalist: 22pt per event + 20pt header per day
            for group in dayGroups {
                totalHeight += 20  // Date header with padding
                totalHeight += CGFloat(group.meetings.count) * 22  // Events (tight spacing)
            }
            totalHeight += 12  // Padding between sections
        } else {
            // Normal mode: more generous spacing
            // Header: 18pt + 4pt padding = 22pt per day
            // Event: 32pt + padding = 40pt each
            for group in dayGroups {
                totalHeight += 22  // Date header with padding
                totalHeight += CGFloat(group.meetings.count) * 40  // Events with padding
            }
            totalHeight += 16  // Padding between sections
        }
        
        // Add footer
        totalHeight += 50
        
        // Add vertical padding
        totalHeight += 8
        
        // Minimum height, maximum around 700 to accommodate most scenarios
        return min(max(totalHeight, 150), 700)
     }
  }

// Note: SwiftUI's ScrollView on macOS has natural deceleration.
// The scroll behavior will naturally slow down as you scroll up into the past.
// To further customize scroll physics on macOS would require NSScrollView wrapper,
// which is beyond SwiftUI's simple API.
struct LiveNotesView: View {
    @ObservedObject var coordinator: MeetingRecordingCoordinator
    @State private var searchText: String = ""
    @State private var showTranscript = true
    @State private var showNotes = true
    @State private var showAI = true
    @State private var isRegenerating = false
    @State private var notesPrefilled = false
    @State private var llmStateDescription: String = "Checking…"
    @State private var isWarmingLLM = false
    @State private var warmupTask: Task<Void, Never>?
    @State private var llmStatePollTask: Task<Void, Never>?
    @State private var llmIsReady = false
    @State private var lastLoggedLLMState: String?
    var onHide: () -> Void

    private var statusText: String {
        coordinator.isRecording ? "Recording…" : "Stopped"
    }

    private var statusColor: Color {
        coordinator.isRecording ? .green : .secondary
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            consentNotice
            if showTranscript { transcriptSection }
            if showNotes { notesSection }
            if showAI { aiSection }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.25), radius: 12, x: 0, y: 10)
        )
        .frame(minWidth: 460, minHeight: 500)
        .onAppear {
            Task { await prefillNotesIfNeeded() }
            Task { await refreshLLMState() }
            Task { await warmLLM() }
            startLLMStatePolling()
        }
        .onDisappear {
            llmStatePollTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: LocalLLMPipeline.stateChangedNotification)) { _ in
            Task { await refreshLLMState() }
            if llmIsReady {
                llmStatePollTask?.cancel()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: "mic.fill")
                    .foregroundColor(.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("New Note")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(coordinator.activeMeeting?.title ?? "Manual Recording")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer()
            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(statusColor.opacity(0.15)))
                .foregroundColor(statusColor)
            Button {
                Task { await coordinator.stopRecording() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                        .foregroundColor(.white)
                    Text("Stop")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.red))
            }
            .buttonStyle(.plain)
            .help("Stop recording")
            Button(action: onHide) {
                Image(systemName: "minus.rectangle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide window")
            Menu {
                if coordinator.isRecording {
                    Button("Stop recording") {
                        Task { await coordinator.stopRecording() }
                    }
                }
                Button("Open Sound settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Troubleshoot transcription issues") {
                    if let url = URL(string: "https://help.granola.ai/article/transcription") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
                Button(showTranscript ? "Hide transcript" : "Show transcript") {
                    showTranscript.toggle()
                }
                Button(showNotes ? "Hide notes" : "Show notes") {
                    showNotes.toggle()
                }
                Button(showAI ? "Hide AI bullets" : "Show AI bullets") {
                    showAI.toggle()
                }
            } label: {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var consentNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .foregroundColor(.secondary)
            Text("Always get consent when transcribing others.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Live transcript")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Find in transcript…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 180)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            }
            LiveTranscriptList(segments: coordinator.liveSegments, searchText: searchText)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notes")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    copyNotes()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy notes")
                Button {
                    prependBullet()
                } label: {
                    Image(systemName: "list.bullet")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Insert bullet")
            }
            ZStack(alignment: .topLeading) {
                if coordinator.liveNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Write notes…")
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                }
                TextEditor(text: $coordinator.liveNotes)
                    .font(.system(size: 13))
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
                    .frame(minHeight: 120)
                    .onChange(of: coordinator.liveNotes) { _, newValue in
                        // Manual notes persistence best-effort
                        Task { await coordinator.saveNotes(newValue) }
                    }
            }
        }
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI-enhanced bullets")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if coordinator.summary != nil {
                    Text("Ready")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.green)
                } else {
                Text("Generates after recording")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Text(llmStateDescription)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                if llmIsReady {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("LLM ready")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.green)
                    }
                } else {
                    Button {
                        Task { await warmLLM() }
                    } label: {
                        Text(isWarmingLLM ? "Warming…" : "Warm up LLM")
                    }
                    .disabled(isWarmingLLM)
                    .controlSize(.mini)
                }
                Menu {
                    Button("Regenerate (default prompt)") {
                        Task { await regenerateSummary(template: PromptTemplate.defaultTemplate) }
                    }
                    Divider()
                    ForEach(PromptTemplate.allTemplates, id: \.id) { template in
                        Button("Regenerate with \(template.title)") {
                            Task { await regenerateSummary(template: template) }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .disabled(isRegenerating || coordinator.liveTranscript.isEmpty)
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
            if let summary = coordinator.summary {
                VStack(alignment: .leading, spacing: 10) {
                    if !summary.summary.isEmpty {
                        Text(summary.summary)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !summary.highlights.isEmpty {
                        Divider()
                        Text("Highlights")
                            .font(.system(size: 12, weight: .semibold))
                        ForEach(summary.highlights, id: \.self) { highlight in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundColor(.secondary)
                                    .padding(.top, 4)
                                Text(highlight)
                                    .font(.system(size: 12))
                            }
                        }
                    }
                    if !summary.actionItems.isEmpty {
                        Divider()
                        Text("Action items")
                            .font(.system(size: 12, weight: .semibold))
                        ForEach(summary.actionItems, id: \.self) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "checkmark.circle")
                                    .foregroundColor(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.description)
                                        .font(.system(size: 12))
                                    if let owner = item.owner, !owner.isEmpty {
                                        Text("Owner: \(owner)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            } else {
                Text("AI-enhanced bullets will appear here once the note finishes processing.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }

    private func prependBullet() {
        if coordinator.liveNotes.isEmpty {
            coordinator.liveNotes = "- "
        } else if !coordinator.liveNotes.hasSuffix("\n") {
            coordinator.liveNotes += "\n- "
        } else {
            coordinator.liveNotes += "- "
        }
    }

    private func copyNotes() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(coordinator.liveNotes, forType: .string)
    }

    private func copySummary() {
        guard let summary = coordinator.summary else { return }
        let bullets = (summary.summary.isEmpty ? [] : [summary.summary])
            + summary.highlights
            + summary.actionItems.map { "Action: \($0.description)\( ($0.owner?.isEmpty == false) ? " [\($0.owner!)]" : "")" }
        let text = bullets.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func regenerateSummary(template: PromptTemplate? = nil) async {
        guard !isRegenerating else { return }
        isRegenerating = true
        await refreshLLMState()
        await coordinator.regenerateSummary(template: template)
        isRegenerating = false
    }

    private func prefillNotesIfNeeded() async {
        let shouldPrefill = await MainActor.run { () -> Bool in
            guard !notesPrefilled else { return false }
            guard coordinator.liveNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                notesPrefilled = true
                return false
            }
            return true
        }
        guard shouldPrefill else { return }
        guard let transcriptID = coordinator.transcriptID else {
            await MainActor.run { notesPrefilled = true }
            return
        }
        do {
            let store = try TranscriptStore()
            let stored = try await store.retrieve(id: transcriptID)
            if let notes = stored.notes, !notes.isEmpty {
                await MainActor.run {
                    coordinator.liveNotes = notes
                }
            }
        } catch {
            // best-effort; ignore errors
        }
        await MainActor.run {
            notesPrefilled = true
        }
    }

    private func refreshLLMState() async {
        let state = await LocalLLMPipeline.shared.currentState()
        await MainActor.run {
            switch state {
            case .unavailable(let reason):
                llmStateDescription = "LLM unavailable (\(reason))"
                llmIsReady = false
            case .idle:
                llmStateDescription = "LLM idle"
                llmIsReady = false
            case .downloading(let progress):
                let pct = Int((progress * 100).rounded())
                llmStateDescription = "LLM downloading… \(pct)%"
                llmIsReady = false
            case .warming:
                llmStateDescription = "LLM warming…"
                llmIsReady = false
            case .ready(let modelID):
                if let modelID {
                    llmStateDescription = "LLM ready (\(modelID))"
                } else {
                    llmStateDescription = "LLM ready"
                }
                llmIsReady = true
            }
            if llmIsReady {
                // Ready is the steady-state; avoid noisy logs.
                lastLoggedLLMState = llmStateDescription
                return
            }
            lastLoggedLLMState = llmStateDescription
        }
    }

    private func warmLLM() async {
        if let warmupTask {
            await warmupTask.value
            return
        }
        isWarmingLLM = true
        let task = Task {
            await LocalLLMPipeline.shared.warmup()
        }
        warmupTask = task
        await task.value
        warmupTask = nil
        await refreshLLMState()
        if llmIsReady {
            llmStatePollTask?.cancel()
        } else {
            startLLMStatePolling()
        }
        isWarmingLLM = false
    }

    private func startLLMStatePolling() {
        llmStatePollTask?.cancel()
        guard !llmIsReady else { return }
        llmStatePollTask = Task { @MainActor in
            var attempts = 0
            defer { llmStatePollTask = nil }
            while !Task.isCancelled && !llmIsReady && attempts < 120 {
                attempts += 1
                await refreshLLMState()
                if llmIsReady { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func exportSummary() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NewNote.md"
        panel.allowedContentTypes = [.plainText, .text, UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task.detached(priority: .utility) {
                let (title, summary, liveNotes) = await MainActor.run { () -> (String, MeetingSummary?, String) in
                    let title = coordinator.activeMeeting?.title ?? "New Note"
                    return (title, coordinator.summary, coordinator.liveNotes)
                }
                var lines: [String] = ["# \(title)"]
                if let summary {
                    if !summary.summary.isEmpty {
                        lines.append("\n## Summary\n\(summary.summary)")
                    }
                    if !summary.highlights.isEmpty {
                        lines.append("\n## Highlights")
                        summary.highlights.forEach { lines.append("- \($0)") }
                    }
                    if !summary.actionItems.isEmpty {
                        lines.append("\n## Action Items")
                        summary.actionItems.forEach { item in
                            let owner = (item.owner?.isEmpty == false) ? " [\(item.owner!)]" : ""
                            lines.append("- \(item.description)\(owner)")
                        }
                    }
                }
                if !liveNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("\n## Notes")
                    lines.append(liveNotes)
                }
                let text = lines.joined(separator: "\n")
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    FileLogger.log(category: "LiveNotesView", message: "Failed to export summary: \(error.localizedDescription)")
                }
            }
        }
    }
}

struct LiveNotesManagerView: View {
    @ObservedObject var manager: MeetingRecordingManager
    @State private var searchText: String = ""
    @State private var showTranscript = true
    @State private var showNotes = true
    @State private var showAI = true
    @State private var isRegenerating = false
    @State private var liveNotes: String = ""
    @State private var llmStateDescription: String = "Checking…"
    @State private var isWarmingLLM = false
    @State private var warmupTask: Task<Void, Never>?
    var onHide: () -> Void

    private var isActiveRecording: Bool {
        switch manager.status {
        case .capturing, .transcribing:
            return true
        default:
            return false
        }
    }

    private var statusText: String {
        switch manager.status {
        case .capturing, .transcribing: return "Recording…"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .idle: return "Idle"
        }
    }

    private var statusColor: Color {
        switch manager.status {
        case .capturing, .transcribing: return .green
        case .completed: return .blue
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            consentNotice
            if showTranscript { transcriptSection }
            if showNotes { notesSection }
            if showAI { aiSection }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.25), radius: 12, x: 0, y: 10)
        )
        .frame(minWidth: 460, minHeight: 500)
        .onAppear {
            Task { await refreshLLMState() }
            Task { await warmLLM() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: "mic.fill")
                    .foregroundColor(.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("New Note")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(manager.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer()
            Text(statusText)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(statusColor.opacity(0.15)))
                .foregroundColor(statusColor)
            Button {
                Task { await manager.stopRecording() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                        .foregroundColor(.white)
                    Text("Stop")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.red))
            }
            .buttonStyle(.plain)
            .help("Stop recording")
            Button(action: onHide) {
                Image(systemName: "minus.rectangle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide window")
            Menu {
                if isActiveRecording {
                    Button("Stop recording") {
                        Task { await manager.stopRecording() }
                    }
                }
                Button("Open Sound settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Troubleshoot transcription issues") {
                    if let url = URL(string: "https://help.granola.ai/article/transcription") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
                Button(showTranscript ? "Hide transcript" : "Show transcript") {
                    showTranscript.toggle()
                }
                Button(showNotes ? "Hide notes" : "Show notes") {
                    showNotes.toggle()
                }
                Button(showAI ? "Hide AI bullets" : "Show AI bullets") {
                    showAI.toggle()
                }
            } label: {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var consentNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .foregroundColor(.secondary)
            Text("Always get consent when transcribing others.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Live transcript")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Find in transcript…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 180)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            }
            LiveTranscriptList(segments: manager.liveSegments, searchText: searchText)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notes")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    copyNotes()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy notes")
                Button {
                    prependBullet()
                } label: {
                    Image(systemName: "list.bullet")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Insert bullet")
            }
            ZStack(alignment: .topLeading) {
                if liveNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Write notes…")
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                }
                TextEditor(text: $liveNotes)
                    .font(.system(size: 13))
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
                    .frame(minHeight: 120)
                    .onChange(of: liveNotes) { _, newValue in
                        Task { await manager.saveNotes(newValue) }
                    }
            }
        }
        .onAppear {
            Task {
                if liveNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await loadStoredNotes()
                }
            }
        }
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI-enhanced bullets")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if manager.summary != nil {
                    Text("Ready")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.green)
                } else {
                    Text("Generates after recording")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Text(llmStateDescription)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Menu {
                    Button("Regenerate (default prompt)") {
                        Task { await regenerateSummary(template: PromptTemplate.defaultTemplate) }
                    }
                    Divider()
                    ForEach(PromptTemplate.allTemplates, id: \.id) { template in
                        Button("Regenerate with \(template.title)") {
                            Task { await regenerateSummary(template: template) }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .disabled(isRegenerating || manager.liveTranscript.isEmpty)
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
            if let summary = manager.summary {
                VStack(alignment: .leading, spacing: 10) {
                    if !summary.summary.isEmpty {
                        Text(summary.summary)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !summary.highlights.isEmpty {
                        Divider()
                        Text("Highlights")
                            .font(.system(size: 12, weight: .semibold))
                        ForEach(summary.highlights, id: \.self) { highlight in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundColor(.secondary)
                                    .padding(.top, 4)
                                Text(highlight)
                                    .font(.system(size: 12))
                            }
                        }
                    }
                    if !summary.actionItems.isEmpty {
                        Divider()
                        Text("Action items")
                            .font(.system(size: 12, weight: .semibold))
                        ForEach(summary.actionItems, id: \.self) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "checkmark.circle")
                                    .foregroundColor(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.description)
                                        .font(.system(size: 12))
                                    if let owner = item.owner, !owner.isEmpty {
                                        Text("Owner: \(owner)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            } else {
                Text("AI-enhanced bullets will appear here once the note finishes processing.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }

    private func prependBullet() {
        if liveNotes.isEmpty {
            liveNotes = "- "
        } else if !liveNotes.hasSuffix("\n") {
            liveNotes += "\n- "
        } else {
            liveNotes += "- "
        }
    }

    private func copyNotes() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(liveNotes, forType: .string)
    }

    private func copySummary() {
        guard let summary = manager.summary else { return }
        let bullets = (summary.summary.isEmpty ? [] : [summary.summary])
            + summary.highlights
            + summary.actionItems.map { "Action: \($0.description)\( ($0.owner?.isEmpty == false) ? " [\($0.owner!)]" : "")" }
        let text = bullets.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func regenerateSummary(template: PromptTemplate? = nil) async {
        guard !isRegenerating else { return }
        isRegenerating = true
        await refreshLLMState()
        await manager.regenerateSummary(template: template)
        isRegenerating = false
    }

    private func prefillNotesIfNeeded() async {
        guard liveNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let transcriptID = manager.transcriptID else { return }
        do {
            let store = try TranscriptStore()
            let stored = try await store.retrieve(id: transcriptID)
            if let notes = stored.notes, !notes.isEmpty {
                await MainActor.run {
                    self.liveNotes = notes
                }
            }
        } catch {
            // best-effort
        }
    }

    private func exportSummary() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NewNote.md"
        panel.allowedContentTypes = [.plainText, .text, UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let title = manager.displayTitle
            var lines: [String] = ["# \(title)"]
            if let summary = manager.summary {
                if !summary.summary.isEmpty {
                    lines.append("\n## Summary\n\(summary.summary)")
                }
                if !summary.highlights.isEmpty {
                    lines.append("\n## Highlights")
                    summary.highlights.forEach { lines.append("- \($0)") }
                }
                if !summary.actionItems.isEmpty {
                    lines.append("\n## Action Items")
                    summary.actionItems.forEach { item in
                        let owner = (item.owner?.isEmpty == false) ? " [\(item.owner!)]" : ""
                        lines.append("- \(item.description)\(owner)")
                    }
                }
            }
            if !liveNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("\n## Notes")
                lines.append(liveNotes)
            }
            let text = lines.joined(separator: "\n")
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                FileLogger.log(category: "LiveNotesManagerView", message: "Failed to export summary: \(error.localizedDescription)")
            }
        }
    }

    private func loadStoredNotes() async {
        guard let transcriptID = manager.transcriptID else { return }
        do {
            let store = try TranscriptStore()
            let stored = try await store.retrieve(id: transcriptID)
            if let notes = stored.notes, !notes.isEmpty {
                await MainActor.run {
                    self.liveNotes = notes
                }
            }
        } catch {
            // Ignore; notes are optional best-effort.
        }
    }

    private func refreshLLMState() async {
        let state = await LocalLLMPipeline.shared.currentState()
        await MainActor.run {
            switch state {
            case .unavailable(let reason):
                llmStateDescription = "LLM unavailable (\(reason))"
            case .idle:
                llmStateDescription = "LLM idle"
            case .downloading:
                llmStateDescription = "LLM downloading model…"
            case .warming:
                llmStateDescription = "LLM warming…"
            case .ready(let modelID):
                if let modelID {
                    llmStateDescription = "LLM ready (\(modelID))"
                } else {
                    llmStateDescription = "LLM ready"
                }
            }
        }
    }

    private func warmLLM() async {
        if let warmupTask {
            await warmupTask.value
            return
        }
        isWarmingLLM = true
        let task = Task {
            await LocalLLMPipeline.shared.warmup()
        }
        warmupTask = task
        await task.value
        warmupTask = nil
        await refreshLLMState()
        isWarmingLLM = false
    }
}

struct RecordingBannerView: View {
    @ObservedObject var recordingCoordinator: MeetingRecordingCoordinator
    var openLiveNotes: () -> Void
    var stopRecording: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording in progress")
                    .font(.system(size: 12, weight: .semibold))
                if let meeting = recordingCoordinator.activeMeeting {
                    Text(meeting.title)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text(recordingCoordinator.liveTranscript.isEmpty ? "Waiting for audio…" : recordingCoordinator.liveTranscript)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: openLiveNotes) {
                Text("Live Notes")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(action: stopRecording) {
                Image(systemName: "stop.fill")
                    .foregroundColor(.white)
                    .padding(4)
                    .background(Color.red)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.2)))
        .padding(.horizontal, 6)
    }
}
