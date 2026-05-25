import Foundation
import Observation

@MainActor
@Observable
final class BenchmarkCoordinator {
    enum State: Equatable {
        case idle
        case running(elapsed: Double)
        case failed(message: String)
    }

    private(set) var state: State = .idle
    private(set) var history: [BenchmarkResult] = []

    private var tickerTask: Task<Void, Never>?
    private var writeTask: Task<BenchmarkResult, Error>?

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var latest: BenchmarkResult? { history.first }
    var previous: BenchmarkResult? { history.count > 1 ? history[1] : nil }

    func startBenchmark(on drive: T7Drive) {
        guard !isRunning else { return }

        let start = Date()
        state = .running(elapsed: 0)

        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                if case .running = self.state {
                    self.state = .running(elapsed: Date().timeIntervalSince(start))
                } else {
                    return
                }
            }
        }

        let wt = Task.detached(priority: .userInitiated) {
            try Benchmark.runWriteSync(on: drive.mountPath, durationSeconds: 10)
        }
        writeTask = wt

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await wt.value
                self.tickerTask?.cancel()
                self.history.insert(result, at: 0)
                if self.history.count > 5 { self.history = Array(self.history.prefix(5)) }
                self.state = .idle
            } catch is CancellationError {
                self.tickerTask?.cancel()
                self.state = .idle
            } catch {
                self.tickerTask?.cancel()
                self.state = .failed(message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            self.writeTask = nil
        }
    }

    func cancelBenchmark() {
        writeTask?.cancel()
        writeTask = nil
        tickerTask?.cancel()
        state = .idle
    }

    func clearHistory() {
        writeTask?.cancel()
        writeTask = nil
        tickerTask?.cancel()
        history = []
        state = .idle
    }
}
