import Foundation
import Carbon.HIToolbox

enum OsascriptBridgeError: LocalizedError {
    case cancelled
    case scriptFailed(detail: String)
    case noUUIDInOutput
    case appleScriptFailure
    case tempFileFailure

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The fix was cancelled before it could finish."
        case .scriptFailed(let detail):
            return "Something went wrong while applying the fix. \(detail)"
        case .noUUIDInOutput:
            return "The fix ran but the result couldn't be confirmed. Check Disk Utility to see whether a T7FIXER partition exists, and try again if it doesn't."
        case .appleScriptFailure:
            return "Could not start the privileged step. Try restarting the app."
        case .tempFileFailure:
            return "Could not create a temporary script file. Make sure your disk has free space and try again."
        }
    }
}

final class OsascriptBridge: @unchecked Sendable {
    static let shared = OsascriptBridge()
    private init() {}

    nonisolated func performFix(on drive: T7Drive) async throws -> String {
        let bash = makeBashScript(
            wholeDisk: drive.wholeDisk,
            apfsPartition: drive.apfsPartition,
            label: T7HelperConstants.partitionLabel,
            sizeGB: T7HelperConstants.partitionSizeGB,
            marker: T7HelperConstants.fstabMarker
        )

        return try await Task.detached(priority: .userInitiated) {
            try OsascriptBridge.runWithAdminPrivileges(bash: bash)
        }.value
    }

