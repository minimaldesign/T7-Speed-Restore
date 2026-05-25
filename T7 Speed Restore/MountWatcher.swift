import Foundation

enum MountWatcherError: LocalizedError {
    case plistWriteFailed
    case launchctlFailed

    var errorDescription: String? {
        switch self {
        case .plistWriteFailed:
            return "Couldn't install the background helper that keeps T7FIXER hidden. The fix still worked, but T7FIXER may appear in Finder after you unplug and replug the drive."
        case .launchctlFailed:
            return "Couldn't start the background helper that keeps T7FIXER hidden. The fix still worked, but T7FIXER may appear in Finder until you next sign in."
        }
    }
}

/// Installs a per-user LaunchAgent that auto-unmounts T7FIXER whenever
/// macOS mounts it at /Volumes/T7FIXER. Replaces the role that /etc/fstab
/// would play if it were writable.
enum MountWatcher {
    nonisolated static let label = "net.mnmldsgn.t7fixer.unmount-watcher"

    nonisolated static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    nonisolated static func installIfPossible(partitionLabel: String) throws {
        let mountPath = "/Volumes/\(partitionLabel)"
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                "/bin/bash",
                "-c",
                "/usr/sbin/diskutil unmount \"\(mountPath)\" 2>/dev/null || true"
            ],
            "WatchPaths": [mountPath],
            "RunAtLoad": true,
            "ThrottleInterval": 1
        ]

        // Make sure ~/Library/LaunchAgents exists.
        let dir = agentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Serialize and atomically write the plist.
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: agentURL, options: .atomic)
        } catch {
            throw MountWatcherError.plistWriteFailed
        }

        // Unload any previous version (idempotent — error is fine if not loaded).
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])

        // Load the new agent.
        let load = runLaunchctl(["bootstrap", "gui/\(getuid())", agentURL.path])
        if load.exitCode != 0 {
            throw MountWatcherError.launchctlFailed
        }
    }

    nonisolated static func uninstall() {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: agentURL)
    }

    @discardableResult
    private nonisolated static func runLaunchctl(_ args: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return (-1, "", "\(error)")
        }
        let outStr = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errStr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, outStr, errStr)
    }
}
