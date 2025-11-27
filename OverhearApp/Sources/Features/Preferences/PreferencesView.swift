import EventKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var preferences: PreferencesService
    @ObservedObject var calendarService: CalendarService

    @State private var calendarsBySource: [(source: EKSource, calendars: [EKCalendar])] = []
    @State private var isLoadingCalendars = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            calendarsTab
                .tabItem { Label("Calendars", systemImage: "calendar") }
            advancedTab
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .padding()
        .frame(width: 520, height: 420)
        .task {
            await loadCalendars()
        }
    }

    private var generalTab: some View {
        Form {
            Toggle("Launch at login", isOn: $preferences.launchAtLogin)
            Toggle("Use 24-hour clock", isOn: $preferences.use24HourClock)
            Toggle("Show events without links", isOn: $preferences.showEventsWithoutLinks)
            Toggle("Show maybe events", isOn: $preferences.showMaybeEvents)
            Stepper("Days ahead: \(preferences.daysAhead)", value: $preferences.daysAhead, in: 1...14)
            Stepper("Days back: \(preferences.daysBack)", value: $preferences.daysBack, in: 0...7)
        }
    }

    private var calendarsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Calendars")
                    .font(.headline)
                if isLoadingCalendars {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(calendarsBySource, id: \.source.sourceIdentifier) { sourceGroup in
                        VStack(alignment: .leading, spacing: 6) {
                            // Source header with toggle
                            SourceToggle(
                                source: sourceGroup.source,
                                calendars: sourceGroup.calendars,
                                preferences: preferences
                            )
                            
                            // Calendars in this source
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(sourceGroup.calendars, id: \.calendarIdentifier) { calendar in
                                    CalendarToggle(
                                        calendar: calendar,
                                        preferences: preferences
                                    )
                                    .padding(.leading, 20)
                                }
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    
                    if calendarsBySource.isEmpty {
                        Text("No calendars available. Please grant calendar access.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var advancedTab: some View {
        Form {
            Toggle("Show countdown in menu bar", isOn: $preferences.countdownEnabled)
            Stepper("Notify minutes before: \(preferences.notificationMinutesBefore)", value: $preferences.notificationMinutesBefore, in: 0...30)
            Section(header: Text("Open rules (coming soon)")) {
                Text("Configure how Overhear opens Zoom, Meet, Teams, and Webex links.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Section(header: Text("Hotkeys (coming soon)")) {
                Text("Set shortcuts to open Overhear or join your next meeting.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func loadCalendars() async {
        isLoadingCalendars = true
        let accessGranted = await calendarService.requestAccessIfNeeded()
        guard accessGranted else {
            isLoadingCalendars = false
            calendarsBySource = []
            return
        }
        
        calendarsBySource = calendarService.calendarsBySource()
        
        // Initialize with all calendars on first run
        let allCalendarIDs = calendarsBySource.flatMap { $0.calendars.map { $0.calendarIdentifier } }
        preferences.initializeWithAllCalendars(allCalendarIDs)
        
        isLoadingCalendars = false
    }
}

/// Toggle for an entire source
private struct SourceToggle: View {
    let source: EKSource
    let calendars: [EKCalendar]
    @ObservedObject var preferences: PreferencesService
    
    var body: some View {
        Toggle(isOn: Binding(
            get: {
                // All calendars in this source are selected
                calendars.allSatisfy { preferences.selectedCalendarIDs.contains($0.calendarIdentifier) }
            },
            set: { newValue in
                for calendar in calendars {
                    preferences.toggleCalendar(id: calendar.calendarIdentifier, enabled: newValue)
                }
            }
        )) {
            Text(source.title)
                .font(.system(size: 13, weight: .semibold))
        }
    }
}

/// Toggle for a single calendar
private struct CalendarToggle: View {
    let calendar: EKCalendar
    @ObservedObject var preferences: PreferencesService
    
    var body: some View {
        Toggle(isOn: Binding(
            get: {
                preferences.selectedCalendarIDs.contains(calendar.calendarIdentifier)
            },
            set: { newValue in
                preferences.toggleCalendar(id: calendar.calendarIdentifier, enabled: newValue)
            }
        )) {
            HStack {
                Circle()
                    .fill(Color(cgColor: calendar.cgColor))
                    .frame(width: 8, height: 8)
                Text(calendar.title)
                    .font(.system(size: 12))
            }
        }
    }
}
