import SwiftUI
import PylibKit_iOS

struct DeviceListView: View {
    let devices: [Pyatv.Interface.BaseconfigInstance]
    let isBusy: Bool
    let isScanning: Bool
    let labelForDevice: (Pyatv.Interface.BaseconfigInstance, Int) -> String
    let onConnect: (Pyatv.Interface.BaseconfigInstance, Int) -> Void
    
    var body: some View {
        GroupBox("Discovered HomePods") {
            if isBusy || isScanning {
                VStack(spacing: 8) {
                    ProgressView(isScanning ? "Scanning..." : "Working...")
                    Text(isScanning ? "Searching the network..." : "Preparing runtime...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else if devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No HomePods yet. Tap Scan to search for HomePods on your network.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(devices.enumerated()), id: \.offset) { idx, entry in
                        DeviceRow(index: idx, label: labelForDevice(entry, idx)) {
                            onConnect(entry, idx)
                        }
                        .disabled(isBusy)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}
