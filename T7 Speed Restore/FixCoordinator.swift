import Foundation
import Observation

@MainActor
@Observable
final class FixCoordinator {
    enum State: Equatable {
        case idle
        case fixing
        case success(uuid: String, completedAt: Date)
        case failed(message: String)
    }

    private(set) var state: State = .idle

    /// Shown while the fix runs. The APFS shrink verifies the whole file
    /// system first, which can take many minutes on a large drive, and
    /// interrupting it mid-shrink is the one thing the user must not do.
    static let fixingNotice = "Applying fix. Enter your password when prompted. macOS checks the drive’s file system before resizing it, which can take several minutes on a large drive. Don’t unplug the drive or quit the app."

    var isBusy: Bool {
        if case .fixing = state { return true }
        return false
    }

    var statusText: String? {
        switch state {
        case .idle: return nil
        case .fixing: return FixCoordinator.fixingNotice
        case .success: return "Fix applied. Run benchmark to verify."
        case .failed(let msg): return msg
        }
    }

    func runFix(on drive: T7Drive) async {
        state = .fixing
        do {
            let uuid = try await PrivilegeRouter.shared.performFix(on: drive)
            state = .success(uuid: uuid, completedAt: Date())
        } catch {
            state = .failed(message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    func reset() {
        state = .idle
    }
}
