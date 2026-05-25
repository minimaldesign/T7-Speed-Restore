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

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var latest: BenchmarkResult? { history.first }
    var previous: BenchmarkResult? { history.count > 1 ? history[1] : nil }

    func runBenchmark(on drive: T7Drive) async {
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

        do {
            let result = try await Benchmark.runWrite(on: drive.mountPath, durationSeconds: 10)
            tickerTask?.cancel()
            history.insert(result, at: 0)
            if history.count > 5 { history = Array(history.prefix(5)) }
            state = .idle
        } catch {
            tickerTask?.cancel()
            state = .failed(message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    func clearHistory() {
        history = []
        state = .idle
    }
}
