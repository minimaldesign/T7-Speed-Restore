import Foundation

enum T7Detector {

    nonisolated static func detect(at url: URL) async throws -> T7Drive {
        guard url.isFileURL else { throw T7DetectionError.notAVolume }
        let path = url.path

        let volInfo: [String: Any]
        do {
            volInfo = try runDiskutilPlist(["info", "-plist", path])
        } catch {
            throw T7DetectionError.diskutilFailure(String(describing: error))
        }

        let fs = (volInfo["FilesystemName"] as? String)
            ?? (volInfo["FilesystemType"] as? String)
            ?? ""
        if !["APFS", "Apple File System", "HFS+", "Mac OS Extended", "Mac OS Extended (Journaled)"].contains(fs) {
            throw T7DetectionError.unsupportedFilesystem(name: fs.isEmpty ? "unknown" : fs)
        }

        // Resolve the physical GPT partition that holds this volume.
        // For APFS, the volume's ParentWholeDisk is the SYNTHESIZED APFS
        // container disk (e.g., disk5), not the physical disk. The actual
        // physical GPT partition is the container's APFSPhysicalStore.
        let apfsPartition: String
        var containerFreeSpace: Int64 = 0
        if let containerRef = nonEmpty(volInfo["APFSContainerReference"] as? String) {
            let containerInfo = try runDiskutilPlist(["info", "-plist", containerRef])
            guard let stores = containerInfo["APFSPhysicalStores"] as? [[String: Any]],
                  let firstStore = stores.first,
                  let storeID = nonEmpty(firstStore["APFSPhysicalStore"] as? String)
                                ?? nonEmpty(firstStore["DeviceIdentifier"] as? String) else {
                throw T7DetectionError.diskutilFailure(
                    "Could not resolve physical store for APFS container \(containerRef)")
            }
            apfsPartition = storeID
            containerFreeSpace = readInt64(containerInfo["FreeSpace"])
        } else {
            apfsPartition = nonEmpty(volInfo["DeviceIdentifier"] as? String) ?? ""
        }

        if apfsPartition.isEmpty {
            throw T7DetectionError.noParentDisk
        }

        // Now derive the actual physical whole disk from the physical store
        // partition. For "disk4s2", parent is "disk4".
        let physicalInfo: [String: Any]
        do {
            physicalInfo = try runDiskutilPlist(["info", "-plist", apfsPartition])
        } catch {
            throw T7DetectionError.diskutilFailure("physical partition: \(error)")
        }

        guard let wholeDisk = nonEmpty(physicalInfo["ParentWholeDisk"] as? String) else {
            throw T7DetectionError.noParentDisk
        }

        // If the "physical store" IS the whole disk, this is whole-disk APFS
        // with no GPT — refuse.
        if apfsPartition == wholeDisk {
            throw T7DetectionError.wholeDiskAPFS
        }

        let wholeInfo: [String: Any]
        do {
            wholeInfo = try runDiskutilPlist(["info", "-plist", wholeDisk])
        } catch {
            throw T7DetectionError.diskutilFailure("parent disk: \(error)")
        }

        let isInternal = wholeInfo["Internal"] as? Bool ?? true
        if isInternal { throw T7DetectionError.internalDisk }

        let removable = (wholeInfo["RemovableMedia"] as? Bool ?? false)
            || (wholeInfo["Removable"] as? Bool ?? false)
            || (wholeInfo["Ejectable"] as? Bool ?? false)
        if !removable { throw T7DetectionError.internalDisk }

        let model = nonEmpty(wholeInfo["MediaName"] as? String)
            ?? nonEmpty(wholeInfo["IORegistryEntryName"] as? String)
            ?? nonEmpty(wholeInfo["DeviceModel"] as? String)
            ?? "Unknown"
        if !isSamsungT7(model: model) {
            throw T7DetectionError.notSamsungT7(model: model)
        }

        // Free-space sanity check (only applies when we have an APFS container)
        if containerFreeSpace > 0 {
            let neededGB = T7HelperConstants.partitionSizeGB + 1
            let neededBytes = Int64(neededGB) * 1_073_741_824
            if containerFreeSpace < neededBytes {
                let freeGB = Double(containerFreeSpace) / 1_073_741_824
                throw T7DetectionError.notEnoughFreeSpace(neededGB: neededGB, freeGB: freeGB)
            }
        }

        let volSize = readInt64(volInfo["TotalSize"])
        let wholeSize = readInt64(wholeInfo["TotalSize"])

        let t7fixerPart = try? findExistingT7Fixer(onWholeDisk: wholeDisk)

        let extras = try extraGPTPartitions(onWholeDisk: wholeDisk,
                                            apfsBackingPartition: apfsPartition)
        if !extras.isEmpty {
            throw T7DetectionError.extraGPTPartitions(names: extras)
        }

        return T7Drive(
            wholeDisk: wholeDisk,
            apfsPartition: apfsPartition,
            mountPath: path,
            model: model,
            sizeBytes: wholeSize > 0 ? wholeSize : volSize,
            filesystem: fs,
            t7fixerPartition: t7fixerPart
        )
    }

