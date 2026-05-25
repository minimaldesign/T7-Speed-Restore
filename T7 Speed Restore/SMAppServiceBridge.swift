import Foundation
import ServiceManagement

enum SMAppServiceBridgeError: LocalizedError {
    case helperRegistrationFailed
    case helperNotApproved
    case connectionFailed
    case fixFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperRegistrationFailed:
            return "Couldn't install the background helper. Try restarting the app."
        case .helperNotApproved:
            return "Approve the background helper in System Settings, then click Fix again. (System Settings should have opened for you.)"
        case .connectionFailed:
            return "Couldn't connect to the background helper. Try restarting the app."
        case .fixFailed(let msg):
            return msg.isEmpty ? "Something went wrong while applying the fix." : msg
        }
    }
}

final class SMAppServiceBridge: @unchecked Sendable {
    static let shared = SMAppServiceBridge()

    private let helperPlistName = "net.mnmldsgn.t7fixer.helper.plist"

    private init() {}

    nonisolated func installIfNeeded() throws {
        let daemon = SMAppService.daemon(plistName: helperPlistName)
        switch daemon.status {
        case .enabled:
            return
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            throw SMAppServiceBridgeError.helperNotApproved
        case .notRegistered, .notFound:
            do {
                try daemon.register()
            } catch {
                throw SMAppServiceBridgeError.helperRegistrationFailed
            }
            if daemon.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                throw SMAppServiceBridgeError.helperNotApproved
            }
        @unknown default:
            throw SMAppServiceBridgeError.helperRegistrationFailed
        }
    }

    nonisolated func performFix(on drive: T7Drive) async throws -> String {
        try installIfNeeded()

        let box = ResumeBox()

        return try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(
                machServiceName: T7HelperConstants.machServiceName,
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(with: T7HelperProtocol.self)

            connection.invalidationHandler = {
                box.resumeFailure(continuation, .connectionFailed)
            }
            connection.interruptionHandler = {
                box.resumeFailure(continuation, .connectionFailed)
            }
            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                box.resumeFailure(continuation, .connectionFailed)
            } as? T7HelperProtocol

            guard let proxy = proxy else {
                connection.invalidate()
                box.resumeFailure(continuation, .connectionFailed)
                return
            }

            proxy.performFix(
                wholeDisk: drive.wholeDisk,
                apfsPartition: drive.apfsPartition,
                partitionLabel: T7HelperConstants.partitionLabel,
                sizeGB: T7HelperConstants.partitionSizeGB
            ) { success, newUUID, errorMessage in
                connection.invalidate()
                if success, let uuid = newUUID {
                    box.resumeSuccess(continuation, uuid)
                } else {
                    box.resumeFailure(continuation, .fixFailed(errorMessage ?? "Unknown error"))
                }
            }
        }
    }
}

private nonisolated final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resumeSuccess(_ c: CheckedContinuation<String, Error>, _ value: String) {
        lock.lock()
        let shouldResume = !done
        done = true
        lock.unlock()
        if shouldResume { c.resume(returning: value) }
    }

    func resumeFailure(_ c: CheckedContinuation<String, Error>, _ error: SMAppServiceBridgeError) {
        lock.lock()
        let shouldResume = !done
        done = true
        lock.unlock()
        if shouldResume { c.resume(throwing: error) }
    }
}
