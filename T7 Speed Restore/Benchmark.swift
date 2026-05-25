import Foundation
import Security

struct BenchmarkResult: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let mbPerSecond: Double
    let bytesWritten: Int64
    let elapsedSeconds: Double

    var displayString: String {
        String(format: "%.1f MB/s", mbPerSecond)
    }
}

enum BenchmarkError: LocalizedError {
    case cannotOpen
    case writeFailed
    case noVolume

    var errorDescription: String? {
        switch self {
        case .cannotOpen:
            return "Couldn't write to the drive. Make sure it's connected and not full."
        case .writeFailed:
            return "The benchmark write failed. The drive may have disconnected."
        case .noVolume:
            return "No drive selected. Drop a Samsung T7 first."
        }
    }
}

enum Benchmark {

    nonisolated static func runWrite(on volumePath: String,
                                      durationSeconds: Double = 10) async throws -> BenchmarkResult {
        try await Task.detached(priority: .userInitiated) {
            try runWriteSync(on: volumePath, durationSeconds: durationSeconds)
        }.value
    }

    nonisolated static func runWriteSync(on volumePath: String,
                                          durationSeconds: Double) throws -> BenchmarkResult {
        let tmpName = ".t7fixer-bench-\(UUID().uuidString).tmp"
        let path = (volumePath as NSString).appendingPathComponent(tmpName)

        let fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        if fd < 0 {
            throw BenchmarkError.cannotOpen
        }
        defer {
            close(fd)
            unlink(path)
        }
        _ = fcntl(fd, F_NOCACHE, 1)

        let bufSize = 1 * 1024 * 1024
        var buf = [UInt8](repeating: 0, count: bufSize)
        _ = buf.withUnsafeMutableBytes { ptr -> Int32 in
            SecRandomCopyBytes(kSecRandomDefault, ptr.count, ptr.baseAddress!)
        }

        let start = Date()
        var totalWritten: Int = 0
        while Date().timeIntervalSince(start) < durationSeconds {
            if Task.isCancelled { throw CancellationError() }
            let n = buf.withUnsafeBytes { ptr -> Int in
                write(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 {
                throw BenchmarkError.writeFailed
            }
            totalWritten += n
        }
        _ = fsync(fd)
        let elapsed = Date().timeIntervalSince(start)

        let mbps = (Double(totalWritten) / elapsed) / (1024 * 1024)
        return BenchmarkResult(
            timestamp: Date(),
            mbPerSecond: mbps,
            bytesWritten: Int64(totalWritten),
            elapsedSeconds: elapsed
        )
    }
}
