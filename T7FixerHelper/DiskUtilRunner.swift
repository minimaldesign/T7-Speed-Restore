import Foundation

struct DiskUtilResult {
    let stdout: Data
    let stderr: String
    let exitCode: Int32
    var ok: Bool { exitCode == 0 }
}

enum DiskUtilError: Error, CustomStringConvertible {
    case nonZeroExit(command: String, exitCode: Int32, stderr: String)
    case parseFailure(String)

    var description: String {
        switch self {
        case .nonZeroExit(let cmd, let code, let err):
            return "`\(cmd)` exited \(code): \(err)"
        case .parseFailure(let msg):
            return "Parse failure: \(msg)"
        }
    }
}

enum DiskUtilRunner {
    @discardableResult
    static func run(_ args: [String]) throws -> DiskUtilResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let result = DiskUtilResult(
            stdout: outData,
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: proc.terminationStatus
        )
        if !result.ok {
            throw DiskUtilError.nonZeroExit(
                command: "diskutil " + args.joined(separator: " "),
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return result
    }

    static func plist(_ args: [String]) throws -> [String: Any] {
        let result = try run(args)
        guard let plist = try PropertyListSerialization.propertyList(
            from: result.stdout, options: [], format: nil
        ) as? [String: Any] else {
            throw DiskUtilError.parseFailure("diskutil output not a plist dict")
        }
        return plist
    }

    static func findPartition(named label: String, onWholeDisk wholeDisk: String) throws -> String? {
        let plist = try plist(["list", "-plist", wholeDisk])
        guard let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return nil
        }
        for disk in allDisks {
            if let partitions = disk["Partitions"] as? [[String: Any]] {
                for part in partitions {
                    if let name = part["VolumeName"] as? String, name == label,
                       let bsdName = part["DeviceIdentifier"] as? String {
                        return bsdName
                    }
                }
            }
            if let apfsVolumes = disk["APFSVolumes"] as? [[String: Any]] {
                for vol in apfsVolumes {
                    if let name = vol["Name"] as? String, name == label,
                       let bsdName = vol["DeviceIdentifier"] as? String {
                        return bsdName
                    }
                }
            }
        }
        return nil
    }

    static func readSizeBytes(of bsdName: String) throws -> Int64 {
        let info = try plist(["info", "-plist", bsdName])
        if let n = info["Size"] as? Int64 { return n }
        if let n = info["Size"] as? Int { return Int64(n) }
        if let n = info["Size"] as? NSNumber { return n.int64Value }
        if let n = info["TotalSize"] as? Int64 { return n }
        if let n = info["TotalSize"] as? Int { return Int64(n) }
        if let n = info["TotalSize"] as? NSNumber { return n.int64Value }
        throw DiskUtilError.parseFailure("no Size for \(bsdName)")
    }

    static func volumeUUID(of bsdName: String) throws -> String {
        let plist = try plist(["info", "-plist", bsdName])
        if let uuid = plist["VolumeUUID"] as? String, !uuid.isEmpty {
            return uuid
        }
        if let uuid = plist["DiskUUID"] as? String, !uuid.isEmpty {
            return uuid
        }
        throw DiskUtilError.parseFailure("no UUID for \(bsdName)")
    }

    static func isRemovable(wholeDisk: String) throws -> Bool {
        let plist = try plist(["info", "-plist", wholeDisk])
        let internalFlag = plist["Internal"] as? Bool ?? true
        let removable = plist["Removable"] as? Bool ?? false
        let ejectable = plist["Ejectable"] as? Bool ?? false
        return !internalFlag && (removable || ejectable)
    }
}
