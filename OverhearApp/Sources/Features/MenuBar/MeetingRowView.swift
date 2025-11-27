import SwiftUI

struct MeetingRowView: View {
    let meeting: Meeting
    let use24HourClock: Bool
    var onJoin: (Meeting) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    
    private var isPastEvent: Bool {
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
        ZStack {
            // Background that responds to hover
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? 
                      Color.blue.opacity(0.3) :
                      (colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04)))
            
            // Content
            HStack(alignment: .center, spacing: 8) {
                // Holiday emoji or icon
                if meeting.holidayInfo.isHoliday {
                    Text(meeting.holidayEmoji)
                        .font(.system(size: 16))
                } else {
                    let iconColor = Color(red: meeting.iconInfo.color.redComponent,
                                         green: meeting.iconInfo.color.greenComponent,
                                         blue: meeting.iconInfo.color.blueComponent)
                    Image(systemName: meeting.iconInfo.iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(iconColor)
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
                
                // Join indicator if has URL (non-interactive, just visual)
                if meeting.url != nil {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color(meeting.iconInfo.color))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
        }
        .opacity((isPastEvent || isPastDate) ? 0.5 : 1.0)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onJoin(meeting)  // Always allow click
        }
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
