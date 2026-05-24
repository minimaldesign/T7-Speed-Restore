import Foundation

@objc nonisolated public protocol T7HelperProtocol {
    func performFix(wholeDisk: String,
                    apfsPartition: String,
                    partitionLabel: String,
                    sizeGB: Int,
                    reply: @escaping (_ success: Bool,
                                      _ newUUID: String?,
                                      _ errorMessage: String?) -> Void)

    func ping(reply: @escaping (String) -> Void)
}

nonisolated public enum T7HelperConstants {
    public static let machServiceName = "net.mnmldsgn.t7fixer.helper"
    public static let fstabMarker = "# T7FIXER managed by Samsung T7 Fixer"
    public static let partitionLabel = "T7FIXER"
    public static let partitionSizeGB = 5
}
