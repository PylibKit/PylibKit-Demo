import SwiftUI

struct MediaButton: View {
    let icon: String
    var prominent: Bool = false
    var enabled: Bool = true
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 64, height: 64)
        }
        .buttonStyle(.plain)
        .background(
            Circle().fill(
                prominent ? Color.accentColor : Color(.secondarySystemBackground)
            )
        )
        .foregroundStyle(prominent ? Color.white : Color.primary)
        .opacity(enabled ? 1.0 : 0.35)
        .allowsHitTesting(enabled)
    }
}

struct DeviceRow: View {
    let index: Int
    let label: String
    let onConnect: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.isEmpty ? "Device #\(index + 1)" : label)
                .font(.headline)
            Button(action: onConnect) {
                Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "--:--" }
    let total = Int(seconds.rounded())
    let minutes = total / 60
    let secs = total % 60
    return String(format: "%d:%02d", minutes, secs)
}

func formatElapsedTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded())
    let minutes = total / 60
    let secs = total % 60
    return String(format: "%d:%02d", minutes, secs)
}
