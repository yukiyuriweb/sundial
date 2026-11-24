import AppKit
import ServiceManagement
import SwiftUI

/// Owns the store and the recorder for the life of the app, and keeps today's total for the menu bar
@MainActor
final class AppModel: ObservableObject {
    let store = Store()
    let recorder: Recorder
    @Published private(set) var today = ""
    /// Views reload only while the panel is open
    var panelOpen = false {
        didSet { if panelOpen { store.noteChanges() } }
    }

    init() {
        recorder = Recorder(store: store)
        recorder.onTick = { [weak self] in
            guard let self else { return }
            if panelOpen { store.noteChangesIfAny() }
            showToday()
        }
        showToday()
        registerAtLoginOnce()
        if !recorder.hasAccessibility { recorder.requestAccessibility() }
    }

    /// Today's total as hours and minutes
    private func showToday() {
        let seconds = Int(store.totalSeconds(in: Period.today.range()))
        let text = String(format: "%d:%02d", seconds / 3600, seconds / 60 % 60)
        // Assigned only on change, since every assignment redraws the menu bar label and the panel
        if text != today { today = text }
    }

    /// Registers once; after that the panel's Open at Login toggle is the user's choice.
    private func registerAtLoginOnce() {
        let key = "registeredOpenAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("Sundial couldn't register to open at login: %@", error.localizedDescription)
        }
    }
}

/// Sundial lives in the menu bar only: its item shows today's total, and clicking it opens a panel with the
/// overview, as MemoryLens does. A panel needs no activation, so it always opens in front.
struct SundialApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.recorder)
        } label: {
            MenuBarLabel(model: model, recorder: model.recorder)
        }
        .menuBarExtraStyle(.window)
    }
}

/// With no Dock icon or menus, the menu bar item is the only way in. Where it can't be seen (no room beside the
/// notch, or turned off in System Settings), opening Sundial again from the Finder or Spotlight says where it
/// is and offers to quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Sundial is running in the menu bar")
        alert.informativeText = String(localized: "Click its icon and today's total in the menu bar to see the overview. If you can't see it, the menu bar may have no room for it, or it may be turned off in System Settings › Menu Bar.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Quit Sundial"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil) }
        return false
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: Recorder

    var body: some View {
        Image(systemName: recorder.paused ? "pause.circle" : "sun.max")
        Text(model.today)
    }
}

// A hook command: never start the app from here, even when the tool name is missing.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "agent" {
    if CommandLine.arguments.count >= 3 {
        runAgentHook(tool: CommandLine.arguments[2])
    } else {
        print("{}")
    }
    exit(0)
}

SundialApp.main()
