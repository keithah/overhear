import SwiftUI

private func isRecordedOrReadyManual(recorded: Bool, meeting: Meeting) -> Bool {
    recorded || meeting.isManual
}

struct MeetingRowView: View {
    let meeting: Meeting
    let use24HourClock: Bool
    var recorded: Bool = false
    var manualRecordingStatus: MeetingListViewModel.ManualRecordingStatus? = nil
    var onJoin: (Meeting) -> Void
    var onShowRecordings: (Meeting) -> Void = { _ in }

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
            HStack(alignment: .center, spacing: 10) {
                // Left spacing
                Spacer()
                    .frame(width: 4)
                
                // Holiday emoji or icon
                if meeting.holidayInfo.isHoliday {
                    Text(meeting.holidayEmoji)
                        .font(.system(size: 16))
                } else if meeting.iconInfo.isSystemIcon {
                    Image(systemName: meeting.iconInfo.iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(meeting.iconInfo.swiftUIColor)
                        .frame(width: 14)
                } else {
                    // Custom image asset
                    if let image = loadImageFromAsset(meeting.iconInfo.iconName) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                    } else {
                        // Fallback
                        Image(systemName: "video.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(meeting.iconInfo.swiftUIColor)
                            .frame(width: 14)
                    }
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
                // Always show tape for manual or recorded meetings so transcripts are discoverable.
                if isRecordedOrReadyManual(recorded: recorded, meeting: meeting) {
                    Button {
                        onShowRecordings(meeting)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "tape")
                                .font(.system(size: 12, weight: .semibold))
                            Text("View")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(0.2))
                        )
                    }
                    .buttonStyle(.borderless)
                } else if meeting.isManual, manualRecordingStatus == .processing {
                    Text("Processing…")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
        }
        .opacity((isPastEvent || isPastDate) ? 0.5 : 1.0)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            if meeting.isManual {
                onShowRecordings(meeting)
            } else {
                onJoin(meeting)
            }
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

// MARK: - Minimalist View (Meeter-style)

struct MinimalistMeetingRowView: View {
    let meeting: Meeting
    let use24HourClock: Bool
    var recorded: Bool = false
    var manualRecordingStatus: MeetingListViewModel.ManualRecordingStatus? = nil
    var onJoin: (Meeting) -> Void
    var onShowRecordings: (Meeting) -> Void = { _ in }

    @State private var isHovered = false
    
    private var isPastEvent: Bool {
        meeting.endDate < Date()
    }
    
    private var isPastDate: Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let eventDay = calendar.startOfDay(for: meeting.startDate)
        return eventDay < today
    }

    var body: some View {
         // Simple one-line format matching Meeter exactly
         ZStack {
             // Hover background
             RoundedRectangle(cornerRadius: 4)
                 .fill(isHovered ? Color.blue.opacity(0.15) : Color.clear)
             
HStack(alignment: .center, spacing: 10) {
                  // Left spacing
                  Spacer()
                      .frame(width: 4)
                  
                  // Icon (Meeter size: ~14px)
                  if meeting.holidayInfo.isHoliday {
                      Text(meeting.holidayEmoji)
                          .font(.system(size: 16))
                          .frame(width: 18)
                  } else if meeting.iconInfo.isSystemIcon {
                      Image(systemName: meeting.iconInfo.iconName)
                          .font(.system(size: 12, weight: .semibold))
                          .foregroundColor(meeting.iconInfo.swiftUIColor)
                          .frame(width: 16)
                   } else {
                       // Custom image asset
                       if let image = loadImageFromAsset(meeting.iconInfo.iconName) {
                           Image(nsImage: image)
                               .resizable()
                               .scaledToFit()
                               .frame(width: 16, height: 16)
                       } else {
                           // Fallback
                           Image(systemName: "video.fill")
                               .font(.system(size: 12, weight: .semibold))
                               .foregroundColor(meeting.iconInfo.swiftUIColor)
                           .frame(width: 16)
                       }
                   }
                 
                 // Time (Meeter size: 13px)
                 if !meeting.isAllDay {
                     Text(timeString(for: meeting))
                         .font(.system(size: 13, weight: .regular))
                         .foregroundColor(.secondary)
                         .frame(width: 56, alignment: .leading)
                 } else {
                     Text("All day")
                         .font(.system(size: 13, weight: .regular))
                         .foregroundColor(.secondary)
                         .frame(width: 56, alignment: .leading)
                 }
                 
                 // Title (Meeter size: 13px, truncated with ...)
                 Text(meeting.title)
                     .font(.system(size: 13, weight: .regular))
                     .lineLimit(1)
                     .truncationMode(.tail)
                 
                 Spacer()
                 // Always show tape for manual or recorded meetings.
                 if isRecordedOrReadyManual(recorded: recorded, meeting: meeting) {
                     Button {
                         onShowRecordings(meeting)
                     } label: {
                         HStack(spacing: 4) {
                             Image(systemName: "tape")
                                 .font(.system(size: 12, weight: .semibold))
                             Text("View")
                                 .font(.system(size: 11, weight: .medium))
                         }
                         .padding(.horizontal, 6)
                         .padding(.vertical, 2)
                         .background(
                             RoundedRectangle(cornerRadius: 6)
                                 .fill(Color.accentColor.opacity(0.2))
                         )
                     }
                     .buttonStyle(.borderless)
                 } else if meeting.isManual, manualRecordingStatus == .processing {
                     Text("Processing…")
                         .font(.system(size: 10, weight: .regular))
                         .foregroundColor(.secondary)
                 }
            }
            .frame(height: 24)
        }
         .opacity((isPastEvent || isPastDate) ? 0.5 : 1.0)
         .contentShape(Rectangle())
         .onHover { hovering in
             isHovered = hovering
         }
         .onTapGesture {
             onJoin(meeting)
         }
     }
    
     private func timeString(for meeting: Meeting) -> String {
         let formatter = DateFormatter()
         formatter.dateStyle = .none
         formatter.timeStyle = .short
         if use24HourClock {
             formatter.dateFormat = "HH:mm"
         } else {
             formatter.dateFormat = "h:mm a"
         }
         return formatter.string(from: meeting.startDate)
     }
 }

// MARK: - Platform Icon Helper

func platformIcon(for platform: MeetingPlatform) -> some View {
    Group {
        switch platform {
        case .zoom:
            Image("ZoomIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        case .meet:
            Image("MeetIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        case .teams:
            Image("TeamsIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        case .webex:
            Image("WebexIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
        case .unknown:
            Image(systemName: "link")
        }
    }
}


// MARK: - Image Loading Helper

private func loadImageFromAsset(_ name: String) -> NSImage? {
    // Try loading from main bundle's asset catalog
    if let image = NSImage(named: name) {
        return image
    }
    
    // Try with NSImage.Name
    if let image = NSImage(named: NSImage.Name(name)) {
        return image
    }
    
    return nil
}
