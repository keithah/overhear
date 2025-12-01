import SwiftUI
import AppKit

struct MenuBarContentView: View {
     @ObservedObject var viewModel: MeetingListViewModel
     @ObservedObject var preferences: PreferencesService
     var openPreferences: () -> Void
    
     @State private var lastScrollTime: Date = Date()
     @State private var canScrollToPast: Bool = true
     @State private var lastScrollOffset: CGFloat = 0
     
     
     

      var body: some View {
         VStack(spacing: 0) {
             // Meetings list
             ScrollViewReader { proxy in
                 ScrollView(.vertical) {
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
                                         MinimalistMeetingRowView(meeting: meeting, use24HourClock: preferences.use24HourClock, onJoin: viewModel.join)
                                     } else {
                                         MeetingRowView(meeting: meeting, use24HourClock: preferences.use24HourClock, onJoin: viewModel.join)
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
                   .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ScrollToToday"))) { _ in
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
                 // Today button on left
                 Button(action: scrollToToday) {
                     Text("Today")
                         .font(.system(size: 11))
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
    
    private func scrollToToday() {
        // Scroll to today's position
        NotificationCenter.default.post(name: NSNotification.Name("ScrollToToday"), object: nil)
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
 