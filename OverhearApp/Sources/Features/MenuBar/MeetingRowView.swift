import SwiftUI

struct MeetingRowView: View {
    let meeting: Meeting
    let use24HourClock: Bool
    var onJoin: (Meeting) -> Void

    @Environment(\.colorScheme) private var colorScheme
    
    private var isPastEvent: Bool {
        // An event is past if it has already ended
        meeting.endDate < Date()
    }
    
    private var isPastDate: Bool {
        // A date is in the past if the entire day has passed
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let eventDay = calendar.startOfDay(for: meeting.startDate)
        return eventDay < today
    }

    var body: some View {
        Button(action: { 
            onJoin(meeting) 
        }) {
            HStack(alignment: .center, spacing: 8) {
                // Holiday emoji or icon
                if meeting.holidayInfo.isHoliday {
                    Text(meeting.holidayEmoji)
                        .font(.system(size: 16))
                } else {
                    Image(systemName: meeting.iconInfo.iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(meeting.iconInfo.color))
                        .frame(width: 14)
                }
                
                // Title and time
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    
                    if !meeting.isAllDay {
                        Text(timeRangeText(for: meeting))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Join indicator if has URL
                if meeting.url != nil {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color(meeting.iconInfo.color))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .opacity((isPastEvent || isPastDate) ? 0.5 : 1.0)  // Fade if event ended OR date is in past
            .foregroundColor((isPastEvent || isPastDate) ? .gray : .primary)  // Grey out text too
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .disabled(isPastEvent || isPastDate)  // Disable join for past events or events from past dates
    }

    private func timeRangeText(for meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        if use24HourClock {
            formatter.dateFormat = "HH:mm"
        }
        let start = formatter.string(from: meeting.startDate)
        let end = formatter.string(from: meeting.endDate)
        if meeting.isAllDay {
            return "All day"
        }
        return "\(start) – \(end)"
    }
}