    private nonisolated static func nonEmpty(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return nil }
        return s
    }

    private nonisolated static func readInt64(_ any: Any?) -> Int64 {
        if let i = any as? Int64 { return i }
        if let i = any as? Int { return Int64(i) }
        if let i = any as? UInt64 { return Int64(i) }
        if let n = any as? NSNumber { return n.int64Value }
        return 0
    }

    private nonisolated static func isSamsungT7(model: String) -> Bool {
        let lowered = model.lowercased()
        if lowered.contains("portable ssd t7") { return true }
        if lowered.contains("t7 shield") { return true }
        if lowered.contains("t7 touch") { return true }
        if lowered.contains("samsung") && lowered.contains("t7") { return true }
        return false
    }

    private nonisolated static func extraGPTPartitions(onWholeDisk wholeDisk: String,
                                                        apfsBackingPartition: String) throws -> [String] {
        let plist = try runDiskutilPlist(["list", "-plist", wholeDisk])
        guard let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }
        guard let physical = allDisks.first(where: {
            ($0["DeviceIdentifier"] as? String) == wholeDisk
        }) else {
            return []
        }
        guard let partitions = physical["Partitions"] as? [[String: Any]] else {
            return []
        }

        var extras: [String] = []
        for part in partitions {
            let bsdName = part["DeviceIdentifier"] as? String ?? ""
            let content = part["Content"] as? String ?? ""
            let volName = part["VolumeName"] as? String ?? ""

            if content == "EFI" { continue }
            if bsdName == apfsBackingPartition { continue }
            if volName == T7HelperConstants.partitionLabel { continue }

            let label = volName.isEmpty ? bsdName : volName
            extras.append(label)
        }
        return extras
    }

    private nonisolated static func findExistingT7Fixer(onWholeDisk wholeDisk: String) throws -> String? {
        let plist = try runDiskutilPlist(["list", "-plist", wholeDisk])
        guard let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return nil
        }
        for disk in allDisks {
            if let partitions = disk["Partitions"] as? [[String: Any]] {
                for part in partitions {
                    if let name = part["VolumeName"] as? String, name == "T7FIXER",
                       let id = part["DeviceIdentifier"] as? String {
                        return id
                    }
                }
            }
        }
        return nil
    }

    private nonisolated static func runDiskutilPlist(_ args: [String]) throws -> [String: Any] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        if proc.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            throw T7DetectionError.diskutilFailure("exit \(proc.terminationStatus): \(err)")
        }
        guard let plist = try PropertyListSerialization.propertyList(
            from: out, options: [], format: nil
        ) as? [String: Any] else {
            throw T7DetectionError.diskutilFailure("could not parse plist output")
        }
        return plist
    }
}
