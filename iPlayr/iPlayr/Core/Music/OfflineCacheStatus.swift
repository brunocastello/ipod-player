import Foundation
import Observation

/// Observable state of the background duration prefetch, used to tell the user
/// why the connection matters and when the offline library is ready.
@MainActor
@Observable
final class OfflineCacheStatus {
    enum Phase: Equatable {
        case idle
        case preparing
        case ready
        case paused
    }

    private(set) var phase: Phase = .idle
    private(set) var resolved = 0
    private(set) var total = 0

    func begin() {
        resolved = 0
        total = 0
        phase = .preparing
    }

    func update(total: Int) {
        self.total = total
        resolved = 0
    }

    func advance() {
        resolved += 1
    }

    func reset() {
        phase = .idle
        resolved = 0
        total = 0
    }

    func finish() {
        phase = .ready
        hideLater()
    }

    func pause() {
        phase = .paused
    }

    private func hideLater() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.phase == .ready || self.phase == .paused else { return }
            self.phase = .idle
        }
    }
}
