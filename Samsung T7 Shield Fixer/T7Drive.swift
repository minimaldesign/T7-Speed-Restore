import Foundation

struct T7Drive: Equatable, Sendable {
    let wholeDisk: String
    let apfsPartition: String
    let mountPath: String
    let model: String
    let sizeBytes: Int64
    let filesystem: String
    let t7fixerPartition: String?

    var sizeDescription: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sizeBytes)
    }

    var displaySummary: String {
        "\(model), \(sizeDescription), /dev/\(wholeDisk)"
    }
}

enum T7DetectionError: LocalizedError {
    case notAVolume
    case internalDisk
    case notSamsungT7(model: String)
    case unsupportedFilesystem(name: String)
    case wholeDiskAPFS
    case noParentDisk
    case notEnoughFreeSpace(neededGB: Int, freeGB: Double)
    case extraGPTPartitions(names: [String])
    case diskutilFailure(String)

    var errorDescription: String? {
        switch self {
        case .notAVolume:
            return "That isn't a mounted volume. Drag the drive's icon from Finder (or its mount point in /Volumes)."
        case .internalDisk:
            return "This is an internal disk. Only external Samsung T7 drives are supported."
        case .notSamsungT7(let model):
            if model.isEmpty || model == "Unknown" {
                return "This doesn't look like a Samsung T7. Only the T7, T7 Shield, and T7 Touch are supported."
            }
            return "This is a \(model). Only the Samsung T7, T7 Shield, and T7 Touch are supported."
        case .unsupportedFilesystem(let name):
            return "This drive is formatted as \(name). Back up its data and reformat to APFS in Disk Utility, then try again."
        case .wholeDiskAPFS:
            return "This drive is APFS-formatted without a GPT partition table. Reformat it in Disk Utility (choose APFS, GUID Partition Map scheme), then try again."
        case .noParentDisk:
            return "Could not identify the drive's hardware. Try unplugging and replugging the drive."
        case .notEnoughFreeSpace(let needed, let free):
            return String(format: "The drive needs about %d GB of free space, but only %.1f GB is free. Delete some files and try again.", needed, free)
        case .extraGPTPartitions(let names):
            let joined = names.map { "\"\($0)\"" }.joined(separator: ", ")
            return "This drive has an extra partition (\(joined)) sitting after the main APFS partition, which prevents the fix from being applied. Back up that partition's data, delete it in Disk Utility, then try again."
        case .diskutilFailure:
            return "Couldn't read the drive's layout. Try unplugging and replugging the drive."
        }
    }
}
