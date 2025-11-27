import SwiftUI
import AppKit

// MARK: - Next Event Header View

struct NextEventHeaderView: View {
    let meeting: Meeting
    var onJoin: (Meeting) -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        Button(action: { onJoin(meeting) }) {
            HStack(spacing: 12) {
                // Icon with background
                ZStack {
                    Circle()
                        .fill(Color(meeting.iconInfo.color).opacity(0.2))
                        .frame(width: 40, height: 40)
                    
                    if meeting.holidayInfo.isHoliday {
                        Text(meeting.holidayEmoji)
                            .font(.system(size: 20))
                    } else {
                        Image(systemName: meeting.iconInfo.iconName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(meeting.iconInfo.color))
                    }
                }
                
                // Content
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    
                    Text(timeUntilString)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Join indicator
                if meeting.url != nil {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Color(meeting.iconInfo.color))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
    
    private var timeUntilString: String {
        let now = Date()
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: meeting.startDate)
        
        if let day = components.day, day > 0 {
            if day == 1 {
                return "tomorrow"
            } else {
                return "in \(day)d"
            }
        }
        
        if let hour = components.hour, hour > 0 {
            if let minute = components.minute {
                return "in \(hour)h \(minute)m"
            }
            return "in \(hour)h"
        }
        
        if let minute = components.minute, minute > 0 {
            return "in \(minute)m"
        }
        
        return "starting now"
    }
}

// MARK: - Main Content View

struct MenuBarContentView: View {
    @ObservedObject var viewModel: MeetingListViewModel
    @ObservedObject var preferences: PreferencesService
    var openPreferences: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Next event header (if there's an upcoming meeting)
            if let nextEvent = nextUpcomingEvent {
                NextEventHeaderView(meeting: nextEvent, onJoin: viewModel.join)
                Divider()
            }
            
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
    
    private var nextUpcomingEvent: Meeting? {
        let now = Date()
        return allMeetings
            .filter { $0.startDate > now }
            .min { $0.startDate < $1.startDate }
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
