import AppKit
import ServiceManagement
import SwiftUI

/// Sundial records in the background, so closing its window only takes it out of the Dock; the menu bar item
/// with today's total stays until Quit. Clicking that item opens the window; the rarely used commands (pause,
/// open at login, Accessibility access) live in the app menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = Store()
    private lazy var recorder = Recorder(store: store)
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let pauseItem = NSMenuItem(title: "", action: #selector(togglePause(_:)), keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: String(localized: "Allow Accessibility Access…"), action: #selector(requestAccessibility(_:)), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: String(localized: "Open at Login"), action: #selector(toggleOpenAtLogin(_:)), keyEquivalent: "")

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read before anything else handles an Apple event.
        let atLogin = Self.launchedAsLoginItem
        setUpStatusItem()
        recorder.onTick = { [weak self] in
            guard let self else { return }
            // A closed window is kept, so it is left alone until it opens again.
            if window?.isVisible == true { store.noteChangesIfAny() }
            showToday()
        }
        showToday()
        registerAtLoginOnce()
        if !recorder.hasAccessibility { recorder.requestAccessibility() }
        if atLogin {
            NSApp.setActivationPolicy(.accessory)
        } else {
            openWindow(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow(nil)
        return true
    }

    @objc func openWindow(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        if window == nil { window = makeWindow() }
        store.noteChanges()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: ContentView().environmentObject(store).environmentObject(recorder))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.title = "Sundial"
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1000, height: 640))
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
        }
        return window
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Sundial")
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = String(localized: "Open Sundial")
        item.button?.target = self
        item.button?.action = #selector(openWindow(_:))
        statusItem = item
    }

    /// Today's total next to the menu bar icon, as hours and minutes
    private func showToday() {
        let seconds = Int(store.totalSeconds(in: Period.today.range()))
        statusItem?.button?.title = String(format: " %d:%02d", seconds / 3600, seconds / 60 % 60)
        statusItem?.button?.appearsDisabled = recorder.paused
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem.title = recorder.paused ? String(localized: "Resume Recording") : String(localized: "Pause Recording")
        accessibilityItem.isHidden = recorder.hasAccessibility
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func togglePause(_ sender: Any?) {
        recorder.paused.toggle()
        showToday()
    }

    @objc func requestAccessibility(_ sender: Any?) {
        recorder.requestAccessibility()
    }

    // MARK: Open at login

    /// Registers once; after that the menu bar item's toggle is the user's choice.
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

    @objc func toggleOpenAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// A login item starts in the menu bar without opening its window.
    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.delegate = self
        appMenu.addItem(withTitle: String(localized: "About Sundial"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        pauseItem.target = self
        appMenu.addItem(pauseItem)
        loginItem.target = self
        appMenu.addItem(loginItem)
        accessibilityItem.target = self
        appMenu.addItem(accessibilityItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide Sundial"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: String(localized: "Quit Sundial"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: String(localized: "File"))
        fileMenu.addItem(withTitle: String(localized: "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = editMenu

        let viewMenu = NSMenu(title: String(localized: "View"))
        viewMenu.addItem(withTitle: String(localized: "Toggle Sidebar"), action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s").keyEquivalentModifierMask = [.command, .control]
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = viewMenu

        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
