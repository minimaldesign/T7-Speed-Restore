import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var drive: T7Drive?
    @State private var detectionError: String?
    @State private var overridableURL: URL?
    @State private var isDetecting = false
    @State private var dropTargeted = false
    @State private var summaryDropTargeted = false

    @State private var fixCoordinator = FixCoordinator()
    @State private var benchmarkCoordinator = BenchmarkCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if let drive {
                driveSummary(drive, isDropTargeted: summaryDropTargeted)
                    .onDrop(of: [.fileURL], isTargeted: $summaryDropTargeted) { providers in
                        handleDropProviders(providers)
                    }
                feedbackStrip
                HStack(alignment: .top, spacing: 16) {
                    benchmarkCard(drive: drive)
                    fixCard(drive: drive)
                }
            } else {
                DropZoneView(isTargeted: $dropTargeted, onDrop: { handleDrop(url: $0) })
                if isDetecting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Inspecting drive...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let detectionError {
                    detectionErrorView(detectionError)
                        .padding(.top, 4)
                }
            }
        }
        .padding(28)
        .frame(minWidth: 620, maxWidth: 1200)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Samsung T7 Speed Restore")
                .font(.title2.weight(.semibold))
            Text("Restore your T7's to its original write speed.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func driveSummary(_ drive: T7Drive, isDropTargeted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(.tint)
                Text(drive.volumeName)
                    .font(.headline)
                Spacer()
                Button("Use a different drive") {
                    resetDrive()
                }
                .buttonStyle(FlatSecondaryButtonStyle(compact: true))
            }
            Text(drive.displaySummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 26)
            HStack(spacing: 8) {
                Text(drive.filesystem).foregroundStyle(.secondary)
                if drive.t7fixerPartition != nil {
                    Text("•").foregroundStyle(.secondary)
                    Text("T7FIXER partition present").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.leading, 26)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.10) : Color.white.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(isDropTargeted ? 0.65 : 0), lineWidth: 1.5)
        )
        .animation(.easeInOut(duration: 0.12), value: isDropTargeted)
    }

    private var feedbackStrip: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if isDetecting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Inspecting drive...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if let detectionError {
                    detectionErrorView(detectionError)
                }

                switch fixCoordinator.state {
                case .idle:
                    EmptyView()
                case .fixing:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Applying fix. Enter your password when prompted.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                case .success:
                    Text("Fix applied. Run a benchmark to verify.")
                        .font(.callout)
                        .foregroundStyle(successColor)
                case .failed(let msg):
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(errorColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                switch benchmarkCoordinator.state {
                case .idle:
                    EmptyView()
                case .running(let elapsed):
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Running benchmark...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ProgressView(value: min(elapsed / Benchmark.defaultDurationSeconds, 1.0))
                            .progressViewStyle(.linear)
                    }
                case .failed(let msg):
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(errorColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !benchmarkCoordinator.isRunning, let latest = benchmarkCoordinator.latest {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(latest.displayString)
                            .font(.title3.weight(.medium))
                        if let previous = benchmarkCoordinator.previous {
                            Text("Previous: \(previous.displayString)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !hasAnyFeedback {
                    Text("Run a benchmark before and after the fix to measure the speed improvement.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 110)
        .scrollIndicators(.hidden)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.30))
        )
    }

    private func detectionErrorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.callout)
                .foregroundStyle(errorColor)
                .fixedSize(horizontal: false, vertical: true)
            if overridableURL != nil {
                Button("Use This Drive Anyway") {
                    if let url = overridableURL {
                        handleDrop(url: url, allowUnrecognizedModel: true)
                    }
                }
                .buttonStyle(FlatSecondaryButtonStyle(compact: true))
            }
        }
    }

    private var hasAnyFeedback: Bool {
        isDetecting ||
        detectionError != nil ||
        fixCoordinator.state != .idle ||
        benchmarkCoordinator.state != .idle ||
        benchmarkCoordinator.latest != nil
    }

    private func fixCard(drive: T7Drive) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore Write Speed").font(.headline)
            Button {
                Task { await fixCoordinator.runFix(on: drive) }
            } label: {
                Text("Restore Speed").frame(maxWidth: .infinity)
            }
            .buttonStyle(FlatProminentButtonStyle())
            .disabled(fixCoordinator.isBusy || benchmarkCoordinator.isRunning)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.10))
        )
    }

    private func benchmarkCard(drive: T7Drive) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Write Speed Benchmark").font(.headline)
            if benchmarkCoordinator.isRunning {
                Button {
                    benchmarkCoordinator.cancelBenchmark()
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(FlatSecondaryButtonStyle())
            } else {
                Button {
                    benchmarkCoordinator.startBenchmark(on: drive)
                } label: {
                    Text("Run Benchmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(FlatSecondaryButtonStyle())
                .disabled(fixCoordinator.isBusy)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.10))
        )
    }

    private func resetDrive() {
        drive = nil
        detectionError = nil
        overridableURL = nil
        fixCoordinator.reset()
        benchmarkCoordinator.clearHistory()
    }

    private func handleDropProviders(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in handleDrop(url: url) }
        }
        return true
    }

    private func handleDrop(url: URL, allowUnrecognizedModel: Bool = false) {
        guard !isDetecting else { return }
        isDetecting = true
        detectionError = nil
        overridableURL = nil
        Task {
            do {
                let detected = try await T7Detector.detect(
                    at: url, allowUnrecognizedModel: allowUnrecognizedModel)
                if detected.wholeDisk != drive?.wholeDisk {
                    fixCoordinator.reset()
                    benchmarkCoordinator.clearHistory()
                }
                drive = detected
                isDetecting = false
            } catch {
                if case T7DetectionError.notSamsungT7 = error {
                    overridableURL = url
                }
                detectionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                isDetecting = false
            }
        }
    }
}

private struct FlatProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .opacity(isEnabled ? 1 : 0.35)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { inside in
                if inside && isEnabled { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

private struct FlatSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.vertical, compact ? 6 : 10)
            .padding(.horizontal, compact ? 12 : 16)
            .background(
                RoundedRectangle(cornerRadius: compact ? 6 : 8)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.08))
            )
            .opacity(isEnabled ? 1 : 0.35)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { inside in
                if inside && isEnabled { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

private let successColor = Color(red: 0.29, green: 0.86, blue: 0.49) // #4ade80
private let errorColor   = Color(red: 0.98, green: 0.44, blue: 0.44) // #f87171

#Preview {
    ContentView()
}
