import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class FixCoordinator {
    enum State: Equatable {
        case idle
        case fixing
        case success(uuid: String, completedAt: Date, duration: TimeInterval)
        case failed(message: String)
    }

    private(set) var state: State = .idle
    private(set) var progress: FixProgress?

    /// Read by the app delegate to warn before quitting mid-fix.
    private(set) static var isAnyFixRunning = false

    /// Shown under the progress while the fix runs. Interrupting the resize
    /// while macOS moves data is the one thing that can hurt the drive, and
    /// a fix can legitimately take over an hour.
    static let safetyNotice = "Don’t unplug the drive, quit the app, or close your Mac’s lid. You can keep using your Mac, and it won’t go to sleep on its own until the fix is done."

    var isBusy: Bool {
        if case .fixing = state { return true }
        return false
    }

    var statusText: String? {
        switch state {
        case .idle: return nil
        case .fixing: return progress?.phase.title ?? FixPhase.working.title
        case .success(_, _, let duration): return Self.successText(duration: duration)
        case .failed(let msg): return msg
        }
    }

    func runFix(on drive: T7Drive) async {
        let runID = UUID().uuidString
        let monitor = FixProgress(
            wholeDisk: drive.wholeDisk,
            runID: runID,
            followsLog: PrivilegeRouter.shared.detectPath() == .osascript
        )
        progress = monitor
        state = .fixing
        Self.isAnyFixRunning = true
        monitor.start()
        // A first run on a large, slowed-down drive can take over an hour.
        // Idle sleep in the middle would stall it at best.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Repartitioning the Samsung T7"
        )
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            monitor.stop()
            progress = nil
            Self.isAnyFixRunning = false
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }

        do {
            let uuid = try await PrivilegeRouter.shared.performFix(on: drive, runID: runID)
            state = .success(uuid: uuid, completedAt: Date(), duration: Date().timeIntervalSince(monitor.startedAt))
        } catch {
            state = .failed(message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    func reset() {
        state = .idle
    }

    static func successText(duration: TimeInterval) -> String {
        "Fix applied in \(Self.duration(duration)). Run a benchmark to verify."
    }

    /// "less than a minute", "12 min", "1 h 6 min".
    static func duration(_ t: TimeInterval) -> String {
        let minutes = Int((t / 60).rounded())
        if minutes < 1 { return "less than a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
