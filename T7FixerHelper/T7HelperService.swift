import Foundation

final class T7HelperService: NSObject, T7HelperProtocol {

    func ping(reply: @escaping (String) -> Void) {
        reply("pong")
    }

    func performFix(wholeDisk: String,
                    apfsPartition: String,
                    partitionLabel: String,
                    sizeGB: Int,
                    reply: @escaping (Bool, String?, String?) -> Void) {

        guard validateWholeDiskIdentifier(wholeDisk),
              validatePartitionIdentifier(apfsPartition, on: wholeDisk),
              validatePartitionLabel(partitionLabel),
              sizeGB > 0 && sizeGB <= 50 else {
            reply(false, nil, "Invalid input parameters")
            return
        }

        do {
            guard try DiskUtilRunner.isRemovable(wholeDisk: wholeDisk) else {
                reply(false, nil, "Refusing to operate on non-removable disk \(wholeDisk)")
                return
            }

            if let existing = try DiskUtilRunner.findPartition(named: partitionLabel,
                                                                onWholeDisk: wholeDisk) {
                _ = try? DiskUtilRunner.run(["unmount", "force", existing])
                try DiskUtilRunner.run(["eraseVolume", "free", "Empty", existing])
                try DiskUtilRunner.run(["apfs", "resizeContainer", apfsPartition, "0"])
            }

            // Two-step shrink-and-add. Single-step `addPartition` fails on
            // T7s whose APFS container fills the disk (no pre-existing gap).
            let currentSize = try DiskUtilRunner.readSizeBytes(of: apfsPartition)
            let targetSize = currentSize - Int64(sizeGB) * 1_073_741_824
            try DiskUtilRunner.run(["apfs", "resizeContainer", apfsPartition, "\(targetSize)"])
            try DiskUtilRunner.run([
                "addPartition", apfsPartition, "ExFAT", partitionLabel, "\(sizeGB)G"
            ])

            // diskutil list can briefly lag — retry until the new partition
            // appears, up to ~8 seconds.
            var newPart: String? = nil
            for _ in 0..<8 {
                if let found = try DiskUtilRunner.findPartition(named: partitionLabel,
                                                                onWholeDisk: wholeDisk) {
                    newPart = found
                    break
                }
                Thread.sleep(forTimeInterval: 1.0)
            }
            guard let newPart = newPart else {
                reply(false, nil, "New \(partitionLabel) partition not found after creation")
                return
            }

            let newUUID = try DiskUtilRunner.volumeUUID(of: newPart)

            // Write fstab BEFORE unmount so diskarbitrationd sees noauto,ro
            // and doesn't re-mount the volume after we unmount it.
            let fstabLine = "UUID=\(newUUID) none exfat ro,noauto \(T7HelperConstants.fstabMarker)"
            try FstabManager.rewrite(
                removingLinesContaining: T7HelperConstants.fstabMarker,
                appending: fstabLine
            )

            _ = try? DiskUtilRunner.run(["unmount", newPart])
            Thread.sleep(forTimeInterval: 1.0)
            if let info = try? DiskUtilRunner.plist(["info", "-plist", newPart]),
               let mounted = info["Mounted"] as? Bool, mounted {
                _ = try? DiskUtilRunner.run(["unmount", "force", newPart])
            }

            reply(true, newUUID, nil)
        } catch {
            reply(false, nil, String(describing: error))
        }
    }

    private func validateWholeDiskIdentifier(_ s: String) -> Bool {
        let pattern = #"^disk[0-9]+$"#
        return s.range(of: pattern, options: .regularExpression) != nil
            && s != "disk0" && s != "disk1"
    }

    private func validatePartitionIdentifier(_ s: String, on wholeDisk: String) -> Bool {
        let pattern = #"^\#(wholeDisk)s[0-9]+$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    private func validatePartitionLabel(_ s: String) -> Bool {
        let pattern = #"^[A-Z0-9]{1,11}$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }
}
