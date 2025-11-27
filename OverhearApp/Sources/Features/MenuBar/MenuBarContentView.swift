import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @ObservedObject var viewModel: MeetingListViewModel
    @ObservedObject var preferences: PreferencesService
    var openPreferences: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if viewModel.isLoading {
                        HStack { Spacer(); ProgressView("Loading events..."); Spacer() }
                    } else {
                        if !viewModel.pastSections.isEmpty {
                            SectionHeader(title: "Past")
                            MeetingSectionList(sections: viewModel.pastSections,
                                               preferences: preferences,
                                               onJoin: viewModel.join)
                        }
                        SectionHeader(title: "Upcoming")
                        MeetingSectionList(sections: viewModel.upcomingSections,
                                           preferences: preferences,
                                           onJoin: viewModel.join)
                    }
                }
                .padding(.vertical, 12)
            }
            Divider()
            footer
        }
        .frame(width: 360, height: 520)
        .padding(.horizontal, 12)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Overhear")
                    .font(.title2.bold())
                if let updated = viewModel.lastUpdated {
                    Text("Updated \(relativeDate(updated))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Meeting launcher")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button(action: { Task { await viewModel.reload() } }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Button("Preferences…") { openPreferences() }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.vertical, 10)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct MeetingSectionList: View {
    let sections: [MeetingSection]
    @ObservedObject var preferences: PreferencesService
    var onJoin: (Meeting) -> Void

    var body: some View {
        ForEach(sections) { section in
            VStack(alignment: .leading, spacing: 8) {
                Text(section.title)
                    .font(.headline)
                ForEach(section.meetings) { meeting in
                    MeetingRowView(meeting: meeting,
                                   use24HourClock: preferences.use24HourClock,
                                   onJoin: onJoin)
                }
            }
            .padding(.bottom, 8)
        }
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .textCase(.uppercase)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}
