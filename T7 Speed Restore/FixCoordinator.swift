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

    var isBusy: Bool {
        if case .fixing = state { return true }
        return false
    }

    var statusText: String? {
        switch state {
        case .idle: return nil
        case .fixing: return "Applying fix. Enter your password when prompted."
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
