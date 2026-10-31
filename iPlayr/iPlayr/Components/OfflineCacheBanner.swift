import SwiftUI

struct OfflineCacheBanner: View {
    @Environment(OfflineCacheStatus.self) private var status

    var body: some View {
        Group {
            switch status.phase {
            case .idle:
                EmptyView()
            case .preparing:
                content {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.65)
                    if status.total > 0 {
                        Text("Preparing offline library \(status.resolved)/\(status.total) — keep internet on.")
                    } else {
                        Text("Preparing offline library — keep internet on.")
                    }
                }
            case .ready:
                content {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Offline library ready.")
                }
            case .paused:
                content {
                    Image(systemName: "wifi.slash")
                    Text("Offline preparation paused — connect to internet.")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 30)
        .animation(.easeInOut(duration: 0.2), value: status.phase)
    }

    private func content<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            content()
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .multilineTextAlignment(.leading)
        .lineLimit(2)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.72)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
