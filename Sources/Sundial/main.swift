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
        today = String(format: "%d:%02d", seconds / 3600, seconds / 60 % 60)
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
