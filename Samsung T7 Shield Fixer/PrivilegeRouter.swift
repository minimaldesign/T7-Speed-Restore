import Foundation
import Security

enum PrivilegePath: String, Sendable {
    case smAppService
    case osascript

    var description: String {
        switch self {
        case .smAppService: return "SMAppService helper"
        case .osascript: return "AppleScript admin shell"
        }
    }
}

final class PrivilegeRouter: @unchecked Sendable {
    static let shared = PrivilegeRouter()
    private init() {}

    nonisolated func detectPath() -> PrivilegePath {
        guard let teamID = readOwnTeamIdentifier(), !teamID.isEmpty else {
            return .osascript
        }
        return .smAppService
    }

    nonisolated func performFix(on drive: T7Drive) async throws -> String {
        let uuid: String
        switch detectPath() {
        case .smAppService:
            uuid = try await SMAppServiceBridge.shared.performFix(on: drive)
        case .osascript:
            uuid = try await OsascriptBridge.shared.performFix(on: drive)
        }

        // Install/refresh the LaunchAgent that auto-unmounts T7FIXER on
        // mount. This is the cross-replug "hide the volume" mechanism
        // when /etc/fstab isn't writable on this macOS version.
        // Best-effort: if it fails, the fix itself still succeeded.
        try? MountWatcher.installIfPossible(
            partitionLabel: T7HelperConstants.partitionLabel
        )

        return uuid
    }

    private nonisolated func readOwnTeamIdentifier() -> String? {
        var codeRef: SecCode?
        let copyStatus = SecCodeCopySelf([], &codeRef)
        guard copyStatus == errSecSuccess, let codeRef = codeRef else {
            return nil
        }

        var infoDict: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            codeRef as! SecStaticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoDict
        )
        guard infoStatus == errSecSuccess, let info = infoDict as? [String: Any] else {
            return nil
        }

        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
