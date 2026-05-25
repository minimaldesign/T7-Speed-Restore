import SwiftUI

struct ContentView: View {
    @State private var drive: T7Drive?
    @State private var detectionError: String?
    @State private var isDetecting = false
    @State private var dropTargeted = false

    @State private var fixCoordinator = FixCoordinator()
    @State private var benchmarkCoordinator = BenchmarkCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let drive {
                driveSummary(drive)
                HStack(alignment: .top, spacing: 16) {
                    fixCard(drive: drive)
                    benchmarkCard(drive: drive)
                }
                resetButton
            } else {
                DropZoneView(isTargeted: $dropTargeted, onDrop: handleDrop)
                if isDetecting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Inspecting drive...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let detectionError {
                    Text(detectionError)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 440)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Samsung T7 Fixer")
                .font(.title2.weight(.semibold))
            Text("Restore your T7's write speed by recreating a hidden exFAT partition.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func driveSummary(_ drive: T7Drive) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(.tint)
                Text(drive.displaySummary)
                    .font(.headline)
            }
            HStack(spacing: 8) {
                Text(drive.filesystem).foregroundStyle(.secondary)
                if drive.t7fixerPartition != nil {
                    Text("•").foregroundStyle(.secondary)
                    Text("T7FIXER partition present").foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func fixCard(drive: T7Drive) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fix").font(.headline)
            Button {
                Task { await fixCoordinator.runFix(on: drive) }
            } label: {
                if fixCoordinator.isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Working...")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("Fix Write Speed")
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(fixCoordinator.isBusy)

            if let status = fixCoordinator.statusText {
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(statusColor(for: fixCoordinator.state))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25))
        )
    }

    private func benchmarkCard(drive: T7Drive) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Benchmark").font(.headline)
            Button {
                Task { await benchmarkCoordinator.runBenchmark(on: drive) }
            } label: {
                if benchmarkCoordinator.isRunning {
                    if case .running(let elapsed) = benchmarkCoordinator.state {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(String(format: "Writing... %.1fs", elapsed))
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text("Running...").frame(maxWidth: .infinity)
                    }
                } else {
                    Text("Run Benchmark")
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .disabled(benchmarkCoordinator.isRunning)

            if let latest = benchmarkCoordinator.latest {
                VStack(alignment: .leading, spacing: 2) {
                    Text(latest.displayString)
                        .font(.title3.weight(.medium))
                    if let previous = benchmarkCoordinator.previous {
                        Text("Previous: \(previous.displayString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if case .failed(let msg) = benchmarkCoordinator.state {
                Text(msg).font(.subheadline).foregroundStyle(.red)
            } else {
                Text("Writes random data for 10 seconds to measure throughput.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25))
        )
    }

    private var resetButton: some View {
        HStack {
            Spacer()
            Button("Use a different drive") {
                drive = nil
                detectionError = nil
                fixCoordinator.reset()
                benchmarkCoordinator.clearHistory()
            }
            .buttonStyle(.link)
        }
    }

    private func statusColor(for state: FixCoordinator.State) -> Color {
        switch state {
        case .success: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private func handleDrop(url: URL) {
        guard !isDetecting else { return }
        isDetecting = true
        detectionError = nil
        Task {
            do {
                let detected = try await T7Detector.detect(at: url)
                drive = detected
                isDetecting = false
            } catch {
                detectionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                isDetecting = false
            }
        }
    }
}

#Preview {
    ContentView()
}
