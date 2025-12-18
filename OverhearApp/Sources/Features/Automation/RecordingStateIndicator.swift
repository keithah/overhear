import SwiftUI
import AppKit

struct RecordingStateIndicator: View {
    let title: String
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle.fill")
                .foregroundColor(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording")
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Button(action: stop) {
                Image(systemName: "stop.circle.fill")
                    .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }
}