    /// Builds the bash script that runs (as root) inside the
    /// AppleScript `do shell script ... with administrator privileges` call.
    ///
    /// The script:
    ///   1. Validates the disk is external/removable.
    ///   2. Removes any pre-existing T7FIXER partitions and grows APFS back.
    ///   3. Shrinks the APFS container by `sizeGB` GiB.
    ///   4. Adds a fresh exFAT T7FIXER partition in the freed space.
    ///   5. Attempts to write /etc/fstab (best-effort; the LaunchAgent
    ///      installed by Swift handles the cross-replug hiding if this
    ///      fails, which it does on Sequoia+ via osascript elevation).
    ///   6. Unmounts the new partition.
    ///
    /// A run-by-run debug log is written to /tmp/t7fixer-debug.log (it
    /// truncates on each run). Only `RESULT_UUID=` and `RESULT_PART=` go
    /// to stdout, which is what AppleScript hands back to Swift.
    private nonisolated func makeBashScript(wholeDisk: String,
                                             apfsPartition: String,
                                             label: String,
                                             sizeGB: Int,
                                             marker: String) -> String {
        return """
        #!/bin/bash
        set -euo pipefail

        WHOLE_DISK='\(wholeDisk)'
        APFS_PART='\(apfsPartition)'
        LABEL='\(label)'
        SIZE='\(sizeGB)G'
        MARKER='\(marker)'

        DEBUG_LOG=/tmp/t7fixer-debug.log
        : > "$DEBUG_LOG" || true
        chmod 666 "$DEBUG_LOG" 2>/dev/null || true
        debug() { echo "[$(date '+%H:%M:%S')] $*" >> "$DEBUG_LOG"; }
        debug "=== T7Fixer script start ==="
        debug "WHOLE_DISK=$WHOLE_DISK APFS_PART=$APFS_PART LABEL=$LABEL SIZE=$SIZE"

        if ! [[ "$WHOLE_DISK" =~ ^disk[2-9][0-9]*$ ]]; then
            echo "The selected drive isn't a removable disk we can safely modify." >&2
            exit 64
        fi

        plist_bool() {
            diskutil info -plist "$WHOLE_DISK" 2>/dev/null \
                | plutil -extract "$1" raw - 2>/dev/null \
                || echo ""
        }

        if [ "$(plist_bool Internal)" = "true" ]; then
            echo "Refusing to modify an internal disk." >&2
            exit 64
        fi

        if [ "$(plist_bool Ejectable)" != "true" ] \
           && [ "$(plist_bool RemovableMedia)" != "true" ] \
           && [ "$(plist_bool Removable)" != "true" ]; then
            echo "The selected drive isn't reported as removable." >&2
            exit 64
        fi

        # Find a partition with a given volume label by checking each slot's
        # plist. More reliable than parsing `diskutil list` text output
        # which can wrap columns when run without a controlling terminal.
        find_partition_by_name() {
            local target="$1"
            local s PART_ID INFO NAME KEY
            for s in 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
                PART_ID="${WHOLE_DISK}s${s}"
                INFO=$(diskutil info -plist "$PART_ID" 2>/dev/null) || continue
                for KEY in VolumeName MediaName IORegistryEntryName; do
                    NAME=$(echo "$INFO" | plutil -extract "$KEY" raw - 2>/dev/null) || continue
                    if [ "$NAME" = "$target" ]; then
                        echo "$PART_ID"
                        return 0
                    fi
                done
            done
            return 1
        }

        # Find the device backing a /Volumes/<label> mount point.
        find_partition_by_mount() {
            local label="$1"
            local line dev
            line=$(/sbin/mount | grep -E " on /Volumes/${label}( |$)" | head -1) || return 1
            [ -z "$line" ] && return 1
            dev=$(echo "$line" | awk '{print $1}' | sed 's|^/dev/||')
            if [[ "$dev" =~ ^${WHOLE_DISK}s[0-9]+$ ]]; then
                echo "$dev"
                return 0
            fi
            return 1
        }

        find_partition() {
            local target="$1"
            find_partition_by_mount "$target" 2>/dev/null && return 0
            find_partition_by_name "$target" 2>/dev/null && return 0
            return 1
        }

        # ---- Step 1: clean up any pre-existing T7FIXER partitions ----
        debug "Looking for existing $LABEL partitions..."
        EXISTING=$(find_partition "$LABEL" || true)
        debug "  existing: '$EXISTING'"

        if [ -n "$EXISTING" ]; then
            debug "Cleaning up $EXISTING"
            diskutil unmount force "$EXISTING" 2>/dev/null || true
            diskutil eraseVolume free Empty "$EXISTING"
            diskutil apfs resizeContainer "$APFS_PART" 0
            # Sweep duplicates from older buggy runs
            while EXTRA=$(find_partition "$LABEL" 2>/dev/null); do
                [ -z "$EXTRA" ] && break
                debug "Sweeping extra $EXTRA"
                diskutil unmount force "$EXTRA" 2>/dev/null || true
                diskutil eraseVolume free Empty "$EXTRA"
                diskutil apfs resizeContainer "$APFS_PART" 0
            done
        fi

        # ---- Step 2: shrink APFS, then add exFAT T7FIXER ----
        # Single-step addPartition fails when the APFS container fills the
        # disk right up to the GPT secondary header (no pre-existing gap).
        # Explicit two-step resize + add works reliably.
        debug "Reading current APFS container size..."
        CURRENT_BYTES=$(diskutil info -plist "$APFS_PART" | plutil -extract Size raw -)
        debug "  size=$CURRENT_BYTES"
        if [ -z "$CURRENT_BYTES" ] || [ "$CURRENT_BYTES" -lt 1 ]; then
            echo "Could not read the drive's APFS container size." >&2
            exit 65
        fi
        TARGET_BYTES=$((CURRENT_BYTES - \(sizeGB) * 1024 * 1024 * 1024))
        debug "Shrinking APFS to $TARGET_BYTES bytes..."
        diskutil apfs resizeContainer "$APFS_PART" "$TARGET_BYTES"
        debug "Adding partition..."
        diskutil addPartition "$APFS_PART" ExFAT "$LABEL" "$SIZE"
        debug "addPartition returned"

        # ---- Step 3: find the freshly-created partition (it auto-mounts) ----
        # diskutil list can briefly lag the actual partition table update,
        # so poll until the partition is visible.
        sleep 2
        NEW_PART=""
        for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            NEW_PART=$(find_partition "$LABEL" 2>/dev/null || true)
            if [ -n "$NEW_PART" ]; then
                debug "Found new partition $NEW_PART on attempt $attempt"
                break
            fi
            sleep 1
        done
        if [ -z "$NEW_PART" ]; then
            echo "The new partition was created but couldn't be located afterwards." >&2
            exit 65
        fi

        NEW_UUID=$(diskutil info -plist "$NEW_PART" | plutil -extract VolumeUUID raw -)
        debug "UUID=$NEW_UUID"
        if [ -z "$NEW_UUID" ]; then
            echo "Could not read the new partition's UUID." >&2
            exit 65
        fi

        # ---- Step 4: best-effort /etc/fstab write ----
        # /etc/fstab is the macOS-standard place to mark a volume noauto+ro.
        # It's not writable via osascript-elevated bash on Sequoia+ (the
        # AuthorizationExecuteWithPrivileges path strips some root capabilities),
        # so we just try and continue. The Swift app installs a LaunchAgent
        # that handles the cross-replug hiding.
        TMP=$(mktemp /tmp/fstab.t7fixer.XXXXXX)
        if [ -f /etc/fstab ]; then
            grep -v "$MARKER" /etc/fstab > "$TMP" || true
        fi
        echo "UUID=$NEW_UUID none exfat ro,noauto $MARKER" >> "$TMP"
        chmod 644 "$TMP"

        FSTAB_WRITTEN=0
        if cp "$TMP" /etc/fstab 2>>"$DEBUG_LOG"; then
            FSTAB_WRITTEN=1
            debug "fstab written via cp"
        elif cat "$TMP" > /etc/fstab 2>>"$DEBUG_LOG"; then
            FSTAB_WRITTEN=1
            debug "fstab written via cat redirect"
        elif [ -x /usr/sbin/vifs ]; then
            EDITOR_SCRIPT=$(mktemp /tmp/t7fixer-editor.XXXXXX)
            printf '#!/bin/bash\\ncp "%s" "$1"\\n' "$TMP" > "$EDITOR_SCRIPT"
            chmod +x "$EDITOR_SCRIPT"
            if EDITOR="$EDITOR_SCRIPT" /usr/sbin/vifs 2>>"$DEBUG_LOG"; then
                FSTAB_WRITTEN=1
                debug "fstab written via vifs"
            fi
            rm -f "$EDITOR_SCRIPT"
        fi
        rm -f "$TMP"
        if [ "$FSTAB_WRITTEN" = "0" ]; then
            debug "fstab unwritable; LaunchAgent fallback will handle hiding"
        fi

        # ---- Step 5: unmount the new partition ----
        diskutil unmount "$NEW_PART" 2>/dev/null || true
        sleep 1
        if diskutil info "$NEW_PART" 2>/dev/null | grep -qE "Mounted:[[:space:]]+Yes"; then
            debug "Still mounted, force-unmount"
            diskutil unmount force "$NEW_PART" 2>/dev/null || true
        fi
        debug "Done"

        echo "RESULT_UUID=$NEW_UUID"
        echo "RESULT_PART=$NEW_PART"
        """
    }

