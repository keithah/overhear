import SwiftUI

struct MeetingRowView: View {
    let meeting: Meeting
    let use24HourClock: Bool
    var onJoin: (Meeting) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: { onJoin(meeting) }) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(timeRangeText(for: meeting))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                platformIcon(for: meeting.platform)
                    .foregroundColor(.accentColor)
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    private func platformIcon(for platform: MeetingPlatform) -> some View {
        let symbol: String
        switch platform {
        case .zoom: symbol = "video"
        case .meet: symbol = "person.2.wave.2"
        case .teams: symbol = "person.3.sequence"
        case .webex: symbol = "person.badge.clock"
        case .unknown: symbol = "link"
        }
        return Image(systemName: symbol)
            .imageScale(.medium)
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
