import AppKit
import ApplicationServices

enum BundleID {
    static let ghostty = "com.mitchellh.ghostty"
    static let brave = "com.brave.Browser"
    static let fount = "local.fount"
    static let rejoin = "local.rejoin"
    static let markdownPreview = "doc.md-preview"
}

/// Every few seconds, notes which app is in front and what it shows, unless the screen is locked or asleep,
/// recording is paused, or there has been no keyboard or mouse input for a while.
@MainActor
final class Recorder: ObservableObject {
    static let interval: TimeInterval = 5
    /// Seconds without input after which you count as away
    static let idleLimit: TimeInterval = 180
    /// Longer for apps you mostly read in, where minutes can pass without input
    static let readingIdleLimit: TimeInterval = 600
    static let readingApps: Set<String> = [BundleID.fount, BundleID.rejoin, BundleID.markdownPreview]

    @Published var paused = UserDefaults.standard.bool(forKey: "paused") {
        didSet { UserDefaults.standard.set(paused, forKey: "paused") }
    }
    @Published private(set) var hasAccessibility = AXIsProcessTrusted()
    var onTick: (() -> Void)?

    private let store: Store
    private var timer: Timer?
    private var locked = false
    private var screensAsleep = false
    private var sessionInactive = false
    private var scripts: [String: NSAppleScript] = [:]
    private var projectCache: [String: String?] = [:]

    init(store: Store) {
        self.store = store
        let center = NSWorkspace.shared.notificationCenter
        observe(center, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(center, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        observe(center, NSWorkspace.willSleepNotification) { $0.screensAsleep = true }
        observe(center, NSWorkspace.didWakeNotification) { $0.screensAsleep = false }
        observe(center, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(center, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }

        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 1
    }

    /// Shows the system prompt that leads to Privacy & Security › Accessibility
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        hasAccessibility = AXIsProcessTrustedWithOptions(options)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping @MainActor (Recorder) -> Void) {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { change(self) } }
        }
    }

    private func tick() {
        defer { onTick?() }
        if hasAccessibility != AXIsProcessTrusted() { hasAccessibility.toggle() }
        guard !paused, !locked, !screensAsleep, !sessionInactive,
              let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { return }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard idle < (Self.readingApps.contains(bundle) ? Self.readingIdleLimit : Self.idleLimit) else { return }
        store.record(activity(of: app, bundle: bundle), at: Date(), interval: Self.interval)
    }

    // MARK: What the front app shows

    private func activity(of app: NSRunningApplication, bundle: String) -> Activity {
        let name = app.localizedName ?? bundle
        switch bundle {
        case BundleID.ghostty:
            let script = """
                tell application id "\(BundleID.ghostty)"
                    with timeout of 2 seconds
                        return working directory of focused terminal of selected tab of front window
                    end timeout
                end tell
                """
            if let cwd = runScript(script), !cwd.isEmpty {
                return Activity(bundle: bundle, app: name, project: project(forPath: cwd), detail: abbreviated(cwd))
            }
        case BundleID.brave:
            let script = """
                tell application id "\(BundleID.brave)"
                    with timeout of 2 seconds
                        return URL of active tab of front window
                    end timeout
                end tell
                """
            if let url = runScript(script).flatMap(URL.init(string:)) {
                return Activity(bundle: bundle, app: name, project: githubRepo(url), detail: pageDetail(url))
            }
        default:
            break
        }
        let window = focusedWindow(of: app.processIdentifier)
        if let document = window.document, let url = URL(string: document), url.isFileURL {
            return Activity(bundle: bundle, app: name, project: project(forPath: url.path), detail: abbreviated(url.path))
        }
        return Activity(bundle: bundle, app: name, project: nil, detail: window.title.flatMap { $0.isEmpty ? nil : $0 })
    }

    private func runScript(_ source: String) -> String? {
        let script = scripts[source] ?? NSAppleScript(source: source)
        scripts[source] = script
        var error: NSDictionary?
        return script?.executeAndReturnError(&error).stringValue
    }

    /// The document (a file URL) and title of the app's focused window, through the Accessibility API
    private func focusedWindow(of pid: pid_t) -> (document: String?, title: String?) {
        guard hasAccessibility else { return (nil, nil) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, nil) }
        let window = value as! AXUIElement
        func string(_ attribute: String) -> String? {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(window, attribute as CFString, &v)
            return v as? String
        }
        return (string(kAXDocumentAttribute), string(kAXTitleAttribute))
    }

    // MARK: Projects

    /// The name of the Git repository holding the path, looking no higher than the home folder. A linked
    /// worktree (such as one an agent made) counts as its main repository.
    private func project(forPath path: String) -> String? {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let start = isDirectory.boolValue ? path : (path as NSString).deletingLastPathComponent
        if let cached = projectCache[start] { return cached }
        let home = NSHomeDirectory()
        var dir = start
        var result: String?
        while dir.hasPrefix(home + "/") {
            let git = dir + "/.git"
            var gitIsDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git, isDirectory: &gitIsDirectory) {
                result = gitIsDirectory.boolValue ? nil : mainRepository(ofWorktree: git)
                result = result ?? (dir as NSString).lastPathComponent
                break
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        projectCache[start] = result
        return result
    }

    /// A worktree's .git file reads "gitdir: <repo>/.git/worktrees/<name>"
    private func mainRepository(ofWorktree gitFile: String) -> String? {
        guard let text = try? String(contentsOfFile: gitFile, encoding: .utf8),
              let range = text.range(of: "/.git/worktrees/") else { return nil }
        let line = text[..<range.lowerBound]
        let repo = line.hasPrefix("gitdir: ") ? line.dropFirst("gitdir: ".count) : line
        return (String(repo) as NSString).lastPathComponent
    }

    private static let githubReserved: Set<String> = [
        "settings", "notifications", "orgs", "organizations", "marketplace", "explore", "topics", "search",
        "pulls", "issues", "new", "login", "sponsors", "features", "codespaces", "dashboard",
    ]

    /// The repository name in a github.com address
    private func githubRepo(_ url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.host == "github.com", parts.count >= 2, !Self.githubReserved.contains(parts[0]) else { return nil }
        return parts[1]
    }

    /// The path for GitHub pages, so pull requests and files stay apart; only the host for other sites
    private func pageDetail(_ url: URL) -> String? {
        guard let host = url.host else { return nil }
        return host == "github.com" ? host + url.path : host
    }

    private func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
