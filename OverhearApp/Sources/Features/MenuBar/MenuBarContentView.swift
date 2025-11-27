import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @ObservedObject var viewModel: MeetingListViewModel
    @ObservedObject var preferences: PreferencesService
    var openPreferences: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Meetings list
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if viewModel.isLoading {
                            HStack { Spacer(); ProgressView().scaleEffect(0.7); Spacer() }
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
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(isDateInPast(group.date) ? .gray : .secondary)
                                    .opacity(isDateInPast(group.date) ? 0.6 : 1.0)
                                    .padding(.top, 4)
                                    .padding(.horizontal, 10)
                                    .padding(.bottom, 1)
                                    .id(dateIdentifier(group.date))  // Anchor for scroll
                                
                                // Meetings for this date
                                ForEach(group.meetings) { meeting in
                                    MeetingRow(meeting: meeting, onJoin: viewModel.join)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear {
                    // Scroll to today
                    withAnimation {
                        proxy.scrollTo(dateIdentifier(todayDate), anchor: .top)
                    }
                }
            }
            
            Divider()
            
            // Footer
            HStack(spacing: 10) {
                Button(action: openPreferences) {
                    Text("Preferences…")
                        .font(.system(size: 11))
                }
                .keyboardShortcut("p")
                
                Button(action: {}) {
                    Text("Send Feedback…")
                        .font(.system(size: 11))
                }
                .keyboardShortcut("f")
                
                Spacer()
                
                Button(action: { NSApp.terminate(nil) }) {
                    Text("Quit")
                        .font(.system(size: 11))
                }
                .keyboardShortcut("q")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: 320, height: 380)
    }
    
    private var allMeetings: [Meeting] {
        (viewModel.pastSections + viewModel.upcomingSections)
            .flatMap { $0.meetings }
    }
    
    private var groupedMeetings: [(date: Date, meetings: [Meeting])] {
        let grouped = Dictionary(grouping: allMeetings) { meeting -> Date in
            Calendar.current.startOfDay(for: meeting.startDate)
        }
        
        return grouped.sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { $0.startDate < $1.startDate }) }
    }
    
    private var todayDate: Date {
        Calendar.current.startOfDay(for: Date())
    }
    
    private func isDateInPast(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return date < today
    }
    
    private func dateIdentifier(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter.string(from: date)
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    var onJoin: (Meeting) -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            // Icon - smaller
            Image(systemName: meetingIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.blue)
                .frame(width: 12)
            
            // Title and time
            VStack(alignment: .leading, spacing: 0) {
                Text(meeting.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                
                if !meeting.isAllDay {
                    Text(timeString)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Join button if has URL
            if meeting.url != nil {
                Button(action: { onJoin(meeting) }) {
                    Image(systemName: "link")
                        .font(.system(size: 10))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Join meeting")
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 10)
    }
    
    private var meetingIcon: String {
        if meeting.url != nil {
            return "video.fill"
        } else if meeting.isAllDay {
            return "calendar"
        } else {
            return "clock"
        }
    }
    
    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: meeting.startDate)
    }
}
