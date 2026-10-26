import AppKit
import Foundation

/// Builds the support report behind the "Copy Diagnostics" button.
///
/// Detection refusals happen before the fix script runs, so for those the
/// debug log does not even exist and the user has nothing to send. This
/// report collects what every bug thread has ended up asking for anyway:
/// macOS version, the dropped volume, its APFS container, the physical disk
/// with every partition on it, the full `diskutil list`, and the last debug
/// log if there is one.
enum Diagnostics {
    static let reportPath = "/tmp/t7fixer-diagnostics.txt"

    nonisolated static func gather(for url: URL?) async -> String {
        let path = url?.path
        return await Task.detached(priority: .userInitiated) {
            build(forVolumePath: path)
        }.value
    }

    /// Writes the report to `reportPath` (best-effort) and puts it on the
    /// clipboard. Returns the user-facing confirmation line.
    static func deliver(_ report: String) -> String {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        let saved = (try? report.write(toFile: reportPath, atomically: true, encoding: .utf8)) != nil
        return saved
            ? "Diagnostics copied to the clipboard and saved to \(reportPath). Paste them into your bug report."
            : "Diagnostics copied to the clipboard. Paste them into your bug report."
    }

    private nonisolated static func build(forVolumePath path: String?) -> String {
        var out = ""
        func section(_ title: String, _ body: String) {
            out += "=== \(title) ===\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        section("T7 Speed Restore diagnostics",
                "App version: \(version) (\(build))\nDate: \(ISO8601DateFormatter().string(from: Date()))\nDropped path: \(path ?? "none")")
        section("macOS", run("/usr/bin/sw_vers") + "\nArchitecture: " + run("/usr/bin/uname", ["-m"]))

        if let path {
            section("diskutil info \(path)", run("/usr/sbin/diskutil", ["info", path]))

            let volInfo = (try? T7Detector.runDiskutilPlist(["info", "-plist", path])) ?? [:]
            var wholeDisks: [String] = []

            if let container = volInfo["APFSContainerReference"] as? String, !container.isEmpty {
                section("diskutil info \(container) (APFS container)",
                        run("/usr/sbin/diskutil", ["info", container]))
                let containerInfo = (try? T7Detector.runDiskutilPlist(["info", "-plist", container])) ?? [:]
                let stores = containerInfo["APFSPhysicalStores"] as? [[String: Any]] ?? []
                for store in stores {
                    guard let id = (store["APFSPhysicalStore"] as? String) ?? (store["DeviceIdentifier"] as? String),
                          !id.isEmpty else { continue }
                    let storeInfo = (try? T7Detector.runDiskutilPlist(["info", "-plist", id])) ?? [:]
                    if let whole = storeInfo["ParentWholeDisk"] as? String, !whole.isEmpty {
                        wholeDisks.append(whole)
                    }
                }
            } else if let whole = volInfo["ParentWholeDisk"] as? String, !whole.isEmpty {
                wholeDisks.append(whole)
            }

            for whole in wholeDisks {
                section("diskutil list \(whole) (physical disk)", run("/usr/sbin/diskutil", ["list", whole]))
                section("diskutil info \(whole)", run("/usr/sbin/diskutil", ["info", whole]))
                for part in partitions(onWholeDisk: whole) {
                    section("diskutil info \(part)", run("/usr/sbin/diskutil", ["info", part]))
                }
            }
        }

        section("diskutil list (all disks)", run("/usr/sbin/diskutil", ["list"]))
        section("launchctl list (t7fixer)",
                run("/bin/launchctl", ["list"]).split(whereSeparator: \.isNewline)
                    .filter { $0.contains("t7fixer") }.joined(separator: "\n"))

        let logPath = "/tmp/t7fixer-debug.log"
        if let log = try? String(contentsOfFile: logPath, encoding: .utf8) {
            section("\(logPath)", log)
        } else {
            section("\(logPath)", "not present (the fix script has not run on this Mac since the last reboot)")
        }
        return out
    }

    private nonisolated static func partitions(onWholeDisk whole: String) -> [String] {
        guard let plist = try? T7Detector.runDiskutilPlist(["list", "-plist", whole]),
              let all = plist["AllDisksAndPartitions"] as? [[String: Any]],
              let disk = all.first(where: { ($0["DeviceIdentifier"] as? String) == whole }),
              let parts = disk["Partitions"] as? [[String: Any]] else { return [] }
        return parts.compactMap { $0["DeviceIdentifier"] as? String }
    }

    private nonisolated static func run(_ executable: String, _ args: [String] = []) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return "could not run \(executable): \(error)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? "(non-UTF8 output)"
    }
}
