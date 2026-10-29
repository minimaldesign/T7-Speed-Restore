import Foundation
import IOKit
import Observation

/// The step the fix is on, as far as the app can tell from outside.
nonisolated enum FixPhase: Equatable, Sendable {
    case waitingForPassword
    case working
    case removingOld
    case checking
    case movingData
    case creating
    case finishing

    var title: String {
        switch self {
        case .waitingForPassword: return "Waiting for your password"
        case .working: return "Applying the fix"
        case .removingOld: return "Removing the previous speed-reset partition"
        case .checking: return "Checking the drive’s file system"
        case .movingData: return "Making room for the speed-reset partition"
        case .creating: return "Creating the speed-reset partition"
        case .finishing: return "Finishing up"
        }
    }

    var detail: String {
        switch self {
        case .waitingForPassword:
            return "macOS needs your password so the app can repartition the drive."
        case .working:
            return "This can take from a few minutes to over an hour on a large drive."
        case .removingOld:
            return "Returning the space from your last fix to your main volume."
        case .checking:
            return "macOS verifies the whole file system before resizing it. This can take several minutes on a large drive."
        case .movingData:
            return "macOS is moving any data stored in the last \(T7HelperConstants.partitionSizeGB) GB of the drive to free space elsewhere. While the drive is slowed down this is usually the longest step. Your files stay on the drive."
        case .creating:
            return "Formatting the new partition. This resets the drive’s write speed."
        case .finishing:
            return "Hiding the new partition from Finder."
        }
    }
}

/// Follows a running fix from the outside, once a second: which step the
/// script is on (from its debug log), how much the drive is reading and
/// writing (from IOKit's per-disk counters, readable without root), and how
/// long it has been going.
///
/// The phase only comes from the osascript path's log. Signed builds that
/// use the SMAppService helper show `.working` plus the live counters.
@MainActor
@Observable
final class FixProgress {
    let startedAt = Date()
    private(set) var now = Date()
    private(set) var phase: FixPhase
    private(set) var readRate: Double = 0
    private(set) var writeRate: Double = 0
    private(set) var hasIOStats = false
    /// Bytes written to the drive since the data-move step started.
    private(set) var movedBytes: Int64 = 0
    private(set) var moveStartedAt: Date?

    /// The shrink can only have to relocate what lives in the region being
    /// removed, so this bounds the data move. Writes also include some
    /// file-system metadata, which is why the estimate says "up to about".
    nonisolated static let moveCeilingBytes = Int64(T7HelperConstants.partitionSizeGB) * 1_073_741_824

    @ObservationIgnored private let wholeDisk: String
    @ObservationIgnored private let runID: String
    @ObservationIgnored private let followsLog: Bool
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var samples: [(date: Date, read: Int64, written: Int64)] = []
    @ObservationIgnored private var writtenAtMoveStart: Int64 = 0

    init(wholeDisk: String, runID: String, followsLog: Bool) {
        self.wholeDisk = wholeDisk
        self.runID = runID
        self.followsLog = followsLog
        self.phase = followsLog ? .waitingForPassword : .working
    }

    var elapsed: TimeInterval { now.timeIntervalSince(startedAt) }

    /// Upper-bound estimate for the data-move step, once it has run long
    /// enough for the average speed to mean something.
    var moveTimeLeft: TimeInterval? {
        guard phase == .movingData, let moveStartedAt else { return nil }
        let t = now.timeIntervalSince(moveStartedAt)
        guard t >= 30, movedBytes > 0 else { return nil }
        let remaining = Double(Self.moveCeilingBytes - movedBytes)
        guard remaining > 0 else { return nil }
        return remaining / (Double(movedBytes) / t)
    }

    func start() {
        tick()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() {
        now = Date()
        let io = Self.diskIOBytes(bsdName: wholeDisk)

        if followsLog, let logged = Self.phaseFromLog(runID: runID), logged != phase {
            phase = logged
            if logged == .movingData {
                moveStartedAt = now
                writtenAtMoveStart = io?.written ?? 0
                movedBytes = 0
            }
        }

        guard let io else { return }
        hasIOStats = true
        samples.append((now, io.read, io.written))
        samples.removeAll { now.timeIntervalSince($0.date) > 6 }
        if let first = samples.first, let last = samples.last, last.date > first.date {
            let dt = last.date.timeIntervalSince(first.date)
            readRate = max(0, Double(last.read - first.read) / dt)
            writeRate = max(0, Double(last.written - first.written) / dt)
        }
        if phase == .movingData {
            movedBytes = max(0, io.written - writtenAtMoveStart)
        }
    }

    // MARK: - Sources

    nonisolated static let debugLogPath = "/tmp/t7fixer-debug.log"

    /// Reads the debug log and returns the phase of the run tagged `runID`,
    /// or nil until the script has started (the password prompt is up).
    nonisolated static func phaseFromLog(runID: String, path: String = debugLogPath) -> FixPhase? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let marker = text.range(of: "run=\(runID)") else { return nil }
        return phase(fromLog: text[marker.upperBound...])
    }

    /// The last recognized marker wins. Markers are the script's own debug
    /// lines plus diskutil's output for resizeContainer, which goes: verify
    /// ("Verifying storage system"), then "Shrinking APFS Physical Store" /
    /// "Shrinking APFS data structures" (the data move), or "Growing APFS"
    /// when a previous T7FIXER's space is being given back.
    nonisolated static func phase(fromLog text: Substring) -> FixPhase {
        var phase = FixPhase.working
        for line in text.split(whereSeparator: \.isNewline) {
            if line.contains("Cleaning up") || line.contains("Growing APFS") {
                phase = .removingOld
            } else if line.contains("Verifying storage system") {
                phase = .checking
            } else if line.contains("Shrinking APFS Physical Store") || line.contains("Shrinking APFS data structures") {
                phase = .movingData
            } else if line.contains("Adding partition") {
                phase = .creating
            } else if line.contains("addPartition returned") {
                phase = .finishing
            }
        }
        return phase
    }

    /// Cumulative bytes read and written on a whole disk, from the
    /// "Statistics" dictionary of the IOBlockStorageDriver above its IOMedia.
    nonisolated static func diskIOBytes(bsdName: String) -> (read: Int64, written: Int64)? {
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        guard media != 0 else { return nil }
        var entry: io_registry_entry_t = media
        defer { IOObjectRelease(entry) }
        for _ in 0..<4 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(entry)
            entry = parent
            if let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                let read = (stats["Bytes (Read)"] as? NSNumber)?.int64Value ?? 0
                let written = (stats["Bytes (Write)"] as? NSNumber)?.int64Value ?? 0
                return (read, written)
            }
        }
        return nil
    }
}