    private nonisolated static func runWithAdminPrivileges(bash: String) throws -> String {
        let tmpDir = NSTemporaryDirectory()
        let scriptPath = (tmpDir as NSString).appendingPathComponent("t7fixer-\(UUID().uuidString).sh")
        do {
            try bash.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            throw OsascriptBridgeError.tempFileFailure
        }
        defer { unlink(scriptPath) }
        chmod(scriptPath, 0o700)

        let appleScriptSource = """
        do shell script "/bin/bash " & quoted form of "\(scriptPath)" with administrator privileges
        """

        guard let script = NSAppleScript(source: appleScriptSource) else {
            throw OsascriptBridgeError.appleScriptFailure
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo = errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            let raw = (errorInfo[NSAppleScript.errorMessage] as? String) ?? ""
            if code == Int(errAEEventNotPermitted) || code == -128 {
                throw OsascriptBridgeError.cancelled
            }
            throw OsascriptBridgeError.scriptFailed(detail: friendlyDetail(from: raw))
        }

        let stdout = result.stringValue ?? ""
        guard let uuid = extractResultUUID(from: stdout) else {
            throw OsascriptBridgeError.noUUIDInOutput
        }
        return uuid
    }

    /// Picks the most-useful sentence out of a typically-noisy bash stderr
    /// for surfacing to the user. Falls back to a generic line if nothing
    /// looks human-readable.
    private nonisolated static func friendlyDetail(from raw: String) -> String {
        let lines = raw.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        // Look for the last non-empty, non-shellish-looking line.
        for line in lines.reversed() {
            if line.isEmpty { continue }
            if line.contains("set -") { continue }
            if line.hasPrefix("+") { continue }
            return line
        }
        return "See /tmp/t7fixer-debug.log for details."
    }

    /// NSAppleScript / `do shell script` returns multi-line output with
    /// classic-Mac CR (\r) line endings rather than Unix LF (\n). Split on
    /// any Unicode newline to be robust.
    private nonisolated static func extractResultUUID(from stdout: String) -> String? {
        for line in stdout.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("RESULT_UUID=") {
                return String(line.dropFirst("RESULT_UUID=".count))
            }
        }
        return nil
    }
}
