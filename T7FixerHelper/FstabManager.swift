import Foundation

enum FstabError: Error, CustomStringConvertible {
    case writeFailed(String)
    var description: String {
        switch self {
        case .writeFailed(let msg): return "fstab write failed: \(msg)"
        }
    }
}

enum FstabManager {
    static let path = "/etc/fstab"

    static func rewrite(removingLinesContaining marker: String, appending newLine: String) throws {
        let existing: String
        if FileManager.default.fileExists(atPath: path) {
            existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        } else {
            existing = ""
        }
        var kept = existing
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(marker) }
            .joined(separator: "\n")
        if !kept.isEmpty && !kept.hasSuffix("\n") {
            kept += "\n"
        }
        kept += newLine + "\n"

        // /etc/fstab on modern macOS is protected against rename(2) even for
        // root. Write directly to the path using open/write semantics.
        do {
            try kept.write(toFile: path, atomically: false, encoding: .utf8)
            chmod(path, 0o644)
            return
        } catch {
            // Fall through to vifs fallback below
        }

        // Fallback: use vifs with a scripted EDITOR
        let tmpDir = NSTemporaryDirectory()
        let contentPath = (tmpDir as NSString)
            .appendingPathComponent("t7fixer-fstab-\(UUID().uuidString)")
        let editorPath = (tmpDir as NSString)
            .appendingPathComponent("t7fixer-editor-\(UUID().uuidString).sh")
        defer {
            unlink(contentPath)
            unlink(editorPath)
        }

        do {
            try kept.write(toFile: contentPath, atomically: true, encoding: .utf8)
            let editorScript = "#!/bin/bash\ncp \"\(contentPath)\" \"$1\"\n"
            try editorScript.write(toFile: editorPath, atomically: true, encoding: .utf8)
            chmod(editorPath, 0o755)
        } catch {
            throw FstabError.writeFailed("Could not prepare vifs editor: \(error.localizedDescription)")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/vifs")
        proc.environment = ProcessInfo.processInfo.environment.merging(["EDITOR": editorPath]) { _, new in new }
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                throw FstabError.writeFailed("vifs exited \(proc.terminationStatus)")
            }
        } catch let e as FstabError {
            throw e
        } catch {
            throw FstabError.writeFailed("vifs invocation: \(error.localizedDescription)")
        }
    }
}
