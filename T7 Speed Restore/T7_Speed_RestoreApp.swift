//
//  T7_Speed_RestoreApp.swift
//  T7 Speed Restore
//
//  Created by Yann on 5/23/26.
//

import AppKit
import SwiftUI

@main
struct T7_Speed_RestoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A fix can run for over an hour, and a user who thinks it's stuck will
    /// reach for Quit. Whether quitting stops the root shell mid-resize is
    /// not something we want to find out on someone's drive, so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard FixCoordinator.isAnyFixRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The fix is still running"
        alert.informativeText = "Quitting now may interrupt macOS while it moves data on the drive, which can damage files. The progress shows what the fix is doing. It can take over an hour on a large drive."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
