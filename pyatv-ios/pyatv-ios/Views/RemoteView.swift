import SwiftUI

struct RemoteView: View {
    @ObservedObject var viewModel: PyatvViewModel
    var onRefresh: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            GroupBox("Target") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connected: \(viewModel.connectedName)")
                    Text(viewModel.connectionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            if !viewModel.hasRemoteControl {
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Connect to a HomePod with remote support to enable controls.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            
            GroupBox("Now Playing") {
                VStack(spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(.secondarySystemBackground))
                            .frame(width: 140, height: 140)
                        Image(systemName: "music.note.list")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 6) {
                        Text(viewModel.nowPlayingTitle.isEmpty ? "재생 정보 없음" : viewModel.nowPlayingTitle)
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .center)
                        if !viewModel.nowPlayingSubtitle.isEmpty {
                            Text(viewModel.nowPlayingSubtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    if !viewModel.nowPlayingTitle.isEmpty {
                        VStack(spacing: 6) {
                            if viewModel.nowPlayingDuration > 0 {
                                ProgressView(
                                    value: min(viewModel.nowPlayingPosition, viewModel.nowPlayingDuration),
                                    total: viewModel.nowPlayingDuration
                                )
                                .tint(.accentColor)
                            }
                            HStack {
                                Text(formatElapsedTime(viewModel.nowPlayingPosition))
                                Spacer()
                                Text(formatTime(viewModel.nowPlayingDuration))
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 28) {
                        MediaButton(icon: "backward.fill", enabled: viewModel.hasRemoteControl) {
                            viewModel.previous()
                        }
                        MediaButton(icon: "playpause.fill", prominent: true, enabled: viewModel.hasRemoteControl) {
                            viewModel.playPause()
                        }
                        MediaButton(icon: "forward.fill", enabled: viewModel.hasRemoteControl) {
                            viewModel.next()
                        }
                    }
                }
            }
            
            Spacer()
        }
        .onAppear {
            viewModel.resumeNowPlayingUpdates()
            onRefresh()
        }
    }
}
