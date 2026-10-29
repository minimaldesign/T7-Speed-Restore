import SwiftUI

/// What the feedback strip shows while a fix runs: the current step, how
/// long it has been going, live drive activity, and for the data move an
/// upper-bound estimate. The point is that a fix that takes an hour never
/// looks stuck.
struct FixProgressView: View {
    let progress: FixProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress.phase.title)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(Self.clock(progress.elapsed))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Time since you clicked Restore Speed")
            }
            Text(progress.phase.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let moveLine {
                Text(moveLine)
                    .font(.callout.monospacedDigit())
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let activityLine {
                Text(activityLine)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(FixCoordinator.safetyNotice)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var activityLine: String? {
        guard progress.hasIOStats, progress.phase != .waitingForPassword else { return nil }
        let quiet = 100_000.0
        if progress.readRate < quiet && progress.writeRate < quiet {
            return "Drive activity: quiet right now"
        }
        return "Drive activity: reading \(Self.rate(progress.readRate)), writing \(Self.rate(progress.writeRate))"
    }

    private var moveLine: String? {
        guard progress.phase == .movingData, progress.hasIOStats else { return nil }
        var line = "Moved so far: \(Self.bytes(progress.movedBytes)) of at most \(Self.bytes(FixProgress.moveCeilingBytes))."
        if let left = progress.moveTimeLeft {
            line += " Up to about \(FixCoordinator.duration(left)) left at the current speed."
        }
        return line
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }
}
