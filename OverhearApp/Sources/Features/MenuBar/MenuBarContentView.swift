import SwiftUI
import AppKit

extension NSNotification.Name {
    static let scrollToToday = NSNotification.Name("ScrollToToday")
    static let closeMenuPopover = NSNotification.Name("CloseMenuPopover")
}

struct MenuBarContentView: View {
     @ObservedObject var viewModel: MeetingListViewModel
     @ObservedObject var preferences: PreferencesService
     @ObservedObject var recordingCoordinator: MeetingRecordingCoordinator
     var openPreferences: () -> Void
     var onToggleRecording: () -> Void
    
     
     
     
     

      var body: some View {
        VStack(spacing: 0) {
            if recordingCoordinator.isRecording {
                RecordingBannerView(
                    recordingCoordinator: recordingCoordinator,
                    openLiveNotes: {
                        LiveNotesWindowController.shared.show(with: recordingCoordinator)
                    },
                    stopRecording: {
                        recordingCoordinator.stopRecording()
                    }
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
                                            onJoin: viewModel.joinAndRecord,
                                            onShowRecordings: viewModel.showRecordings
                                        )
                                    } else {
                                        MeetingRowView(
                                            meeting: meeting,
                                            use24HourClock: preferences.use24HourClock,
                                            recorded: viewModel.isRecorded(meeting),
                                            manualRecordingStatus: viewModel.manualRecordingStatus(for: meeting),
                                            onJoin: viewModel.joinAndRecord,
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
                       // Scroll to today when view appears
                       withAnimation {
                           proxy.scrollTo(dateIdentifier(todayDate), anchor: .top)
                       }
                   }
                   .onReceive(NotificationCenter.default.publisher(for: .scrollToToday)) { _ in
                       DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                           withAnimation {
                               proxy.scrollTo(dateIdentifier(todayDate), anchor: .top)
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
    }
    
    private var allMeetings: [Meeting] {
        (viewModel.pastSections + viewModel.upcomingSections)
            .flatMap { $0.meetings }
    }
    
private var groupedMeetings: [(date: Date, meetings: [Meeting])] {
         let grouped = Dictionary(grouping: allMeetings) { meeting -> Date in
              Calendar.current.startOfDay(for: meeting.startDate)
         }
         
         // Sort by date
         let sorted = grouped.sorted { $0.key < $1.key }
         let mapped = sorted.map { (date: $0.key, meetings: $0.value.sorted { $0.startDate < $1.startDate }) }
         
          // Separate past, today, and future
          let today = todayDate
          let past = mapped.filter { $0.date < today }  // Past in chronological order (oldest first)
          let todayAndFuture = mapped.filter { $0.date >= today }
          
          // Return: past first (at top), then today and future
          // This way Wednesday is at top, Thursday below it, then Friday, Sunday, etc.
          return past + todayAndFuture
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

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "mic.fill")
                    .foregroundColor(.blue)
                Text(coordinator.activeMeeting?.title ?? "Manual Recording")
                    .font(.headline)
                Spacer()
                Text(coordinator.isRecording ? "Recording…" : "Idle")
                    .font(.subheadline)
                    .foregroundColor(coordinator.isRecording ? .green : .secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Live transcript")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                LiveTranscriptList(segments: coordinator.liveSegments)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Notes", systemImage: "pencil")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextEditor(text: $coordinator.liveNotes)
                    .font(.system(size: 13))
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            }
        }
        .padding(16)
        .frame(minWidth: 400, minHeight: 360)
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

struct LiveTranscriptList: View {
    let segments: [LiveTranscriptSegment]
    private let palette: [Color] = [
        .blue, .purple, .green, .orange, .pink, .teal, .indigo, .brown
    ]

    private func color(for speaker: String) -> Color {
        let hash = abs(speaker.hashValue)
        return palette[hash % palette.count]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if segments.isEmpty {
                        Text("Waiting for audio…")
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(segments) { segment in
                            VStack(alignment: .leading, spacing: 4) {
                                if let speaker = segment.speaker {
                                    Text(speaker)
                                        .font(.caption.bold())
                                        .foregroundColor(color(for: speaker))
                                }
                                Text(segment.text)
                                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(segment.isConfirmed ? Color(NSColor.controlBackgroundColor) : Color.blue.opacity(0.15))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(segment.isConfirmed ? Color.secondary.opacity(0.25) : Color.blue.opacity(0.35))
                            )
                            .id(segment.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .onChange(of: segments.count) { _ in
                if let last = segments.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: 200)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
    }
}

@MainActor
final class LiveNotesWindowController {
    static let shared = LiveNotesWindowController()

    private var window: NSWindow?
    private var hostingController: NSHostingController<LiveNotesView>?

    func show(with coordinator: MeetingRecordingCoordinator) {
        if let hosting = hostingController {
            hosting.rootView = LiveNotesView(coordinator: coordinator)
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let view = LiveNotesView(coordinator: coordinator)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Live Notes"
        window.contentView = controller.view
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.window = window
        self.hostingController = controller
    }
}
 
